defmodule Dran.Agent.WeeklyReviewTest do
  # Tests for Dran.Agent.WeeklyReview.
  #
  # Two layers:
  #   1. Unit test for gather_stats — seeds goals/todos/pages and verifies
  #      the returned structured map has the expected shape and counts.
  #   2. E2E test with Req.Test stub — the LLM calls gather_stats →
  #      create_review_page → done; verifies the journal page was created
  #      with meta review "weekly".
  use Dran.DataCase, async: false

  alias Dran.Agent.{Session, WeeklyReview}
  alias Dran.{Brain, Repo}
  alias Dran.Brain.Page

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp build_session(context_id) do
    struct(%Session{
      id: Ecto.UUID.generate(),
      context_id: context_id,
      agent_type: "weekly_review",
      input: "test weekly review run",
      status: "running"
    })
  end

  defp build_state(context_id, attrs \\ []) do
    struct(
      %WeeklyReview.State{
        session: build_session(context_id),
        pages_created: 0,
        opts: [],
        stats: nil
      },
      attrs
    )
  end

  defp insert_page!(context_id, attrs) do
    %Page{
      context_id: context_id,
      title: attrs[:title] || "Test page",
      slug: attrs[:slug] || "test-#{:rand.uniform(999_999)}",
      body: attrs[:body] || "test body",
      page_type: attrs[:page_type] || "note",
      embedding_hash: attrs[:embedding_hash] || "hash-#{:rand.uniform(999_999)}",
      meta: attrs[:meta] || %{}
    }
    |> Repo.insert!()
  end

  defp ensure_context! do
    Brain.get_context_by_slug("personal") ||
      elem(Brain.create_context(%{name: "Personal", slug: "personal"}), 1)
  end

  # ── Unit test: gather_stats ───────────────────────────────────────────────

  describe "gather_stats" do
    setup do
      # Inference disabled so Brain.create_page (if called) doesn't hit the API.
      original = Application.get_env(:dran, :inference)

      Application.put_env(:dran, :inference,
        base_url: nil,
        api_key: nil,
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

      context = ensure_context!()
      {:ok, context: context}
    end

    test "returns structured map with stats, goals, todos, recent_pages, and week",
         %{context: ctx} do
      # Seed a goal with health
      _goal =
        insert_page!(ctx.id,
          title: "Goal A",
          slug: "goal-a",
          page_type: "goal",
          meta: %{"health" => "green", "target_date" => "2026-12-31"}
        )

      _goal_red =
        insert_page!(ctx.id,
          title: "Goal B",
          slug: "goal-b",
          page_type: "goal",
          meta: %{"health" => "red", "target_date" => "2026-06-30"}
        )

      # Seed todos with different kanban statuses
      _todo_done =
        insert_page!(ctx.id,
          title: "Todo Done",
          slug: "todo-done",
          page_type: "todo",
          meta: %{"kanban_status" => "done", "priority" => "high"}
        )

      _todo_backlog =
        insert_page!(ctx.id,
          title: "Todo Backlog",
          slug: "todo-backlog",
          page_type: "todo",
          meta: %{"kanban_status" => "backlog", "priority" => "medium"}
        )

      _todo_in_progress =
        insert_page!(ctx.id,
          title: "Todo In Progress",
          slug: "todo-ip",
          page_type: "todo",
          meta: %{"kanban_status" => "in_progress", "priority" => "urgent"}
        )

      # Seed a regular note (not a goal/todo)
      _note =
        insert_page!(ctx.id,
          title: "Some Note",
          slug: "some-note",
          page_type: "note",
          meta: %{"kind" => "journal"}
        )

      state = build_state(ctx.id)
      {{:ok, result}, new_state} = WeeklyReview.execute_tool("gather_stats", %{}, state)

      # Top-level structure
      assert Map.has_key?(result, :stats)
      assert Map.has_key?(result, :goals)
      assert Map.has_key?(result, :todos)
      assert Map.has_key?(result, :todos_by_status)
      assert Map.has_key?(result, :recent_pages)
      assert Map.has_key?(result, :week)

      # Week is ISO format like "2026-W29"
      assert result.week =~ ~r/^\d{4}-W\d{2}$/

      # Goals: 2 goals with health
      goals = result.goals
      assert length(goals) == 2

      goal_a = Enum.find(goals, fn g -> g.slug == "goal-a" end)
      assert goal_a.health == "green"
      assert goal_a.target_date == "2026-12-31"

      goal_b = Enum.find(goals, fn g -> g.slug == "goal-b" end)
      assert goal_b.health == "red"

      # Todos: 3 todos
      todos = result.todos
      assert length(todos) == 3

      # todos_by_status: done=1, backlog=1, in_progress=1
      assert result.todos_by_status["done"] == 1
      assert result.todos_by_status["backlog"] == 1
      assert result.todos_by_status["in_progress"] == 1

      # recent_pages: all 6 pages were just created (within 7 days)
      recent = result.recent_pages
      assert length(recent) == 6

      # stats from Brain.stats
      assert result.stats.total_pages >= 6
      assert result.stats.by_type["goal"] == 2
      assert result.stats.by_type["todo"] == 3

      # State stores the stats
      assert new_state.stats == result
    end

    test "returns empty structures when no pages exist", %{context: ctx} do
      state = build_state(ctx.id)
      {{:ok, result}, _new_state} = WeeklyReview.execute_tool("gather_stats", %{}, state)

      assert result.goals == []
      assert result.todos == []
      assert result.todos_by_status == %{}
      assert result.recent_pages == []
      assert result.stats.total_pages == 0
    end

    test "todos without kanban_status default to backlog", %{context: ctx} do
      _todo =
        insert_page!(ctx.id,
          title: "Todo No Status",
          slug: "todo-no-status",
          page_type: "todo",
          meta: %{}
        )

      state = build_state(ctx.id)
      {{:ok, result}, _new_state} = WeeklyReview.execute_tool("gather_stats", %{}, state)

      assert result.todos_by_status["backlog"] == 1
    end
  end

  # ── Unit test: current_iso_week ────────────────────────────────────────────

  describe "current_iso_week" do
    test "returns ISO 8601 week format" do
      week = WeeklyReview.current_iso_week()
      assert week =~ ~r/^\d{4}-W\d{2}$/
    end
  end

  # ── E2E test with Req.Test stub ────────────────────────────────────────────

  describe "E2E: LLM calls gather_stats → create_review_page → done" do
    setup do
      original = Application.get_env(:dran, :inference)

      Application.put_env(:dran, :inference,
        base_url: "http://localhost:8000/v1",
        api_key: "test-key",
        chat_model: "test-chat-model",
        embedding_model: "Qwen3-Embedding",
        markitdown_model: "MarkItDown",
        timeout: 5_000,
        req_plug: {Req.Test, Dran.Inference.Client},
        schedule_async: false
      )

      # Ensure the inference queue GenServers are running
      ensure_queue_started(:chat)
      ensure_queue_started(:embed)

      context = ensure_context!()

      # Seed a goal and a todo so gather_stats has data
      insert_page!(context.id,
        title: "Goal A",
        slug: "wr-goal-a",
        page_type: "goal",
        meta: %{"health" => "green", "target_date" => "2026-12-31"}
      )

      insert_page!(context.id,
        title: "Todo Done",
        slug: "wr-todo-done",
        page_type: "todo",
        meta: %{"kanban_status" => "done", "priority" => "high"}
      )

      on_exit(fn ->
        if is_nil(original) do
          Application.delete_env(:dran, :inference)
        else
          Application.put_env(:dran, :inference, original)
        end
      end)

      {:ok, context: context}
    end

    test "full weekly review workflow creates a journal page with review weekly",
         %{context: ctx} do
      # The LLM stub simulates a 3-step conversation:
      # Step 0: call gather_stats
      # Step 1: call create_review_page with a markdown body
      # Step 2: call done
      #
      # We use an Agent counter (not Process.get) because tool execution
      # happens inside spawned Tasks — Process.get doesn't survive.
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(Dran.Inference.Client, fn conn ->
        case conn.request_path do
          "/v1/embeddings" ->
            # Answer embedding requests (from Brain.create_page on create_review_page)
            Req.Test.json(conn, %{
              "object" => "list",
              "data" => [
                %{ "object" => "embedding", "index" => 0, "embedding" => List.duplicate(0.0, 1024) }
              ]
            })

          "/v1/chat/completions" ->
            step = Agent.get_and_update(counter, fn s -> {s, s + 1} end)

            tool_call =
              case step do
                0 ->
                  %{
                    "id" => "call-1",
                    "type" => "function",
                    "function" => %{
                      "name" => "gather_stats",
                      "arguments" => "{}"
                    }
                  }

                1 ->
                  %{
                    "id" => "call-2",
                    "type" => "function",
                    "function" => %{
                      "name" => "create_review_page",
                      "arguments" =>
                        ~s({"body": "## Review Semanal\\n\\n### Goals\\n- Goal A: green\\n\\n### Todos\\n- Completados: 1\\n\\n### Sugerencias\\n- Mantener el ritmo."})
                    }
                  }

                _ ->
                  %{
                    "id" => "call-3",
                    "type" => "function",
                    "function" => %{
                      "name" => "done",
                      "arguments" => ~s({"summary": "Review semanal generado."})
                    }
                  }
              end

            Req.Test.json(conn, %{
              "id" => "chat-#{step}",
              "object" => "chat.completion",
              "model" => "test-chat-model",
              "choices" => [
                %{
                  "message" => %{
                    "role" => "assistant",
                    "content" => "",
                    "tool_calls" => [tool_call]
                  }
                }
              ],
              "usage" => %{ "total_tokens" => 100 }
            })
        end
      end)

      {:ok, session} = WeeklyReview.run("scheduled weekly review", ctx.id)

      # Wait for the async agent to finish
      assert eventually(fn ->
               s = Repo.get(Session, session.id)
               s.status == "done"
             end)

      # Verify the session completed successfully
      session = Repo.get(Session, session.id)
      assert session.status == "done"
      assert session.summary =~ "Review semanal"

      # Verify the review page was created with correct meta
      week = WeeklyReview.current_iso_week()
      # The slug is derived from the title "Weekly Review <week>"
      # Brain.create_page slugifies the title
      review_page =
        Repo.one(
          from p in Page,
            where: p.context_id == ^ctx.id and p.title == ^"Weekly Review #{week}"
        )

      assert review_page != nil
      assert review_page.page_type == "note"
      assert review_page.created_by == "weekly-review"
      assert review_page.meta["kind"] == "journal"
      assert review_page.meta["review"] == "weekly"
      assert review_page.meta["week"] == week
      assert review_page.body =~ "Review Semanal"

      Agent.stop(counter)
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp ensure_queue_started(capability) do
    case Registry.start_link(keys: :unique, name: Dran.Inference.QueueRegistry) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    case Dran.Inference.Queue.start_link(capability: capability) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
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
