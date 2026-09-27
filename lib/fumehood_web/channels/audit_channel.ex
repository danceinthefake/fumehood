defmodule FumehoodWeb.AuditChannel do
  @moduledoc """
  Live audit feed of one database (`audit:<database id>`). Joining replies
  with the latest entries; every new entry is pushed as `"entry"` the moment
  it's written (`Fumehood.Services.Query` broadcasts it).
  """
  use Phoenix.Channel

  alias Fumehood.Services.Query

  @impl true
  def join("audit:" <> db_id, _params, socket) do
    case Query.audit(db_id) do
      {:ok, entries} -> {:ok, %{entries: entries}, socket}
      {:error, :not_found} -> {:error, %{reason: "unknown database"}}
    end
  end
end
