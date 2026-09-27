defmodule Fumehood.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    prepare_store()

    children =
      [
        FumehoodWeb.Telemetry,
        Fumehood.Repo,
        {Ecto.Migrator,
         repos: Application.fetch_env!(:fumehood, :ecto_repos), skip: skip_migrations?()},
        {Phoenix.PubSub, name: Fumehood.PubSub},
        Fumehood.Queries
      ] ++ databases() ++ [FumehoodWeb.Endpoint]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Fumehood.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    FumehoodWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # Target databases from fumehood.toml; not started in tests (they bring
  # their own connections). A bad config stops startup with every problem.
  defp databases do
    case Application.get_env(:fumehood, :config_path) do
      nil ->
        []

      path ->
        case Fumehood.Config.load(path) do
          {:ok, config} -> [{Fumehood.Databases, config}, Fumehood.Jobs.ExpireBackups]
          {:error, errors} -> raise "invalid #{path}:\n  - " <> Enum.join(errors, "\n  - ")
        end
    end
  end

  # A fresh SQLite file switched to WAL by every pool connection at once
  # fails with "database is locked" until they retry; switch it once first.
  defp prepare_store do
    path = Application.fetch_env!(:fumehood, Fumehood.Repo)[:database]

    if not File.exists?(path) do
      File.mkdir_p!(Path.dirname(path))
      {:ok, db} = Exqlite.Sqlite3.open(path)
      :ok = Exqlite.Sqlite3.execute(db, "PRAGMA journal_mode = WAL")
      Exqlite.Sqlite3.close(db)
    end
  end

  defp skip_migrations?() do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") == nil
  end
end
