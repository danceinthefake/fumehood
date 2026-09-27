defmodule FumehoodWeb.Plugs.Identity do
  @moduledoc """
  Puts the requester's identity in `conn.assigns.identity`
  (`%{id: email_or_username, source: :iap | :ssh_tunnel | :dev}`), or halts
  with 401. The mode comes from `config :fumehood, :access` unless given as
  an option (tests).
  """

  import Plug.Conn

  alias Fumehood.Identity

  def init(opts), do: opts

  def call(conn, opts) do
    access = if opts == [], do: Application.fetch_env!(:fumehood, :access), else: opts

    case identify(conn, access) do
      {:ok, id} ->
        assign(conn, :identity, %{id: id, source: access[:mode]})

      {:error, reason} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, JSON.encode!(%{error: "not identified: #{reason}"}))
        |> halt()
    end
  end

  defp identify(conn, mode: :iap, audience: audience) do
    conn |> get_req_header("x-goog-iap-jwt-assertion") |> List.first() |> Identity.iap(audience)
  end

  # Cached for the lifetime of the TCP connection: Bandit serves all requests
  # of one connection from one process, so the process dictionary is
  # per connection.
  defp identify(conn, mode: :ssh_tunnel) do
    %{address: peer_ip, port: peer_port} = get_peer_data(conn)
    %{address: local_ip, port: local_port} = get_sock_data(conn)
    key = {__MODULE__, peer_ip, peer_port}

    case Process.get(key) do
      nil ->
        with {:ok, id} <- Identity.ssh_tunnel({peer_ip, peer_port}, {local_ip, local_port}) do
          Process.put(key, id)
          {:ok, id}
        end

      id ->
        {:ok, id}
    end
  end

  defp identify(_conn, mode: :dev, user: user), do: {:ok, user}
end
