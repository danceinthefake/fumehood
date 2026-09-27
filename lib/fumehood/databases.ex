defmodule Fumehood.Databases do
  @moduledoc """
  The configured target databases: one Postgrex connection pool each,
  looked up by the database id from `fumehood.toml`.

  The config is loaded once at startup and kept in `:persistent_term`
  (read on every request, written once).
  """

  use Supervisor

  alias Fumehood.Config
  alias Fumehood.Config.Database

  @registry Fumehood.Databases.Registry

  def start_link(%Config{} = config),
    do: Supervisor.start_link(__MODULE__, config, name: __MODULE__)

  @impl true
  def init(config) do
    :persistent_term.put({__MODULE__, :config}, config)

    pools =
      for {id, db} <- config.databases do
        opts =
          Keyword.merge(db.connect,
            pool_size: db.pool_size,
            name: {:via, Registry, {@registry, id}}
          )

        Supervisor.child_spec({Postgrex, opts}, id: {:pool, id})
      end

    Supervisor.init([{Registry, keys: :unique, name: @registry} | pools], strategy: :one_for_one)
  end

  @doc "The loaded config."
  @spec config() :: Config.t()
  def config, do: :persistent_term.get({__MODULE__, :config})

  @doc "All databases, sorted by id."
  @spec list() :: [Database.t()]
  def list, do: config().databases |> Map.values() |> Enum.sort_by(& &1.id)

  @doc "One database by id."
  @spec fetch(String.t()) :: {:ok, Database.t()} | :error
  def fetch(id), do: Map.fetch(config().databases, id)

  @doc "The connection pool of a database, for `Fumehood.Runner` calls."
  @spec conn(String.t()) :: GenServer.name()
  def conn(id), do: {:via, Registry, {@registry, id}}
end
