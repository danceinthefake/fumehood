defmodule Fumehood.RestoreTest do
  use ExUnit.Case,
    async: true,
    parameterize: for(v <- Fumehood.TargetDB.versions(), do: %{pg: v})

  alias Fumehood.{Restore, Runner, Safety, TargetDB}

  @moduletag :tmp_dir

  @setup [
    "CREATE TABLE users (id int PRIMARY KEY, name text, email text, born date)",
    "INSERT INTO users SELECT g, 'user ' || g, 'u' || g || '@x.com', DATE '2000-01-01' + g FROM generate_series(1, 10) g",
    ~s{CREATE TABLE "Odd Name" (tenant uuid, n int, note text, tags text[], PRIMARY KEY (tenant, n))},
    ~s|INSERT INTO "Odd Name" VALUES ('00000000-0000-0000-0000-000000000001', 1, E'has "quotes", commas,\\nand a newline', '{a,"b c"}'), ('00000000-0000-0000-0000-000000000001', 2, NULL, NULL), ('00000000-0000-0000-0000-000000000002', 1, '', '{}')|
  ]

  setup %{pg: pg} do
    TargetDB.connect!(pg, @setup)
  end

  defp rows(conn, sql), do: Postgrex.query!(conn, sql, []).rows

  defp write!(conn, sql, dir) do
    {:ok, statement} = Safety.check(sql)
    {:ok, %{count: count}} = Runner.dry_run(conn, statement)

    {:ok, %{backup: %{json: json}}} =
      Runner.commit(conn, statement, expected_count: count, backup_dir: dir)

    json
  end

  defp restore!(conn, json, dir) do
    {:ok, %{count: count}} = Restore.dry_run(conn, json)
    Restore.commit(conn, json, expected_count: count, backup_dir: Path.join(dir, "restores"))
  end

  test "undo DELETE puts the rows back exactly", %{conn: conn, tmp_dir: dir} do
    before = rows(conn, "SELECT * FROM users ORDER BY id")
    json = write!(conn, "DELETE FROM users WHERE id > 7", dir)
    assert rows(conn, "SELECT count(*) FROM users") == [[7]]

    assert {:ok, %{count: 3}} = restore!(conn, json, dir)
    assert rows(conn, "SELECT * FROM users ORDER BY id") == before
  end

  test "undo UPDATE sets the old values back", %{conn: conn, tmp_dir: dir} do
    before = rows(conn, "SELECT * FROM users ORDER BY id")

    json =
      write!(conn, "UPDATE users SET name = 'x', email = NULL, born = NULL WHERE id <= 4", dir)

    assert {:ok, %{count: 4}} = restore!(conn, json, dir)
    assert rows(conn, "SELECT * FROM users ORDER BY id") == before
  end

  test "undo INSERT deletes the inserted rows", %{conn: conn, tmp_dir: dir} do
    json = write!(conn, "INSERT INTO users (id, name) VALUES (50, 'a'), (51, 'b')", dir)

    assert {:ok, %{count: 2}} = restore!(conn, json, dir)
    assert rows(conn, "SELECT count(*) FROM users WHERE id >= 50") == [[0]]
  end

  test "composite keys, quoted names, NULL vs empty string, arrays round-trip", %{
    conn: conn,
    tmp_dir: dir
  } do
    table = ~s["Odd Name"]
    before = rows(conn, "SELECT * FROM #{table} ORDER BY tenant, n")

    delete = write!(conn, "DELETE FROM #{table} WHERE n >= 1", dir)
    assert {:ok, %{count: 3}} = restore!(conn, delete, dir)
    assert rows(conn, "SELECT * FROM #{table} ORDER BY tenant, n") == before

    update = write!(conn, "UPDATE #{table} SET note = 'changed', tags = '{z}' WHERE n = 1", dir)
    assert {:ok, %{count: 2}} = restore!(conn, update, dir)
    assert rows(conn, "SELECT * FROM #{table} ORDER BY tenant, n") == before
  end

  test "the restore is itself backed up and can be undone", %{conn: conn, tmp_dir: dir} do
    json = write!(conn, "UPDATE users SET name = 'x' WHERE id = 1", dir)
    {:ok, %{backup: %{json: restore_json}}} = restore!(conn, json, dir)

    meta = restore_json |> File.read!() |> JSON.decode!()
    assert meta["restore_of"] == Path.basename(json, ".json")

    # undoing the restore brings the change back
    assert {:ok, _} = restore!(conn, restore_json, dir)
    assert rows(conn, "SELECT name FROM users WHERE id = 1") == [["x"]]
  end

  test "dry run shows the generated SQL and changes nothing", %{conn: conn, tmp_dir: dir} do
    json = write!(conn, "DELETE FROM users WHERE id = 1", dir)

    assert {:ok, %{count: 1, sql: sql}} = Restore.dry_run(conn, json)
    assert sql =~ "INSERT INTO users"
    assert rows(conn, "SELECT count(*) FROM users") == [[9]]
  end

  test "rows gone since the backup: restore is blocked", %{conn: conn, tmp_dir: dir} do
    json = write!(conn, "UPDATE users SET name = 'x' WHERE id <= 3", dir)
    Postgrex.query!(conn, "DELETE FROM users WHERE id = 2", [])

    assert {:error, {:blocked, :changed_since_commit, _}} = Restore.dry_run(conn, json)
  end

  test "rows edited since the commit: the undo never overwrites them", %{conn: conn, tmp_dir: dir} do
    json = write!(conn, "UPDATE users SET name = 'x' WHERE id <= 3", dir)
    Postgrex.query!(conn, "UPDATE users SET email = 'later@x.com' WHERE id = 3", [])

    assert {:error, {:blocked, :changed_since_commit, _}} = Restore.dry_run(conn, json)

    assert {:error, {:blocked, :changed_since_commit, _}} =
             Restore.commit(conn, json, expected_count: 3, backup_dir: dir)

    assert rows(conn, "SELECT email FROM users WHERE id = 3") == [["later@x.com"]]
  end

  test "a backup can't be restored twice", %{conn: conn, tmp_dir: dir} do
    json = write!(conn, "UPDATE users SET name = 'x' WHERE id = 1", dir)
    assert {:ok, _} = restore!(conn, json, dir)
    assert {:error, {:blocked, :changed_since_commit, _}} = Restore.dry_run(conn, json)
  end

  test "an insert undo finds new rows touched later, too", %{conn: conn, tmp_dir: dir} do
    json = write!(conn, "INSERT INTO users VALUES (11, 'new', 'n@x.com', NULL)", dir)
    Postgrex.query!(conn, "UPDATE users SET name = 'edited' WHERE id = 11", [])
    assert {:error, {:blocked, :changed_since_commit, _}} = Restore.dry_run(conn, json)
  end

  test "a backup without after_hash (older fumehood) is refused", %{conn: conn, tmp_dir: dir} do
    json = write!(conn, "UPDATE users SET name = 'x' WHERE id = 1", dir)
    meta = json |> File.read!() |> JSON.decode!() |> Map.delete("after_hash")
    File.write!(json, JSON.encode!(meta))
    assert {:error, {:blocked, :restore_unavailable, _}} = Restore.dry_run(conn, json)
  end

  test "table changed shape since the backup: clear error, nothing changed", %{
    conn: conn,
    tmp_dir: dir
  } do
    json = write!(conn, "DELETE FROM users WHERE id = 1", dir)
    Postgrex.query!(conn, "ALTER TABLE users DROP COLUMN born", [])

    assert {:error, {:db_error, message}} = Restore.dry_run(conn, json)
    assert message =~ "doesn't fit"
    assert rows(conn, "SELECT count(*) FROM users") == [[9]]
  end

  test "missing backup file is a clear error", %{conn: conn, tmp_dir: dir} do
    assert {:error, {:db_error, message}} = Restore.dry_run(conn, Path.join(dir, "nope.json"))
    assert message =~ "can't be read"
  end
end
