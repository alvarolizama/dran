defmodule Dran.Services.Call do
  @moduledoc """
  El registro de una ejecución de tool (tabla `service_calls`).

  Una fila por intento, con lo que hace auditable la superficie: quién, con qué
  agente, qué tool, qué dijo el proveedor (`log_id`) y un resumen truncado del
  resultado. `status` incluye `blocked`: el intento que dran cortó ANTES de
  llamar (sin conexión `ACTIVE`, por ejemplo) también queda escrito — el log
  tiene que decir lo que no llegó al proveedor, no solo lo que llegó.

  Nunca guarda credenciales: el vendor las redacta por diseño (F36) y acá se
  descartan además por nombre de campo (`redact/1`).
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Dran.Repo

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :integer

  # El resumen que se guarda: acotado, para que una tool que devuelve un payload
  # enorme no convierta el log en un almacén de datos.
  @max_result_chars 1_000

  # Nombres de campo que nunca se escriben, aunque el vendor los mandara.
  @secret_field ~r/(token|secret|password|passwd|api[_-]?key|credential|authorization)/i

  @derive {Jason.Encoder,
           only: [
             :id,
             :user_id,
             :toolkit,
             :tool_slug,
             :actor,
             :agent_name,
             :log_id,
             :status,
             :result,
             :duration_ms,
             :inserted_at
           ]}

  schema "service_calls" do
    field :user_id, :integer
    field :toolkit, :string
    field :tool_slug, :string
    field :actor, :string
    field :agent_name, :string
    field :log_id, :string
    field :status, :string, default: "ok"
    field :result, :string
    field :duration_ms, :integer

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc false
  def changeset(call, attrs) do
    call
    |> cast(attrs, [
      :user_id,
      :toolkit,
      :tool_slug,
      :actor,
      :agent_name,
      :log_id,
      :status,
      :result,
      :duration_ms
    ])
    |> validate_required([:user_id, :toolkit, :tool_slug, :status])
    |> validate_inclusion(:status, ~w(ok error blocked))
  end

  @doc """
  Escribe una fila. Best-effort: un fallo del registro no puede tumbar la
  ejecución que ya ocurrió (se loguea y sigue).
  """
  @spec record(map()) :: {:ok, struct()} | {:error, Ecto.Changeset.t()}
  def record(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Las últimas llamadas de un lector (para la UI o un diagnóstico).
  """
  @spec recent(integer(), pos_integer()) :: [struct()]
  def recent(user_id, limit \\ 20) do
    import Ecto.Query

    Repo.all(
      from c in __MODULE__,
        where: c.user_id == ^user_id,
        order_by: [desc: c.inserted_at],
        limit: ^limit
    )
  end

  @doc """
  Convierte cualquier resultado del vendor en el texto que se guarda: JSON
  truncado y sin campos con pinta de credencial.
  """
  @spec summarize(term()) :: String.t() | nil
  def summarize(nil), do: nil

  def summarize(term) do
    term
    |> redact()
    |> encode()
    |> truncate()
  end

  @doc false
  def redact(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      if is_binary(key) and Regex.match?(@secret_field, key) do
        {key, "[redacted]"}
      else
        {key, redact(value)}
      end
    end)
  end

  def redact(list) when is_list(list), do: Enum.map(list, &redact/1)
  def redact(other), do: other

  defp encode(term) when is_binary(term), do: term

  defp encode(term) do
    case Jason.encode(term) do
      {:ok, json} -> json
      {:error, _} -> inspect(term)
    end
  end

  defp truncate(text) when is_binary(text) do
    if String.length(text) > @max_result_chars do
      String.slice(text, 0, @max_result_chars) <> "…"
    else
      text
    end
  end
end
