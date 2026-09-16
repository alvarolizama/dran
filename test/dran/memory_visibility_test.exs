defmodule Dran.MemoryVisibilityTest do
  @moduledoc """
  Gate W3 (P6 + P5): la matriz de visibilidad aplicada al CONTEXTO de memoria.

  Dos usuarios con facts en el mismo workspace: en aislado cada uno ve solo lo
  suyo (y lo de sus agentes), el admin ve todo, y el dedupe no filtra la
  existencia de facts ajenos vía 409.
  """
  use Dran.DataCase, async: false

  alias Dran.{ContentVisibility, Knowledge, Memory, Repo}
  alias Dran.Accounts.{ApiKey, User, UserWorkspace}

  setup do
    original = Application.get_env(:dran, :inference)

    Application.put_env(:dran, :inference,
      base_url: "http://localhost:8000/v1",
      api_key: "test-key",
      embedding_model: "Qwen3-Embedding",
      chat_model: "Qwen3.5-9B",
      timeout: 5_000,
      req_plug: {Req.Test, Dran.Inference.Client},
      schedule_async: false,
      embedding_dimensions: 1024
    )

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:dran, :inference)
      else
        Application.put_env(:dran, :inference, original)
      end
    end)

    :ok
  end

  defp create_user do
    unique = System.unique_integer([:positive])

    {:ok, user} =
      %User{}
      |> User.changeset(%{email: "mv-#{unique}@dran.test", api_token: "mv-#{unique}"})
      |> Repo.insert()

    user
  end

  defp create_workspace(share_memory) do
    unique = System.unique_integer([:positive])

    {:ok, ws} =
      Knowledge.create_workspace(%{name: "MV #{unique}", slug: "mv-#{unique}"})

    {:ok, ws} =
      ws
      |> Dran.Workspace.settings_changeset(%{share_memory: share_memory, share_pages: share_memory})
      |> Repo.update()

    ws
  end

  defp member(user, workspace, role, content_scope \\ "all") do
    {:ok, _} =
      %UserWorkspace{}
      |> UserWorkspace.changeset(%{
        user_id: user.id,
        workspace_id: workspace.id,
        role: role,
        content_scope: content_scope
      })
      |> Repo.insert()

    :ok
  end

  # Sin inferencia real: el add almacena el fact con embedding nil (degradado
  # pero válido) — el dedupe por hash sigue operando.
  defp add_fact(workspace, content, owner_user_id) do
    stub_embeddings()

    Memory.add(%{
      "workspace_id" => workspace.id,
      "content" => content,
      "created_by" => "test-agent",
      "owner_user_id" => owner_user_id
    })
  end

  describe "P6 — workspace aislado" do
    setup do
      ws = create_workspace(false)

      alice = create_user()
      bob = create_user()
      admin = create_user()

      member(alice, ws, "editor")
      member(bob, ws, "editor")
      member(admin, ws, "admin")

      {:ok, _, _} = add_fact(ws, "Alice prefiere Elixir", alice.id)
      {:ok, _, _} = add_fact(ws, "Bob prefiere Rust", bob.id)

      %{ws: ws, alice: alice, bob: bob, admin: admin}
    end

    test "cada usuario ve solo sus facts con su scope", %{ws: ws, alice: alice, bob: bob} do
      alice_scope = ContentVisibility.scope(ws, alice, :memory)
      bob_scope = ContentVisibility.scope(ws, bob, :memory)

      assert alice_scope == {:own, alice.id}
      assert bob_scope == {:own, bob.id}

      alice_sees = Memory.list_memories(ws.id, scope: alice_scope)
      assert Enum.map(alice_sees, & &1.content) == ["Alice prefiere Elixir"]

      bob_sees = Memory.list_memories(ws.id, scope: bob_scope)
      assert Enum.map(bob_sees, & &1.content) == ["Bob prefiere Rust"]
    end

    test "el admin ve todo", %{ws: ws, alice: alice, admin: admin} do
      scope = ContentVisibility.scope(ws, admin, :memory)
      assert scope == :all

      contents = Memory.list_memories(ws.id, scope: scope) |> Enum.map(& &1.content)
      assert "Alice prefiere Elixir" in contents
      assert "Bob prefiere Rust" in contents
      assert alice.id != admin.id
    end

    test "search respeta el scope en aislado", %{ws: ws, alice: alice, bob: bob} do
      alice_hits =
        Memory.search(ws.id, "prefiere", scope: {:own, alice.id}, bump_retrieval: false)

      assert Enum.map(alice_hits, & &1.memory.content) == ["Alice prefiere Elixir"]

      bob_hits =
        Memory.search(ws.id, "prefiere", scope: {:own, bob.id}, bump_retrieval: false)

      assert Enum.map(bob_hits, & &1.memory.content) == ["Bob prefiere Rust"]
    end

    test "count_memories cuenta solo lo visible", %{ws: ws, alice: alice} do
      assert Memory.count_memories(ws.id, scope: {:own, alice.id}) == 1
      assert Memory.count_memories(ws.id, scope: :all) == 2
    end

    test "P6 — el dedupe por owner deja que dos dueños sostengan el MISMO fact" do
      ws = create_workspace(false)
      a = create_user()
      b = create_user()
      member(a, ws, "editor")
      member(b, ws, "editor")

      assert {:ok, _m1, :created} = add_fact(ws, "El deploy es los martes", a.id)
      assert {:ok, _m2, :created} = add_fact(ws, "El deploy es los martes", b.id)

      a_sees = Memory.list_memories(ws.id, scope: {:own, a.id})
      b_sees = Memory.list_memories(ws.id, scope: {:own, b.id})

      assert length(a_sees) == 1
      assert length(b_sees) == 1
      assert hd(a_sees).id != hd(b_sees).id
    end

    test "P6 — el mismo dueño re-agregando su fact sigue recibiendo :duplicate" do
      ws = create_workspace(false)
      a = create_user()
      member(a, ws, "editor")

      assert {:ok, first, :created} = add_fact(ws, "Un fact del mismo dueño", a.id)
      assert {:ok, second, :duplicate} = add_fact(ws, "Un fact del mismo dueño", a.id)
      assert first.id == second.id
    end
  end

  describe "P6 — workspace compartido (comportamiento previo)" do
    setup do
      ws = create_workspace(true)
      alice = create_user()
      bob = create_user()
      member(alice, ws, "editor")
      member(bob, ws, "editor")

      %{ws: ws, alice: alice, bob: bob}
    end

    test "el dedupe sigue siendo GLOBAL del workspace", %{ws: ws, alice: alice, bob: bob} do
      assert {:ok, first, :created} = add_fact(ws, "El workspace comparte facts", alice.id)

      # Otro dueño, mismo contenido ⇒ duplicate (no se duplica el fact)
      assert {:ok, second, :duplicate} = add_fact(ws, "El workspace comparte facts", bob.id)
      assert first.id == second.id
    end

    test "con content_scope 'all' los dos ven todo", %{ws: ws, alice: alice, bob: bob} do
      {:ok, _, _} = add_fact(ws, "Fact compartido", alice.id)

      assert ContentVisibility.scope(ws, alice, :memory) == :all
      assert ContentVisibility.scope(ws, bob, :memory) == :all

      assert length(Memory.list_memories(ws.id, scope: :all)) == 1
    end

    test "content_scope 'own' filtra sin aislar el dedupe", %{ws: ws, alice: alice, bob: bob} do
      unique = System.unique_integer([:positive])
      member_with_scope(alice, ws, "own")

      {:ok, _, _} = add_fact(ws, "Fact de Alice #{unique}", alice.id)
      {:ok, _, _} = add_fact(ws, "Fact de Bob #{unique}", bob.id)

      alice_sees = Memory.list_memories(ws.id, scope: {:own, alice.id})
      assert Enum.map(alice_sees, & &1.content) == ["Fact de Alice #{unique}"]
    end
  end

  describe "backwards-compat (guard de la feature)" do
    test "sin :scope los facts de todos los dueños vuelven (pre-feature)" do
      ws = create_workspace(false)
      a = create_user()
      b = create_user()
      member(a, ws, "editor")
      member(b, ws, "editor")

      {:ok, _, _} = add_fact(ws, "Fact A", a.id)
      {:ok, _, _} = add_fact(ws, "Fact B", b.id)

      all = Memory.list_memories(ws.id)
      assert length(all) == 2
      assert Memory.count_memories(ws.id) == 2
    end

    test "contenido sin dueño (owner nil) es visible con {:own, nil}" do
      ws = create_workspace(false)
      {:ok, _, _} = add_fact(ws, "Fact del workspace (sin dueño)", nil)

      workspace_only = Memory.list_memories(ws.id, scope: {:own, nil})
      assert Enum.map(workspace_only, & &1.content) == ["Fact del workspace (sin dueño)"]

      # Y NO es visible para un dueño concreto
      a = create_user()
      member(a, ws, "editor")
      assert Memory.list_memories(ws.id, scope: {:own, a.id}) == []
    end
  end

  describe "agentes heredan la preferencia del dueño (P4)" do
    test "la misma key cambia su vista cuando cambia content_scope del dueño" do
      ws = create_workspace(true)
      owner = create_user()
      member(owner, ws, "editor", "all")

      actor = ApiKey.ensure_actor_for_key_name("pref-#{System.unique_integer([:positive])}")
      {:ok, actor} = actor |> Ecto.Changeset.change(%{owner_user_id: owner.id}) |> Repo.update()
      identity = %{actor: actor}

      # Preferencia "all": el agente ve todo
      assert ContentVisibility.scope(ws, identity, :memory) == :all

      # Cambia la preferencia del dueño a "own"
      {:ok, _} =
        Dran.Accounts.UserWorkspace
        |> Repo.get_by(user_id: owner.id, workspace_id: ws.id)
        |> Dran.Accounts.UserWorkspace.changeset(%{content_scope: "own"})
        |> Repo.update()

      assert ContentVisibility.scope(ws, identity, :memory) == {:own, owner.id}
    end
  end

  # ── Stubs de inferencia ────────────────────────────────────────────────────
  # Mismo patrón que test/dran/memory_test.exs: vectores determinísticos por
  # contenido (mismo texto → mismo vector, textos distintos → ejes ortogonales)
  # para que el dedupe semántico no convierta todo en duplicado del primero.

  defp stub_embeddings do
    Req.Test.stub(Dran.Inference.Client, fn conn ->
      {:ok, body, _conn} = Plug.Conn.read_body(conn)
      input = extract_embed_input(body)
      Req.Test.json(conn, embeddings_response(embedding_for(input)))
    end)
  end

  defp extract_embed_input(body) do
    case Jason.decode(body) do
      {:ok, %{"input" => [input | _]}} when is_binary(input) -> input
      {:ok, %{"input" => input}} when is_binary(input) -> input
      _ -> ""
    end
  end

  # Stable pseudo-embedding derived from the content: same text -> same vector,
  # different text -> one-hot on a different axis (cosine similarity 0.0).
  defp embedding_for(input) do
    idx = rem(:erlang.phash2(input), 1024)
    List.duplicate(0.0, idx) ++ [1.0] ++ List.duplicate(0.0, 1023 - idx)
  end

  defp embeddings_response(vec) do
    %{
      "object" => "list",
      "data" => [%{"object" => "embedding", "index" => 0, "embedding" => vec}],
      "model" => "Qwen3-Embedding",
      "usage" => %{"prompt_tokens" => 2, "total_tokens" => 2}
    }
  end

  defp member_with_scope(user, workspace, content_scope) do
    Dran.Accounts.UserWorkspace
    |> Repo.get_by(user_id: user.id, workspace_id: workspace.id)
    |> Dran.Accounts.UserWorkspace.changeset(%{content_scope: content_scope})
    |> Repo.update()
  end
end
