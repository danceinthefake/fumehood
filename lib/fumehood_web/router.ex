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
end
