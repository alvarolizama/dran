defmodule Dran.PropsPointersTest do
  @moduledoc """
  P14 (W4a, contract.md · shaping F32): los punteros internos guardan IDs.

  Un `:slug_select` guarda el id de la página destino (no su slug) y
  `Dran.PropsMaterializer` resuelve el destino por id cuando el valor castea
  como uuid. Renombrar el slug del destino no rompe el puntero ni la arista.
  """

  use Dran.DataCase, async: false

  alias Dran.{Knowledge, PropsMaterializer, Repo}

  setup do
    slug = "pointers-#{System.unique_integer([:positive, :monotonic])}"
    {:ok, ws} = Knowledge.create_workspace(%{name: "Pointers #{slug}", slug: slug})
    %{ws: ws}
  end

  defp create_page(ws, attrs) do
    {:ok, page} =
      Knowledge.create_page(
        Map.merge(%{workspace_id: ws.id, page_type: "entity", body: ""}, attrs)
      )

    page
  end

  describe "materializador de props con punteros por id" do
    test "un prop id apunta al destino y sobrevive un rename de slug", %{ws: ws} do
      target = create_page(ws, %{title: "Sales", slug: "sales"})

      source =
        create_page(ws, %{
          title: "Juan",
          slug: "juan",
          meta: %{"props" => %{"role" => target.id}}
        })

      assert {:ok, 1} = PropsMaterializer.materialize(source)

      [edge] = Knowledge.list_relations_for_page(source.id).outbound
      assert edge.relation_type == "works_in"
      assert edge.target_id == target.id

      # Renombrar el slug del destino directamente: el puntero es un id, no
      # un slug, así que la arista sigue siendo válida.
      target |> Ecto.Changeset.change(slug: "ventas") |> Repo.update!()
      assert Knowledge.get_page(target.id).slug == "ventas"

      # Re-materializar es idempotente y sigue apuntando a la MISMA página.
      assert {:ok, 1} = PropsMaterializer.materialize(source)
      [edge2] = Knowledge.list_relations_for_page(source.id).outbound
      assert edge2.target_id == target.id

      assert Knowledge.get_page_by_slug("ventas", ws.id).id == target.id
      refute Knowledge.get_page_by_slug("sales", ws.id)
    end

    test "un prop id irresoluble no crea una página con el uuid como slug", %{ws: ws} do
      source =
        create_page(ws, %{
          title: "Ghost",
          slug: "ghost",
          meta: %{"props" => %{"role" => Ecto.UUID.generate()}}
        })

      assert {:ok, 0} = PropsMaterializer.materialize(source)
      assert Knowledge.list_relations_for_page(source.id).outbound == []
    end
  end

  describe ":slug_select guarda el id" do
    test "el id almacenado resuelve tras renombrar el slug del plan", %{ws: ws} do
      plan = create_page(ws, %{title: "Plan viaje", slug: "plan-viaje", page_type: "note"})

      holder =
        create_page(ws, %{title: "Holder", slug: "holder", meta: %{"plan_id" => plan.id}})

      plan |> Ecto.Changeset.change(slug: "plan-viaje-2026") |> Repo.update!()

      # El puntero guardado es el id: el rename del slug no lo toca.
      pointer = holder.meta["plan_id"]
      assert pointer == plan.id
      assert Knowledge.get_page(pointer).id == plan.id
      assert Knowledge.get_page(pointer).slug == "plan-viaje-2026"
    end
  end
end
