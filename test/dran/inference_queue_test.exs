defmodule Dran.InferenceQueueTest do
  use ExUnit.Case, async: false

  alias Dran.Inference.Queue

  setup do
    original = Application.get_env(:dran, :inference)

    Application.put_env(:dran, :inference,
      base_url: "http://localhost:9999",
      api_key: "test",
      timeout: 5_000
    )

    ensure_registry()
    ensure_queue(:vision)

    on_exit(fn ->
      Application.put_env(:dran, :inference, original)
    end)

    :ok
  end

  test "run/2 executes requests one at a time per capability" do
    {:ok, tracker} = Agent.start_link(fn -> %{active: 0, max: 0} end)

    mark_active = fn ->
      Agent.get_and_update(tracker, fn state ->
        new_active = state.active + 1
        new_max = max(state.max, new_active)
        {:ok, %{active: new_active, max: new_max}}
      end)
    end

    mark_inactive = fn ->
      Agent.update(tracker, fn state -> %{state | active: state.active - 1} end)
    end

    work = fn ->
      :ok = mark_active.()
      Process.sleep(200)
      mark_inactive.()
      :done
    end

    task1 = Task.async(fn -> Queue.run(:vision, work) end)
    task2 = Task.async(fn -> Queue.run(:vision, work) end)

    assert :done = Task.await(task1)
    assert :done = Task.await(task2)

    state = Agent.get(tracker, & &1)
    assert state.active == 0
    assert state.max == 1
  end

  defp ensure_registry do
    case Registry.start_link(keys: :unique, name: Dran.Inference.QueueRegistry) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end

  defp ensure_queue(capability) do
    case Queue.start_link(capability: capability) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end
end
