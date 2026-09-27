import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/fumehood start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :fumehood, FumehoodWeb.Endpoint, server: true
end

config :fumehood, FumehoodWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# How people reach fumehood and where their identity comes from (DESIGN.md §6).
# Production must choose iap or ssh_tunnel; a fixed dev user is refused there.
env = config_env()

access =
  case System.get_env("FUMEHOOD_ACCESS") do
    "iap" ->
      [mode: :iap, audience: System.fetch_env!("FUMEHOOD_IAP_AUDIENCE")]

    "ssh_tunnel" ->
      [mode: :ssh_tunnel]

    nil when env != :prod ->
      [mode: :dev, user: System.get_env("FUMEHOOD_DEV_USER", "dev@localhost")]

    other ->
      raise "FUMEHOOD_ACCESS must be iap or ssh_tunnel (got #{inspect(other)})"
  end

# Tests set their own identity in config/test.exs.
if env != :test, do: config(:fumehood, :access, access)

if config_env() == :prod do
  config :fumehood, config_path: System.get_env("FUMEHOOD_CONFIG", "/etc/fumehood/fumehood.toml")

  database_path =
    System.get_env("DATABASE_PATH") ||
      raise """
      environment variable DATABASE_PATH is missing.
      For example: /etc/fumehood/fumehood.db
      """

  config :fumehood, Fumehood.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5")

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :fumehood, FumehoodWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # ssh_tunnel: loopback only, reachable just through SSH on the VM.
      # iap: all interfaces, behind the load balancer.
      ip: if(access[:mode] == :ssh_tunnel, do: {127, 0, 0, 1}, else: {0, 0, 0, 0, 0, 0, 0, 0})
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :fumehood, FumehoodWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :fumehood, FumehoodWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
