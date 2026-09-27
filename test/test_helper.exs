ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Fumehood.Repo, :manual)

# Target databases for API tests: the compose containers, pg16 read_write and
# pg18 read_only, backups in a fresh temporary directory.
backup_dir =
  Path.join(System.tmp_dir!(), "fumehood-test-backups-#{System.unique_integer([:positive])}")

{:ok, config} =
  Fumehood.Config.parse(
    """
    backup_dir = "#{backup_dir}"

    [databases.pg16]
    label = "Test 16"
    mode = "read_write"
    url_env = "PG16"

    [databases.pg18]
    label = "Test 18"
    mode = "read_only"
    url_env = "PG18"
    """,
    %{
      "PG16" => "postgres://postgres:fumehood@localhost:55416/fumehood_target",
      "PG18" => "postgres://postgres:fumehood@localhost:55418/fumehood_target"
    }
  )

{:ok, _} = Fumehood.Databases.start_link(config)
ExUnit.after_suite(fn _ -> File.rm_rf!(backup_dir) end)
