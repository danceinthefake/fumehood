defmodule FumehoodWeb.FallbackController do
  @moduledoc "Turns service errors into JSON responses."
  use FumehoodWeb, :controller

  def call(conn, {:error, {:blocked, rule, message}}), do: error(conn, 422, rule, message)
  def call(conn, {:error, {:db_error, message}}), do: error(conn, 422, :db_error, message)
  def call(conn, {:error, {:cancelled, message}}), do: error(conn, 409, :cancelled, message)
  def call(conn, {:error, :not_found}), do: error(conn, 404, :not_found, "Not found.")
  def call(conn, {:error, {:bad_request, message}}), do: error(conn, 400, :bad_request, message)

  defp error(conn, status, rule, message) do
    conn |> put_status(status) |> json(%{error: %{rule: rule, message: message}})
  end
end
