defmodule Dran.PlansTest do
  @moduledoc """
  Gate W1 (contract.md): el plan es una ENTIDAD, no un tipo de página.

  El plan vive en su propia tabla (`plans`) con `owner_user_id` + `visibility`
  default `private`, se lee por la política única y su checklist es el MISMO
  jsonb `[%{text, done}]` de la task — sin tabla `plan_steps`, sin `steps` y sin
  `checklist_items` (P6, P7, P8 / Constraints 7 y 8).

  Revisa el modelo anterior: el contrato cerrado resolvía el plan como página de
  un tipo declarado por instancia (su Constraint 16). La medición que sostiene el
  cambio: en `dran_dev` `workspace_page_types` es `[]`, así que el tipo `plan`
  sólo existía en un fixture de test.
  """

  use Dran.DataCase, async: false

  alias Dran.{Accounts, Checklist, ContentVisibility, Plans, Relation, Tasks, Workspace}
  alias Dran.Plans.Plan

  setup do
    ws = Dran.DataCase.ensure_workspace!()
    {:ok, ws: ws, alice: member!("alice"), bob: member!("bob")}
  end

  # ── El modelo: entidad, no página ─────────────────────────────────────────

  describe "el plan es una tabla, no un tipo de página" do
    test "la tabla plans existe y las de pasos NO" do
      assert table_exists?("plans")
      refute table_exists?("steps")
      refute table_exists?("plan_steps")
      refute table_exists?("checklist_items")
    end

    test "`plan` no se puede declarar como tipo de página custom", %{ws: ws} do
      fields = [
        %{"slug" => "plan", "label" => "Plan", "plural" => "Planes", "path" => "plans"}
      ]

      {:error, changeset} =
        ws |> Workspace.settings_changeset(%{workspace_page_types: fields}) |> Repo.update()

      # El slug `plan` choca por DOS razones (es primera clase Y su path está
      # reservado): las dos se reportan, ninguna se silencia.
      messages = errors_on(changeset).workspace_page_types
      assert Enum.any?(messages, &(&1 =~ "first-class entity"))
      assert Enum.any?(messages, &(&1 =~ "reserved route segment"))

      # Y el path queda reservado: el router sirve `/plans`, así que un tipo
      # declarado con ese path sería inalcanzable.
      {:error, path_changeset} =
        ws
        |> Workspace.settings_changeset(%{
          workspace_page_types: [
            %{"slug" => "recetario", "label" => "Receta", "path" => "plans"}
          ]
        })
        |> Repo.update()

      assert %{workspace_page_types: [path_message]} = errors_on(path_changeset)
      assert path_message =~ "reserved route segment"
    end

    test "un tipo de página `plan` NO existe en ninguna instancia", %{ws: ws} do
      refute "plan" in Dran.Knowledge.effective_page_types(ws)
      assert Workspace.page_type_meta_fields(ws, "plan") == []
      assert Dran.PageRegistry.config("plan") == nil
    end
  end

  # ── Propiedad y lectura ───────────────────────────────────────────────────

  describe "dueño y visibilidad propios" do
    test "nace privado y con su dueño", %{alice: alice} do
      plan = plan!(alice, %{"title" => "Lanzamiento"})

      assert plan.visibility == "private"
      assert plan.owner_user_id == alice.id
      assert plan.status == "draft"
      assert plan.checklist == []
      assert plan.lock_version == 1
    end

    test "el dueño lee lo suyo y un tercero no, ni por id ni por slug",
         %{alice: alice, bob: bob} do
      plan = plan!(alice, %{"title" => "Privado"})

      alice_scope = ContentVisibility.resolve(nil, alice, :plan)
      bob_scope = ContentVisibility.resolve(nil, bob, :plan)

      assert Plans.get_plan(plan.id, scope: alice_scope).id == plan.id
      assert Plans.get_plan(plan.id, scope: bob_scope) == nil
      assert Plans.get_plan_by_slug(plan.slug, scope: alice_scope).id == plan.id
      assert Plans.get_plan_by_slug(plan.slug, scope: bob_scope) == nil
    end

    test "lo público lo lee cualquiera", %{alice: alice, bob: bob} do
      plan = plan!(alice, %{"title" => "Público", "visibility" => "public"})

      bob_scope = ContentVisibility.resolve(nil, bob, :plan)
      assert Plans.get_plan(plan.id, scope: bob_scope).id == plan.id
    end

    test "lo compartido solo lo lee el invitado", %{alice: alice, bob: bob} do
      plan = plan!(alice, %{"title" => "Compartido", "visibility" => "shared"})
      tercero = member!("tercero")

      {:ok, group} = Dran.Sharing.create_group(%{name: "Equipo #{uniq()}"})
      {:ok, _} = Dran.Sharing.add_group_member(group, bob.id)
      {:ok, :shared} = Dran.Sharing.share_with_group("plan", plan.id, group.id)

      bob_scope = ContentVisibility.resolve(nil, bob, :plan)
      tercero_scope = ContentVisibility.resolve(nil, tercero, :plan)

      assert Plans.get_plan(plan.id, scope: bob_scope).id == plan.id
      assert Plans.get_plan(plan.id, scope: tercero_scope) == nil
    end

    test "un id forjado no revienta la query", %{alice: alice} do
      scope = ContentVisibility.resolve(nil, alice, :plan)
      assert Plans.get_plan("forged-binary-xyz", scope: scope) == nil
    end

    test "el slug es único por dueño (mismo balde que el índice)", %{
      alice: alice,
      bob: bob
    } do
      a1 = plan!(alice, %{"title" => "Roadmap"})
      b1 = plan!(bob, %{"title" => "Roadmap"})
      a2 = plan!(alice, %{"title" => "Roadmap"})

      assert a1.slug == "roadmap"
      # bob NO colisiona con alice: la unicidad es por dueño.
      assert b1.slug == "roadmap"
      # alice sí colisiona consigo misma → sufijo.
      assert a2.slug != "roadmap"
      assert String.starts_with?(a2.slug, "roadmap-")
    end
  end

  # ── Checklist: una sola forma, con la task ────────────────────────────────

  describe "checklist" do
    test "el plan y la task comparten forma y cast", %{alice: alice} do
      plan =
        plan!(alice, %{
          "title" => "Con pasos",
          "checklist" => [%{"text" => "uno"}, "dos", %{text: "  ", done: true}]
        })

      assert plan.checklist == [
               %{"text" => "uno", "done" => false},
               %{"text" => "dos", "done" => false}
             ]

      {:ok, goal} = Dran.Goals.create_goal(%{"title" => "G", "owner_user_id" => alice.id})

      {:ok, task} =
        Tasks.create_task(%{"goal_id" => goal.id, "title" => "T", "checklist" => ["uno", "dos"]})

      assert task.checklist == plan.checklist
      assert Checklist.cast(plan.checklist) == plan.checklist
    end

    test "tachar un paso reescribe el jsonb y no crea ni mueve tasks", %{alice: alice} do
      plan = plan!(alice, %{"title" => "Pasos", "checklist" => ["uno", "dos"]})
      tasks_before = Repo.aggregate(Tasks.Task, :count)

      {:ok, toggled} = Plans.toggle_checklist(plan, 0)

      assert toggled.checklist == [
               %{"text" => "uno", "done" => true},
               %{"text" => "dos", "done" => false}
             ]

      assert toggled.lock_version == plan.lock_version + 1

      # También por texto, y destacha.
      {:ok, again} = Plans.toggle_checklist(toggled, "uno")
      assert again.checklist == plan.checklist

      assert Repo.aggregate(Tasks.Task, :count) == tasks_before
    end

    test "un ítem inexistente no toca la fila", %{alice: alice} do
      plan = plan!(alice, %{"title" => "Pasos", "checklist" => ["uno"]})

      assert {:error, :not_found} = Plans.toggle_checklist(plan, 7)
      assert {:error, :not_found} = Plans.toggle_checklist(plan, "no existe")
      assert Repo.get(Plan, plan.id).lock_version == plan.lock_version
    end

    test "una versión vieja del checklist no pisa a la nueva", %{alice: alice} do
      plan = plan!(alice, %{"title" => "Carrera", "checklist" => ["uno"]})

      # La mano rápida tacha primero.
      {:ok, _fast} = Plans.toggle_checklist(plan, 0)

      # La mano lenta todavía cree que está en lock_version 1.
      assert {:error, :stale} =
               Plans.toggle_checklist(plan, 0, lock_version: plan.lock_version)

      assert Repo.get(Plan, plan.id).checklist == [%{"text" => "uno", "done" => true}]
    end

    test "set_checklist reescribe el array completo", %{alice: alice} do
      plan = plan!(alice, %{"title" => "Reescritura", "checklist" => ["uno"]})

      {:ok, updated} = Plans.set_checklist(plan, ["dos", %{"text" => "tres", "done" => true}])

      assert updated.checklist == [
               %{"text" => "dos", "done" => false},
               %{"text" => "tres", "done" => true}
             ]
    end

    test "el progreso se DERIVA del checklist y nunca se guarda", %{alice: alice} do
      plan =
        plan!(alice, %{
          "title" => "Progreso",
          "checklist" => [%{"text" => "a", "done" => true}, %{"text" => "b", "done" => false}]
        })

      assert Plans.progress(plan) == %{done: 1, total: 2, percent: 50}
      assert Plans.progress([]) == %{done: 0, total: 0, percent: 0}
    end
  end

  # ── Borrado y grafo ───────────────────────────────────────────────────────

  describe "el plan es un nodo del grafo" do
    test "`plan` es un node type declarado" do
      assert "plan" in Relation.node_types()
    end

    test "borrar un plan limpia sus aristas", %{ws: ws, alice: alice} do
      {:ok, page} =
        Dran.Knowledge.create_page(%{
          workspace_id: ws.id,
          title: "Nota #{uniq()}",
          page_type: "note",
          owner_user_id: alice.id
        })

      plan = plan!(alice, %{"title" => "Con arista"})

      {:ok, _} =
        Dran.Knowledge.create_relation(%{
          source_id: plan.id,
          source_type: "plan",
          target_id: page.id,
          target_type: "page",
          relation_type: "related"
        })

      refute edges_touching(plan.id) == []
      assert {:ok, _} = Plans.delete_plan(plan)
      assert edges_touching(plan.id) == []
      assert Repo.get(Plan, plan.id) == nil
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp edges_touching(id) do
    Repo.all(from r in Relation, where: r.source_id == ^id or r.target_id == ^id)
  end

  defp member!(label) do
    unique = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.create_user(%{
        email: "#{label}-#{unique}@dran.test",
        api_token: "tok-#{label}-#{unique}"
      })

    user
  end

  defp plan!(owner, attrs) do
    {:ok, plan} =
      Plans.create_plan(Map.merge(%{"owner_user_id" => owner.id}, attrs))

    plan
  end

  defp table_exists?(name) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_name = $1",
        [name]
      )

    count == 1
  end

  defp uniq, do: System.unique_integer([:positive])
end
