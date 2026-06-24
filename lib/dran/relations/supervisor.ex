defmodule Dran.Relations.Supervisor do
  @moduledoc """
  Supervises async relation-augmentation jobs for pages.

  When a page is created or updated, `Dran.Brain.PageAugmenter.schedule/1`
  enqueues a task under this supervisor. The task:

  - Generates/stores an embedding for the page.
  - Finds semantically similar pages in the same context.
  - Suggests related page links via the inference API.
  - Creates `related` relations automatically when confidence is high.
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
