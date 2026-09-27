defmodule Fumehood.Repo do
  use Ecto.Repo,
    otp_app: :fumehood,
    adapter: Ecto.Adapters.SQLite3
end
