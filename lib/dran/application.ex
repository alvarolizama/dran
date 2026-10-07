defmodule Dran.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information about OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      DranWeb.Telemetry,
      # Settings ETS cache — before anything reads Dran.Settings.get/1.
      Dran.Settings,
      Dran.Repo,
      # System actors are code-managed: upsert idempotently on every boot,
      # after the Repo is up. Task exits normally when done (temporary).
      %{
        id: Dran.SystemActorsBoot,
        start: {Task, :start_link, [&Dran.Actors.ensure_system_actors!/0]},
        restart: :temporary
      },
      # Built-in skills: the code-managed catalog that Dran serves to EVERY API
      # credential, reconciled with the `skills/**/SKILL.md` baked into the
      # release on every boot. `nil` in test (the sync is opt-in there).
      Dran.Skills.BuiltinBoot.child_spec(),
      {DNSCluster, query: Application.get_env(:dran, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Dran.PubSub},
      {Registry, keys: :unique, name: Dran.Worker.SessionRegistry},
      Dran.Inference.QueueSupervisor,
      Dran.Embeddings.Supervisor,
      Dran.Relations.Supervisor,
      Dran.Scheduler,
      Dran.GraphCache,
      # External-embed metadata (oEmbed titles/thumbnails): written when an
      # embed is inserted, read — never fetched — while rendering.
      Dran.Embeds.Cache,
      DranWeb.LoginThrottle,
      DranWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Dran.Supervisor]

    children
    |> Enum.reject(&is_nil/1)
    |> then(&Supervisor.start_link(&1, opts))
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    DranWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
