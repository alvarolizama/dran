defmodule Dran.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information about OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      DranWeb.Telemetry,
      Dran.Repo,
      {DNSCluster, query: Application.get_env(:dran, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Dran.PubSub},
      {Registry, keys: :unique, name: Dran.Agent.SessionRegistry},
      Dran.Inference.QueueSupervisor,
      Dran.Embeddings.Supervisor,
      Dran.Relations.Supervisor,
      Dran.Scheduler,
      DranWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Dran.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    DranWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
