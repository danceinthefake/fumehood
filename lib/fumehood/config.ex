defmodule Fumehood.Config do
  @moduledoc """
  Reads `fumehood.toml` (DESIGN.md §6.5): where backups go and which target
  databases exist. Connection strings never live in the file — each database
  names the environment variable that holds its URL.

      backup_dir = "/var/lib/fumehood/backups"

      [databases.orders_prod]
      label   = "Orders (production)"
      mode    = "read_only"          # or "read_write"
      url_env = "ORDERS_PROD_URL"
      # optional: max_rows, statement_timeout_ms, lock_timeout_ms,
      #           backup_retention_days, pool_size
  """

  defmodule Database do
    @moduledoc "One target database from the config."

    @enforce_keys [:id, :label, :mode, :connect]
    defstruct [
      :id,
      :label,
      :mode,
      :connect,
      max_rows: 1000,
      statement_timeout_ms: 30_000,
      lock_timeout_ms: 5_000,
      backup_retention_days: 30,
      pool_size: 5
    ]

    @type t :: %__MODULE__{
            id: String.t(),
            label: String.t(),
            mode: :read_only | :read_write,
            # Postgrex connection options, built from the URL
            connect: keyword(),
            max_rows: pos_integer(),
            statement_timeout_ms: pos_integer(),
            lock_timeout_ms: pos_integer(),
            backup_retention_days: pos_integer(),
            pool_size: pos_integer()
          }
  end

  @enforce_keys [:backup_dir, :databases]
  defstruct [:backup_dir, :databases]

  @type t :: %__MODULE__{backup_dir: Path.t(), databases: %{String.t() => Database.t()}}

  @optional ~w(max_rows statement_timeout_ms lock_timeout_ms backup_retention_days pool_size)

  @doc "Reads and validates the file at `path`, taking URLs from `env`."
  @spec load(Path.t(), %{String.t() => String.t()}) :: {:ok, t()} | {:error, [String.t()]}
  def load(path, env \\ System.get_env()) do
    case File.read(path) do
      {:ok, text} -> parse(text, env)
      {:error, reason} -> {:error, ["can't read #{path}: #{:file.format_error(reason)}"]}
    end
  end

  @doc "Parses and validates TOML text. Returns every problem found, not just the first."
  @spec parse(String.t(), %{String.t() => String.t()}) :: {:ok, t()} | {:error, [String.t()]}
  def parse(text, env) do
    with {:ok, toml} <- decode(text) do
      {databases, errors} =
        toml
        |> Map.get("databases", %{})
        |> Enum.sort()
        |> Enum.map(fn {id, table} -> database(id, table, env) end)
        |> Enum.split_with(&match?({:ok, _}, &1))

      errors = Enum.flat_map(errors, fn {:error, e} -> e end)

      errors =
        if databases == [] and errors == [], do: ["no [databases.<id>] defined"], else: errors

      case errors do
        [] ->
          {:ok,
           %__MODULE__{
             backup_dir: Map.get(toml, "backup_dir", "backups"),
             databases: Map.new(databases, fn {:ok, db} -> {db.id, db} end)
           }}

        errors ->
          {:error, errors}
      end
    end
  end

  defp decode(text) do
    case Toml.decode(text) do
      {:ok, toml} -> {:ok, toml}
      {:error, {:invalid_toml, reason}} -> {:error, ["invalid TOML: #{reason}"]}
      {:error, reason} -> {:error, ["invalid TOML: #{inspect(reason)}"]}
    end
  end

  defp database(id, table, env) do
    errors =
      [
        unless(is_binary(table["label"]), do: "databases.#{id}: label is required"),
        unless(table["mode"] in ["read_only", "read_write"],
          do: "databases.#{id}: mode must be \"read_only\" or \"read_write\""
        ),
        url_error(id, table["url_env"], env)
        | Enum.map(@optional, &positive_error(id, &1, table[&1]))
      ]
      |> Enum.reject(&is_nil/1)

    with [] <- errors,
         {:ok, connect} <- connect_opts(env[table["url_env"]]) do
      optional =
        for key <- @optional,
            Map.has_key?(table, key),
            do: {String.to_existing_atom(key), table[key]}

      {:ok,
       struct!(
         Database,
         [
           id: id,
           label: table["label"],
           mode: String.to_existing_atom(table["mode"]),
           connect: connect
         ] ++
           optional
       )}
    else
      {:error, reason} -> {:error, ["databases.#{id}: #{reason}"]}
      errors -> {:error, errors}
    end
  end

  defp url_error(id, nil, _env), do: "databases.#{id}: url_env is required"

  defp url_error(id, name, env) do
    if env[name] in [nil, ""], do: "databases.#{id}: environment variable #{name} is not set"
  end

  defp positive_error(_id, _key, nil), do: nil
  defp positive_error(_id, _key, value) when is_integer(value) and value > 0, do: nil
  defp positive_error(id, key, _value), do: "databases.#{id}: #{key} must be a positive integer"

  @doc """
  Postgrex options from a `postgres://user:pass@host:port/db?sslmode=…` URL.
  `sslmode=require` (or `verify-full`) turns TLS on.
  """
  @spec connect_opts(String.t()) :: {:ok, keyword()} | {:error, String.t()}
  def connect_opts(url) do
    uri = URI.parse(url)

    with true <-
           uri.scheme in ["postgres", "postgresql"] || {:error, "URL must start with postgres://"},
         "/" <> database when database != "" <- uri.path || {:error, "URL has no database name"} do
      {username, password} = userinfo(uri.userinfo)
      query = URI.decode_query(uri.query || "")

      opts =
        [
          hostname: uri.host,
          port: uri.port || 5432,
          database: URI.decode(database),
          username: username,
          password: password,
          ssl: query["sslmode"] in ["require", "verify-ca", "verify-full"]
        ]
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)

      {:ok, opts}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, "URL has no database name"}
    end
  end

  defp userinfo(nil), do: {nil, nil}

  defp userinfo(info) do
    case String.split(info, ":", parts: 2) do
      [user, pass] -> {URI.decode(user), URI.decode(pass)}
      [user] -> {URI.decode(user), nil}
    end
  end
end
