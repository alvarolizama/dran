defmodule Dran.Services.Session do
  @moduledoc """
  Una sesión de Composio por lector (tabla `service_sessions`).

  Es un PUNTERO, no una copia: guarda el `trs_…` del vendor y el snapshot de la
  allowlist que se le declaró. El estado de las conexiones NUNCA se guarda aquí
  — se lee del servidor cada vez (el estado es un ciclo de vida, F31).

  `@derive Jason.Encoder` existe solo para tests y logs: el `composio_session_id`
  no viaja a ningún cliente.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Dran.Repo

  @primary_key {:id, :binary_id, autogenerate: true}

  @derive {Jason.Encoder, only: [:id, :user_id, :toolkits, :inserted_at, :updated_at]}

  schema "service_sessions" do
    field :user_id, :integer
    field :composio_session_id, :string
    field :toolkits, {:array, :string}, default: []

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(session, attrs) do
    session
    |> cast(attrs, [:user_id, :composio_session_id, :toolkits])
    |> validate_required([:user_id, :composio_session_id])
  end

  @doc """
  The reader's session, if it exists.
  """
  @spec get_by_user(integer() | String.t()) :: struct() | nil
  def get_by_user(user_id), do: Repo.get_by(__MODULE__, user_id: user_id)

  @doc """
  Insert-or-return-existing for the reader. The unique index on `user_id` is the
  arbiter: two concurrent first calls cannot create two sessions.
  """
  @spec upsert(integer() | String.t(), String.t(), [String.t()]) ::
          {:ok, struct()} | {:error, Ecto.Changeset.t()}
  def upsert(user_id, composio_session_id, toolkits) do
    case get_by_user(user_id) do
      nil ->
        %__MODULE__{}
        |> changeset(%{
          user_id: user_id,
          composio_session_id: composio_session_id,
          toolkits: toolkits
        })
        |> Repo.insert(
          on_conflict: [set: [composio_session_id: composio_session_id, toolkits: toolkits]],
          conflict_target: :user_id
        )

      %__MODULE__{} = session ->
        {:ok, session}
    end
  end

  @doc """
  Record the snapshot of toolkits the session was last written with.
  """
  @spec put_toolkits(struct(), [String.t()]) :: {:ok, struct()} | {:error, Ecto.Changeset.t()}
  def put_toolkits(%__MODULE__{} = session, toolkits) do
    session
    |> change(toolkits: toolkits)
    |> Repo.update()
  end
end
