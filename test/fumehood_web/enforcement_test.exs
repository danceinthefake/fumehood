defmodule FumehoodWeb.EnforcementTest do
  use FumehoodWeb.ConnCase, async: true

  alias Fumehood.{Runner, Safety}

  # pg18 is read_only in the test config; its pool connects as the superuser,
  # so fumehood's own checks are all that stand in the way.
  setup do
    table = "enf_#{System.unique_integer([:positive])}"
    ro = Fumehood.Databases.conn("pg18")
    Postgrex.query!(ro, "CREATE TABLE #{table} (id int PRIMARY KEY, n int)", [])
    Postgrex.query!(ro, "INSERT INTO #{table} VALUES (1, 1), (2, 2)", [])
    on_exit(fn -> Postgrex.query!(Fumehood.Databases.conn("pg18"), "DROP TABLE #{table}", []) end)
    %{table: table}
  end

  defp rows(db, table),
    do:
      Postgrex.query!(Fumehood.Databases.conn(db), "SELECT id, n FROM #{table} ORDER BY id", []).rows

  test "a read_only database refuses every write path", %{conn: conn, table: table} do
    for sql <- [
          "INSERT INTO #{table} VALUES (3, 3)",
          "UPDATE #{table} SET n = 0 WHERE id = 1",
          "DELETE FROM #{table} WHERE id = 1"
        ] do
      assert %{"error" => %{"rule" => "read_only_database"}} =
               conn |> post("/api/databases/pg18/run", %{sql: sql}) |> json_response(422),
             sql

      assert %{"error" => %{"rule" => "read_only_database"}} =
               conn
               |> post("/api/databases/pg18/commit", %{sql: sql, expected_count: 1})
               |> json_response(422),
             sql
    end

    assert %{"error" => %{"rule" => "read_only_database"}} =
             conn
             |> post("/api/databases/pg18/backups/20260101T000000-deadbeef/restore", %{})
             |> json_response(422)

    assert %{"error" => %{"rule" => "read_only_database"}} =
             conn
             |> post("/api/databases/pg18/backups/20260101T000000-deadbeef/restore/commit", %{
               expected_count: 1
             })
             |> json_response(422)

    assert rows("pg18", table) == [[1, 1], [2, 2]]
    # reads still work
    assert %{"rows" => [[2]]} =
             conn
             |> post("/api/databases/pg18/run", %{sql: "SELECT count(*) FROM #{table}"})
             |> json_response(200)
  end

  test "third wall: a SELECT-only Postgres role refuses writes even past fumehood's checks", %{
    table: table
  } do
    role = "fh_ro_#{System.unique_integer([:positive])}"
    admin = Fumehood.Databases.conn("pg18")
    Postgrex.query!(admin, "CREATE ROLE #{role} LOGIN PASSWORD 'ro'", [])
    Postgrex.query!(admin, "GRANT SELECT ON #{table} TO #{role}", [])

    on_exit(fn ->
      admin = Fumehood.Databases.conn("pg18")
      Postgrex.query!(admin, "REVOKE ALL ON ALL TABLES IN SCHEMA public FROM #{role}", [])
      Postgrex.query!(admin, "DROP ROLE #{role}", [])
    end)

    opts = [
      hostname: "localhost",
      port: 55418,
      username: role,
      password: "ro",
      database: "fumehood_target"
    ]

    ro = start_supervised!({Postgrex, opts})

    {:ok, read} = Safety.check("SELECT n FROM #{table} WHERE id = 1")
    assert {:ok, %{rows: [[1]]}} = Runner.read(ro, read)

    # Call the Runner directly — skipping the read_only mode check on purpose.
    {:ok, write} = Safety.check("UPDATE #{table} SET n = 0 WHERE id = 1")
    assert {:error, {:db_error, message}} = Runner.dry_run(ro, write)
    assert message =~ "permission denied"

    assert rows("pg18", table) == [[1, 1], [2, 2]]
  end

  # The grants docs/setup.md tells admins to give a read_write role must be
  # enough for everything fumehood does: dry run, commit with backup, and
  # restore (which needs a temporary table).
  @tag :tmp_dir
  test "the documented read_write grants are enough for commit and restore", %{
    table: table,
    tmp_dir: dir
  } do
    role = "fh_rw_#{System.unique_integer([:positive])}"
    admin = Fumehood.Databases.conn("pg18")

    for sql <- [
          "CREATE ROLE #{role} LOGIN PASSWORD 'rw'",
          # -- docs/setup.md, read_write role --
          "GRANT CONNECT, TEMPORARY ON DATABASE fumehood_target TO #{role}",
          "GRANT USAGE ON SCHEMA public TO #{role}",
          "GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO #{role}",
          "GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO #{role}"
        ],
        do: Postgrex.query!(admin, sql, [])

    on_exit(fn ->
      admin = Fumehood.Databases.conn("pg18")
      Postgrex.query!(admin, "REVOKE ALL ON ALL TABLES IN SCHEMA public FROM #{role}", [])
      Postgrex.query!(admin, "REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM #{role}", [])
      Postgrex.query!(admin, "REVOKE ALL ON SCHEMA public FROM #{role}", [])
      Postgrex.query!(admin, "REVOKE ALL ON DATABASE fumehood_target FROM #{role}", [])
      Postgrex.query!(admin, "DROP ROLE #{role}", [])
    end)

    opts = [
      hostname: "localhost",
      port: 55418,
      username: role,
      password: "rw",
      database: "fumehood_target"
    ]

    rw = start_supervised!({Postgrex, opts})

    {:ok, write} = Safety.check("UPDATE #{table} SET n = 9 WHERE id = 2")
    assert {:ok, %{count: 1}} = Runner.dry_run(rw, write)

    assert {:ok, %{backup: %{json: json}}} =
             Runner.commit(rw, write, expected_count: 1, backup_dir: dir)

    assert rows("pg18", table) == [[1, 1], [2, 9]]

    assert {:ok, %{count: 1}} = Fumehood.Restore.dry_run(rw, json)

    assert {:ok, _} =
             Fumehood.Restore.commit(rw, json, expected_count: 1, backup_dir: Path.join(dir, "r"))

    assert rows("pg18", table) == [[1, 1], [2, 2]]
  end

  test "oversized SQL is refused before parsing" do
    big = "SELECT 1 -- " <> String.duplicate("x", 100_000)
    assert {:error, {:blocked, :too_long, _}} = Safety.check(big)
  end

  test "security headers: CSP on the UI shell, nosniff on the API", %{conn: conn} do
    page = get(conn, "/")
    [csp] = get_resp_header(page, "content-security-policy")
    assert csp =~ "default-src 'self'"
    assert csp =~ "frame-ancestors 'none'"
    # Phoenix 1.8 leaves framing to CSP's frame-ancestors (checked above)
    assert get_resp_header(page, "referrer-policy") == ["strict-origin-when-cross-origin"]
    assert get_resp_header(page, "x-content-type-options") == ["nosniff"]

    api = get(conn, "/api/me")
    assert get_resp_header(api, "x-content-type-options") == ["nosniff"]
  end
end
