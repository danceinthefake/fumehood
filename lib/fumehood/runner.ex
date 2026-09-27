defmodule Fumehood.Runner do
  @moduledoc """
  Runs statements that passed `Fumehood.Safety` against a target Postgres
  connection (a `Postgrex` connection).

  Every call runs in its own transaction and ends it before returning —
  nothing is left open. See DESIGN.md §5.3.

  Options (all calls):

    * `:statement_timeout` — ms, default 30_000
    * `:lock_timeout` — ms, default 5_000
    * `:max_rows` — rows returned by a read / changed by a write, default 1000
    * `:max_result_bytes` — a read stops early past this size, default 10 MB
    * `:preview` — rows shown from a write dry run, default 20
    * `:on_backend` — `fn {backend_pid, xact_start} -> any end`, called once
      the transaction has started: its Postgres backend and when this
      transaction began, which together name this transaction and no later
      one on the same pooled connection (used by `Fumehood.Queries` to
      cancel a running statement)
    * `:prepare` — `fn tx -> :ok | {:error, reason} end`, run first inside
      the transaction (used by `Fumehood.Restore` to load a backup into a
      temporary table)
  """

  alias Fumehood.Backup
  alias Fumehood.Safety
  alias Fumehood.Safety.Statement

  # The table named by $1 (schema or NULL) and $2, resolved like Postgres
  # resolves a name in the statement: NULL schema → search_path.
  @regclass """
  to_regclass(CASE WHEN $1::text IS NULL THEN format('%I', $2::text)
                   ELSE format('%I.%I', $1::text, $2::text) END)
  """

  @defaults [
    statement_timeout: 30_000,
    lock_timeout: 5_000,
    max_rows: 1000,
    max_result_bytes: 10_000_000,
    preview: 20
  ]

  # Rows come from Postgres in chunks of this many, so a huge result is never
  # held in memory at once.
  @chunk 100

  @type result :: %{columns: [String.t()], rows: [list()]}
  @type error :: {:blocked, atom(), String.t()} | {:db_error, String.t()}

  @doc """
  Runs a read inside a `READ ONLY` transaction. Results are capped at
  `:max_rows` rows and about `:max_result_bytes`; `truncated` tells whether
  more existed.
  """
  @spec read(DBConnection.conn(), Statement.t(), keyword()) ::
          {:ok, %{columns: [String.t()], rows: [list()], truncated: boolean()}}
          | {:error, error()}
  def read(conn, %Statement{kind: :read} = statement, opts \\ []) do
    opts = Keyword.merge(@defaults, opts)
    max = opts[:max_rows]

    max_bytes = opts[:max_result_bytes]

    in_transaction(conn, opts, :read_only, fn tx ->
      collect = fn row, {rows, n, bytes, _more} ->
        if n >= max or bytes >= max_bytes,
          do: {:halt, {rows, n, bytes, true}},
          else: {:cont, {[row | rows], n + 1, bytes + :erlang.external_size(row), false}}
      end

      with {:ok, {rows, _n, _bytes, more}, query} <-
             reduce_rows(tx, read_sql(statement, max + 1), [], {[], 0, 0, false}, collect) do
        {:ok,
         %{
           columns: query.columns || [],
           types: types(query),
           rows: Enum.reverse(rows),
           truncated: more
         }}
      end
    end)
  end

  @doc """
  Runs a write, counts and previews the rows it changes, then rolls back.
  Nothing is kept.

  `rows_token` identifies exactly which rows an `UPDATE` / `DELETE` touched
  (nil for `INSERT`, whose new keys aren't known until commit); pass it to
  `commit/3` as `:expected_token`.

  `warnings` names what can change *other* tables along with this one —
  triggers, cascading foreign keys — which the backup doesn't cover.
  """
  @spec dry_run(DBConnection.conn(), Statement.t(), keyword()) ::
          {:ok,
           %{
             count: non_neg_integer(),
             columns: [String.t()],
             preview: [list()],
             rows_token: String.t() | nil,
             warnings: [String.t()]
           }}
          | {:error, error()}
  def dry_run(conn, %Statement{kind: :write} = statement, opts \\ []) do
    opts = Keyword.merge(@defaults, opts)
    {max, preview} = {opts[:max_rows], opts[:preview]}

    in_transaction(conn, opts, :rollback, fn tx ->
      with :ok <- no_custom_functions(tx, statement),
           {:ok, table} <- table_info(tx, statement) do
        # RETURNING the key (as text) first, then the whole row for the preview.
        k = length(table.pk)

        collect = fn row, {keys, rows, n} ->
          {key, rest} = Enum.split(row, k)
          rows = if n < preview, do: [rest | rows], else: rows
          acc = {[key | keys], rows, n + 1}
          if n + 1 > max, do: {:halt, acc}, else: {:cont, acc}
        end

        sql =
          statement.sql <> "\nRETURNING " <> returning(statement, table, "#{target(statement)}.*")

        with {:ok, warnings} <- side_effects(tx, statement.command, table.relation),
             {:ok, {keys, rows, n}, query} <- reduce_rows(tx, sql, [], {[], [], 0}, collect),
             :ok <- within_limit(n, max) do
          {:ok,
           %{
             count: n,
             columns: Enum.drop(query.columns, k),
             types: Enum.drop(types(query), k),
             preview: Enum.reverse(rows),
             rows_token: if(statement.command == :insert, do: nil, else: rows_token(keys)),
             warnings: warnings
           }}
        end
      end
    end)
  end

  @doc """
  Commits a write after backing up the rows it changes (DESIGN.md §5.4).

  Required options:

    * `:expected_count` — the count the person confirmed from `dry_run/3`;
      if the statement would now change a different number of rows (or, for
      `UPDATE` / `DELETE`, different rows), nothing is committed

  Optional `:expected_token` (the dry run's `rows_token`): for `UPDATE` /
  `DELETE`, the rows must be exactly the ones the dry run touched — not just
  as many. When the option is given, nil never matches.
    * `:backup_dir` — where the backup files go

  Optional: `:backup_id` (default `Backup.new_id/0`), `:meta` (map merged
  into the backup's JSON, e.g. who ran it).

  `UPDATE` / `DELETE`: the rows are found with a probe inside a savepoint,
  locked, exported as CSV by `COPY`, written to disk, and only then changed
  for real. `INSERT`: the new rows' keys are recorded so they can be undone.
  """
  @spec commit(DBConnection.conn(), Statement.t(), keyword()) ::
          {:ok, %{count: non_neg_integer(), backup: %{csv: Path.t() | nil, json: Path.t()}}}
          | {:error, error()}
  def commit(conn, %Statement{kind: :write} = statement, opts) do
    opts =
      @defaults
      |> Keyword.merge(opts)
      |> Keyword.put_new_lazy(:backup_id, &Backup.new_id/0)

    Keyword.fetch!(opts, :expected_count)
    Keyword.fetch!(opts, :backup_dir)

    in_transaction(conn, opts, :commit, fn tx ->
      with :ok <- no_custom_functions(tx, statement),
           {:ok, table} <- table_info(tx, statement) do
        commit_change(tx, statement, table, opts)
      end
    end)
  end

  @doc """
  Primary key columns of a table as `[{name, type}]` in key order, `[]` when
  the table has none, or `nil` when the table doesn't exist.
  """
  @spec primary_key(DBConnection.conn(), {String.t() | nil, String.t()}) ::
          [{String.t(), String.t()}] | nil
  def primary_key(conn, {schema, name}) do
    sql = """
    SELECT a.attname, format_type(a.atttypid, a.atttypmod), r.oid IS NULL
    FROM (SELECT #{@regclass} AS oid) r
    LEFT JOIN pg_index i ON i.indrelid = r.oid AND i.indisprimary
    LEFT JOIN pg_attribute a ON a.attrelid = r.oid AND a.attnum = ANY (i.indkey)
    ORDER BY array_position(i.indkey::int2[], a.attnum)
    """

    case Postgrex.query!(conn, sql, [schema, name]).rows do
      [[nil, nil, true]] -> nil
      [[nil, nil, false]] -> []
      rows -> Enum.map(rows, fn [column, type, _] -> {column, type} end)
    end
  end

  # -- internals -------------------------------------------------------------

  # SELECTs are wrapped to cap the rows; EXPLAIN / SHOW run as they are.
  # New lines around the statement keep a trailing `-- comment` from
  # swallowing what we add.
  defp read_sql(%Statement{command: :select, sql: sql}, limit),
    do: "SELECT * FROM (\n#{sql}\n) AS fumehood_read LIMIT #{limit}"

  defp read_sql(%Statement{sql: sql}, _limit), do: sql

  # The target table: its key columns and its name as Postgres quotes it.
  # UPDATE / DELETE need a primary key (backup and restore find rows by it).
  defp table_info(tx, %Statement{table: {schema, name} = table, command: command}) do
    case primary_key(tx, table) do
      nil ->
        {:error, {:db_error, "Table #{format_table(table)} doesn't exist."}}

      [] when command != :insert ->
        blocked(
          :no_primary_key,
          "#{format_table(table)} has no primary key; its rows can't be backed up and restored reliably."
        )

      pk ->
        [[relation]] = Postgrex.query!(tx, "SELECT (#{@regclass})::text", [schema, name]).rows
        {:ok, %{pk: pk, relation: relation}}
    end
  end

  defp commit_change(tx, %Statement{command: :insert} = statement, table, opts) do
    with {:ok, keys} <- run_returning_keys(tx, statement, table, opts[:max_rows]),
         :ok <- within_limit(length(keys), opts[:max_rows]),
         :ok <- same_count(length(keys), opts[:expected_count]),
         keys = if(table.pk == [], do: [], else: keys),
         {:ok, files} <- write_backup(statement, table, keys, nil, opts),
         :ok <- put_after_hash(tx, table, keys, files) do
      {:ok, %{count: opts[:expected_count], backup: files}}
    end
  end

  defp commit_change(tx, statement, table, opts) do
    with {:ok, keys} <- probe_keys(tx, statement, table, opts[:max_rows]),
         :ok <- within_limit(length(keys), opts[:max_rows]),
         :ok <- same_count(length(keys), opts[:expected_count]),
         :ok <- same_token(keys, opts),
         {:ok, csv} <- lock_and_export(tx, table, keys),
         {:ok, files} <- write_backup(statement, table, keys, csv, opts),
         {:ok, changed} <- run_returning_keys(tx, statement, table, opts[:max_rows]),
         :ok <- same_keys(keys, changed),
         :ok <- put_after_hash(tx, table, keys, files) do
      {:ok, %{count: length(changed), backup: files}}
    end
  end

  # Which rows the statement touches: run it in a savepoint returning the
  # keys, then undo it.
  defp probe_keys(tx, statement, table, max) do
    Postgrex.query!(tx, "SAVEPOINT fumehood_probe", [])
    result = run_returning_keys(tx, statement, table, max)
    Postgrex.query!(tx, "ROLLBACK TO SAVEPOINT fumehood_probe", [])
    result
  end

  # Keys come back as text so they are JSON-safe and comparable. Stops one
  # past `max` (the caller then refuses: too many rows).
  defp run_returning_keys(tx, statement, table, max) do
    collect = fn key, {keys, n} ->
      acc = {[key | keys], n + 1}
      if n + 1 > max, do: {:halt, acc}, else: {:cont, acc}
    end

    sql = statement.sql <> "\nRETURNING " <> returning(statement, table, nil)

    with {:ok, {keys, _n}, _query} <- reduce_rows(tx, sql, [], {[], 0}, collect) do
      {:ok, if(table.pk == [], do: Enum.map(keys, fn _ -> [nil] end), else: Enum.reverse(keys))}
    end
  end

  # The RETURNING list: the target's key columns as text, then `rest` if any.
  defp returning(statement, %{pk: pk}, rest) do
    keys = Enum.map(pk, fn {column, _} -> "#{target(statement)}.#{quote_ident(column)}::text" end)

    case keys ++ List.wrap(rest) do
      [] -> "NULL"
      list -> Enum.join(list, ", ")
    end
  end

  @doc false
  # Which rows, as one opaque string (order doesn't matter).
  def rows_token(keys),
    do:
      :crypto.hash(:sha256, keys |> Enum.sort() |> JSON.encode!())
      |> Base.url_encode64(padding: false)

  defp same_token(keys, opts) do
    case Keyword.fetch(opts, :expected_token) do
      :error ->
        :ok

      {:ok, nil} ->
        blocked(:dry_run_required, "Run the dry run first, then commit the rows it showed.")

      {:ok, token} ->
        if token == rows_token(keys),
          do: :ok,
          else: changed_since_dry_run("other rows match the statement now")
    end
  end

  # Locks exactly the rows with `keys`, then exports them with COPY. Keys are
  # passed as text arrays and cast back to the column types, so the primary
  # key index is used; COPY can't take parameters, so its key list is
  # quoted by Postgres itself (quote_literal).
  defp lock_and_export(tx, %{pk: pk, relation: relation}, keys) do
    columns = Enum.map_join(pk, ", ", fn {column, _} -> quote_ident(column) end)
    params = keys |> Enum.zip() |> Enum.map(&Tuple.to_list/1) |> pad(length(pk))

    typed =
      pk
      |> Enum.with_index(1)
      |> Enum.map_join(", ", fn {{_, type}, i} -> "$#{i}::text[]::#{type}[]" end)

    text = Enum.map_join(1..length(pk), ", ", &"$#{&1}::text[]")
    names = Enum.map_join(1..length(pk), ", ", &"c#{&1}")
    literals = Enum.map_join(1..length(pk), " || ',' || ", &"quote_literal(k.c#{&1})")

    lock_sql = """
    SELECT count(*) FROM (
      SELECT 1 FROM #{relation} WHERE (#{columns}) IN (SELECT * FROM unnest(#{typed})) FOR UPDATE
    ) locked
    """

    list_sql =
      "SELECT string_agg('(' || #{literals} || ')', ',') FROM unnest(#{text}) AS k(#{names})"

    with {:ok, %{rows: [[locked]]}} <- query(tx, lock_sql, params),
         :ok <- same_count(locked, length(keys)),
         {:ok, %{rows: [[list]]}} <- query(tx, list_sql, params) do
      where = if keys == [], do: "false", else: "(#{columns}) IN (#{list})"

      copy_sql =
        "COPY (SELECT * FROM #{relation} WHERE #{where}) TO STDOUT WITH (FORMAT csv, HEADER)"

      {:ok, tx |> Postgrex.stream(copy_sql, []) |> Enum.flat_map(& &1.rows)}
    end
  end

  # The rows as this transaction left them, recorded before COMMIT: if the
  # commit fails, a restore of this backup finds different rows and refuses.
  defp put_after_hash(_tx, %{pk: []}, _keys, _files), do: :ok

  defp put_after_hash(tx, table, keys, files) do
    with {:ok, hash} <- rows_hash(tx, table, keys) do
      case Backup.put(files.json, after_hash: hash) do
        :ok -> :ok
        {:error, message} -> blocked(:backup_failed, message)
      end
    end
  end

  @doc """
  A hash of the current rows with `keys` in `table` (`%{relation, pk}` as
  from `table_info/2`, or `key_columns/2`), locked until the transaction
  ends. The same rows with the same values give the same hash.
  """
  @spec rows_hash(DBConnection.conn(), map(), [[String.t()]]) ::
          {:ok, String.t()} | {:error, error()}
  def rows_hash(tx, %{pk: pk, relation: relation}, keys) do
    columns = Enum.map_join(pk, ", ", fn {column, _} -> "t.#{quote_ident(column)}" end)
    params = keys |> Enum.zip() |> Enum.map(&Tuple.to_list/1) |> pad(length(pk))

    typed =
      pk
      |> Enum.with_index(1)
      |> Enum.map_join(", ", fn {{_, type}, i} -> "$#{i}::text[]::#{type}[]" end)

    sql = """
    SELECT md5(coalesce(string_agg(s.r::text, E'\\n' ORDER BY s.r::text), ''))
    FROM (SELECT t AS r FROM #{relation} t
          WHERE (#{columns}) IN (SELECT * FROM unnest(#{typed})) FOR UPDATE OF t) s
    """

    with {:ok, %{rows: [[hash]]}} <- query(tx, sql, params), do: {:ok, hash}
  end

  @doc """
  `%{relation, pk}` for a table named as Postgres prints it (a backup's
  `table`), with the key columns in `names` order; nil when it's gone.
  """
  @spec key_columns(DBConnection.conn(), String.t(), [String.t()]) :: map() | nil
  def key_columns(conn, relation, names) do
    sql = """
    SELECT a.attname, format_type(a.atttypid, a.atttypmod)
    FROM pg_attribute a
    WHERE a.attrelid = to_regclass($1) AND a.attname = ANY ($2) AND NOT a.attisdropped
    """

    types = Map.new(Postgrex.query!(conn, sql, [relation, names]).rows, &List.to_tuple/1)

    if map_size(types) == length(names),
      do: %{relation: relation, pk: Enum.map(names, &{&1, types[&1]})}
  end

  # A function that isn't part of Postgres and can change data (volatile)
  # may write to other tables, which the backup can't cover. Matched by name
  # (any overload), so it errs on the side of blocking.
  # ponytail: user-defined operators, casts and column defaults can call such
  # functions too; not checked (DESIGN.md §5.4).
  defp no_custom_functions(tx, statement) do
    case Enum.unzip(Safety.function_calls(statement)) do
      {[], []} ->
        :ok

      {schemas, names} ->
        sql = """
        SELECT p.oid::regproc::text
        FROM unnest($1::text[], $2::text[]) f(schema, name)
        JOIN pg_proc p ON p.proname = f.name
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE p.provolatile = 'v'
          AND n.nspname NOT IN ('pg_catalog', 'information_schema')
          AND (f.schema IS NULL OR n.nspname = f.schema)
        LIMIT 1
        """

        case query(tx, sql, [schemas, names]) do
          {:ok, %{rows: []}} ->
            :ok

          {:ok, %{rows: [[name]]}} ->
            blocked(
              :custom_function,
              "Function #{name}() isn't built into Postgres and can change data; what it changes can't be backed up. Changes may only call Postgres's own functions."
            )

          error ->
            error
        end
    end
  end

  # What else changes when this table does, outside the backup: enabled user
  # triggers, and foreign keys from other tables that cascade (or set NULL /
  # default) on this command.
  defp side_effects(tx, command, relation) do
    sql = """
    SELECT format('Trigger %I runs on this table; what it changes elsewhere isn''t backed up.', t.tgname)
    FROM pg_trigger t
    WHERE t.tgrelid = to_regclass($1) AND NOT t.tgisinternal AND t.tgenabled <> 'D'
    UNION ALL
    SELECT format('Rows in %s that reference these rows are %s (foreign key %I); they aren''t backed up.',
                  c.conrelid::regclass,
                  CASE a.action WHEN 'c' THEN $2 || 'd too' WHEN 'n' THEN 'set to NULL' ELSE 'set to their default' END,
                  c.conname)
    FROM pg_constraint c
    CROSS JOIN LATERAL (SELECT CASE $2 WHEN 'delete' THEN c.confdeltype ELSE c.confupdtype END AS action) a
    WHERE c.contype = 'f' AND c.confrelid = to_regclass($1) AND $2 <> 'insert' AND a.action IN ('c', 'n', 'd')
    """

    with {:ok, %{rows: rows}} <- query(tx, sql, [relation, Atom.to_string(command)]) do
      {:ok, List.flatten(rows)}
    end
  end

  # Enum.zip([]) is [] — keep one (empty) array per key column.
  defp pad([], columns), do: List.duplicate([], columns)
  defp pad(params, _columns), do: params

  defp write_backup(statement, table, keys, csv, opts) do
    meta =
      Map.merge(opts[:meta] || %{}, %{
        id: opts[:backup_id],
        operation: statement.command,
        table: table.relation,
        primary_key: Enum.map(table.pk, &elem(&1, 0)),
        keys: keys,
        statement: statement.sql
      })

    case Backup.write(opts[:backup_dir], meta, csv) do
      {:ok, files} -> {:ok, files}
      {:error, message} -> blocked(:backup_failed, message)
    end
  end

  defp same_count(count, count), do: :ok

  defp same_count(count, expected),
    do: changed_since_dry_run("it would now change #{count} rows, the dry run showed #{expected}")

  defp same_keys(keys, changed) do
    if Enum.sort(keys) == Enum.sort(changed),
      do: :ok,
      else: changed_since_dry_run("it changed different rows than the ones backed up")
  end

  defp changed_since_dry_run(detail),
    do:
      blocked(
        :changed_since_dry_run,
        "The data changed since the dry run (#{detail}). Nothing was committed; run the dry run again."
      )

  # How RETURNING refers to the target table: its alias, or its bare name.
  # Qualifying matters when the statement joins other tables
  # (UPDATE … FROM, DELETE … USING) that have columns with the same names.
  defp target(%Statement{alias: nil, table: {_schema, name}}), do: quote_ident(name)
  defp target(%Statement{alias: alias}), do: quote_ident(alias)

  defp quote_ident(name), do: ~s(") <> String.replace(name, ~s("), ~s("")) <> ~s(")

  defp within_limit(count, max) when count <= max, do: :ok

  defp within_limit(_count, max),
    do:
      blocked(
        :too_many_rows,
        "This would change more than #{max} rows, the limit. Split it into smaller changes."
      )

  # Opens a transaction, applies the guardrails, runs `fun`, and ends it:
  # `:read_only` and `:commit` commit when `fun` succeeds, `:rollback` always
  # rolls back. Any error rolls back.
  defp in_transaction(conn, opts, mode, fun) do
    Postgrex.transaction(conn, fn tx ->
      if mode == :read_only, do: Postgrex.query!(tx, "SET TRANSACTION READ ONLY", [])

      if on_backend = opts[:on_backend] do
        [[backend, started]] = Postgrex.query!(tx, "SELECT pg_backend_pid(), now()", []).rows
        on_backend.({backend, started})
      end

      Postgrex.query!(tx, "SET LOCAL statement_timeout = #{opts[:statement_timeout]}", [])
      Postgrex.query!(tx, "SET LOCAL lock_timeout = #{opts[:lock_timeout]}", [])

      prepare = opts[:prepare] || fn _tx -> :ok end

      case with(:ok <- prepare.(tx), do: fun.(tx)) do
        {:ok, value} when mode == :rollback -> Postgrex.rollback(tx, {:ok, value})
        {:ok, value} -> value
        {:error, reason} -> Postgrex.rollback(tx, {:error, reason})
      end
    end)
    |> case do
      {:ok, value} -> {:ok, value}
      {:error, {:ok, value}} -> {:ok, value}
      {:error, {:error, reason}} -> {:error, reason}
    end
  rescue
    # A statement of ours (e.g. SET LOCAL) failing — or being cancelled —
    # has already rolled the transaction back; report it like any other
    # database error instead of crashing the caller.
    e in Postgrex.Error -> {:error, {:db_error, Exception.message(e)}}
  end

  # Streams the result rows of `sql` through `fun` (reduce_while style) in
  # chunks. Returns the accumulator and the prepared query (columns, types).
  defp reduce_rows(tx, sql, params, acc, fun) do
    with {:ok, query} <- Postgrex.prepare(tx, "", sql) do
      acc =
        tx
        |> Postgrex.stream(query, params, max_rows: @chunk)
        |> Stream.flat_map(& &1.rows)
        |> Enum.reduce_while(acc, fun)

      {:ok, acc, query}
    end
  rescue
    e in Postgrex.Error -> db_error(e)
  else
    {:error, e} -> db_error(e)
    ok -> ok
  end

  defp db_error(%Postgrex.Error{postgres: %{message: message}}),
    do: {:error, {:db_error, message}}

  defp db_error(error), do: {:error, {:db_error, Exception.message(error)}}

  # Each result column's type (for `Fumehood.Values`).
  defp types(query), do: Enum.zip(query.result_types || [], query.result_oids || [])

  defp query(tx, sql, params) do
    case Postgrex.query(tx, sql, params) do
      {:ok, result} -> {:ok, result}
      {:error, %Postgrex.Error{postgres: %{message: message}}} -> {:error, {:db_error, message}}
      {:error, error} -> {:error, {:db_error, Exception.message(error)}}
    end
  end

  defp blocked(rule, message), do: {:error, {:blocked, rule, message}}

  defp format_table({nil, name}), do: name
  defp format_table({schema, name}), do: "#{schema}.#{name}"
end
