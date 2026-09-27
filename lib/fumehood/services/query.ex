defmodule Fumehood.Services.Query do
  @moduledoc """
  What the API does, without HTTP: list databases, run a statement (a read,
  or a write's dry run), commit a write, list backups, restore one.

  Enforces the per-database mode (`read_only` databases take no writes,
  restores included) and stamps backups with who ran them.
  """

  alias Fumehood.{Backup, Databases, Restore, Runner, Safety, Values}
  alias Fumehood.Config.Database

  @type identity :: %{id: String.t(), source: atom()}
  @type error :: {:blocked, atom(), String.t()} | {:db_error, String.t()} | :not_found

  @spec list_databases() :: [map()]
  def list_databases do
    for db <- Databases.list(), do: %{id: db.id, label: db.label, mode: db.mode}
  end

  @doc "Runs a read, or a write's dry run (nothing is kept)."
  @spec run(String.t(), String.t(), identity()) :: {:ok, map()} | {:error, error()}
  def run(db_id, sql, _identity) do
    with {:ok, db} <- fetch(db_id),
         {:ok, statement} <- Safety.check(sql),
         :ok <- allowed(db, statement) do
      case statement.kind do
        :read ->
          with {:ok, r} <- Runner.read(Databases.conn(db.id), statement, limits(db)) do
            {:ok,
             %{
               kind: :read,
               command: statement.command,
               columns: r.columns,
               rows: Values.rows(r.rows, r.types),
               truncated: r.truncated
             }}
          end

        :write ->
          with {:ok, r} <- Runner.dry_run(Databases.conn(db.id), statement, limits(db)) do
            {:ok, dry_run_view(statement, r)}
          end
      end
    end
  end

  @doc "Commits a write whose dry run showed `expected_count` rows."
  @spec commit(String.t(), String.t(), non_neg_integer(), identity()) ::
          {:ok, map()} | {:error, error()}
  def commit(db_id, sql, expected_count, identity) do
    with {:ok, db} <- fetch(db_id),
         {:ok, statement} <- Safety.check(sql),
         :ok <- is_write(statement),
         :ok <- allowed(db, statement),
         backup_id = Backup.new_id(),
         {:ok, r} <-
           Runner.commit(
             Databases.conn(db.id),
             statement,
             limits(db) ++
               [
                 expected_count: expected_count,
                 backup_dir: backup_dir(db),
                 backup_id: backup_id,
                 meta: %{user: identity.id, database: db.id}
               ]
           ) do
      {:ok, %{count: r.count, backup_id: backup_id}}
    end
  end

  @doc "Backups of a database, newest first (at most `limit`)."
  @spec backups(String.t(), pos_integer()) :: {:ok, [map()]} | {:error, error()}
  def backups(db_id, limit \\ 100) do
    with {:ok, db} <- fetch(db_id) do
      dir = backup_dir(db)

      list =
        case File.ls(dir) do
          {:ok, files} ->
            files |> Enum.filter(&String.ends_with?(&1, ".json")) |> Enum.sort(:desc)

          {:error, _} ->
            []
        end

      {:ok,
       list
       |> Enum.take(limit)
       |> Enum.map(fn file ->
         meta = dir |> Path.join(file) |> File.read!() |> JSON.decode!()

         %{
           id: meta["id"],
           operation: meta["operation"],
           table: meta["table"],
           rows: length(meta["keys"]),
           statement: meta["statement"],
           user: meta["user"],
           taken_at: meta["taken_at"],
           restore_of: meta["restore_of"]
         }
       end)}
    end
  end

  @doc "Dry run of undoing a backup."
  @spec restore_dry_run(String.t(), String.t(), identity()) :: {:ok, map()} | {:error, error()}
  def restore_dry_run(db_id, backup_id, _identity) do
    with {:ok, db, path} <- backup(db_id, backup_id),
         {:ok, r} <- Restore.dry_run(Databases.conn(db.id), path, limits(db)) do
      {:ok,
       %{
         sql: r.sql,
         count: r.count,
         columns: r.columns,
         preview: Values.rows(r.preview, r.types)
       }}
    end
  end

  @doc "Commits the undo of a backup."
  @spec restore_commit(String.t(), String.t(), non_neg_integer(), identity()) ::
          {:ok, map()} | {:error, error()}
  def restore_commit(db_id, backup_id, expected_count, identity) do
    with {:ok, db, path} <- backup(db_id, backup_id),
         new_id = Backup.new_id(),
         {:ok, r} <-
           Restore.commit(
             Databases.conn(db.id),
             path,
             limits(db) ++
               [
                 expected_count: expected_count,
                 backup_dir: backup_dir(db),
                 backup_id: new_id,
                 meta: %{user: identity.id, database: db.id}
               ]
           ) do
      {:ok, %{count: r.count, backup_id: new_id}}
    end
  end

  # -- helpers ---------------------------------------------------------------

  defp fetch(db_id) do
    case Databases.fetch(db_id) do
      {:ok, db} -> {:ok, db}
      :error -> {:error, :not_found}
    end
  end

  # Restores write too, so they need a read_write database. Backup ids come
  # from the URL: only our own id format, so no path can escape the dir.
  defp backup(db_id, backup_id) do
    with {:ok, db} <- fetch(db_id),
         :ok <- allowed(db, %{kind: :write}),
         true <- Regex.match?(~r/\A[0-9A-Za-z-]{1,64}\z/, backup_id) || {:error, :not_found},
         path = Path.join(backup_dir(db), backup_id <> ".json"),
         true <- File.exists?(path) || {:error, :not_found} do
      {:ok, db, path}
    end
  end

  defp allowed(%Database{mode: :read_only, id: id}, %{kind: :write}) do
    {:error,
     {:blocked, :read_only_database, "#{id} is read-only in fumehood; writes are not allowed."}}
  end

  defp allowed(_db, _statement), do: :ok

  defp is_write(%{kind: :write}), do: :ok

  defp is_write(_),
    do: {:error, {:blocked, :not_a_write, "Only writes are committed; reads just run."}}

  defp limits(db) do
    [
      max_rows: db.max_rows,
      statement_timeout: db.statement_timeout_ms,
      lock_timeout: db.lock_timeout_ms
    ]
  end

  defp backup_dir(db), do: Path.join(Databases.config().backup_dir, db.id)

  defp dry_run_view(statement, r) do
    %{
      kind: :write,
      command: statement.command,
      table: format_table(statement.table),
      count: r.count,
      columns: r.columns,
      preview: Values.rows(r.preview, r.types)
    }
  end

  defp format_table({nil, name}), do: name
  defp format_table({schema, name}), do: "#{schema}.#{name}"
end
