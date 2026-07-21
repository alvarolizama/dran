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
#     PHX_SERVER=true bin/dran start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
# Always start the HTTP listener. The endpoint is a child of Dran.Application
# and is the only listener in this app, so the boot script (start/daemon)
# will pick it up automatically. Leaving this on `true` makes the release
# work the same whether started via `bin/server`, `bin/dran start`, or any
# other entrypoint (Coolify, Railpack, Nixpacks, bare metal).
# Guard: in :test this would fight the Endpoint's `server: false` and try to
# bind the port during `mix test` / `mix precommit` (eaddrinuse).
if config_env() != :test do
  config :dran, DranWeb.Endpoint, server: true
end

config :dran, DranWeb.Endpoint, http: [port: String.to_integer(System.get_env("PORT", "4000"))]

config :dran, :uploads,
  dir: System.get_env("UPLOADS_DIR", "priv/static/uploads"),
  max_size: String.to_integer(System.get_env("UPLOADS_MAX_SIZE", "104857600"))

# Inference API configuration. Disabled when DRAN_INFERENCE_API_URL is not set.
config :dran, :inference, Dran.Inference.Config.load_from_env()

# Firecrawl configuration. Disabled when FIRECRAWL_API_KEY is not set.
config :dran, :firecrawl,
  api_key: System.get_env("FIRECRAWL_API_KEY"),
  base_url: "https://api.firecrawl.dev/v1"

config :dran, :agent_max_steps, String.to_integer(System.get_env("AGENT_MAX_STEPS", "150"))

config :dran,
       :agent_per_step_timeout,
       String.to_integer(System.get_env("AGENT_PER_STEP_TIMEOUT", "120000"))

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :dran, Dran.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6,
    types: Dran.PostgresTypes

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

  # PHX_HOST is the bare hostname (no scheme, no port). If you serve over
  # a non-standard port via reverse-proxy, set PHX_PORT to match the
  # external port so generated URLs include it.
  # PHX_SCHEME defaults to "https" but can be overridden to "http" when
  # the app is served over plain HTTP (e.g. behind a NetBird / Wireguard
  # tunnel without a TLS terminator in front).
  host =
    System.get_env("PHX_HOST") ||
      raise """
      environment variable PHX_HOST is missing.
      Set it to the public hostname the app is served from, e.g. dran.example.com
      """

  scheme = System.get_env("PHX_SCHEME", "https")
  url_port = String.to_integer(System.get_env("PHX_PORT", "443"))

  config :dran, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # force_ssl: only enabled when PHX_SCHEME is "https" (default) AND
  # DISABLE_FORCE_SSL is not "1". Serving over plain HTTP (e.g. behind a
  # NetBird / Wireguard tunnel without a TLS terminator) sets PHX_SCHEME=http
  # or DISABLE_FORCE_SSL=1, which disables the HTTPS redirect.
  force_ssl_opts =
    cond do
      System.get_env("DISABLE_FORCE_SSL") == "1" ->
        []

      scheme == "http" ->
        []

      true ->
        [
          force_ssl: [
            rewrite_on: [:x_forwarded_proto],
            exclude: [hosts: ["localhost", "127.0.0.1"]]
          ]
        ]
    end

  config :dran, DranWeb.Endpoint,
    url: [host: host, port: url_port, scheme: scheme],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  if force_ssl_opts != [], do: config(:dran, DranWeb.Endpoint, force_ssl_opts)

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :dran, DranWeb.Endpoint,
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
  #     config :dran, DranWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :dran, Dran.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://swoosh.hexdocs.pm/Swoosh.html#module-installation for details.
end
