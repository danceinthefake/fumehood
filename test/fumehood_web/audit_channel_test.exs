defmodule FumehoodWeb.AuditChannelTest do
  # The channel runs in its own process: shared sandbox, not async.
  use FumehoodWeb.ChannelCase, async: false

  alias Fumehood.Services.Query
  alias FumehoodWeb.{AuditChannel, UserSocket}

  @identity %{id: "test@localhost", source: :dev}

  test "the socket takes the identity like the API does" do
    assert {:ok, socket} = connect(UserSocket, %{}, connect_info: %{})
    assert socket.assigns.identity == %{id: "test@localhost", source: :dev}
  end

  test "IAP mode without a valid token: no socket" do
    previous = Application.fetch_env!(:fumehood, :access)
    Application.put_env(:fumehood, :access, mode: :iap, audience: "/projects/1/x")
    on_exit(fn -> Application.put_env(:fumehood, :access, previous) end)

    assert :error = connect(UserSocket, %{}, connect_info: %{x_headers: []})

    assert :error =
             connect(UserSocket, %{},
               connect_info: %{x_headers: [{"x-goog-iap-jwt-assertion", "forged"}]}
             )
  end

  test "joining replies with recent entries, then new ones are pushed live" do
    {:ok, _} = Query.run("pg16", "SELECT 1", @identity)

    {:ok, socket} = connect(UserSocket, %{}, connect_info: %{})

    assert {:ok, %{entries: [%{action: "read", sql: "SELECT 1"} | _]}, _socket} =
             subscribe_and_join(socket, AuditChannel, "audit:pg16")

    {:ok, _} = Query.run("pg16", "SELECT 2", @identity)
    assert_push "entry", %{action: "read", outcome: "ok", sql: "SELECT 2", user: "test@localhost"}

    Query.run("pg16", "DROP TABLE x", @identity)
    assert_push "entry", %{action: "run", outcome: "blocked", rule: "ddl"}
  end

  test "entries of other databases are not pushed" do
    {:ok, socket} = connect(UserSocket, %{}, connect_info: %{})
    {:ok, _, _} = subscribe_and_join(socket, AuditChannel, "audit:pg18")

    {:ok, _} = Query.run("pg16", "SELECT 1", @identity)
    refute_push "entry", _
  end

  test "unknown database: join refused" do
    {:ok, socket} = connect(UserSocket, %{}, connect_info: %{})

    assert {:error, %{reason: "unknown database"}} =
             subscribe_and_join(socket, AuditChannel, "audit:nope")
  end
end
