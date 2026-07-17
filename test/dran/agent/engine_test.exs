defmodule Dran.Agent.EngineTest do
  use Dran.DataCase, async: false

  alias Dran.{Brain, Repo}
  alias Dran.Agent.{Engine, Session}

  defmodule CrashingAgent do
    @moduledoc "Agent that raises before the first step"
    def agent_type, do: "crasher"
    def tools, do: []

    def build_messages(_input, _session, _opts) do
      raise "boom in build_messages"
    end
  end

  defmodule SmartTruncateProbe do
    @moduledoc false
    defdelegate smart_truncate(str, max), to: Dran.Agent.Engine
  end

  setup do
    original = Application.get_env(:dran, :inference)

    Application.put_env(:dran, :inference,
      base_url: nil,
      api_key: nil,
      embedding_model: nil,
      rerank_model: nil,
      markitdown_model: nil,
      timeout: 100,
      schedule_async: false
    )

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:dran, :inference)
      else
        Application.put_env(:dran, :inference, original)
      end
    end)

    context =
      Brain.get_context_by_slug("personal") ||
        elem(Brain.create_context(%{name: "Personal", slug: "personal"}), 1)

    {:ok, context: context}
  end

  describe "run/4 crash recovery" do
    test "session is marked failed when the runner crashes before the first step",
         %{context: ctx} do
      {:ok, session} = Engine.run(CrashingAgent, "crash me", ctx.id)

      # Wait for the async runner to crash and finish the session
      assert eventually(fn ->
               s = Repo.get(Session, session.id)
               s.status == "failed"
             end)

      session = Repo.get(Session, session.id)
      assert session.summary =~ "Agent crashed"
    end
  end

  describe "smart_truncate/2" do
    test "truncates plain text at line boundary with marker" do
      long = Enum.map_join(1..500, "\n", &"line #{&1} with some content here")
      truncated = Dran.Agent.Engine.smart_truncate(long, 500)

      assert String.length(truncated) < 600
      assert truncated =~ "…[truncated]"
      # ends at a full line, not mid-line
      body = String.replace(truncated, "\n…[truncated]", "")
      assert body == String.trim_trailing(body)
    end

    test "returns short strings untouched" do
      assert Dran.Agent.Engine.smart_truncate("short", 500) == "short"
    end

    test "truncates JSON at a parseable boundary" do
      json = Jason.encode!(%{items: Enum.map(1..200, &%{id: &1, name: "item-#{&1}"})})
      truncated = Dran.Agent.Engine.smart_truncate(json, 500)

      assert truncated =~ "…[truncated]"
    end
  end

  describe "cancel/1" do
    test "returns {:error, :not_found} for non-existent session_id" do
      fake_id = Ecto.UUID.generate()
      assert {:error, :not_found} = Engine.cancel(fake_id)
    end
  end

  defp eventually(fun, attempts \\ 50)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(100)
      eventually(fun, attempts - 1)
    end
  end
end
