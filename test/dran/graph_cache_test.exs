defmodule Dran.GraphCacheTest do
  @moduledoc """
  Gate W4 (P7): el grafo dibuja goals y plans como nodos — con su color, su
  slug de entidad y sus aristas a las páginas relacionadas — y NO pinta lo que
  el lector no lee: un goal/plan fuera del scope PERSONAL no es nodo, y una
  arista con un extremo oculto no se pinta.

  El scope de las entidades es la puerta personal (`ContentVisibility.
  personal_scope/1`), no la de páginas: un admin lee las páginas de la
  instancia pero NO los goals privados ajenos.
  """

  use DranWeb.ConnCase, async: false

  alias Dran.{Accounts, Goals, GraphCache, Knowledge, Plans}
  alias DranWeb.GraphHelpers

  defp user!(label, attrs \\ %{}) do
    unique = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.create_user(
        Map.merge(
          %{email: "#{label}-#{unique}@dran.test", api_token: "tok-#{label}-#{unique}"},
          attrs
        )
      )

    user
  end

  defp goal!(owner, extra \\ %{}) do
    {:ok, goal} =
      Goals.create_goal(
        Map.merge(
          %{"title" => "Goal #{System.unique_integer([:positive])}", "owner_user_id" => owner.id},
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

  # El payload tal como lo sirve el endpoint: cache limpia, build en el proceso
  # del caller.
  defp payload(workspace, page_scope, entity_scope) do
    GraphCache.clear()

    workspace.id
    |> GraphCache.get(page_scope, entity_scope)
    |> Map.fetch!(:json)
    |> Jason.decode!()
  end

  defp node_ids(payload, type) do
    payload["nodes"] |> Enum.filter(&(&1["type"] == type)) |> Enum.map(& &1["id"])
  end

  defp edge_pairs(payload) do
    Enum.map(payload["edges"], &{&1["source_id"], &1["target_id"]})
  end

  test "un goal y un plan del lector son nodos, con su color y su slug de entidad" do
    workspace = Dran.DataCase.ensure_workspace!()
    owner = user!("graph-owner")
    goal = goal!(owner)
    plan = plan!(owner)

    payload = payload(workspace, :all, {:reader, owner.id})

    assert goal.id in node_ids(payload, "goal")
    assert plan.id in node_ids(payload, "plan")

    goal_node = Enum.find(payload["nodes"], &(&1["id"] == goal.id))
    plan_node = Enum.find(payload["nodes"], &(&1["id"] == plan.id))

    assert goal_node["color"] == GraphHelpers.type_colors()["goal"]
    assert plan_node["color"] == GraphHelpers.type_colors()["plan"]

    # El slug de una entidad es su ID: su ruta canónica es `/goals/:id`.
    assert goal_node["slug"] == goal.id

    # La leyenda cuenta con la MISMA puerta que los nodos.
    assert payload["type_counts"]["goal"] == 1
    assert payload["type_counts"]["plan"] == 1
  end

  test "un goal privado ajeno NO es nodo — tampoco para un admin" do
    workspace = Dran.DataCase.ensure_workspace!()
    owner = user!("graph-private-owner")
    admin = user!("graph-admin", %{instance_role: "admin"})
    goal = goal!(owner)

    # El admin lee las PÁGINAS como :all, pero los goals con la puerta personal.
    payload = payload(workspace, :all, {:reader, admin.id})

    refute goal.id in node_ids(payload, "goal")
    assert payload["type_counts"]["goal"] == 0

    # El dueño sí lo ve: la puerta no es «nadie ve nada».
    owner_payload = payload(workspace, {:reader, owner.id}, {:reader, owner.id})
    assert goal.id in node_ids(owner_payload, "goal")
  end

  test "una arista goal↔página se pinta sólo si AMBOS extremos son visibles" do
    workspace = Dran.DataCase.ensure_workspace!()
    author = user!("graph-edge-author")
    reader = user!("graph-edge-reader")

    goal = goal!(author)
    page = page!(workspace, author, "Página pública del autor", "public")

    {:ok, _} =
      Knowledge.create_relation(%{
        source_id: goal.id,
        source_type: "goal",
        target_id: page.id,
        target_type: "page",
        relation_type: "related"
      })

    # La página es pública y el goal es privado ajeno: el lector ve la página y
    # NO el goal — la arista no puede pintarse a medias.
    foreign = payload(workspace, {:reader, reader.id}, {:reader, reader.id})

    assert page.id in node_ids(foreign, "note")
    refute goal.id in node_ids(foreign, "goal")
    refute {goal.id, page.id} in edge_pairs(foreign)
    refute {page.id, goal.id} in edge_pairs(foreign)

    # El dueño del goal ve los dos extremos: ahí la arista SÍ está.
    own = payload(workspace, {:reader, author.id}, {:reader, author.id})

    assert goal.id in node_ids(own, "goal")
    assert page.id in node_ids(own, "note")

    assert {goal.id, page.id} in edge_pairs(own) or {page.id, goal.id} in edge_pairs(own)
  end

  # El total de aristas (total_edges) cuenta TODAS las familias que la lista
  # pinta: page↔page, memory→page, memory↔memory y page↔entidad. Antes el
  # aggregate capeado sólo contaba page↔page (su join interno a Page no matchea
  # extremos polimórficos) y el «X de Y» del UI subcontaba.
  test "total_edges cuenta las aristas de entidad y de memoria, capeado o no" do
    workspace = Dran.DataCase.ensure_workspace!()
    author = user!("graph-totals-author")

    page_a = page!(workspace, author, "Página A del total", "public")
    page_b = page!(workspace, author, "Página B del total", "public")
    goal = goal!(author)
    plan = plan!(author)

    # Dos aristas de página↔página, una goal↔página y una plan↔página.
    {:ok, _} =
      Knowledge.create_relation(%{
        source_id: page_a.id,
        source_type: "page",
        target_id: page_b.id,
        target_type: "page",
        relation_type: "related"
      })

    {:ok, _} =
      Knowledge.create_relation(%{
        source_id: goal.id,
        source_type: "goal",
        target_id: page_a.id,
        target_type: "page",
        relation_type: "related"
      })

    {:ok, _} =
      Knowledge.create_relation(%{
        source_id: plan.id,
        source_type: "plan",
        target_id: page_b.id,
        target_type: "page",
        relation_type: "related"
      })

    # Uncapped: la lista completa es el total.
    full = Knowledge.graph_data(workspace.id, scope: :all)

    assert length(full.edges) == full.total_edges
    assert full.total_edges == 3

    # Capeado (máximo 1 página visible): el total de page↔page sale del
    # aggregate REAL del workspace (1), no de la lista truncada (0). Las
    # aristas de entidad cuentan las que el grafo PINTA: con una sola página
    # visible, la intersección estricta deja fuera las dos — el «X de Y»
    # describe la vista, no el universo.
    capped = Knowledge.graph_data(workspace.id, scope: :all, max_nodes: 1)

    assert length(capped.edges) < capped.total_edges
    assert capped.total_edges == 2
    # El cap guarda la página MÁS CONECTADA (page_a): su arista de entidad
    # sobrevive en la lista; la de page_b queda fuera con la página.
    assert length(capped.edges) == 1
  end

  test "el cache está keyeado por los DOS scopes: dos lectores, dos payloads" do
    workspace = Dran.DataCase.ensure_workspace!()
    one = user!("graph-cache-one")
    two = user!("graph-cache-two")

    goal_one = goal!(one)
    goal_two = goal!(two)

    GraphCache.clear()

    first = workspace.id |> GraphCache.get(:all, {:reader, one.id}) |> Map.fetch!(:json)
    second = workspace.id |> GraphCache.get(:all, {:reader, two.id}) |> Map.fetch!(:json)

    # La MISMA página (scope :all en los dos) con puertas personales distintas:
    # sin la segunda mitad de la key, el segundo lector recibiría el payload del
    # primero (fuga de existencia).
    refute first == second

    assert Jason.decode!(first)["nodes"] |> Enum.any?(&(&1["id"] == goal_one.id))
    refute Jason.decode!(second)["nodes"] |> Enum.any?(&(&1["id"] == goal_one.id))
    assert Jason.decode!(second)["nodes"] |> Enum.any?(&(&1["id"] == goal_two.id))
  end
end
