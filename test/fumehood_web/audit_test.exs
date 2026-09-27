defmodule FumehoodWeb.AuditTest do
  use FumehoodWeb.ConnCase, async: true

  alias Fumehood.Models.AuditEntry
  alias Fumehood.Repo
  alias Fumehood.Repos.AuditRepo

  setup do
    table = "audit_#{System.unique_integer([:positive])}"
    pool = Fumehood.Databases.conn("pg16")
    Postgrex.query!(pool, "CREATE TABLE #{table} (id int PRIMARY KEY, n int)", [])
    Postgrex.query!(pool, "INSERT INTO #{table} SELECT g, g FROM generate_series(1, 5) g", [])
    on_exit(fn -> Postgrex.query!(Fumehood.Databases.conn("pg16"), "DROP TABLE #{table}", []) end)
    %{table: table}
  end

  defp entries(conn, db \\ "pg16"),
    do: conn |> get("/api/databases/#{db}/audit") |> json_response(200) |> Map.fetch!("entries")

  defp run(conn, sql, db \\ "pg16"), do: post(conn, "/api/databases/#{db}/run", %{sql: sql})

  test "the audit log is append-only in the database itself" do
    {:ok, entry} =
      AuditRepo.insert(%{
        at: DateTime.utc_now(),
        user: "a@x",
        source: "dev",
        database: "pg16",
        action: "read",
        outcome: "ok"
      })

    assert_raise Exqlite.Error, ~r/append-only/, fn ->
      entry |> Ecto.Changeset.change(outcome: "error") |> Repo.update()
    end

    assert_raise Exqlite.Error, ~r/append-only/, fn -> Repo.delete(entry) end
    assert Repo.get!(AuditEntry, entry.id).outcome == "ok"
  end

  test "reads, dry runs and blocked statements are recorded", %{conn: conn, table: table} do
    run(conn, "SELECT * FROM #{table}")
    run(conn, "UPDATE #{table} SET n = 0 WHERE id <= 2")
    run(conn, "DELETE FROM #{table}")

    assert [
             %{"action" => "run", "outcome" => "blocked", "rule" => "missing_where"},
             %{"action" => "dry_run", "outcome" => "ok", "rows" => 2},
             %{
               "action" => "read",
               "outcome" => "ok",
               "rows" => 5,
               "user" => "test@localhost",
               "source" => "dev"
             }
           ] = entries(conn) |> Enum.take(3)
  end

  test "a commit writes `started` before it runs, then its outcome", %{conn: conn, table: table} do
    sql = "DELETE FROM #{table} WHERE id = 1"

    %{"backup_id" => backup_id} =
      conn
      |> post("/api/databases/pg16/commit", %{sql: sql, expected_count: 1})
      |> json_response(200)

    assert [
             %{
               "action" => "commit",
               "outcome" => "ok",
               "rows" => 1,
               "expected_count" => 1,
               "backup_id" => ^backup_id
             },
             %{
               "action" => "commit",
               "outcome" => "started",
               "sql" => ^sql,
               "backup_id" => ^backup_id
             }
           ] = entries(conn) |> Enum.take(2)
  end

  test "a refused commit keeps its `started` entry and records why", %{conn: conn, table: table} do
    post(conn, "/api/databases/pg16/commit", %{
      sql: "DELETE FROM #{table} WHERE id <= 2",
      expected_count: 9
    })

    assert [
             %{"action" => "commit", "outcome" => "blocked", "rule" => "changed_since_dry_run"},
             %{"action" => "commit", "outcome" => "started"}
           ] = entries(conn) |> Enum.take(2)
  end

  test "restores are recorded with the backup they undo", %{conn: conn, table: table} do
    %{"backup_id" => backup_id} =
      conn
      |> post("/api/databases/pg16/commit", %{
        sql: "UPDATE #{table} SET n = 0 WHERE id = 3",
        expected_count: 1
      })
      |> json_response(200)

    path = "/api/databases/pg16/backups/#{backup_id}/restore"
    post(conn, path, %{})
    post(conn, path <> "/commit", %{expected_count: 1})

    assert [
             %{"action" => "restore_commit", "outcome" => "ok", "restore_of" => ^backup_id},
             %{"action" => "restore_commit", "outcome" => "started", "restore_of" => ^backup_id},
             %{
               "action" => "restore_dry_run",
               "outcome" => "ok",
               "rows" => 1,
               "restore_of" => ^backup_id
             }
           ] = entries(conn) |> Enum.take(3)
  end

  test "writes on a read-only database are recorded as blocked", %{conn: conn} do
    run(conn, "DELETE FROM t WHERE id = 1", "pg18")
    assert [%{"outcome" => "blocked", "rule" => "read_only_database"} | _] = entries(conn, "pg18")
  end

  test "no audit log, no commit: production is untouched", %{conn: conn, table: table} do
    # Inside this test's sandbox transaction, so it's rolled back afterwards.
    Repo.query!("DROP TABLE audit_entries")

    assert %{"error" => %{"rule" => "audit_unavailable"}} =
             conn
             |> post("/api/databases/pg16/commit", %{
               sql: "DELETE FROM #{table} WHERE id = 1",
               expected_count: 1
             })
             |> json_response(422)

    assert Postgrex.query!(Fumehood.Databases.conn("pg16"), "SELECT count(*) FROM #{table}", []).rows ==
             [[5]]
  end
end
