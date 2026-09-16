defmodule DranWeb.VisibilityLiveTest do
  @moduledoc """
  Gate W6 (P3 + P4 + P5-UI): superficies LiveView de la visibilidad.

  - memory_live filtra por el scope del lector y ofrece el toggle
    "todo | solo míos" SOLO en workspace compartido.
  - settings expone los toggles de compartición del workspace.
  """
  use DranWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Dran.{Accounts, Knowledge, Memory, Repo}
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

    stub_embeddings()
    :ok
  end

  defp create_user(unique, role \\ nil) do
    {:ok, user} =
      %User{}
      |> User.changeset(%{
        email: "vl-#{unique}@dran.test",
        api_token: "vl-#{unique}",
        name: "VL #{unique}"
      })
      |> Repo.insert()

    {user, role}
  end

  defp login(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{
      "user" => user.email,
      "workspace_slug" => nil
    })
  end

  defp create_workspace(unique, share_memory) do
    {:ok, ws} =
      Knowledge.create_workspace(%{name: "VL #{unique}", slug: "vl-#{unique}"})

    {:ok, ws} =
      ws
      |> Dran.Workspace.settings_changeset(%{share_memory: share_memory, share_pages: true})
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

  describe "memory_live — filtro y toggle" do
    test "workspace compartido: el usuario ve ambos facts y el toggle aparece", %{conn: conn} do
      unique = System.unique_integer([:positive])
      ws = create_workspace(unique, true)

      {alice, _} = create_user(unique * 10 + 1)
      {bob, _} = create_user(unique * 10 + 2)
      member(alice, ws, "editor")
      member(bob, ws, "editor")

      {:ok, _, _} = Memory.add(%{"workspace_id" => ws.id, "content" => "Fact A #{unique}", "owner_user_id" => alice.id})
      {:ok, _, _} = Memory.add(%{"workspace_id" => ws.id, "content" => "Fact B #{unique}", "owner_user_id" => bob.id})

      {:ok, view, html} = conn |> login(alice) |> live(~p"/#{ws.slug}/memory")

      assert has_element?(view, "#memory-scope-toggle")
      assert html =~ "Fact A #{unique}"
      assert html =~ "Fact B #{unique}"
    end

    test "el toggle cambia a 'solo míos' y persiste la preferencia", %{conn: conn} do
      unique = System.unique_integer([:positive])
      ws = create_workspace(unique, true)

      {alice, _} = create_user(unique * 10 + 3)
      {bob, _} = create_user(unique * 10 + 4)
      member(alice, ws, "editor")
      member(bob, ws, "editor")

      {:ok, _, _} = Memory.add(%{"workspace_id" => ws.id, "content" => "Mía #{unique}", "owner_user_id" => alice.id})
      {:ok, _, _} = Memory.add(%{"workspace_id" => ws.id, "content" => "Ajena #{unique}", "owner_user_id" => bob.id})

      {:ok, view, _html} = conn |> login(alice) |> live(~p"/#{ws.slug}/memory")

      html =
        view
        |> element("#memory-scope-own")
        |> render_click()

      assert html =~ "Mía #{unique}"
      refute html =~ "Ajena #{unique}"

      # La preferencia se persistió (los agentes de Alice la heredan).
      assert Dran.ContentVisibility.content_scope_for(alice.id, ws.id) == "own"

      # Y sobrevive a un remount.
      {:ok, _view2, html2} = conn |> login(alice) |> live(~p"/#{ws.slug}/memory")
      assert html2 =~ "Mía #{unique}"
      refute html2 =~ "Ajena #{unique}"
    end

    test "workspace aislado: no hay toggle y cada uno ve lo suyo", %{conn: conn} do
      unique = System.unique_integer([:positive])
      ws = create_workspace(unique, false)

      {alice, _} = create_user(unique * 10 + 5)
      {bob, _} = create_user(unique * 10 + 6)
      member(alice, ws, "editor", "all")
      member(bob, ws, "editor", "all")

      {:ok, _, _} = Memory.add(%{"workspace_id" => ws.id, "content" => "Propia #{unique}", "owner_user_id" => alice.id})
      {:ok, _, _} = Memory.add(%{"workspace_id" => ws.id, "content" => "De otro #{unique}", "owner_user_id" => bob.id})

      {:ok, view, html} = conn |> login(alice) |> live(~p"/#{ws.slug}/memory")

      refute has_element?(view, "#memory-scope-toggle"),
             "en aislado la política ya filtra: el toggle sería mentira"

      assert html =~ "Propia #{unique}"
      refute html =~ "De otro #{unique}"
    end

    test "el admin conserva la vista completa en aislado", %{conn: conn} do
      unique = System.unique_integer([:positive])
      ws = create_workspace(unique, false)

      {admin, _} = create_user(unique * 10 + 7)
      {other, _} = create_user(unique * 10 + 8)
      member(admin, ws, "admin")
      member(other, ws, "editor")

      {:ok, _, _} = Memory.add(%{"workspace_id" => ws.id, "content" => "Del admin #{unique}", "owner_user_id" => admin.id})
      {:ok, _, _} = Memory.add(%{"workspace_id" => ws.id, "content" => "Del otro #{unique}", "owner_user_id" => other.id})

      {:ok, _view, html} = conn |> login(admin) |> live(~p"/#{ws.slug}/memory")

      assert html =~ "Del admin #{unique}"
      assert html =~ "Del otro #{unique}"
    end
  end

  describe "settings — toggles de compartición" do
    test "el form expone ambos toggles y persiste el cambio", %{conn: conn} do
      unique = System.unique_integer([:positive])
      ws = create_workspace(unique, true)
      {owner, _} = create_user(unique * 10 + 9)
      member(owner, ws, "owner")

      {:ok, view, _html} = conn |> login(owner) |> live(~p"/#{ws.slug}/settings")

      # El form de automatización (donde viven los toggles) está en su tab.
      view |> element("button[phx-value-tab='brain_tuning']") |> render_click()

      assert has_element?(view, "#workspace-share-memory")
      assert has_element?(view, "#workspace-share-pages")
      assert has_element?(view, "#workspace-share-memory[checked]")

      # Desactiva compartir memoria (el form envía ambos toggles: uno solo
      # dejaría el otro en su default del hidden input).
      html =
        view
        |> form("#workspace-settings-form", %{
          "workspace" => %{"share_memory" => "false", "share_pages" => "true"}
        })
        |> render_submit()

      assert html

      updated = Knowledge.get_workspace_by_slug(ws.slug)
      assert updated.share_memory == false
      assert updated.share_pages == true
    end
  end

  # Mismo stub determinístico que los otros tests de memoria.
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
