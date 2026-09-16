defmodule Dran.ContentVisibilityTest do
  @moduledoc """
  Gate W3 (P5): la política de visibilidad se decide en UN módulo
  (`Dran.ContentVisibility`) y su matriz es la del contrato:

    | política workspace | content_scope | scope        |
    |--------------------|---------------|--------------|
    | shared (true)      | "all"         | :all         |
    | shared (true)      | "own"         | {:own, id}   |
    | isolated (false)   | cualquiera    | {:own, id}   |

  owner/admin del workspace y el instance owner conservan vista completa.
  """
  use Dran.DataCase, async: false

  alias Dran.{ContentVisibility, Knowledge, Repo}
  alias Dran.Accounts.{ApiKey, User, UserWorkspace}

  defp create_user do
    unique = System.unique_integer([:positive])

    {:ok, user} =
      %User{}
      |> User.changeset(%{email: "vis-#{unique}@dran.test", api_token: "vis-#{unique}"})
      |> Repo.insert()

    user
  end

  defp create_workspace(share_memory), do: create_workspace(share_memory, true)

  defp create_workspace(share_memory, share_pages) do
    unique = System.unique_integer([:positive])
    {:ok, ws} =
      Knowledge.create_workspace(%{name: "Vis #{unique}", slug: "vis-#{unique}"})

    {:ok, ws} =
      ws
      |> Dran.Workspace.settings_changeset(%{
        share_memory: share_memory,
        share_pages: share_pages
      })
      |> Repo.update()

    ws
  end

  defp member(user, workspace, role, content_scope \\ "all") do
    {:ok, uw} =
      %UserWorkspace{}
      |> UserWorkspace.changeset(%{
        user_id: user.id,
        workspace_id: workspace.id,
        role: role,
        content_scope: content_scope
      })
      |> Repo.insert()

    uw
  end

  describe "scope/3 — identidades sin privilegio" do
    test "identidad nil ⇒ :all (comportamiento previo a la feature)" do
      ws = create_workspace(false)
      assert ContentVisibility.scope(ws, nil, :memory) == :all
      assert ContentVisibility.scope(ws, nil, :pages) == :all
    end

    test "instance owner ⇒ :all incluso en workspace aislado" do
      ws = create_workspace(false)
      assert ContentVisibility.scope(ws, %{is_owner: true}, :memory) == :all
    end

    test "workspace compartido + content_scope 'all' ⇒ :all" do
      ws = create_workspace(true)
      user = create_user()
      member(user, ws, "viewer", "all")

      assert ContentVisibility.scope(ws, user, :memory) == :all
    end

    test "workspace compartido + content_scope 'own' ⇒ {:own, user_id}" do
      ws = create_workspace(true, true)
      user = create_user()
      member(user, ws, "viewer", "own")

      assert ContentVisibility.scope(ws, user, :memory) == {:own, user.id}
      assert ContentVisibility.scope(ws, user, :pages) == {:own, user.id}
    end

    test "workspace aislado ⇒ {:own, user_id} sin importar content_scope" do
      ws = create_workspace(false, false)
      user = create_user()
      member(user, ws, "editor", "all")

      assert ContentVisibility.scope(ws, user, :memory) == {:own, user.id}
      assert ContentVisibility.scope(ws, user, :pages) == {:own, user.id}
    end

    test "owner/admin del workspace conservan vista completa en aislado" do
      ws = create_workspace(false, false)

      owner = create_user()
      member(owner, ws, "owner", "own")
      assert ContentVisibility.scope(ws, owner, :memory) == :all

      admin = create_user()
      member(admin, ws, "admin", "all")
      assert ContentVisibility.scope(ws, admin, :pages) == :all
    end

    test "editor/viewer NO conservan vista completa en aislado" do
      ws = create_workspace(false, false)

      editor = create_user()
      member(editor, ws, "editor")
      assert ContentVisibility.scope(ws, editor, :memory) == {:own, editor.id}

      viewer = create_user()
      member(viewer, ws, "viewer")
      assert ContentVisibility.scope(ws, viewer, :pages) == {:own, viewer.id}
    end
  end

  describe "scope/3 — identidad de agente (API key)" do
    test "el agente hereda la preferencia de su dueño" do
      ws = create_workspace(true, true)
      owner = create_user()
      member(owner, ws, "editor", "own")

      actor = ApiKey.ensure_actor_for_key_name("agent-#{System.unique_integer([:positive])}")
      {:ok, actor} = actor |> Ecto.Changeset.change(%{owner_user_id: owner.id}) |> Repo.update()

      identity = %{actor: actor}
      assert ContentVisibility.scope(ws, identity, :memory) == {:own, owner.id}
    end

    test "agente sin dueño en workspace aislado ⇒ {:own, nil} (solo contenido del workspace)" do
      ws = create_workspace(false, false)
      actor = ApiKey.ensure_actor_for_key_name("orphan-#{System.unique_integer([:positive])}")

      assert ContentVisibility.scope(ws, %{actor: actor}, :memory) == {:own, nil}
    end

    test "agente sin dueño en workspace compartido ⇒ :all" do
      ws = create_workspace(true, true)
      actor = ApiKey.ensure_actor_for_key_name("shared-#{System.unique_integer([:positive])}")

      assert ContentVisibility.scope(ws, %{actor: actor}, :memory) == :all
    end
  end

  describe "scope/3 — postura defensiva" do
    test "un mapa autenticado sin ownership ⇒ :all (no rompe superficies viejas)" do
      ws = create_workspace(false, false)
      assert ContentVisibility.scope(ws, %{key_name: "legacy"}, :memory) == :all
    end

    test "workspace sin el campo share_* ⇒ compartido (pre-feature)" do
      assert ContentVisibility.scope(%{}, nil, :memory) == :all
    end
  end

  describe "filter/3" do
    test "aplica el WHERE del dueño y es no-op en :all" do
      import Ecto.Query

      base = from(m in Dran.Memory)

      assert ContentVisibility.filter(base, :all) == base

      filtered = ContentVisibility.filter(base, {:own, 42})
      assert inspect(filtered) =~ "owner_user_id"
    end
  end

  describe "visible?/2" do
    test "matriz de visibilidad de una fila" do
      assert ContentVisibility.visible?(123, :all)
      assert ContentVisibility.visible?(123, {:own, 123})
      refute ContentVisibility.visible?(123, {:own, 456})
      assert ContentVisibility.visible?(nil, {:own, nil})
      refute ContentVisibility.visible?(nil, {:own, 456})
      refute ContentVisibility.visible?(123, {:own, nil})
    end
  end

  describe "shared?/2" do
    test "lee la política por tipo de contenido" do
      ws = create_workspace(false, true)
      assert ContentVisibility.shared?(ws, :pages) == true
      assert ContentVisibility.shared?(ws, :memory) == false
    end
  end

  describe "content_scope_for/2" do
    test "devuelve la preferencia guardada, 'all' cuando no hay membresía" do
      ws = create_workspace(true)
      user = create_user()
      member(user, ws, "viewer", "own")

      assert ContentVisibility.content_scope_for(user.id, ws.id) == "own"
      assert ContentVisibility.content_scope_for(user.id, nil) == "all"
      assert ContentVisibility.content_scope_for(nil, ws.id) == "all"
    end
  end

  describe "resolve/3" do
    test "acepta id o slug y resuelve la política" do
      ws = create_workspace(false, false)
      user = create_user()
      member(user, ws, "viewer")

      assert ContentVisibility.resolve(ws.id, user, :memory) == {:own, user.id}
      assert ContentVisibility.resolve(ws.slug, user, :memory) == {:own, user.id}
      assert ContentVisibility.resolve(nil, user, :memory) == :all
    end
  end
end
