defmodule Fumehood.Queries do
  @moduledoc """
  Running queries, so they can be cancelled (DESIGN.md §5.5).

  Each HTTP request already runs in its own process; while it runs a query it
  registers here under an id the browser chose, with its owner and — once the
  transaction has started — its Postgres backend pid and transaction start. `cancel/2` then asks
  Postgres to stop that backend's statement (`pg_cancel_backend`) from another
  pooled connection: the statement fails, the transaction rolls back, and the
  query's result becomes `{:error, {:cancelled, _}}`.

  Killing the Elixir process alone wouldn't do: Postgres would keep running
  the statement until it finished or hit `statement_timeout`.

  The table is an ETS set owned by this (supervised) process.
  """
  use GenServer

  @table __MODULE__

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end

  @doc """
  Runs `fun` as query `query_id` of `owner` on database `db_id`. `fun` gets an
  `on_backend` callback to pass to `Fumehood.Runner` (`on_backend:` option).
  A cancelled query's database error is turned into `{:error, {:cancelled, _}}`.
  `query_id: nil` just runs `fun` (nothing to cancel it by).
  """
  @spec track(String.t() | nil, String.t(), String.t(), (fun() -> result)) :: result
        when result: term()
  def track(nil, _owner, _db_id, fun), do: fun.(fn _pid -> :ok end)

  def track(query_id, owner, db_id, fun) do
    if :ets.insert_new(@table, {query_id, owner, db_id, nil, false}) do
      try do
        result = fun.(fn backend -> :ets.update_element(@table, query_id, {4, backend}) end)

        case {result, :ets.lookup(@table, query_id)} do
          {{:error, {:db_error, _}}, [{_, _, _, _, true}]} -> {:error, {:cancelled, "Cancelled."}}
          _ -> result
        end
      after
        :ets.delete(@table, query_id)
      end
    else
      {:error, {:blocked, :duplicate_query_id, "A query with this id is already running."}}
    end
  end

  @doc """
  Cancels a running query. Only its owner can; anyone else (or an unknown or
  finished id) gets `:not_found`.
  """
  @spec cancel(String.t(), String.t()) :: :ok | {:error, :not_found}
  def cancel(query_id, owner) do
    case :ets.lookup(@table, query_id) do
      [{^query_id, ^owner, _db_id, _backend, _}] ->
        :ets.update_element(@table, query_id, {5, true})
        cancel_backend(query_id)
        # pg_cancel_backend only stops a *running* statement: if the query is
        # between statements (just after BEGIN, say), it's a no-op. Keep
        # cancelling until the query has ended.
        Task.start(fn -> keep_cancelling(query_id, 100) end)
        :ok

      _ ->
        {:error, :not_found}
    end
  end

  # ponytail: an unsupervised polling task per cancel (100 ms, at most 10 s);
  # fine for a handful of cancels, supervise it if cancels become frequent.
  defp keep_cancelling(_query_id, 0), do: :ok

  defp keep_cancelling(query_id, tries) do
    Process.sleep(100)
    if cancel_backend(query_id) == :running, do: keep_cancelling(query_id, tries - 1)
  end

  defp cancel_backend(query_id) do
    case :ets.lookup(@table, query_id) do
      [{_, _, db_id, backend, true}] ->
        # Only while that backend is still in *this* query's transaction: once
        # the query ends, its pooled connection may already run someone else's.
        with {pid, started} <- backend do
          Postgrex.query(
            Fumehood.Databases.conn(db_id),
            "SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE pid = $1 AND xact_start = $2",
            [pid, started]
          )
        end

        :running

      _ ->
        :ended
    end
  end
end
