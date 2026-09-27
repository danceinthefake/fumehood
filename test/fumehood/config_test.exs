defmodule Fumehood.ConfigTest do
  use ExUnit.Case, async: true

  alias Fumehood.Config
  alias Fumehood.Config.Database

  @env %{"ORDERS_URL" => "postgres://app:s%40cret@db.internal:6432/orders?sslmode=require"}

  test "a valid config" do
    toml = """
    backup_dir = "/var/lib/fumehood/backups"

    [databases.orders]
    label = "Orders"
    mode = "read_write"
    url_env = "ORDERS_URL"
    max_rows = 200
    """

    assert {:ok, %Config{backup_dir: "/var/lib/fumehood/backups", databases: %{"orders" => db}}} =
             Config.parse(toml, @env)

    assert %Database{
             id: "orders",
             label: "Orders",
             mode: :read_write,
             max_rows: 200,
             lock_timeout_ms: 5_000
           } =
             db

    assert db.connect == [
             hostname: "db.internal",
             port: 6432,
             database: "orders",
             username: "app",
             password: "s@cret",
             ssl: true
           ]
  end

  test "defaults: backup_dir, limits, port, no TLS" do
    toml = ~s([databases.a]\nlabel = "A"\nmode = "read_only"\nurl_env = "A_URL")

    assert {:ok, %Config{backup_dir: "backups", databases: %{"a" => db}}} =
             Config.parse(toml, %{"A_URL" => "postgres://u@h/db"})

    assert db.max_rows == 1000
    assert db.connect[:port] == 5432
    refute db.connect[:ssl]
    refute Keyword.has_key?(db.connect, :password)
  end

  test "reports every problem at once" do
    toml = """
    [databases.a]
    mode = "everything"
    url_env = "MISSING"
    max_rows = 0

    [databases.b]
    label = "B"
    mode = "read_only"
    """

    assert {:error, errors} = Config.parse(toml, %{})

    assert errors == [
             "databases.a: label is required",
             ~s(databases.a: mode must be "read_only" or "read_write"),
             "databases.a: environment variable MISSING is not set",
             "databases.a: max_rows must be a positive integer",
             "databases.b: url_env is required"
           ]
  end

  test "bad URL, no databases, invalid TOML, missing file" do
    toml = ~s([databases.a]\nlabel = "A"\nmode = "read_only"\nurl_env = "A_URL")

    assert {:error, ["databases.a: URL must start with postgres://"]} =
             Config.parse(toml, %{"A_URL" => "mysql://h/db"})

    assert {:error, ["databases.a: URL has no database name"]} =
             Config.parse(toml, %{"A_URL" => "postgres://h"})

    assert {:error, ["no [databases.<id>] defined"]} = Config.parse("backup_dir = \"x\"", %{})
    assert {:error, ["invalid TOML" <> _]} = Config.parse("[databases", %{})
    assert {:error, ["can't read /nope.toml" <> _]} = Config.load("/nope.toml", %{})
  end
end
