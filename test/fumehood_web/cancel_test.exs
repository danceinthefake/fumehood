defmodule FumehoodWeb.CancelTest do
  use FumehoodWeb.ConnCase, async: true

  alias Fumehood.Queries

  setup do
    table = "cancel_#{System.unique_integer([:positive])}"
    pool = Fumehood.Databases.conn("pg16")
    Postgrex.query!(pool, "CREATE TABLE #{table} (id int PRIMARY KEY, n int)", [])
    Postgrex.query!(pool, "INSERT INTO #{table} VALUES (1, 1)", [])
    on_exit(fn -> Postgrex.query!(Fumehood.Databases.conn("pg16"), "DROP TABLE #{table}", []) end)
    %{table: table, query_id: "q-#{System.unique_integer([:positive])}"}
  end

  # Waits until the query has started its transaction (backend pid known).
  defp wait_running(query_id, tries \\ 200) do
    case :ets.lookup(Queries, query_id) do
      [{^query_id, _, _, backend, _}] when is_integer(backend) -> :ok
      _ when tries > 0 -> Process.sleep(10) && wait_running(query_id, tries - 1)
      _ -> flunk("query #{query_id} never started")
    end
  end

  defp audit(conn),
    do: conn |> get("/api/databases/pg16/audit") |> json_response(200) |> Map.fetch!("entries")

  test "cancelling a running read stops it in Postgres", %{conn: conn, query_id: id} do
    started = System.monotonic_time(:millisecond)

    request =
      Task.async(fn ->
        post(conn, "/api/databases/pg16/run", %{sql: "SELECT pg_sleep(10)", query_id: id})
      end)

    wait_running(id)

    assert %{"cancelled" => true} =
             conn |> post("/api/queries/#{id}/cancel") |> json_response(200)

    assert %{"error" => %{"rule" => "cancelled"}} = request |> Task.await() |> json_response(409)
    assert System.monotonic_time(:millisecond) - started < 5_000

    assert [%{"outcome" => "cancelled", "action" => "run", "sql" => "SELECT pg_sleep(10)"} | _] =
             audit(conn)

    assert :ets.lookup(Queries, id) == []
  end

  test "cancelling a commit that waits on a lock: nothing is committed", %{
    conn: conn,
    table: table,
    query_id: id
  } do
    parent = self()

    holder =
      Task.async(fn ->
        Postgrex.transaction(Fumehood.Databases.conn("pg16"), fn tx ->
          Postgrex.query!(tx, "SELECT * FROM #{table} WHERE id = 1 FOR UPDATE", [])
          send(parent, :locked)
          receive do: (:release -> :ok)
        end)
      end)

    assert_receive :locked, 5_000

    request =
      Task.async(fn ->
        post(conn, "/api/databases/pg16/commit", %{
          sql: "UPDATE #{table} SET n = 2 WHERE id = 1",
          expected_count: 1,
          query_id: id
        })
      end)

    wait_running(id)
    Process.sleep(100)
    post(conn, "/api/queries/#{id}/cancel")

    assert %{"error" => %{"rule" => "cancelled"}} = request |> Task.await() |> json_response(409)
    send(holder.pid, :release)
    Task.await(holder)

    assert Postgrex.query!(Fumehood.Databases.conn("pg16"), "SELECT n FROM #{table}", []).rows ==
             [[1]]

    assert [
             %{"action" => "commit", "outcome" => "cancelled"},
             %{"action" => "commit", "outcome" => "started"} | _
           ] = audit(conn)
  end

  test "only the owner can cancel; unknown ids are 404; ids can't be reused while running", %{
    conn: conn,
    query_id: id
  } do
    request =
      Task.async(fn ->
        post(conn, "/api/databases/pg16/run", %{sql: "SELECT pg_sleep(10)", query_id: id})
      end)

    wait_running(id)
    assert Queries.cancel(id, "someone-else@example.com") == {:error, :not_found}
    assert conn |> post("/api/queries/nope/cancel") |> json_response(404)

    assert %{"error" => %{"rule" => "duplicate_query_id"}} =
             conn
             |> post("/api/databases/pg16/run", %{sql: "SELECT 1", query_id: id})
             |> json_response(422)

    post(conn, "/api/queries/#{id}/cancel")
    assert request |> Task.await() |> json_response(409)
  end

  test "bad query ids are rejected", %{conn: conn} do
    assert %{"error" => %{"rule" => "bad_request"}} =
             conn
             |> post("/api/databases/pg16/run", %{sql: "SELECT 1", query_id: "../x"})
             |> json_response(400)
  end
end
