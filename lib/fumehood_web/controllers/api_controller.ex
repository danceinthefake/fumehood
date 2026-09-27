defmodule FumehoodWeb.ApiController do
  @moduledoc """
  JSON API. Each action reads its parameters, calls `Fumehood.Services.Query`
  and returns the result; errors go through `FumehoodWeb.FallbackController`.
  """
  use FumehoodWeb, :controller

  alias Fumehood.Queries
  alias Fumehood.Services.Query

  action_fallback FumehoodWeb.FallbackController

  # GET /api/me
  def me(conn, _params), do: json(conn, conn.assigns.identity)

  # GET /api/databases
  def databases(conn, _params), do: json(conn, %{databases: Query.list_databases()})

  # POST /api/databases/:id/run  {"sql": "..."}
  def run(conn, %{"id" => id} = params) do
    with {:ok, sql} <- sql(params),
         {:ok, opts} <- query_opts(params),
         {:ok, result} <- Query.run(id, sql, conn.assigns.identity, opts) do
      json(conn, result)
    end
  end

  # POST /api/databases/:id/commit  {"sql": "...", "expected_count": 3}
  def commit(conn, %{"id" => id} = params) do
    with {:ok, sql} <- sql(params),
         {:ok, count} <- expected_count(params),
         {:ok, opts} <- query_opts(params),
         {:ok, result} <- Query.commit(id, sql, count, conn.assigns.identity, opts) do
      json(conn, result)
    end
  end

  # GET /api/databases/:id/backups
  def backups(conn, %{"id" => id}) do
    with {:ok, backups} <- Query.backups(id), do: json(conn, %{backups: backups})
  end

  # GET /api/databases/:id/audit?before=123
  def audit(conn, %{"id" => id} = params) do
    before =
      case Integer.parse(params["before"] || "") do
        {n, ""} -> n
        _ -> nil
      end

    with {:ok, entries} <- Query.audit(id, 100, before), do: json(conn, %{entries: entries})
  end

  # POST /api/databases/:id/backups/:backup_id/restore
  def restore(conn, %{"id" => id, "backup_id" => backup_id} = params) do
    with {:ok, opts} <- query_opts(params),
         {:ok, result} <- Query.restore_dry_run(id, backup_id, conn.assigns.identity, opts) do
      json(conn, result)
    end
  end

  # POST /api/databases/:id/backups/:backup_id/restore/commit  {"expected_count": 3}
  def restore_commit(conn, %{"id" => id, "backup_id" => backup_id} = params) do
    with {:ok, count} <- expected_count(params),
         {:ok, opts} <- query_opts(params),
         {:ok, result} <-
           Query.restore_commit(id, backup_id, count, conn.assigns.identity, opts) do
      json(conn, result)
    end
  end

  # POST /api/queries/:query_id/cancel — only the query's owner can cancel it
  def cancel(conn, %{"query_id" => query_id}) do
    with :ok <- Queries.cancel(query_id, conn.assigns.identity.id) do
      json(conn, %{cancelled: true})
    end
  end

  # The browser names each query (a UUID) so it can cancel it later.
  defp query_opts(%{"query_id" => id}) when is_binary(id) do
    if id =~ ~r/\A[0-9A-Za-z-]{1,64}\z/,
      do: {:ok, [query_id: id]},
      else: {:error, {:bad_request, "query_id must be up to 64 letters, digits or -"}}
  end

  defp query_opts(_params), do: {:ok, []}

  defp sql(%{"sql" => sql}) when is_binary(sql), do: {:ok, sql}
  defp sql(_), do: {:error, {:bad_request, "sql (a string) is required"}}

  defp expected_count(%{"expected_count" => n}) when is_integer(n) and n >= 0, do: {:ok, n}

  defp expected_count(_),
    do: {:error, {:bad_request, "expected_count (the dry run's row count) is required"}}
end
