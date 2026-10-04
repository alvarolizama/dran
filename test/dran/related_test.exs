defmodule Dran.RelatedTest do
  @moduledoc """
  Gate W5 (P8/P9/P10): la puerta de «páginas relacionadas» de un contenedor de
  trabajo — las relaciones REALES primero, el fallback semántico SÓLO cuando no
  hay ninguna, todo con el scope PERSONAL del lector, y el alta explícita y
  atribuida.
  """

  use Dran.DataCase, async: false

  alias Dran.{Accounts, Goals, Knowledge, Plans, Related}

  setup do
    # Sin inferencia real: el fallback se inyecta en cada test que lo ejercita.
    original = Application.get_env(:dran, :inference)

    Application.put_env(:dran, :inference,
      base_url: nil,
      api_key: nil,
      embedding_model: nil,
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

    workspace = ensure_workspace!()

    {:ok, workspace: workspace, author: user!("related-author"), reader: user!("related-reader")}
  end

  defp user!(label) do
    unique = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.create_user(%{
        email: "#{label}-#{unique}@dran.test",
        api_token: "tok-#{label}-#{unique}"
      })

    user
  end

  defp goal!(owner, extra \\ %{}) do
    {:ok, goal} =
      Goals.create_goal(
        Map.merge(
          %{"title" => "Meta #{System.unique_integer([:positive])}", "owner_user_id" => owner.id},
          extra
        )
      )

    goal
  end

  defp plan!(owner, extra \\ %{}) do
    {:ok, plan} =
      Plans.create_plan(
        Map.merge(
          %{"title" => "Plan #{System.unique_integer([:positive])}", "owner_user_id" => owner.id},
          extra
        )
      )

    plan
  end

  defp page!(workspace, owner, title, visibility) do
    {:ok, page} =
      Knowledge.create_page(%{
        workspace_id: workspace.id,
        title: title,
        body: "cuerpo de #{title}",
        page_type: "note",
        visibility: visibility,
        owner_user_id: owner.id
      })

    page
  end

  defp ids(%{pages: pages}), do: Enum.map(pages, & &1.id)

  describe "las dos fuentes" do
    test "sin ninguna relación real, el fallback semántico entra", ctx do
      goal = goal!(ctx.author)
      page = page!(ctx.workspace, ctx.author, "Página vecina", "public")

      searcher = fn _query, _opts -> {:ok, [%{id: page.id, distance: 0.2}]} end

      result =
        Related.for_entity("goal", goal, scope: {:reader, ctx.author.id}, searcher: searcher)

      assert result.source == :semantic
      assert ids(result) == [page.id]
    end

    test "con una relación real el fallback NO se consulta", ctx do
      goal = goal!(ctx.author)
      page = page!(ctx.workspace, ctx.author, "Vinculada", "public")
      {:ok, _} = Related.link("goal", goal, page.id, ctx.author)

      # Un fallback que revienta: si el sidebar lo consultara, el test explota.
      searcher = fn _query, _opts ->
        raise "el fallback no debe consultarse cuando hay relaciones reales"
      end

      result =
        Related.for_entity("goal", goal, scope: {:reader, ctx.author.id}, searcher: searcher)

      assert result.source == :relations
      assert ids(result) == [page.id]
    end

    test "el umbral descarta los vecinos lejanos", ctx do
      goal = goal!(ctx.author)
      far = page!(ctx.workspace, ctx.author, "Lejana", "public")

      result =
        Related.for_entity("goal", goal,
          scope: :all,
          searcher: fn _q, _o -> {:ok, [%{id: far.id, distance: 0.95}]} end
        )

      assert result.source == :none
      assert result.pages == []
    end

    test "el fallback que no corre (sin inferencia) no inventa vecinos", ctx do
      goal = goal!(ctx.author)

      result =
        Related.for_entity("goal", goal,
          scope: :all,
          searcher: fn _q, _o -> {:error, :not_configured} end
        )

      assert result.source == :none
      assert result.pages == []
    end
  end

  describe "el scope del lector" do
    test "una relación con una página que el lector NO lee no se lista", ctx do
      goal = goal!(ctx.author)
      hidden = page!(ctx.workspace, ctx.author, "Privada del autor", "private")
      {:ok, _} = Related.link("goal", goal, hidden.id, ctx.author)

      # El lector común no la lee: ni por la relación ni por el fallback.
      foreign =
        Related.for_entity("goal", goal,
          scope: {:reader, ctx.reader.id},
          searcher: fn _q, _o -> {:ok, [%{id: hidden.id, distance: 0.1}]} end
        )

      assert foreign.source == :none
      assert foreign.pages == []

      # El autor sí.
      own = Related.for_entity("goal", goal, scope: {:reader, ctx.author.id})
      assert own.source == :relations
      assert ids(own) == [hidden.id]
    end

    test "una página pública de otro SÍ se lista (el scope no es «sólo lo mío»)", ctx do
      goal = goal!(ctx.author)
      public = page!(ctx.workspace, ctx.reader, "Pública del lector", "public")
      {:ok, _} = Related.link("goal", goal, public.id, ctx.reader)

      result = Related.for_entity("goal", goal, scope: {:reader, ctx.author.id})

      assert result.source == :relations
      assert ids(result) == [public.id]
    end

    test "un id forjado no vincula nada que el lector no pueda leer", ctx do
      goal = goal!(ctx.author)
      hidden = page!(ctx.workspace, ctx.author, "Privada", "private")

      assert {:error, :page_not_found} =
               Related.link("goal", goal, hidden.id, ctx.reader, scope: {:reader, ctx.reader.id})

      assert {:error, :page_not_found} =
               Related.link("goal", goal, Ecto.UUID.generate(), ctx.author)
    end
  end

  describe "el alta explícita" do
    test "queda atribuida y desde ahí la fuente es la relación (sin duplicar)", ctx do
      goal = goal!(ctx.author)
      page = page!(ctx.workspace, ctx.author, "Para vincular", "public")

      assert {:ok, relation} = Related.link("goal", goal, page.id, ctx.reader)

      assert relation.relation_type == "related"
      assert relation.source_id == goal.id
      assert relation.source_type == "goal"
      assert relation.target_id == page.id
      assert relation.target_type == "page"
      assert relation.meta["created_by_user_id"] == ctx.reader.id
      assert relation.meta["source"] == "related_sidebar"

      # El fallback ya no la puede duplicar: la fuente pasó a ser la relación.
      result =
        Related.for_entity("goal", goal,
          scope: {:reader, ctx.author.id},
          searcher: fn _q, _o -> {:ok, [%{id: page.id, distance: 0.1}]} end
        )

      assert result.source == :relations
      assert ids(result) == [page.id]
    end

    test "el mismo alta sobre un PLAN usa el extremo correcto", ctx do
      plan = plan!(ctx.author)
      page = page!(ctx.workspace, ctx.author, "Página del plan", "public")

      assert {:ok, relation} = Related.link("plan", plan, page.id, ctx.author)
      assert relation.source_type == "plan"

      result = Related.for_entity("plan", plan, scope: {:reader, ctx.author.id})
      assert result.source == :relations
      assert ids(result) == [page.id]
    end

    test "el picker no ofrece lo que ya está vinculado", ctx do
      goal = goal!(ctx.author)
      linked = page!(ctx.workspace, ctx.author, "Ya vinculada", "public")
      free = page!(ctx.workspace, ctx.author, "Libre", "public")
      {:ok, _} = Related.link("goal", goal, linked.id, ctx.author)

      candidates = Related.linkable_pages("goal", goal, scope: {:reader, ctx.author.id})
      candidate_ids = Enum.map(candidates, & &1.id)

      assert free.id in candidate_ids
      refute linked.id in candidate_ids
    end

    test "una relación derivada por la máquina (semantic) no cuenta como relacionada", ctx do
      goal = goal!(ctx.author)
      page = page!(ctx.workspace, ctx.author, "Inferida", "public")

      {:ok, _} =
        Knowledge.create_relation(%{
          source_id: goal.id,
          source_type: "goal",
          target_id: page.id,
          target_type: "page",
          relation_type: "semantic"
        })

      # `semantic` es inferencia, no una relación legible: ahí el sidebar sí cae
      # al fallback (y el test lo inyecta para no depender de la red).
      result =
        Related.for_entity("goal", goal,
          scope: {:reader, ctx.author.id},
          searcher: fn _q, _o -> {:ok, []} end
        )

      assert result.source == :none
      assert result.pages == []
    end
  end
end
