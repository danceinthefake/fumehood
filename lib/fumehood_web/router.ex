defmodule FumehoodWeb.Router do
  use FumehoodWeb, :router

  # The UI shell: the app's own scripts, styles and API only; Google Fonts
  # for the typefaces; no framing.
  @csp "default-src 'self'; script-src 'self'; connect-src 'self'; " <>
         "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; " <>
         "font-src https://fonts.gstatic.com; img-src 'self' data:; " <>
         "frame-ancestors 'none'; base-uri 'none'; form-action 'none'"

  pipeline :browser do
    plug :put_secure_browser_headers, %{"content-security-policy" => @csp}
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug :require_json
    plug :put_secure_browser_headers
    plug FumehoodWeb.Plugs.Identity
  end

  scope "/api", FumehoodWeb do
    pipe_through :api

    get "/me", ApiController, :me
    get "/databases", ApiController, :databases
    post "/databases/:id/run", ApiController, :run
    post "/databases/:id/commit", ApiController, :commit
    get "/databases/:id/backups", ApiController, :backups
    get "/databases/:id/audit", ApiController, :audit
    post "/queries/:query_id/cancel", ApiController, :cancel
    post "/databases/:id/backups/:backup_id/restore", ApiController, :restore
    post "/databases/:id/backups/:backup_id/restore/commit", ApiController, :restore_commit
  end

  scope "/", FumehoodWeb do
    pipe_through :browser
    get "/", PageController, :index
  end

  # A cross-site form or `no-cors` fetch can only send simple content types;
  # insisting on JSON means a browser must ask first (CORS), and fumehood
  # never allows it. Blocks cross-site requests made as the logged-in person.
  defp require_json(%{method: "GET"} = conn, _opts), do: conn

  defp require_json(conn, _opts) do
    case get_req_header(conn, "content-type") do
      ["application/json" <> _] ->
        conn

      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(415, ~s({"error":{"rule":"bad_request","message":"send JSON"}}))
        |> halt()
    end
  end

  # Load balancer health check; no identity, no data.
  get "/health", FumehoodWeb.PageController, :health
end
