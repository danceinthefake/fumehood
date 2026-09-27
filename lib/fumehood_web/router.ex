defmodule FumehoodWeb.Router do
  use FumehoodWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", FumehoodWeb do
    pipe_through :api
  end
end
