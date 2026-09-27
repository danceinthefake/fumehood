defmodule FumehoodWeb.IdentityPlugTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias FumehoodWeb.Plugs.Identity

  test "dev mode assigns the configured user" do
    conn = conn(:get, "/") |> Identity.call(mode: :dev, user: "me@x.com")
    assert conn.assigns.identity == %{id: "me@x.com", source: :dev}
    refute conn.halted
  end

  test "no valid identity: 401 with a JSON reason" do
    conn = conn(:get, "/") |> Identity.call(mode: :iap, audience: "/projects/1/x")
    assert conn.halted
    assert conn.status == 401

    assert %{"error" => "not identified: missing IAP assertion header"} =
             JSON.decode!(conn.resp_body)
  end

  defmodule Echo do
    # A tiny app behind the plug in ssh_tunnel mode: answers with the identity.
    def init(opts), do: opts

    def call(conn, _opts) do
      conn = Identity.call(conn, mode: :ssh_tunnel)
      if conn.halted, do: conn, else: send_resp(conn, 200, conn.assigns.identity.id)
    end
  end

  # Real TCP: the connection comes from this test process, so the socket's
  # owner is the Linux user running the tests.
  test "ssh_tunnel mode identifies the Linux user owning the connection (IPv4 and IPv6)" do
    {me, 0} = System.cmd("id", ["-un"])

    for ip <- [{127, 0, 0, 1}, {0, 0, 0, 0, 0, 0, 0, 1}] do
      server =
        start_supervised!({Bandit, plug: Echo, ip: ip, port: 0, startup_log: false}, id: ip)

      {:ok, {_, port}} = ThousandIsland.listener_info(server)

      {:ok, socket} = :gen_tcp.connect(ip, port, [:binary, active: false])
      :ok = :gen_tcp.send(socket, "GET / HTTP/1.1\r\nhost: x\r\nconnection: close\r\n\r\n")
      response = recv_all(socket, "")

      assert response =~ "200 OK"
      assert String.ends_with?(response, "\r\n\r\n" <> String.trim(me))
    end
  end

  defp recv_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} -> recv_all(socket, acc <> data)
      {:error, :closed} -> acc
    end
  end
end
