defmodule FumehoodWeb.ApiTest do
  # Shares the public schema of the test databases: each test uses its own
  # table name.
  use FumehoodWeb.ConnCase, async: true

  setup do
    table = "api_#{System.unique_integer([:positive])}"
    pool = Fumehood.Databases.conn("pg16")

    Postgrex.query!(
      pool,
      "CREATE TABLE #{table} (id uuid PRIMARY KEY, n int, price numeric, note text, blob bytea)",
      []
    )

    Postgrex.query!(
      pool,
      "INSERT INTO #{table} SELECT gen_random_uuid(), g, g * 1.5, 'note ' || g, '\\x01ff' FROM generate_series(1, 5) g",
      []
    )

    on_exit(fn -> Postgrex.query!(Fumehood.Databases.conn("pg16"), "DROP TABLE #{table}", []) end)
    %{table: table}
  end

  defp post_json(conn, path, body), do: post(conn, path, body)

  test "GET /health", %{conn: conn} do
    assert conn |> get("/health") |> response(200) == "ok"
  end

  test "GET /api/me and /api/databases", %{conn: conn} do
    assert json_response(get(conn, "/api/me"), 200) == %{
             "id" => "test@localhost",
             "source" => "dev"
           }

    assert %{
             "databases" => [
               %{"id" => "pg16", "mode" => "read_write"},
               %{"id" => "pg18", "mode" => "read_only"}
             ]
           } =
             json_response(get(conn, "/api/databases"), 200)
  end

  test "run a read: JSON-safe values", %{conn: conn, table: table} do
    body =
      post_json(conn, "/api/databases/pg16/run", %{
        sql: "SELECT id, n, price FROM #{table} ORDER BY n LIMIT 1"
      })

    assert %{
             "kind" => "read",
             "command" => "select",
             "columns" => ["id", "n", "price"],
             "rows" => [[uuid, 1, "1.5"]],
             "truncated" => false
           } = json_response(body, 200)

    assert uuid =~ ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  end

  test "dry run → commit → backups → restore", %{conn: conn, table: table} do
    sql = "UPDATE #{table} SET price = 0 WHERE n <= 2"

    assert %{"kind" => "write", "command" => "update", "count" => 2, "preview" => preview} =
             json_response(post_json(conn, "/api/databases/pg16/run", %{sql: sql}), 200)

    assert Enum.all?(preview, fn [_id, _n, price | _] -> price == "0" end)

    assert %{"count" => 2, "backup_id" => backup_id} =
             json_response(
               post_json(conn, "/api/databases/pg16/commit", %{sql: sql, expected_count: 2}),
               200
             )

    assert %{"backups" => backups} = json_response(get(conn, "/api/databases/pg16/backups"), 200)

    assert %{"operation" => "update", "rows" => 2, "user" => "test@localhost"} =
             Enum.find(backups, &(&1["id"] == backup_id))

    path = "/api/databases/pg16/backups/#{backup_id}/restore"

    assert %{"count" => 2, "sql" => "UPDATE" <> _} =
             json_response(post_json(conn, path, %{}), 200)

    assert %{"count" => 2, "backup_id" => _} =
             json_response(post_json(conn, path <> "/commit", %{expected_count: 2}), 200)

    assert %{"rows" => [[prices]]} =
             json_response(
               post_json(conn, "/api/databases/pg16/run", %{
                 sql: "SELECT sum(price)::text FROM #{table}"
               }),
               200
             )

    assert prices == "22.5"
  end

  test "blocked statements and read-only databases are 422 with a rule", %{
    conn: conn,
    table: table
  } do
    assert %{"error" => %{"rule" => "missing_where"}} =
             json_response(
               post_json(conn, "/api/databases/pg16/run", %{sql: "DELETE FROM #{table}"}),
               422
             )

    assert %{"error" => %{"rule" => "read_only_database"}} =
             json_response(
               post_json(conn, "/api/databases/pg18/run", %{sql: "DELETE FROM t WHERE id = 1"}),
               422
             )

    assert %{"error" => %{"rule" => "not_a_write"}} =
             json_response(
               post_json(conn, "/api/databases/pg16/commit", %{sql: "SELECT 1", expected_count: 0}),
               422
             )

    assert %{"error" => %{"rule" => "changed_since_dry_run"}} =
             json_response(
               post_json(conn, "/api/databases/pg16/commit", %{
                 sql: "DELETE FROM #{table} WHERE n = 1",
                 expected_count: 3
               }),
               422
             )
  end

  test "bad requests and unknown things", %{conn: conn} do
    assert %{"error" => %{"rule" => "bad_request"}} =
             json_response(post_json(conn, "/api/databases/pg16/run", %{}), 400)

    assert %{"error" => %{"rule" => "bad_request"}} =
             json_response(
               post_json(conn, "/api/databases/pg16/commit", %{sql: "DELETE FROM t WHERE id = 1"}),
               400
             )

    assert json_response(post_json(conn, "/api/databases/nope/run", %{sql: "SELECT 1"}), 404)

    assert json_response(
             post_json(conn, "/api/databases/pg16/backups/..%2F..%2Fetc%2Fpasswd/restore", %{}),
             404
           )

    assert json_response(
             post_json(conn, "/api/databases/pg16/backups/20990101T000000-deadbeef/restore", %{}),
             404
           )
  end

  test "restores are refused on read-only databases", %{conn: conn} do
    assert %{"error" => %{"rule" => "read_only_database"}} =
             json_response(
               post_json(conn, "/api/databases/pg18/backups/anything/restore", %{}),
               422
             )
  end
end
