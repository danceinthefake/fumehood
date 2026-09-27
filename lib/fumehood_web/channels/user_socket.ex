defmodule FumehoodWeb.UserSocket do
  @moduledoc """
  The browser's WebSocket (Phoenix Channels). The connection is identified the
  same way API requests are (`FumehoodWeb.Plugs.Identity`, DESIGN.md §6):
  IAP's signed JWT (sent as an `x-` header with the WebSocket upgrade), the
  owner of the tunnelled TCP connection, or the dev user. No identity, no
  socket.
  """
  use Phoenix.Socket

  alias Fumehood.Identity

  channel "audit:*", FumehoodWeb.AuditChannel

  @impl true
  def connect(_params, socket, connect_info) do
    access = Application.fetch_env!(:fumehood, :access)

    case identify(access, connect_info) do
      {:ok, id} -> {:ok, assign(socket, :identity, %{id: id, source: access[:mode]})}
      {:error, _reason} -> :error
    end
  end

  @impl true
  def id(socket), do: "user:#{socket.assigns.identity.id}"

  defp identify([mode: :iap, audience: audience], %{x_headers: headers}) do
    headers
    |> List.keyfind("x-goog-iap-jwt-assertion", 0)
    |> then(&(&1 && elem(&1, 1)))
    |> Identity.iap(audience)
  end

  # Both ends of a tunnelled connection are on the loopback address; the
  # local port is fumehood's own.
  defp identify([mode: :ssh_tunnel], %{peer_data: %{address: ip, port: port}}) do
    local_port = FumehoodWeb.Endpoint.config(:http)[:port]
    Identity.ssh_tunnel({ip, port}, {ip, local_port})
  end

  defp identify([mode: :dev, user: user], _connect_info), do: {:ok, user}
  defp identify(_access, _connect_info), do: {:error, "not identified"}
end
