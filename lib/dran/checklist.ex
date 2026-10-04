defmodule Dran.Checklist do
  @moduledoc """
  El checklist: un array ORDENADO de pasos en el jsonb de su contenedor.

  Una sola forma para la **task** (columna `tasks.checklist`) y para el **plan**
  (columna `plans.checklist` — el plan es una entidad con tabla propia, no una
  página de un tipo declarado):

      [%{"text" => "Escribir el guion", "done" => false}, ...]

  El orden del array ES el orden del checklist. No hay tabla `plan_steps` ni
  `checklist_items`: tachar un ítem reescribe el array, no crea ni mueve tasks
  ni toca el board (Constraint 8). El estado, el asignado y la fecha de trabajo
  son columnas de la task, nunca ítems del checklist.

  `toggle/2` es la operación pura del RMW: el contexto lee el array ACTUAL, la
  aplica y escribe con `lock_version` (`Dran.Plans.toggle_checklist/3`,
  `Dran.Tasks.toggle_checklist/2`).
  """

  @doc """
  Normaliza cualquier entrada a la forma canónica del checklist.

  Acepta una lista de mapas (`%{"text" => _, "done" => _}`, claves string o
  átomo) o de binarios, y también el JSON serializado de esa lista. Descarta
  ítems sin texto, preserva el orden y devuelve claves string (JSON-safe).
  """
  @spec cast(term()) :: [map()]
  def cast(value) do
    value
    |> to_list()
    |> Enum.map(&normalize/1)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Tacha o destacha UN ítem del array, por índice (0-based) o por texto.

  Devuelve `{:ok, lista_nueva}` preservando el orden, o `:error` cuando la
  referencia no existe (ni el índice está en rango ni hay un ítem con ese
  texto). El texto se compara sin distinguir mayúsculas ni espacios de borde.
  Es una función PURA: la lectura del array actual y la escritura con
  `lock_version` son del contexto.
  """
  @spec toggle(term(), integer() | binary()) :: {:ok, [map()]} | :error
  def toggle(items, ref) do
    list = cast(items)

    case ref do
      index when is_integer(index) and index >= 0 -> toggle_at(list, index)
      text when is_binary(text) -> toggle_text(list, text)
      _ -> :error
    end
  end

  @doc "True cuando el ítem está tachado (la forma canónica usa booleanos)."
  def done?(item) when is_map(item), do: item["done"] == true
  def done?(_), do: false

  defp toggle_at(list, index) do
    case Enum.at(list, index) do
      nil -> :error
      item -> {:ok, List.replace_at(list, index, Map.put(item, "done", not done?(item)))}
    end
  end

  defp toggle_text(list, text) do
    needle = text |> String.trim() |> String.downcase()

    case Enum.find_index(list, &(String.downcase(&1["text"] || "") == needle)) do
      nil -> :error
      index -> toggle_at(list, index)
    end
  end

  defp to_list(value) when is_list(value), do: value

  defp to_list(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end

  defp to_list(_), do: []

  defp normalize(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> %{"text" => trimmed, "done" => false}
    end
  end

  defp normalize(%{} = item) do
    text = item |> pick("text") |> to_string()

    case String.trim(text) do
      "" -> nil
      trimmed -> %{"text" => trimmed, "done" => truthy?(pick(item, "done"))}
    end
  end

  defp normalize(_), do: nil

  defp pick(item, key) do
    Map.get(item, key) || Map.get(item, safe_atom(key))
  end

  defp safe_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  # El flag crudo del jsonb (mapa con claves string o átomo): solo `true`
  # cuenta como tachado. La versión pública `done?/1` recibe el ÍTEM ya
  # normalizado, no el valor suelto.
  defp truthy?(value), do: value == true
end
