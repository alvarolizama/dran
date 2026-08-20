defmodule Dran.Relations.Supervisor do
  @moduledoc """
  Supervises async relation-augmentation jobs for pages.

  When a page is created or updated, `Dran.PageAugmenter.schedule/1`
  enqueues a task under this supervisor. The task:

  - Materializes `meta.props` into typed relations.
  - Enriches metadata via the inference API (title, summary, tags, entities).
  - Generates/stores an embedding for the page.
  - Creates `semantic` relations to the closest neighbours.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      {Task.Supervisor, name: Dran.Relations.TaskSupervisor}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
