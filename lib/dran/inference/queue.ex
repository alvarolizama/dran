defmodule Dran.Inference.Queue do
  @moduledoc """
  Serializes inference requests per capability/model type.

  Dran talks to a single local OpenAI-compatible inference server that may
  struggle with many concurrent requests. This GenServer hands out a single
  "permit" per capability (`:embed`, `:rerank`, `:markdown`, `:vision`,
  `:audio`, `:chat`) so that only one request of that type runs at a time.

  The actual HTTP request still runs in the caller process, which keeps
  `Req.Test` stubs working in tests and avoids blocking a GenServer with
  long-running inference calls.

  The permit is re-entrant: if a caller already holds it, nested `run/2`
  calls proceed without deadlocking. This is needed because higher-level
  helpers like `Vision` may call `Client.chat`, which also goes through the
  same capability queue.
  """

  use GenServer

  alias Dran.Inference.Config

  @registry Dran.Inference.QueueRegistry

  @doc """
  Execute `fun` while holding the permit for the given capability.

  Blocks until all previous jobs for the same capability finish, then runs
  `fun` in the caller process and returns its result.

  ## Capabilities

  - `:embed` — embedding requests
  - `:rerank` — reranking requests
  - `:markdown` — MarkItDown document conversion
  - `:vision` — image understanding
  - `:audio` — audio transcription
  - `:chat` — chat/summary/tag generation
  """
  @spec run(atom(), (-> result)) :: result when result: term()
  def run(capability, fun) when is_atom(capability) and is_function(fun, 0) do
    acquire(capability)

    try do
      fun.()
    after
      release(capability)
    end
  end

  @doc false
  def acquire(capability) do
    timeout = Config.timeout() + 5_000
    GenServer.call(via_tuple(capability), :acquire, timeout)
  end

  @doc false
  def release(capability) do
    GenServer.call(via_tuple(capability), :release)
  end

  @doc false
  def via_tuple(capability) do
    {:via, Registry, {@registry, capability}}
  end

  @doc false
  def child_spec(opts) do
    capability = Keyword.fetch!(opts, :capability)

    %{
      id: {__MODULE__, capability},
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      shutdown: 5_000,
      type: :worker
    }
  end

  @doc false
  def start_link(opts) do
    capability = Keyword.fetch!(opts, :capability)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(capability))
  end

  @impl true
  def init(opts) do
    capability = Keyword.fetch!(opts, :capability)
    {:ok, %{capability: capability, holder: nil, waiting: :queue.new()}}
  end

  @impl true
  def handle_call(:acquire, {pid, _tag}, %{holder: nil} = state) do
    ref = Process.monitor(pid)
    {:reply, :ok, %{state | holder: {pid, ref, 1}}}
  end

  @impl true
  def handle_call(:acquire, {pid, _tag} = _from, %{holder: {pid, ref, count}} = state) do
    {:reply, :ok, %{state | holder: {pid, ref, count + 1}}}
  end

  @impl true
  def handle_call(:acquire, from, state) do
    {:noreply, %{state | waiting: :queue.in(from, state.waiting)}}
  end

  @impl true
  def handle_call(:release, _from, %{holder: nil} = state) do
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:release, _from, %{holder: {pid, ref, count}} = state) do
    if count > 1 do
      {:reply, :ok, %{state | holder: {pid, ref, count - 1}}}
    else
      Process.demonitor(ref, [:flush])
      {:reply, :ok, take_next(state)}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{holder: {_, ref, _}} = state) do
    {:noreply, take_next(state)}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    # Stale monitor, ignore
    {:noreply, state}
  end

  defp take_next(%{waiting: waiting} = state) do
    case :queue.out(waiting) do
      {{:value, {pid, _tag} = next_from}, rest} ->
        next_ref = Process.monitor(pid)
        GenServer.reply(next_from, :ok)
        %{state | holder: {pid, next_ref, 1}, waiting: rest}

      {:empty, _rest} ->
        %{state | holder: nil, waiting: :queue.new()}
    end
  end
end
