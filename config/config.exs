# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :dran,
  ecto_repos: [Dran.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

# Configure the endpoint
config :dran, DranWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: DranWeb.ErrorHTML, json: DranWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Dran.PubSub,
  live_view: [signing_salt: "kfcD1Wtl"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# SEC-008: filter sensitive parameters from logs
config :phoenix, :filter_parameters, [
  "password",
  "secret",
  "token",
  "api_key",
  "client_secret",
  "authorization"
]

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :dran, Dran.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  dran: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  dran: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Quantum scheduler jobs
#
# Every task routes through `Dran.Jobs.run_scheduled/1`, which honors the
# runtime enable/disable toggles (Dran.Settings "disabled_jobs") and writes a
# `report` page (kind: log) per run. The job registry lives in `Dran.Jobs`.
#
# Defined for dev/prod only. `config/test.exs` sets `jobs: []` to disable the
# scheduler during the test suite. We guard with `config_env() != :test` here
# because `Config` deep-merges keyword lists, so an empty `jobs: []` in
# test.exs would NOT override the nested job entries defined below.
if config_env() != :test do
  config :dran, Dran.Scheduler,
    jobs: [
      curator_daily: [
        schedule: "0 6 * * *",
        task: {Dran.Jobs, :run_scheduled, [:curator_daily]}
      ],
      pagerank_nightly: [
        schedule: "0 3 * * *",
        task: {Dran.Jobs, :run_scheduled, [:pagerank_nightly]}
      ],
      community_summaries_nightly: [
        schedule: "30 3 * * *",
        task: {Dran.Jobs, :run_scheduled, [:community_summaries_nightly]}
      ],
      graph_maintenance_nightly: [
        schedule: "45 3 * * *",
        task: {Dran.Jobs, :run_scheduled, [:graph_maintenance_nightly]}
      ],
      link_gardener_weekly: [
        schedule: "0 7 * * 0",
        task: {Dran.Jobs, :run_scheduled, [:link_gardener_weekly]}
      ]
    ]
end

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
