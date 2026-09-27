defmodule Fumehood.Restore do
  @moduledoc """
  Undoes a committed write from its backup files (DESIGN.md §5.4).

  A restore is an ordinary statement generated from the backup and run
  through `Fumehood.Runner` — so it gets the same dry run, key checks and its
  own backup:

    * undo `DELETE` → `INSERT` the backed-up rows again;
    * undo `UPDATE` → `UPDATE` the rows back to their old values, by key;
    * undo `INSERT` → `DELETE` the inserted rows, by key.

  The backup is loaded into a temporary table (`fumehood_restore`) inside the
  same transaction; it disappears when the transaction ends.
  """

  alias Fumehood.{Runner, Safety}

  @temp "fumehood_restore"

  @doc "Dry run of undoing the backup at `json_path` (its `.json` file)."
  @spec dry_run(DBConnection.conn(), Path.t(), keyword()) ::
          {:ok, map()} | {:error, Runner.error()}
  def dry_run(conn, json_path, opts \\ []) do
    with {:ok, plan} <- plan(conn, json_path),
         {:ok, result} <- Runner.dry_run(conn, plan.statement, [prepare: plan.prepare] ++ opts),
         :ok <- all_rows_found(result.count, plan) do
      {:ok, Map.put(result, :sql, plan.statement.sql)}
    end
  end

  @doc """
  Commits the undo. Takes the same options as `Runner.commit/3`
  (`:expected_count` from `dry_run/3`, `:backup_dir`); the restore itself is
  backed up too, with `restore_of` in its metadata.
  """
  @spec commit(DBConnection.conn(), Path.t(), keyword()) ::
          {:ok, map()} | {:error, Runner.error()}
  def commit(conn, json_path, opts) do
    with {:ok, plan} <- plan(conn, json_path) do
      meta = Map.put(opts[:meta] || %{}, :restore_of, plan.meta["id"])
      Runner.commit(conn, plan.statement, [prepare: plan.prepare, meta: meta] ++ opts)
    end
  end

  # -- plan ------------------------------------------------------------------

  defp plan(conn, json_path) do
    with {:ok, meta} <- read_meta(json_path),
         {:ok, columns} <- columns(conn, meta["table"]) do
      {sql, prepare} = build(meta, columns, csv_path(json_path))
      {:ok, statement} = Safety.check(sql)
      {:ok, %{statement: statement, prepare: prepare, meta: meta}}
    end
  end

  defp build(%{"operation" => "delete", "table" => table}, _columns, csv) do
    {"INSERT INTO #{table} OVERRIDING SYSTEM VALUE SELECT * FROM #{@temp}", load_rows(table, csv)}
  end

  defp build(%{"operation" => "update", "table" => table, "primary_key" => pk}, columns, csv) do
    set = Enum.reject(columns, &(&1 in pk))
    targets = Enum.map_join(set, ", ", &quote_ident/1)
    values = Enum.map_join(set, ", ", &"r.#{quote_ident(&1)}")

    sql = """
    UPDATE #{table} AS t SET (#{targets}) = ROW(#{values})
    FROM #{@temp} AS r
    WHERE (#{prefixed(pk, "t")}) = (#{prefixed(pk, "r")})
    """

    {String.trim(sql), load_rows(table, csv)}
  end

  defp build(
         %{"operation" => "insert", "table" => table, "primary_key" => pk, "keys" => keys},
         _columns,
         _csv
       ) do
    sql = "DELETE FROM #{table} WHERE (#{prefixed(pk, nil)}) IN (SELECT * FROM #{@temp})"
    {sql, load_keys(table, pk, keys)}
  end

  # -- prepare hooks (run inside the Runner's transaction) -------------------

  defp load_rows(table, csv) do
    fn tx ->
      with {:ok, data} <- read_file(csv),
           {:ok, _} <- query(tx, "CREATE TEMP TABLE #{@temp} (LIKE #{table}) ON COMMIT DROP") do
        copy = Postgrex.stream(tx, "COPY #{@temp} FROM STDIN WITH (FORMAT csv, HEADER)", [])

        try do
          Enum.into([data], copy)
          :ok
        rescue
          e in Postgrex.Error ->
            {:error,
             {:db_error, "Backup doesn't fit the table any more: " <> Exception.message(e)}}
        end
      end
    end
  end

  defp load_keys(table, pk, keys) do
    fn tx ->
      columns = prefixed(pk, nil)
      params = keys |> Enum.zip() |> Enum.map(&Tuple.to_list/1)
      params = if params == [], do: List.duplicate([], length(pk)), else: params

      with {:ok, _} <-
             query(
               tx,
               "CREATE TEMP TABLE #{@temp} ON COMMIT DROP AS SELECT #{columns} FROM #{table} WITH NO DATA"
             ),
           {:ok, %{rows: types}} <-
             query(
               tx,
               "SELECT format_type(atttypid, atttypmod) FROM pg_attribute WHERE attrelid = '#{@temp}'::regclass AND attnum > 0 ORDER BY attnum"
             ),
           arrays =
             types
             |> List.flatten()
             |> Enum.with_index(1)
             |> Enum.map_join(", ", fn {type, i} -> "$#{i}::text[]::#{type}[]" end),
           {:ok, _} <- query(tx, "INSERT INTO #{@temp} SELECT * FROM unnest(#{arrays})", params) do
        :ok
      end
    end
  end

  # -- helpers ---------------------------------------------------------------

  # The undo must touch every backed-up row; fewer means some were deleted
  # or had their key changed since the backup.
  defp all_rows_found(count, %{meta: %{"keys" => keys}}) when count == length(keys), do: :ok

  defp all_rows_found(count, %{meta: %{"keys" => keys}}) do
    {:error,
     {:blocked, :restore_incomplete,
      "The backup has #{length(keys)} rows but only #{count} can be restored — some changed since the backup."}}
  end

  # Columns that can be written: no dropped or generated columns.
  defp columns(conn, table) do
    sql = """
    SELECT attname FROM pg_attribute
    WHERE attrelid = to_regclass($1) AND attnum > 0 AND NOT attisdropped AND attgenerated = ''
    ORDER BY attnum
    """

    case Postgrex.query!(conn, sql, [table]).rows do
      [] -> {:error, {:db_error, "Table #{table} doesn't exist."}}
      rows -> {:ok, List.flatten(rows)}
    end
  end

  defp read_meta(json_path) do
    with {:ok, text} <- read_file(json_path), do: {:ok, JSON.decode!(text)}
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, data} -> {:ok, data}
      {:error, reason} -> {:error, {:db_error, "Backup file #{path} can't be read: #{reason}"}}
    end
  end

  defp csv_path(json_path), do: String.replace_suffix(json_path, ".json", ".csv")

  defp prefixed(columns, nil), do: Enum.map_join(columns, ", ", &quote_ident/1)
  defp prefixed(columns, alias), do: Enum.map_join(columns, ", ", &"#{alias}.#{quote_ident(&1)}")

  defp quote_ident(name), do: ~s(") <> String.replace(name, ~s("), ~s("")) <> ~s(")

  defp query(tx, sql, params \\ []) do
    case Postgrex.query(tx, sql, params) do
      {:ok, result} -> {:ok, result}
      {:error, %Postgrex.Error{postgres: %{message: message}}} -> {:error, {:db_error, message}}
      {:error, error} -> {:error, {:db_error, Exception.message(error)}}
    end
  end
end
