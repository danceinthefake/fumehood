defmodule Fumehood.Queries do
  @moduledoc """
  Running queries, so they can be cancelled (DESIGN.md §5.5).

  Each HTTP request already runs in its own process; while it runs a query it
  registers here under an id the browser chose, with its owner and — once the
  transaction has started — its Postgres backend pid. `cancel/2` then asks
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
      [{^query_id, ^owner, db_id, backend, _}] ->
        :ets.update_element(@table, query_id, {5, true})

        if backend,
          do:
            Postgrex.query(Fumehood.Databases.conn(db_id), "SELECT pg_cancel_backend($1)", [
              backend
            ])

        :ok

      _ ->
        {:error, :not_found}
    end
  end
end
