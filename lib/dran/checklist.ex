defmodule Dran.Checklist do
  @moduledoc """
  El checklist: un array ORDENADO de pasos en el jsonb de su contenedor.

  Una sola forma para la task y para el plan (una página de tipo declarado con
  el campo `:checklist`):

      [%{"text" => "Escribir el guion", "done" => false}, ...]

  El orden del array ES el orden del checklist. No hay tabla `plans` ni
  `checklist_items`: tachar un ítem reescribe el array, no crea ni mueve
  tasks ni toca el board (Constraint 16 / F35). El estado, el asignado y la
  fecha de trabajo son columnas de la task, nunca ítems del checklist.
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
      trimmed -> %{"text" => trimmed, "done" => done?(pick(item, "done"))}
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

  defp done?(value), do: value == true
end
