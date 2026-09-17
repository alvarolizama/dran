defmodule Dran.RemovedPageTypesTest do
  @moduledoc """
  Cobertura del retiro de `food` (y de los demás tipos colapsados: `idea`,
  `knowledge`, `technical`).

  Reemplaza a `Dran.FoodPageTypeTest`, que cubría `food` como ciudadano de
  primera clase (registry, meta fields, changeset) y ya no puede pasar: el
  registry tiene exactamente cuatro tipos. La cobertura equivalente ahora es
  negativa — el tipo NO está, su vocabulario NO se renderiza y las filas
  históricas viven en `note` — más la cobertura positiva de los cuatro tipos
  vigentes, que `Dran.PageTypesTest` y `Dran.PageMetaTest` mantienen.
  """
  use ExUnit.Case, async: true

  alias Dran.PageRegistry

  @removed ~w(food idea knowledge technical)

  describe "registry" do
    test "los tipos retirados ya no están en la lista canónica" do
      for type <- @removed do
        refute type in PageRegistry.types(), "#{type} sigue siendo un tipo de página"
      end
    end

    test "el registry tiene exactamente los cuatro tipos vigentes" do
      assert PageRegistry.types() == ~w(note entity concept reference)
    end

    test "los tipos retirados no tienen config ni ui" do
      for type <- @removed do
        assert PageRegistry.config(type) == nil
        assert PageRegistry.ui(type) == nil
      end
    end

    test "los paths retirados ya no resuelven a un tipo" do
      for path <- ~w(food ideas knowledge technical) do
        assert PageRegistry.type_from_path(path) == nil,
               "el path #{path} todavía resuelve a un tipo de página"
      end
    end

    test "los tipos retirados no tienen color en el mapa del grafo" do
      colors = PageRegistry.ordered_type_colors()

      for type <- @removed do
        refute Enum.any?(colors, fn {t, _c} -> t == type end),
               "#{type} todavía tiene color en el mapa del grafo"
      end
    end
  end

  describe "meta fields" do
    test "un tipo retirado no expone campos de meta" do
      for type <- @removed do
        assert PageRegistry.meta_fields(type) == []
      end
    end

    test "los campos de food (cuisine, servings, tiempos) ya no existen" do
      keys = PageRegistry.meta_fields("note") |> Enum.map(fn {_t, key, _l} -> key end)

      for key <- ~w(kind cuisine servings prep_time cook_time source_url) do
        refute key in keys, "el campo #{key} sigue en los meta fields de note"
      end
    end
  end

  describe "note como tipo de destino del colapso" do
    test "note existe y su path sigue resolviendo" do
      assert "note" in PageRegistry.types()
      assert PageRegistry.path("note") == "notes"
      assert PageRegistry.type_from_path("notes") == "note"
    end

    test "note expone date y props, nada más" do
      keys = PageRegistry.meta_fields("note") |> Enum.map(fn {_t, key, _l} -> key end)

      assert keys == ["date", "props"]
    end
  end
end
