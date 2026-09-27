defmodule Fumehood.RunnerTest do
  use ExUnit.Case,
    async: true,
    parameterize: for(v <- Fumehood.TargetDB.versions(), do: %{pg: v})

  alias Fumehood.{Runner, Safety, TargetDB}

  @setup [
    "CREATE TABLE users (id int PRIMARY KEY, name text, email text)",
    "INSERT INTO users SELECT g, 'user ' || g, 'u' || g || '@x.com' FROM generate_series(1, 30) g",
    "CREATE TABLE logs (msg text)",
    "INSERT INTO logs VALUES ('a'), ('b')"
  ]

  setup %{pg: pg} do
    TargetDB.connect!(pg, @setup)
  end

  defp statement!(sql) do
    {:ok, statement} = Safety.check(sql)
    statement
  end

  defp count(conn, table), do: Postgrex.query!(conn, "SELECT count(*) FROM #{table}", []).rows

  describe "read/3" do
    test "returns columns and rows", %{conn: conn} do
      assert {:ok, %{columns: ["id", "name"], rows: [[1, "user 1"]], truncated: false}} =
               Runner.read(conn, statement!("SELECT id, name FROM users WHERE id = 1"))
    end

    test "stops early on big results and says so", %{conn: conn} do
      {:ok, result} =
        Runner.read(conn, statement!("SELECT repeat('x', 100000) FROM generate_series(1, 50)"),
          max_result_bytes: 1_000_000
        )

      assert length(result.rows) in 9..11
      assert result.truncated
    end

    test "caps SELECT results at max_rows and says so", %{conn: conn} do
      {:ok, result} =
        Runner.read(conn, statement!("SELECT * FROM users ORDER BY id"), max_rows: 10)

      assert length(result.rows) == 10
      assert result.truncated
      assert hd(result.rows) |> hd() == 1
    end

    test "a trailing line comment doesn't break the wrapping", %{conn: conn} do
      assert {:ok, %{rows: [[30]]}} =
               Runner.read(conn, statement!("SELECT count(*) FROM users -- how many?"))
    end

    test "EXPLAIN and SHOW run as they are", %{conn: conn} do
      assert {:ok, %{rows: [_ | _]}} =
               Runner.read(conn, statement!("EXPLAIN SELECT * FROM users"))

      assert {:ok, %{rows: [[_path]]}} = Runner.read(conn, statement!("SHOW search_path"))
    end

    test "Postgres itself refuses writes hidden in a read (read-only transaction)", %{conn: conn} do
      Postgrex.query!(
        conn,
        """
        CREATE FUNCTION sneaky() RETURNS int LANGUAGE sql AS 'DELETE FROM users; SELECT 1'
        """,
        []
      )

      assert {:error, {:db_error, message}} = Runner.read(conn, statement!("SELECT sneaky()"))
      assert message =~ "read-only transaction"
      assert count(conn, "users") == [[30]]
    end

    test "statement_timeout stops a slow read", %{conn: conn} do
      assert {:error, {:db_error, message}} =
               Runner.read(conn, statement!("SELECT pg_sleep(2)"), statement_timeout: 100)

      assert message =~ "statement timeout"
    end

    test "database errors come back as messages", %{conn: conn} do
      assert {:error, {:db_error, message}} =
               Runner.read(conn, statement!("SELECT * FROM missing"))

      assert message =~ "does not exist"
    end
  end

  describe "dry_run/3" do
    test "counts and previews the changed rows, then rolls back", %{conn: conn} do
      assert {:ok, %{count: 5, columns: ["id", "name", "email"], preview: preview}} =
               Runner.dry_run(conn, statement!("UPDATE users SET name = 'x' WHERE id <= 5"))

      assert length(preview) == 5
      assert Enum.all?(preview, fn [_id, name, _email] -> name == "x" end)

      assert Postgrex.query!(conn, "SELECT count(*) FROM users WHERE name = 'x'", []).rows == [
               [0]
             ]
    end

    test "DELETE and INSERT dry runs leave the table untouched", %{conn: conn} do
      assert {:ok, %{count: 30}} =
               Runner.dry_run(conn, statement!("DELETE FROM users WHERE true"))

      assert {:ok, %{count: 1}} =
               Runner.dry_run(conn, statement!("INSERT INTO logs VALUES ('c')"))

      assert count(conn, "users") == [[30]]
      assert count(conn, "logs") == [[2]]
    end

    test "warns about triggers and cascading foreign keys", %{conn: conn} do
      for sql <- [
            "CREATE TABLE parent (id int PRIMARY KEY)",
            "CREATE TABLE child (id int PRIMARY KEY, parent_id int REFERENCES parent ON DELETE CASCADE)",
            "INSERT INTO parent VALUES (1)",
            "CREATE FUNCTION noop() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN RETURN NEW; END$$",
            "CREATE TRIGGER stamp AFTER UPDATE ON parent FOR EACH ROW EXECUTE FUNCTION noop()"
          ],
          do: Postgrex.query!(conn, sql, [])

      assert {:ok, %{warnings: warnings}} =
               Runner.dry_run(conn, statement!("DELETE FROM parent WHERE id = 1"))

      assert Enum.any?(warnings, &(&1 =~ "Trigger stamp"))
      assert Enum.any?(warnings, &(&1 =~ "child" and &1 =~ "deleted too"))

      # UPDATE: the foreign key doesn't cascade on update (NO ACTION)
      assert {:ok, %{warnings: [trigger]}} =
               Runner.dry_run(conn, statement!("UPDATE parent SET id = 2 WHERE id = 1"))

      assert trigger =~ "stamp"

      assert {:ok, %{warnings: []}} =
               Runner.dry_run(conn, statement!("DELETE FROM users WHERE id = 1"))
    end

    test "preview is limited", %{conn: conn} do
      assert {:ok, %{count: 30, preview: preview}} =
               Runner.dry_run(conn, statement!("DELETE FROM users WHERE id > 0"), preview: 3)

      assert length(preview) == 3
    end

    test "more changed rows than max_rows is blocked", %{conn: conn} do
      assert {:error, {:blocked, :too_many_rows, _}} =
               Runner.dry_run(conn, statement!("DELETE FROM users WHERE id > 0"), max_rows: 10)
    end

    test "UPDATE / DELETE on a table without a primary key is blocked", %{conn: conn} do
      assert {:error, {:blocked, :no_primary_key, _}} =
               Runner.dry_run(conn, statement!("DELETE FROM logs WHERE msg = 'a'"))
    end

    test "missing table is a clear error", %{conn: conn} do
      assert {:error, {:db_error, message}} =
               Runner.dry_run(conn, statement!("DELETE FROM nope WHERE id = 1"))

      assert message =~ "doesn't exist"
    end
  end

  describe "primary_key/2" do
    test "columns in key order, [] without a key, nil when missing", %{conn: conn, schema: schema} do
      Postgrex.query!(conn, "CREATE TABLE pairs (b uuid, a bigint, PRIMARY KEY (a, b))", [])

      assert Runner.primary_key(conn, {nil, "users"}) == [{"id", "integer"}]
      assert Runner.primary_key(conn, {schema, "pairs"}) == [{"a", "bigint"}, {"b", "uuid"}]
      assert Runner.primary_key(conn, {nil, "logs"}) == []
      assert Runner.primary_key(conn, {nil, "nope"}) == nil
    end
  end
end
