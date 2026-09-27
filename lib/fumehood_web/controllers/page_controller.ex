defmodule FumehoodWeb.PageController do
  @moduledoc """
  Serves the Vue app's shell (`priv/static/index.html`, built from
  `assets/`). The shell holds no data; everything comes from `/api`, which
  checks identity on every request.
  """
  use FumehoodWeb, :controller

  def index(conn, _params) do
    path = Application.app_dir(:fumehood, "priv/static/index.html")

    if File.exists?(path) do
      conn |> put_resp_content_type("text/html") |> send_file(200, path)
    else
      send_resp(conn, 503, "The UI isn't built yet: cd assets && pnpm install && pnpm build")
    end
  end
end
