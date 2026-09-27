defmodule FumehoodWeb.Router do
  use FumehoodWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
    plug FumehoodWeb.Plugs.Identity
  end

  scope "/api", FumehoodWeb do
    pipe_through :api
  end
end
