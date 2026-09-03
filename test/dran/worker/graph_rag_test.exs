defmodule Dran.Worker.GraphRagTest do
  use Dran.DataCase, async: false

  alias Dran.Worker.GraphRag
  alias Dran.{Knowledge, Repo}
  alias Dran.Page

  #  Helpers 

  defp build_session(workspace_id) do
    struct(%Dran.Worker.Session{
      id: Ecto.UUID.generate(),
      workspace_id: workspace_id,
      worker_type: "graph_rag",
      input: "test graph_rag query",
      status: "running"
    })
  end

  defp build_state(workspace_id, attrs \\ []) do
    struct(
      %GraphRag.State{
        session: build_session(workspace_id),
        pages_created: 0,
        opts: [],
        mode: nil,
        seeds: [],
        expanded: [],
        answer: nil,
        sources: [],
        searches_done: 0,
        expands_done: 0,
        cluster_contexts_done: 0
      },
      attrs
    )
  end

  defp insert_page!(workspace_id, attrs) do
    %Page{
      workspace_id: workspace_id,
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
    Knowledge.get_workspace_by_slug("personal") ||
      elem(Knowledge.create_workspace(%{name: "Personal", slug: "personal"}), 1)
  end

  defp insert_relation!(source_id, target_id, type) do
    %Dran.Relation{
      source_id: source_id,
      target_id: target_id,
      relation_type: type
    }
    |> Repo.insert!()
  end

  #  worker_type 

  test "worker_type/0 returns graph_rag" do
    assert GraphRag.worker_type() == "graph_rag"
  end

  #  tools 

  test "tools/0 returns a list of tool schemas" do
    tools = GraphRag.tools()
    assert is_list(tools)
    assert length(tools) > 0

    tool_names = Enum.map(tools, & &1["function"]["name"])

    assert "hybrid_search" in tool_names
    assert "expand_neighbors" in tool_names
    assert "get_page_content" in tool_names
    assert "get_cluster_context" in tool_names
    assert "list_clusters" in tool_names
    assert "synthesize_answer" in tool_names
    assert "create_answer_page" in tool_names
    assert "done" in tool_names
  end

  test "tools have valid OpenAI function schema structure" do
    for tool <- GraphRag.tools() do
      assert tool["type"] == "function"
      assert is_binary(tool["function"]["name"])
      assert is_binary(tool["function"]["description"])
      assert is_map(tool["function"]["parameters"])
      assert tool["function"]["parameters"]["type"] == "object"
    end
  end

  #  system_prompt 

  test "system_prompt/0 returns a non-empty string mentioning GraphRAG" do
    prompt = GraphRag.system_prompt()
    assert is_binary(prompt)
    assert String.length(prompt) > 50
    assert prompt =~ "GraphRAG"
    assert prompt =~ "LOCAL"
    assert prompt =~ "GLOBAL"
    assert prompt =~ "DRIFT"
  end

  #  build_messages 

  test "build_messages/2 returns system and user messages" do
    session = build_session(Ecto.UUID.generate())
    messages = GraphRag.build_messages("test query", session)

    assert length(messages) == 2
    assert Enum.at(messages, 0)["role"] == "system"
    assert Enum.at(messages, 1)["role"] == "user"
    assert Enum.at(messages, 1)["content"] =~ "test query"
  end

  #  init_state 

  test "init_state/3 returns a State struct with messages" do
    session = build_session(Ecto.UUID.generate())
    state = GraphRag.init_state(session, GraphRag, [])

    assert %GraphRag.State{} = state
    assert state.session == session
    assert state.module == GraphRag
    assert length(state.messages) == 2
    assert state.step == 0
    assert state.pages_created == 0
    assert state.searches_done == 0
    assert state.expands_done == 0
  end

  #  execute_tool: hybrid_search 

  test "hybrid_search returns error when query is empty" do
    state = build_state(Ecto.UUID.generate())
    {result, _state} = GraphRag.execute_tool("hybrid_search", %{"query" => ""}, state)
    assert {:error, "query is required"} = result
  end

  test "hybrid_search returns error when limit reached" do
    state = build_state(Ecto.UUID.generate(), searches_done: 10)
    {result, _state} = GraphRag.execute_tool("hybrid_search", %{"query" => "test"}, state)
    assert {:error, msg} = result
    assert msg =~ "search limit reached"
  end

  #  execute_tool: expand_neighbors 

  test "expand_neighbors returns error when slug is empty" do
    state = build_state(Ecto.UUID.generate())
    {result, _state} = GraphRag.execute_tool("expand_neighbors", %{"slug" => ""}, state)
    assert {:error, "slug is required"} = result
  end

  test "expand_neighbors returns error when page not found" do
    workspace_id = Ecto.UUID.generate()
    state = build_state(workspace_id)

    {result, _state} =
      GraphRag.execute_tool("expand_neighbors", %{"slug" => "nonexistent"}, state)

    assert {:error, msg} = result
    assert msg =~ "not found"
  end

  test "expand_neighbors returns error when limit reached" do
    state = build_state(Ecto.UUID.generate(), expands_done: 5)
    {result, _state} = GraphRag.execute_tool("expand_neighbors", %{"slug" => "test"}, state)
    assert {:error, msg} = result
    assert msg =~ "expand limit reached"
  end

  test "expand_neighbors finds outbound and inbound neighbors" do
    workspace_id = ensure_context!().id

    page_a = insert_page!(workspace_id, title: "Page A", slug: "page-a")
    page_b = insert_page!(workspace_id, title: "Page B", slug: "page-b")
    page_c = insert_page!(workspace_id, title: "Page C", slug: "page-c")

    # A  B (outbound from A)
    insert_relation!(page_a.id, page_b.id, "related")
    # C  A (inbound to A)
    insert_relation!(page_c.id, page_a.id, "part_of")

    state = build_state(workspace_id)

    {result, new_state} =
      GraphRag.execute_tool("expand_neighbors", %{"slug" => "page-a", "depth" => 1}, state)

    assert {:ok, neighbors} = result
    assert length(neighbors) == 2

    slugs = Enum.map(neighbors, & &1.slug)
    assert "page-b" in slugs
    assert "page-c" in slugs

    # Check direction
    b_neighbor = Enum.find(neighbors, &(&1.slug == "page-b"))
    c_neighbor = Enum.find(neighbors, &(&1.slug == "page-c"))
    assert b_neighbor.direction == "outbound"
    assert c_neighbor.direction == "inbound"

    assert new_state.expands_done == 1
    assert length(new_state.expanded) == 2
  end

  #  execute_tool: get_page_content 

  test "get_page_content returns page body and meta" do
    workspace_id = ensure_context!().id

    _page =
      insert_page!(workspace_id,
        title: "Test Content",
        slug: "test-content",
        body: "This is the body",
        page_type: "concept",
        meta: %{"kind" => "technique", "domain" => "elixir"}
      )

    state = build_state(workspace_id)

    {result, _state} =
      GraphRag.execute_tool("get_page_content", %{"slug" => "test-content"}, state)

    assert {:ok, content} = result
    assert content.slug == "test-content"
    assert content.title == "Test Content"
    assert content.body == "This is the body"
    assert content.page_type == "concept"
    assert content.meta["kind"] == "technique"
  end

  test "get_page_content returns error for missing slug" do
    state = build_state(Ecto.UUID.generate())

    {result, _state} =
      GraphRag.execute_tool("get_page_content", %{"slug" => "nonexistent"}, state)

    assert {:error, msg} = result
    assert msg =~ "not found"
  end

  #  execute_tool: get_cluster_context 

  test "get_cluster_context returns error when slug is empty" do
    state = build_state(Ecto.UUID.generate())

    {result, _state} =
      GraphRag.execute_tool("get_cluster_context", %{"slug" => ""}, state)

    assert {:error, "slug is required"} = result
  end

  test "get_cluster_context returns error when limit reached" do
    state = build_state(Ecto.UUID.generate(), cluster_contexts_done: 3)

    {result, _state} =
      GraphRag.execute_tool("get_cluster_context", %{"slug" => "test"}, state)

    assert {:error, msg} = result
    assert msg =~ "cluster_context limit reached"
  end

  test "get_cluster_context returns cluster data for a page with cluster_id" do
    workspace_id = ensure_context!().id

    _page =
      insert_page!(workspace_id,
        title: "Cluster Page",
        slug: "cluster-page",
        meta: %{"cluster_id" => 1}
      )

    state = build_state(workspace_id)

    {result, new_state} =
      GraphRag.execute_tool("get_cluster_context", %{"slug" => "cluster-page"}, state)

    assert {:ok, data} = result
    assert data.cluster_id == 1
    # Will return fallback since no summary exists yet
    assert is_binary(data.summary)
    assert new_state.cluster_contexts_done == 1
  end

  #  execute_tool: list_clusters 

  test "list_clusters returns a list (possibly empty)" do
    state = build_state(Ecto.UUID.generate())

    {result, _state} = GraphRag.execute_tool("list_clusters", %{}, state)

    assert {:ok, clusters} = result
    assert is_list(clusters)
  end

  #  execute_tool: synthesize_answer 

  test "synthesize_answer records answer, mode, and sources" do
    state = build_state(Ecto.UUID.generate())

    {result, new_state} =
      GraphRag.execute_tool(
        "synthesize_answer",
        %{
          "answer" => "The answer is 42",
          "mode" => "local",
          "sources" => ["page-a", "page-b"]
        },
        state
      )

    assert {:ok, msg} = result
    assert msg =~ "Answer recorded"
    assert new_state.answer == "The answer is 42"
    assert new_state.mode == "local"
    assert new_state.sources == ["page-a", "page-b"]
  end

  test "synthesize_answer returns error when answer is empty" do
    state = build_state(Ecto.UUID.generate())

    {result, _state} =
      GraphRag.execute_tool("synthesize_answer", %{"answer" => ""}, state)

    assert {:error, "answer is required"} = result
  end

  #  execute_tool: create_answer_page 

  test "create_answer_page returns error without synthesize_answer first" do
    state = build_state(Ecto.UUID.generate())

    {result, _state} =
      GraphRag.execute_tool(
        "create_answer_page",
        %{"title" => "Test", "body" => "Body"},
        state
      )

    assert {:error, msg} = result
    assert msg =~ "synthesize_answer first"
  end

  test "create_answer_page returns error when limit reached" do
    state = build_state(Ecto.UUID.generate(), pages_created: 1, answer: "test")

    {result, _state} =
      GraphRag.execute_tool(
        "create_answer_page",
        %{"title" => "Test", "body" => "Body"},
        state
      )

    assert {:error, msg} = result
    assert msg =~ "answer page limit reached"
  end

  test "create_answer_page returns error when title or body is empty" do
    state = build_state(Ecto.UUID.generate(), answer: "test answer")

    {result, _state} =
      GraphRag.execute_tool(
        "create_answer_page",
        %{"title" => "", "body" => "Body"},
        state
      )

    assert {:error, msg} = result
    assert msg =~ "title and body are required"
  end

  test "create_answer_page creates a note page with sources as relations" do
    workspace_id = ensure_context!().id

    source_page =
      insert_page!(workspace_id, title: "Source Page", slug: "source-page")

    state =
      build_state(workspace_id,
        answer: "The synthesized answer",
        mode: "local",
        sources: ["source-page"]
      )

    {result, new_state} =
      GraphRag.execute_tool(
        "create_answer_page",
        %{
          "title" => "Test Query",
          "body" => "The answer is..."
        },
        state
      )

    assert {:ok, %{slug: slug, url: url}} = result
    assert is_binary(slug)
    assert url =~ slug

    # Verify the page was created
    page = Knowledge.get_page_by_slug(slug, workspace_id)
    assert page != nil
    assert page.page_type == "note"
    assert page.title == "Test Query"
    assert page.meta["mode"] == "local"
    assert page.meta["kind"] == "answer"

    # Verify source relation was created
    relations = Knowledge.list_relations_for_page(page.id)
    assert length(relations.outbound) == 1
    assert hd(relations.outbound).relation_type == "related"
    assert hd(relations.outbound).target_id == source_page.id

    assert new_state.pages_created == 1
  end

  #  execute_tool: done 

  test "done returns :done" do
    state = build_state(Ecto.UUID.generate())
    {result, _state} = GraphRag.execute_tool("done", %{"summary" => "finished"}, state)
    assert {:ok, :done} = result
  end

  #  execute_tool: unknown 

  test "unknown tool returns error" do
    state = build_state(Ecto.UUID.generate())
    {result, _state} = GraphRag.execute_tool("unknown_tool", %{}, state)
    assert {:error, :unknown_tool} = result
  end

  #  summarize_result 

  test "summarize_result handles various result shapes" do
    assert GraphRag.summarize_result({:ok, :done}) == %{status: "done"}
    assert GraphRag.summarize_result({:ok, "msg"}) == %{status: "ok", message: "msg"}
    assert GraphRag.summarize_result({:error, "reason"}) == %{status: "error", error: "reason"}
  end

  #  gathered_summary 

  test "gathered_summary returns progress string" do
    state =
      build_state(Ecto.UUID.generate(),
        mode: "local",
        seeds: [%{slug: "a"}],
        expanded: [%{slug: "b"}],
        answer: "test"
      )

    summary = GraphRag.gathered_summary(state)
    assert summary =~ "Mode: local"
    assert summary =~ "seed page"
    assert summary =~ "neighbor"
    assert summary =~ "Answer synthesized"
  end
end
