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

config :dran, :worker_max_steps, String.to_integer(System.get_env("WORKER_MAX_STEPS", "150"))

config :dran,
       :worker_per_step_timeout,
       String.to_integer(System.get_env("WORKER_PER_STEP_TIMEOUT", "120000"))

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  # SSL on by default (AlloyDB/Cloud SQL require it) WITHOUT certificate
  # verification — prod databases use self-signed certs, so verifying against
  # the system CA bundle breaks the connection. Set ECTO_SSL=false to disable
  # SSL entirely for local dev or non-SSL databases, or ECTO_SSL_VERIFY=true
  # to opt back into strict verification against the system CA bundle.
  maybe_ssl =
    cond do
      System.get_env("ECTO_SSL") in ~w(false 0) ->
        []

      System.get_env("ECTO_SSL_VERIFY") in ~w(true 1) ->
        [ssl: true, ssl_opts: [verify: :verify_peer, cacerts: :public_key.cacerts_get()]]

      true ->
        [ssl: true, ssl_opts: [verify: :verify_none]]
    end

  config :dran,
         Dran.Repo,
         [
           url: database_url,
           pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
           # For machines with several cores, consider starting multiple pools of `pool_size`
           # pool_count: 4,
           socket_options: maybe_ipv6,
           types: Dran.PostgresTypes
         ] ++ maybe_ssl

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

  # Session cookie salts. endpoint.ex has dev-friendly fallbacks, but in prod
  # they MUST come from env vars — otherwise every deployment shares the
  # hardcoded salts committed to the repo and session cookies become
  # forgeable/decryptable by anyone who read the source.
  for var <- ["SESSION_SIGNING_SALT", "SESSION_ENCRYPTION_SALT"] do
    System.get_env(var) ||
      raise """
      environment variable #{var} is missing.
      Session cookie salts must not fall back to the repo defaults in prod.
      Generate one with: mix phx.gen.secret 32
      """
  end

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

  # NOTE: force_ssl is compile-time in Phoenix (the endpoint marks it via
  # compile_env), so it cannot live in this file. It stays in prod.exs and
  # can only be disabled at BUILD time with DISABLE_FORCE_SSL=1
  # (see config/prod.exs and the Dockerfile ARG).
  # CHECK_ORIGINS: comma-separated list of allowed origins for CSRF/WS
  # checks, e.g. "https://dran.example.com,http://10.0.0.5:4000".
  # Needed when the app is served from more than one scheme/host/port
  # (e.g. HTTPS public + plain HTTP over VPN) — the CSRF origin check
  # rejects POSTs whose Origin doesn't match, returning 403 on /login.
  # Unset = key omitted entirely, Phoenix default (checks against the
  # configured url).
  check_origin_config =
    case System.get_env("CHECK_ORIGINS") do
      nil -> []
      "" -> []
      origins -> [check_origin: String.split(origins, ",", trim: true)]
    end

  config :dran,
         DranWeb.Endpoint,
         [
           url: [host: host, port: url_port, scheme: scheme],
           http: [
             # Enable IPv6 and bind on all interfaces.
             # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
             # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
             # for details about using IPv6 vs IPv4 and loopback vs public addresses.
             ip: {0, 0, 0, 0, 0, 0, 0, 0}
           ],
           secret_key_base: secret_key_base
         ] ++ check_origin_config

  # Google OAuth (optional — leave env vars empty to disable Google login)
  config :dran, :google_oauth,
    client_id: System.get_env("GOOGLE_OAUTH_CLIENT_ID"),
    client_secret: System.get_env("GOOGLE_OAUTH_CLIENT_SECRET"),
    redirect_uri:
      System.get_env("GOOGLE_OAUTH_REDIRECT_URI") ||
        "#{scheme}://#{host}/auth/google/callback",
    allowed_domains:
      (System.get_env("GOOGLE_OAUTH_ALLOWED_DOMAINS") || "")
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
end
