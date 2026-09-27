defmodule FumehoodWeb.Plugs.AllowedHosts do
  @moduledoc """
  Refuses requests whose `Host` isn't one of `config :fumehood, :allowed_hosts`
  (no list: any host), or of the `hosts:` option (tests).

  In `ssh_tunnel` and `dev` modes fumehood answers on localhost and
  identifies whoever owns the connection — so a web page whose domain
  resolves to 127.0.0.1 (DNS rebinding) would otherwise be served as the
  person browsing it. Only the real local names are let in. `/health` stays
  open for load balancer checks.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(%{request_path: "/health"} = conn, _opts), do: conn

  def call(conn, opts) do
    case opts[:hosts] || Application.get_env(:fumehood, :allowed_hosts) do
      nil ->
        conn

      hosts ->
        if conn.host in hosts,
          do: conn,
          else: conn |> send_resp(403, "unknown host") |> halt()
    end
  end
end
