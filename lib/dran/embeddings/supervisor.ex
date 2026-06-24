defmodule Dran.Embeddings.Supervisor do
  @moduledoc """
  Supervises the Task.Supervisor used for async embedding jobs.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      {Task.Supervisor, name: Dran.Embeddings.TaskSupervisor}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
