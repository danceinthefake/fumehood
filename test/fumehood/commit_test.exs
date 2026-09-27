defmodule Fumehood.CommitTest do
  use ExUnit.Case,
    async: true,
    parameterize: for(v <- Fumehood.TargetDB.versions(), do: %{pg: v})

  alias Fumehood.{Runner, Safety, TargetDB}

  @moduletag :tmp_dir

  @setup [
    "CREATE TABLE users (id int PRIMARY KEY, name text, email text)",
    "INSERT INTO users SELECT g, 'user ' || g, 'u' || g || '@x.com' FROM generate_series(1, 10) g",
    ~s[CREATE TABLE "Odd Name" (tenant uuid, n int, note text, PRIMARY KEY (tenant, n))],
    ~s|INSERT INTO "Odd Name" VALUES ('00000000-0000-0000-0000-000000000001', 1, E'has "quotes", commas,\\nand a newline'), ('00000000-0000-0000-0000-000000000001', 2, NULL), ('00000000-0000-0000-0000-000000000002', 1, '')|,
    "CREATE TABLE logs (msg text)"
  ]

  setup %{pg: pg} do
    TargetDB.connect!(pg, @setup)
  end

  defp statement!(sql) do
    {:ok, statement} = Safety.check(sql)
    statement
  end

  defp dry_then_commit(conn, sql, dir, opts \\ []) do
    statement = statement!(sql)
    {:ok, %{count: count}} = Runner.dry_run(conn, statement)
    Runner.commit(conn, statement, [expected_count: count, backup_dir: dir] ++ opts)
  end

  defp rows(conn, sql), do: Postgrex.query!(conn, sql, []).rows

  test "UPDATE: backs up the old rows, then changes them", %{conn: conn, tmp_dir: dir} do
    assert {:ok, %{count: 3, backup: %{csv: csv, json: json}}} =
             dry_then_commit(conn, "UPDATE users SET name = 'renamed' WHERE id <= 3", dir,
               backup_id: "b1",
               meta: %{user: "jane@example.com"}
             )

    assert rows(conn, "SELECT count(*) FROM users WHERE name = 'renamed'") == [[3]]

    assert csv == Path.join(dir, "b1.csv")
    csv_text = File.read!(csv)
    assert csv_text =~ "id,name,email\n"
    assert csv_text =~ "1,user 1,u1@x.com"
    refute csv_text =~ "renamed"

    meta = json |> File.read!() |> JSON.decode!()
    assert meta["operation"] == "update"
    assert meta["table"] == "users"
    assert meta["primary_key"] == ["id"]
    assert Enum.sort(meta["keys"]) == [["1"], ["2"], ["3"]]
    assert meta["user"] == "jane@example.com"
    assert meta["taken_at"]
  end

  test "DELETE: backs up the deleted rows", %{conn: conn, tmp_dir: dir} do
    assert {:ok, %{count: 2, backup: %{csv: csv}}} =
             dry_then_commit(conn, "DELETE FROM users WHERE id IN (9, 10)", dir)

    assert rows(conn, "SELECT count(*) FROM users") == [[8]]
    assert File.read!(csv) =~ "9,user 9,u9@x.com"
  end

  test "composite key, quoted table name, awkward values", %{conn: conn, tmp_dir: dir} do
    assert {:ok, %{count: 2, backup: %{csv: csv, json: json}}} =
             dry_then_commit(
               conn,
               ~s(DELETE FROM "Odd Name" WHERE tenant = '00000000-0000-0000-0000-000000000001'),
               dir
             )

    assert JSON.decode!(File.read!(json))["table"] == ~s("Odd Name")
    csv_text = File.read!(csv)
    assert csv_text =~ ~s("has ""quotes"", commas,\nand a newline")
    assert rows(conn, ~s[SELECT count(*) FROM "Odd Name"]) == [[1]]
  end

  test "a statement touching no rows commits with a header-only backup", %{
    conn: conn,
    tmp_dir: dir
  } do
    assert {:ok, %{count: 0, backup: %{csv: csv}}} =
             dry_then_commit(conn, "DELETE FROM users WHERE id > 100", dir)

    assert File.read!(csv) == "id,name,email\n"
  end

  test "INSERT: records the new keys, no CSV", %{conn: conn, tmp_dir: dir} do
    assert {:ok, %{count: 2, backup: %{csv: nil, json: json}}} =
             dry_then_commit(
               conn,
               "INSERT INTO users VALUES (11, 'a', 'a@x'), (12, 'b', 'b@x')",
               dir
             )

    assert Enum.sort(JSON.decode!(File.read!(json))["keys"]) == [["11"], ["12"]]
    assert rows(conn, "SELECT count(*) FROM users") == [[12]]
  end

  test "INSERT into a table without a primary key is allowed, keys empty", %{
    conn: conn,
    tmp_dir: dir
  } do
    assert {:ok, %{count: 1, backup: %{json: json}}} =
             dry_then_commit(conn, "INSERT INTO logs VALUES ('x')", dir)

    assert JSON.decode!(File.read!(json))["keys"] == []
  end

  test "data changed since the dry run: nothing committed, no backup", %{conn: conn, tmp_dir: dir} do
    statement = statement!("DELETE FROM users WHERE id <= 5")
    {:ok, %{count: 5}} = Runner.dry_run(conn, statement)

    # someone else deletes a matching row in between
    Postgrex.query!(conn, "DELETE FROM users WHERE id = 1", [])

    assert {:error, {:blocked, :changed_since_dry_run, _}} =
             Runner.commit(conn, statement, expected_count: 5, backup_dir: dir)

    assert rows(conn, "SELECT count(*) FROM users") == [[9]]
    assert File.ls!(dir) == []
  end

  test "backup can't be written: nothing is changed", %{conn: conn, tmp_dir: dir} do
    blocked_dir = Path.join(dir, "not-a-dir")
    File.write!(blocked_dir, "a file where the directory should be")

    assert {:error, {:blocked, :backup_failed, _}} =
             dry_then_commit(conn, "DELETE FROM users WHERE id = 1", blocked_dir)

    assert rows(conn, "SELECT count(*) FROM users") == [[10]]
  end

  test "UPDATE / DELETE without a primary key is blocked at commit too", %{
    conn: conn,
    tmp_dir: dir
  } do
    Postgrex.query!(conn, "INSERT INTO logs VALUES ('a')", [])

    assert {:error, {:blocked, :no_primary_key, _}} =
             Runner.commit(conn, statement!("DELETE FROM logs WHERE msg = 'a'"),
               expected_count: 1,
               backup_dir: dir
             )
  end

  test "a locked row makes the commit time out instead of waiting forever", %{
    conn: conn,
    tmp_dir: dir,
    pg: pg
  } do
    %{conn: other} = TargetDB.connect!(pg)
    parent = self()

    holder =
      Task.async(fn ->
        Postgrex.transaction(other, fn tx ->
          Postgrex.query!(
            tx,
            "SELECT * FROM #{schema_of(conn)}.users WHERE id = 1 FOR UPDATE",
            []
          )

          send(parent, :locked)
          receive do: (:release -> :ok)
        end)
      end)

    assert_receive :locked, 5_000

    assert {:error, {:db_error, message}} =
             Runner.commit(conn, statement!("DELETE FROM users WHERE id = 1"),
               expected_count: 1,
               backup_dir: dir,
               lock_timeout: 200
             )

    assert message =~ "lock timeout"
    send(holder.pid, :release)
    Task.await(holder)
  end

  defp schema_of(conn), do: rows(conn, "SELECT current_schema()") |> hd() |> hd()
end
