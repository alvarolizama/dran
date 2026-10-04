defmodule Dran.ListOrder do
  @moduledoc """
  El orden de un LISTADO — un solo vocabulario para goals y planes.

  El índice de la UI y el API eligen el mismo valor, y el clause vive acá para
  que las dos tablas ordenen igual (el molde de la lista es uno).

  - `due` — por vencer: `asc_nulls_last` deja AL FINAL lo que no tiene fecha,
    así un goal sin vencimiento no tapa al que vence mañana.
  - `updated` — lo último que se tocó primero.
  - `title` — el orden estable (A→Z).

  Un valor fuera de `orders/0` cae al orden estable por título: es el
  fail-safe, no la validación — el caller filtra contra `orders/0` antes.
  """

  @orders ~w(due updated title)

  @doc "Órdenes válidos, en el orden en que la UI los ofrece."
  def orders, do: @orders

  @doc "Clause de `order_by` para un orden del vocabulario."
  def clause(order) when order in [:due, "due"], do: [asc_nulls_last: :due_on, asc: :title]
  def clause(order) when order in [:updated, "updated"], do: [desc: :updated_at, asc: :title]
  def clause(_), do: [asc: :title]
end
