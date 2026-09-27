defmodule Fumehood.SafetyTest do
  use ExUnit.Case, async: true

  alias Fumehood.Safety
  alias Fumehood.Safety.Statement

  defp rule(sql) do
    {:error, {:blocked, rule, message}} = Safety.check(sql)
    assert is_binary(message)
    rule
  end

  defp ok(sql) do
    {:ok, %Statement{} = statement} = Safety.check(sql)
    statement
  end

  describe "read path" do
    test "plain SELECT, any casing" do
      assert %{kind: :read, command: :select} = ok("SELECT * FROM users WHERE id = 1")
      assert %{kind: :read, command: :select} = ok("sElEcT 1")
    end

    test "read-only CTE" do
      assert %{kind: :read} = ok("WITH u AS (SELECT * FROM users) SELECT count(*) FROM u")
    end

    test "EXPLAIN without ANALYZE, even of a write, only plans" do
      assert %{kind: :read, command: :explain} = ok("EXPLAIN DELETE FROM users WHERE id = 1")
    end

    test "EXPLAIN ANALYZE of a SELECT" do
      assert %{kind: :read, command: :explain} = ok("EXPLAIN (ANALYZE, BUFFERS) SELECT 1")
    end

    test "SHOW" do
      assert %{kind: :read, command: :show} = ok("SHOW search_path")
    end
  end

  describe "write path" do
    test "INSERT, UPDATE and DELETE with WHERE carry their target table" do
      assert %{kind: :write, command: :insert, table: {nil, "users"}} =
               ok("INSERT INTO users (name) VALUES ('a')")

      assert %{kind: :write, command: :update, table: {"public", "users"}} =
               ok("UPDATE public.users SET name = 'a' WHERE id = 1")

      assert %{kind: :write, command: :delete, table: {nil, "Users"}} =
               ok(~s(DELETE FROM "Users" WHERE id = 1))
    end

    test "INSERT … SELECT and ON CONFLICT" do
      assert %{kind: :write, command: :insert} =
               ok("INSERT INTO archive SELECT * FROM users WHERE id < 10 ON CONFLICT DO NOTHING")
    end
  end

  describe "blocked" do
    test "unparseable text" do
      assert rule("SELEC 1") == :parse_error
    end

    test "empty text or only a comment" do
      assert rule("") == :empty
      assert rule("-- nothing here") == :empty
    end

    test "more than one statement, including one hidden after a comment" do
      assert rule("SELECT 1; SELECT 2") == :multiple_statements
      assert rule("SELECT 1; /* innocent */ DROP TABLE users") == :multiple_statements
    end

    test "UPDATE / DELETE without WHERE, whatever the casing or comments" do
      assert rule("UPDATE users SET name = 'x'") == :missing_where
      assert rule("/* cleanup */ delete from USERS -- all of them") == :missing_where
    end

    test "data-changing CTEs, in reads and in writes" do
      assert rule("WITH d AS (DELETE FROM t WHERE id = 1 RETURNING *) SELECT * FROM d") ==
               :writing_cte

      assert rule(
               "WITH u AS (UPDATE t SET a = 1 WHERE id = 1 RETURNING id) DELETE FROM s WHERE id IN (SELECT id FROM u)"
             ) ==
               :writing_cte

      assert rule(
               "WITH i AS (INSERT INTO t VALUES (1) RETURNING *) INSERT INTO s SELECT * FROM i"
             ) ==
               :writing_cte
    end

    test "denied functions anywhere, schema-qualified or not" do
      assert rule("SELECT pg_terminate_backend(123)") == :denied_function
      assert rule("SELECT pg_catalog.PG_CANCEL_BACKEND(1)") == :denied_function
      assert rule("UPDATE t SET a = 1 WHERE pg_reload_conf()") == :denied_function
      assert rule("SELECT dblink_exec('host=x', 'DROP TABLE t')") == :denied_function
      assert rule("SELECT lo_import('/etc/passwd')") == :denied_function
      assert rule("SELECT query_to_xml('DELETE FROM t', true, true, '')") == :denied_function
      assert rule("SELECT pg_advisory_lock(1)") == :denied_function

      assert rule("SELECT 1 FROM t WHERE x IN (SELECT pg_notify('ch', 'x'))") ==
               :denied_function
    end

    test "SELECT … INTO and row locking" do
      assert rule("SELECT * INTO copy_of_users FROM users") == :select_into
      assert rule("SELECT * FROM users FOR UPDATE") == :row_locking
      assert rule("SELECT * FROM users FOR SHARE SKIP LOCKED") == :row_locking
    end

    test "EXPLAIN ANALYZE of a write, and of a blocked statement" do
      assert rule("EXPLAIN ANALYZE DELETE FROM t WHERE id = 1") == :explain_analyze_write
      assert rule("EXPLAIN ANALYZE UPDATE t SET a = 1") == :missing_where
    end

    test "MERGE" do
      assert rule("MERGE INTO t USING s ON t.id = s.id WHEN MATCHED THEN DELETE") == :merge
    end

    test "transaction control typed by the user" do
      for sql <- [
            "BEGIN",
            "COMMIT",
            "ROLLBACK",
            "SAVEPOINT a",
            "SET statement_timeout = 0",
            "SET ROLE admin"
          ] do
        assert rule(sql) == :transaction_control, sql
      end
    end

    test "maintenance statements" do
      for sql <- [
            "COPY users TO STDOUT",
            "VACUUM users",
            "CLUSTER users",
            "REINDEX TABLE users",
            "LOCK TABLE users"
          ] do
        assert rule(sql) == :maintenance, sql
      end
    end

    test "schema and permission changes" do
      for sql <- [
            "DROP TABLE users",
            "TRUNCATE users",
            "ALTER TABLE users ADD COLUMN x int",
            "CREATE TABLE x (id int)",
            "CREATE INDEX ON users (name)",
            "GRANT SELECT ON users TO bob",
            "CREATE TABLE x AS SELECT * FROM users",
            "COMMENT ON TABLE users IS 'x'"
          ] do
        assert rule(sql) == :ddl, sql
      end
    end

    test "anything else is not allowed" do
      for sql <- [
            "DO $$ BEGIN DELETE FROM t; END $$",
            "CALL cleanup()",
            "LISTEN ch",
            "DISCARD ALL",
            "CHECKPOINT"
          ] do
        assert rule(sql) == :not_allowed, sql
      end
    end
  end
end
