defmodule Fumehood.Services.Query do
  @moduledoc """
  What the API does, without HTTP: list databases, run a statement (a read,
  or a write's dry run), commit a write, list backups, restore one.

  Enforces the per-database mode (`read_only` databases take no writes,
  restores included) and stamps backups with who ran them.

  Everything that reaches a database is audited (`Fumehood.Repos.AuditRepo`).
  Commits and restores write a `started` entry *before* touching the
  database and are refused if that entry can't be written.
  """

  require Logger

  alias Fumehood.{Backup, Databases, Queries, Restore, Runner, Safety, Values}
  alias Fumehood.Config.Database
  alias Fumehood.Repos.AuditRepo

  @type identity :: %{id: String.t(), source: atom()}
  @type error ::
          {:blocked, atom(), String.t()}
          | {:db_error, String.t()}
          | {:cancelled, String.t()}
          | :not_found

  @spec list_databases() :: [map()]
  def list_databases do
    for db <- Databases.list(), do: %{id: db.id, label: db.label, mode: db.mode}
  end

  @doc "Runs a read, or a write's dry run (nothing is kept)."
  @spec run(String.t(), String.t(), identity()) :: {:ok, map()} | {:error, error()}
  def run(db_id, sql, identity, opts \\ []) do
    with {:ok, db} <- fetch(db_id) do
      audited(db, identity, %{sql: sql}, fn ->
        track(opts, identity, db, fn on_backend ->
          with {:ok, statement} <- Safety.check(sql),
               :ok <- allowed(db, statement) do
            case statement.kind do
              :read ->
                with {:ok, r} <-
                       Runner.read(Databases.conn(db.id), statement, limits(db, on_backend)) do
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
                with {:ok, r} <-
                       Runner.dry_run(Databases.conn(db.id), statement, limits(db, on_backend)) do
                  {:ok, dry_run_view(statement, r)}
                end
            end
          end
        end)
      end)
    end
  end

  @doc """
  Commits a write whose dry run showed `expected_count` rows. `opts[:rows_token]`
  is the dry run's `rows_token`, required for `UPDATE` / `DELETE`.
  """
  @spec commit(String.t(), String.t(), non_neg_integer(), identity()) ::
          {:ok, map()} | {:error, error()}
  def commit(db_id, sql, expected_count, identity, opts \\ []) do
    with {:ok, db} <- fetch(db_id) do
      backup_id = Backup.new_id()
      entry = %{action: "commit", sql: sql, expected_count: expected_count, backup_id: backup_id}

      audited_write(db, identity, entry, fn ->
        track(opts, identity, db, fn on_backend ->
          with {:ok, statement} <- Safety.check(sql),
               :ok <- is_write(statement),
               :ok <- allowed(db, statement),
               {:ok, r} <-
                 Runner.commit(
                   Databases.conn(db.id),
                   statement,
                   limits(db, on_backend) ++
                     [
                       expected_count: expected_count,
                       expected_token: opts[:rows_token],
                       backup_dir: backup_dir(db),
                       backup_id: backup_id,
                       meta: %{user: identity.id, database: db.id}
                     ]
                 ) do
            {:ok, %{count: r.count, backup_id: backup_id}}
          end
        end)
      end)
    end
  end

  @doc "Audit log of a database, newest first; `before` (an entry id) pages back."
  @spec audit(String.t(), pos_integer(), integer() | nil) :: {:ok, [map()]} | {:error, error()}
  def audit(db_id, limit \\ 100, before \\ nil) do
    with {:ok, db} <- fetch(db_id) do
      {:ok, db.id |> AuditRepo.list(limit, before) |> Enum.map(&audit_view/1)}
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
  def restore_dry_run(db_id, backup_id, identity, opts \\ []) do
    with {:ok, db} <- fetch(db_id) do
      audited(db, identity, %{action: "restore_dry_run", restore_of: backup_id}, fn ->
        track(opts, identity, db, fn on_backend ->
          with {:ok, path} <- backup(db, backup_id),
               {:ok, r} <- Restore.dry_run(Databases.conn(db.id), path, limits(db, on_backend)) do
            {:ok,
             %{
               sql: r.sql,
               count: r.count,
               rows_token: r.rows_token,
               warnings: r.warnings,
               columns: r.columns,
               preview: Values.rows(r.preview, r.types)
             }}
          end
        end)
      end)
    end
  end

  @doc "Commits the undo of a backup."
  @spec restore_commit(String.t(), String.t(), non_neg_integer(), identity()) ::
          {:ok, map()} | {:error, error()}
  def restore_commit(db_id, backup_id, expected_count, identity, opts \\ []) do
    with {:ok, db} <- fetch(db_id) do
      new_id = Backup.new_id()

      entry = %{
        action: "restore_commit",
        restore_of: backup_id,
        expected_count: expected_count,
        backup_id: new_id
      }

      audited_write(db, identity, entry, fn ->
        track(opts, identity, db, fn on_backend ->
          with {:ok, path} <- backup(db, backup_id),
               {:ok, r} <-
                 Restore.commit(
                   Databases.conn(db.id),
                   path,
                   limits(db, on_backend) ++
                     [
                       expected_count: expected_count,
                       expected_token: opts[:rows_token],
                       backup_dir: backup_dir(db),
                       backup_id: new_id,
                       meta: %{user: identity.id, database: db.id}
                     ]
                 ) do
            {:ok, %{count: r.count, backup_id: new_id}}
          end
        end)
      end)
    end
  end

  # -- audit -----------------------------------------------------------------

  # Runs `fun` and records one entry with its outcome. The action comes from
  # `entry`, or from the result for plain runs (read / dry_run / run).
  defp audited(db, identity, entry, fun) do
    started = System.monotonic_time(:millisecond)
    result = fun.()
    duration = System.monotonic_time(:millisecond) - started

    db
    |> base_entry(identity, entry)
    |> Map.merge(outcome(result))
    |> Map.put_new_lazy(:action, fn -> run_action(result) end)
    |> Map.put(:duration_ms, duration)
    |> record()

    result
  end

  # Writes: a `started` entry first — refused if it can't be written, so no
  # change reaches the database unrecorded — then the outcome entry.
  defp audited_write(db, identity, entry, fun) do
    case db
         |> base_entry(identity, entry)
         |> Map.put(:outcome, "started")
         |> insert_entry() do
      {:ok, _} ->
        audited(db, identity, entry, fun)

      {:error, reason} ->
        Logger.error("audit log unavailable, write refused: #{inspect(reason)}")

        {:error,
         {:blocked, :audit_unavailable, "The audit log can't be written, so nothing was changed."}}
    end
  end

  defp base_entry(db, identity, entry) do
    Map.merge(
      %{
        at: DateTime.utc_now(),
        user: identity.id,
        source: to_string(identity.source),
        database: db.id
      },
      entry
    )
  end

  defp outcome({:ok, %{kind: :read, rows: rows}}), do: %{outcome: "ok", rows: length(rows)}
  defp outcome({:ok, %{count: count}}), do: %{outcome: "ok", rows: count}

  defp outcome({:error, {:blocked, rule, message}}),
    do: %{outcome: "blocked", rule: to_string(rule), message: message}

  defp outcome({:error, {:db_error, message}}),
    do: %{outcome: "error", rule: "db_error", message: message}

  defp outcome({:error, {:cancelled, message}}),
    do: %{outcome: "cancelled", rule: "cancelled", message: message}

  defp outcome({:error, :not_found}),
    do: %{outcome: "error", rule: "not_found", message: "Not found."}

  defp run_action({:ok, %{kind: :read}}), do: "read"
  defp run_action({:ok, %{kind: :write}}), do: "dry_run"
  defp run_action(_), do: "run"

  # The operation already happened; a failed audit insert here is logged
  # loudly (the `started` entry exists for writes).
  defp record(entry) do
    case insert_entry(entry) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.error("audit entry not written: #{inspect(reason)} #{inspect(entry)}")
    end
  end

  # A broken audit store (locked, missing table, full disk) raises; treat it
  # the same as a failed insert so writes are refused cleanly.
  defp insert_entry(entry) do
    with {:ok, saved} <- AuditRepo.insert(entry) do
      # live feed (FumehoodWeb.AuditChannel)
      FumehoodWeb.Endpoint.broadcast("audit:#{saved.database}", "entry", audit_view(saved))
      {:ok, saved}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp audit_view(e) do
    Map.take(e, [
      :id,
      :at,
      :user,
      :source,
      :action,
      :sql,
      :outcome,
      :rule,
      :message,
      :rows,
      :expected_count,
      :duration_ms,
      :backup_id,
      :restore_of
    ])
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
  defp backup(db, backup_id) do
    with :ok <- allowed(db, %{kind: :write}),
         true <- Regex.match?(~r/\A[0-9A-Za-z-]{1,64}\z/, backup_id) || {:error, :not_found},
         path = Path.join(backup_dir(db), backup_id <> ".json"),
         true <- File.exists?(path) || {:error, :not_found} do
      {:ok, path}
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

  defp limits(db, on_backend) do
    [
      max_rows: db.max_rows,
      statement_timeout: db.statement_timeout_ms,
      lock_timeout: db.lock_timeout_ms,
      on_backend: on_backend
    ]
  end

  # Registers the running query (if the caller gave it an id) so it can be
  # cancelled with `Fumehood.Queries.cancel/2`.
  defp track(opts, identity, db, fun), do: Queries.track(opts[:query_id], identity.id, db.id, fun)

  defp backup_dir(db), do: Path.join(Databases.config().backup_dir, db.id)

  defp dry_run_view(statement, r) do
    %{
      kind: :write,
      command: statement.command,
      table: format_table(statement.table),
      count: r.count,
      rows_token: r.rows_token,
      warnings: r.warnings,
      columns: r.columns,
      preview: Values.rows(r.preview, r.types)
    }
  end

  defp format_table({nil, name}), do: name
  defp format_table({schema, name}), do: "#{schema}.#{name}"
end
