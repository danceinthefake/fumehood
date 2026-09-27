defmodule Fumehood.TargetDB do
  @moduledoc """
  Target Postgres databases for integration tests (`docker compose up -d`).
  Each test gets its own schema; the returned connection has it as
  `search_path`, so test SQL uses unqualified table names.
  """

  import ExUnit.Callbacks, only: [start_supervised!: 1, on_exit: 1]

  @ports %{16 => 55416, 18 => 55418}

  def versions, do: Map.keys(@ports)

  @doc "Connection to Postgres `version` inside a fresh schema, set up with `setup_sql`."
  def connect!(version, setup_sql \\ []) do
    schema = "test_#{System.unique_integer([:positive])}"
    opts = conn_opts(version)

    admin = start_supervised!(Supervisor.child_spec({Postgrex, opts}, id: {:admin, schema}))
    Postgrex.query!(admin, "CREATE SCHEMA #{schema}", [])
    on_exit(fn -> drop_schema(opts, schema) end)

    conn =
      start_supervised!(
        Supervisor.child_spec({Postgrex, Keyword.put(opts, :parameters, search_path: schema)},
          id: {:conn, schema}
        )
      )

    for sql <- List.wrap(setup_sql), do: Postgrex.query!(conn, sql, [])
    %{conn: conn, schema: schema}
  end

  defp conn_opts(version) do
    [
      hostname: "localhost",
      port: Map.fetch!(@ports, version),
      username: "postgres",
      password: "fumehood",
      database: "fumehood_target"
    ]
  end

  defp drop_schema(opts, schema) do
    {:ok, pid} = Postgrex.start_link(opts)
    Postgrex.query!(pid, "DROP SCHEMA #{schema} CASCADE", [])
    GenServer.stop(pid)
  end
end
