defmodule Dran.MemoryVisibilityTest do
  @moduledoc """
  Matriz de visibilidad aplicada al CONTEXTO de memoria, contra el modelo v2
  (per-item visibility, contract-instance-visibility-20260919).

  El modelo v1 (share_memory / content_scope / aislamiento por workspace) murió:
  la lectura se resuelve por ÍTEM — un lector común ve `{:reader, id}` =
  propio ∪ público ∪ compartido-conmigo, y solo un rol de instancia owner/admin
  ve `:all`. Cada test lleva su decisión: `# VIVE` (el invariante sigue vivo,
  reescrito al modelo actual) o se borró (el invariante murió con su modelo, se
  registra en el reporte). El vocabulario `{:own, id}` de v1 ya no existe:
  `ContentVisibility.filter/3` solo acepta `:all` y `{:reader, id}`.
  """
  use DranWeb.ConnCase, async: false

  alias Dran.{ContentVisibility, Knowledge, Memory, Repo}
  alias Dran.Accounts.{User, UserWorkspace}

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
      |> Dran.Workspace.settings_changeset(%{
        share_memory: share_memory,
        share_pages: share_memory
      })
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

  describe "P6 — la matriz por ítem (v2)" do
    setup do
      ws = create_workspace(false)

      alice = create_user()
      bob = create_user()
      admin = create_user()

      member(alice, ws, "editor")
      member(bob, ws, "editor")

      # VIVE: el visor completo ya NO es el rol de workspace "admin" sino el
      # rol de INSTANCIA owner/admin — el eje se movió de contenedor a instancia.
      admin = admin |> Ecto.Changeset.change(instance_role: "admin") |> Repo.update!()

      {:ok, _, _} = add_fact(ws, "Alice prefiere Elixir", alice.id)
      {:ok, _, _} = add_fact(ws, "Bob prefiere Rust", bob.id)

      %{ws: ws, alice: alice, bob: bob, admin: admin}
    end

    test "cada usuario ve solo sus facts con su scope", %{ws: ws, alice: alice, bob: bob} do
      # VIVE: el vocabulario v1 {:own, id} se reescribió a {:reader, id}.
      alice_scope = ContentVisibility.scope(ws, alice, :memory)
      bob_scope = ContentVisibility.scope(ws, bob, :memory)

      assert alice_scope == {:reader, alice.id}
      assert bob_scope == {:reader, bob.id}

      alice_sees = Memory.list_memories(ws.id, scope: alice_scope)
      assert Enum.map(alice_sees, & &1.content) == ["Alice prefiere Elixir"]

      bob_sees = Memory.list_memories(ws.id, scope: bob_scope)
      assert Enum.map(bob_sees, & &1.content) == ["Bob prefiere Rust"]
    end

    test "un admin de instancia ve todo", %{ws: ws, admin: admin} do
      # VIVE: la autoridad plena es el rol de instancia, no la membresía.
      scope = ContentVisibility.scope(ws, admin, :memory)
      assert scope == :all

      contents = Memory.list_memories(ws.id, scope: scope) |> Enum.map(& &1.content)
      assert "Alice prefiere Elixir" in contents
      assert "Bob prefiere Rust" in contents
    end

    test "search respeta el scope", %{ws: ws, alice: alice, bob: bob} do
      # VIVE: reescrito a {:reader, id} (v1 usaba {:own, id}).
      alice_hits =
        Memory.search(ws.id, "prefiere", scope: {:reader, alice.id}, bump_retrieval: false)

      assert Enum.map(alice_hits, & &1.memory.content) == ["Alice prefiere Elixir"]

      bob_hits =
        Memory.search(ws.id, "prefiere", scope: {:reader, bob.id}, bump_retrieval: false)

      assert Enum.map(bob_hits, & &1.memory.content) == ["Bob prefiere Rust"]
    end

    test "count_memories cuenta solo lo visible", %{ws: ws, alice: alice} do
      # VIVE: reescrito a {:reader, id}.
      assert Memory.count_memories(ws.id, scope: {:reader, alice.id}) == 1
      assert Memory.count_memories(ws.id, scope: :all) == 2
    end

    test "el dedupe por owner deja que dos dueños sostengan el MISMO fact", %{ws: ws} do
      # VIVE: reescrito a {:reader, id}.
      a = create_user()
      b = create_user()
      member(a, ws, "editor")
      member(b, ws, "editor")

      assert {:ok, _m1, :created} = add_fact(ws, "El deploy es los martes", a.id)
      assert {:ok, _m2, :created} = add_fact(ws, "El deploy es los martes", b.id)

      a_sees = Memory.list_memories(ws.id, scope: {:reader, a.id})
      b_sees = Memory.list_memories(ws.id, scope: {:reader, b.id})

      assert length(a_sees) == 1
      assert length(b_sees) == 1
      assert hd(a_sees).id != hd(b_sees).id
    end

    test "el mismo dueño re-agregando su fact sigue recibiendo :duplicate", %{ws: ws} do
      # VIVE: sin cambios — el dedupe por owner es el comportamiento actual.
      a = create_user()
      member(a, ws, "editor")

      assert {:ok, first, :created} = add_fact(ws, "Un fact del mismo dueño", a.id)
      assert {:ok, second, :duplicate} = add_fact(ws, "Un fact del mismo dueño", a.id)
      assert first.id == second.id
    end
  end

  describe "backwards-compat (guard de la feature)" do
    test "sin :scope los facts de todos los dueños vuelven (pre-feature)" do
      # VIVE: sin :scope no hay filtro (comportamiento pre-feature).
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

    test "contenido sin dueño y privado no se lee por un lector común (fail-closed)" do
      # VIVE reescrito: el vocabulario v1 {:own, nil} murió. En v2 una fila sin
      # dueño con la visibilidad por defecto (private) NO la ve un lector
      # concreto; solo un lector privilegiado (:all) la ve. El invariante que
      # sobrevive es el fail-closed para contenido huérfano.
      ws = create_workspace(false)
      {:ok, _, _} = add_fact(ws, "Fact del workspace (sin dueño)", nil)

      a = create_user()
      member(a, ws, "editor")

      assert Memory.list_memories(ws.id, scope: {:reader, a.id}) == []
      assert Memory.count_memories(ws.id, scope: :all) == 1
    end
  end

  describe "los agentes leen con el alcance de su dueño" do
    test "una identidad de agente con owner_user_id resuelve {:reader, owner}" do
      # VIVE reescrito: la identidad del agente es un mapa con owner_user_id
      # (el dueño de la credencial). La preferencia content_scope murió con el
      # modelo v2 — la lectura ya está acotada por el filtro por ítem.
      ws = create_workspace(false)
      owner = create_user()
      member(owner, ws, "editor")
      other = create_user()
      member(other, ws, "editor")

      {:ok, _, _} = add_fact(ws, "Del dueño para su agente", owner.id)
      {:ok, _, _} = add_fact(ws, "De otro dueño", other.id)

      identity = %{owner_user_id: owner.id, agent_name: "agent-x"}
      scope = ContentVisibility.scope(ws, identity, :memory)
      assert scope == {:reader, owner.id}

      contents = Memory.list_memories(ws.id, scope: scope) |> Enum.map(& &1.content)
      assert contents == ["Del dueño para su agente"]
    end
  end

  describe "P4 — la credencial REST lee con el alcance de su dueño" do
    test "GET /api/memory aplica el filtro por ítem al token de cuenta" do
      # VIVE reescrito: la versión v1 giraba content_scope para cambiar la
      # vista. Ese eje murió; lo que sobrevive es que la credencial de cuenta
      # lee EXACTAMENTE lo que su dueño puede ver (propio ∪ público ∪
      # compartido), nunca lo ajeno privado. El API targeta la instancia
      # (W5), así que el test escribe en el workspace de instancia.
      unique = System.unique_integer([:positive])
      ws = Dran.DataCase.ensure_workspace!()

      owner = create_user()
      other = create_user()

      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("accept", "application/json")
        |> Plug.Conn.put_req_header("authorization", "Bearer #{owner.api_token}")

      {:ok, _, _} = add_fact(ws, "Del dueño #{unique}", owner.id)
      {:ok, _, _} = add_fact(ws, "De otro #{unique}", other.id)

      resp = get(conn, ~p"/api/memory?workspace=#{ws.slug}")
      assert %{"data" => data} = json_response(resp, 200)
      contents = Enum.map(data, & &1["content"])

      assert "Del dueño #{unique}" in contents
      refute "De otro #{unique}" in contents
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
end
