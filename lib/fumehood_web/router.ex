defmodule FumehoodWeb.Router do
  use FumehoodWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
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
    post "/databases/:id/backups/:backup_id/restore", ApiController, :restore
    post "/databases/:id/backups/:backup_id/restore/commit", ApiController, :restore_commit
  end

  scope "/", FumehoodWeb do
    get "/", PageController, :index
  end
end
