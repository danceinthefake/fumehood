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
    * `:preview` — rows shown from a write dry run, default 20
  """

  alias Fumehood.Backup
  alias Fumehood.Safety.Statement

  # The table named by $1 (schema or NULL) and $2, resolved like Postgres
  # resolves a name in the statement: NULL schema → search_path.
  @regclass """
  to_regclass(CASE WHEN $1::text IS NULL THEN format('%I', $2::text)
                   ELSE format('%I.%I', $1::text, $2::text) END)
  """

  @defaults [statement_timeout: 30_000, lock_timeout: 5_000, max_rows: 1000, preview: 20]

  @type result :: %{columns: [String.t()], rows: [list()]}
  @type error :: {:blocked, atom(), String.t()} | {:db_error, String.t()}

  @doc """
  Runs a read inside a `READ ONLY` transaction. SELECTs are capped at
  `:max_rows`; `truncated` tells whether more rows existed.
  """
  @spec read(DBConnection.conn(), Statement.t(), keyword()) ::
          {:ok, %{columns: [String.t()], rows: [list()], truncated: boolean()}}
          | {:error, error()}
  def read(conn, %Statement{kind: :read} = statement, opts \\ []) do
    opts = Keyword.merge(@defaults, opts)
    max = opts[:max_rows]

    in_transaction(conn, opts, :read_only, fn tx ->
      with {:ok, result} <- query(tx, read_sql(statement, max + 1)) do
        {:ok,
         %{
           columns: result.columns || [],
           rows: Enum.take(result.rows || [], max),
           truncated: length(result.rows || []) > max
         }}
      end
    end)
  end

  @doc """
  Runs a write, counts and previews the rows it changes, then rolls back.
  Nothing is kept.
  """
  @spec dry_run(DBConnection.conn(), Statement.t(), keyword()) ::
          {:ok, %{count: non_neg_integer(), columns: [String.t()], preview: [list()]}}
          | {:error, error()}
  def dry_run(conn, %Statement{kind: :write} = statement, opts \\ []) do
    opts = Keyword.merge(@defaults, opts)

    in_transaction(conn, opts, :rollback, fn tx ->
      with {:ok, _table} <- table_info(tx, statement),
           {:ok, result} <- query(tx, statement.sql <> "\nRETURNING *"),
           :ok <- within_limit(result.num_rows, opts[:max_rows]) do
        {:ok,
         %{
           count: result.num_rows,
           columns: result.columns,
           preview: Enum.take(result.rows, opts[:preview])
         }}
      end
    end)
  end

  @doc """
  Commits a write after backing up the rows it changes (DESIGN.md §5.4).

  Required options:

    * `:expected_count` — the count the person confirmed from `dry_run/3`;
      if the statement would now change a different number of rows (or, for
      `UPDATE` / `DELETE`, different rows), nothing is committed
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
      with {:ok, table} <- table_info(tx, statement) do
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
    with {:ok, keys} <- run_returning_keys(tx, statement, table),
         :ok <- same_count(length(keys), opts[:expected_count]),
         :ok <- within_limit(length(keys), opts[:max_rows]),
         keys = if(table.pk == [], do: [], else: keys),
         {:ok, files} <- write_backup(statement, table, keys, nil, opts) do
      {:ok, %{count: opts[:expected_count], backup: files}}
    end
  end

  defp commit_change(tx, statement, table, opts) do
    with {:ok, keys} <- probe_keys(tx, statement, table),
         :ok <- same_count(length(keys), opts[:expected_count]),
         :ok <- within_limit(length(keys), opts[:max_rows]),
         {:ok, csv} <- lock_and_export(tx, table, keys),
         {:ok, files} <- write_backup(statement, table, keys, csv, opts),
         {:ok, changed} <- run_returning_keys(tx, statement, table),
         :ok <- same_keys(keys, changed) do
      {:ok, %{count: length(changed), backup: files}}
    end
  end

  # Which rows the statement touches: run it in a savepoint returning the
  # keys, then undo it.
  defp probe_keys(tx, statement, table) do
    Postgrex.query!(tx, "SAVEPOINT fumehood_probe", [])
    result = run_returning_keys(tx, statement, table)
    Postgrex.query!(tx, "ROLLBACK TO SAVEPOINT fumehood_probe", [])
    result
  end

  # Keys come back as text so they are JSON-safe and comparable.
  defp run_returning_keys(tx, statement, %{pk: pk}) do
    returning =
      case pk do
        [] -> "NULL"
        pk -> Enum.map_join(pk, ", ", fn {column, _} -> "#{quote_ident(column)}::text" end)
      end

    with {:ok, result} <- query(tx, statement.sql <> "\nRETURNING " <> returning) do
      {:ok, result.rows}
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

  defp quote_ident(name), do: ~s(") <> String.replace(name, ~s("), ~s("")) <> ~s(")

  defp within_limit(count, max) when count <= max, do: :ok

  defp within_limit(count, max),
    do:
      blocked(
        :too_many_rows,
        "This would change #{count} rows; the limit is #{max}. Split it into smaller changes."
      )

  # Opens a transaction, applies the guardrails, runs `fun`, and ends it:
  # `:read_only` and `:commit` commit when `fun` succeeds, `:rollback` always
  # rolls back. Any error rolls back.
  defp in_transaction(conn, opts, mode, fun) do
    Postgrex.transaction(conn, fn tx ->
      if mode == :read_only, do: Postgrex.query!(tx, "SET TRANSACTION READ ONLY", [])
      Postgrex.query!(tx, "SET LOCAL statement_timeout = #{opts[:statement_timeout]}", [])
      Postgrex.query!(tx, "SET LOCAL lock_timeout = #{opts[:lock_timeout]}", [])

      case fun.(tx) do
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
  end

  defp query(tx, sql, params \\ []) do
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
