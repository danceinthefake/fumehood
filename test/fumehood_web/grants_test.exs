defmodule FumehoodWeb.GrantsTest do
  # Not async: GRANT … ON ALL TABLES touches the catalog rows of every table
  # in the schema, racing the other tests that create and drop tables there.
  use ExUnit.Case, async: false

  alias Fumehood.{Runner, Safety}

  setup do
    table = "grants_#{System.unique_integer([:positive])}"
    admin = Fumehood.Databases.conn("pg18")
    Postgrex.query!(admin, "CREATE TABLE #{table} (id int PRIMARY KEY, n int)", [])
    Postgrex.query!(admin, "INSERT INTO #{table} VALUES (1, 1), (2, 2)", [])
    on_exit(fn -> Postgrex.query!(Fumehood.Databases.conn("pg18"), "DROP TABLE #{table}", []) end)
    %{table: table}
  end

  defp rows(table),
    do:
      Postgrex.query!(
        Fumehood.Databases.conn("pg18"),
        "SELECT id, n FROM #{table} ORDER BY id",
        []
      ).rows

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

    assert rows(table) == [[1, 1], [2, 9]]

    assert {:ok, %{count: 1}} = Fumehood.Restore.dry_run(rw, json)

    assert {:ok, _} =
             Fumehood.Restore.commit(rw, json, expected_count: 1, backup_dir: Path.join(dir, "r"))

    assert rows(table) == [[1, 1], [2, 2]]
  end
end
