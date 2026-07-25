defmodule Dran.Inference.QueueSupervisor do
  @moduledoc """
  Supervises one `Dran.Inference.Queue` GenServer per inference capability.

  Capabilities:
  - `:embed`
  - `:rerank`
  - `:chat`
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      {Registry, keys: :unique, name: Dran.Inference.QueueRegistry},
      {Dran.Inference.Queue, capability: :embed},
      {Dran.Inference.Queue, capability: :rerank},
      {Dran.Inference.Queue, capability: :chat}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
