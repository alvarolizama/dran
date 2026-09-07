defmodule Dran.Step do
  @moduledoc """
  First-class step entity — a DEFINITION node of a workflow.

  The step IS the contract: it defines WHAT, in what order, and how it is
  verified. The contract fields live as first-class columns/embeds on the
  step itself (`intent`, `claims`, `gates`, `graph`, ...) — promoted from
  the legacy `meta["contract"]` bag. The step is never executed itself — no
  board status, no due_date, no assignee: execution lives in sessions and
  runs (`Dran.Executions`).

  ## Contract lifecycle

  `status` is the lifecycle of the brief (draft → active → superseded),
  NOT an execution state. `history` keeps the versioned snapshots; the
  active version is `version`. `fingerprint` is the content-based hash the
  execution layer uses to detect staleness (a draft edited after being
  activated).

  The workflow of a step is structural (one and only one) → direct
  `workflow_id` FK, not a polymorphic relation. Step→step `depends_on`
  edges live in `relations`. `position` orders steps within the workflow
  (manual, gap-based); `pos_x`/`pos_y` are canvas coordinates (ex-`meta.pos`).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, read_after_writes: true}
  @foreign_key_type :binary_id

  @derive {Jason.Encoder,
           only: [
             :id,
             :workspace_id,
             :workflow_id,
             :title,
             :slug,
             :position,
             :pos_x,
             :pos_y,
             :intent,
             :status,
             :version,
             :history,
             :fingerprint,
             :model,
             :generated_by,
             :claims,
             :gates,
             :graph,
             :context_snapshot,
             :inserted_at,
             :updated_at
           ]}

  @statuses ~w(draft active superseded)

  schema "steps" do
    field :title, :string
    field :slug, :string
    field :position, :integer, default: 0

    field :pos_x, :integer
    field :pos_y, :integer

    # ── The contract, as first-class fields ──
    field :intent, :string
    field :status, :string, default: "draft"
    field :version, :integer, default: 1
    field :history, {:array, :map}, default: []
    field :fingerprint, :string
    field :model, :string
    field :generated_by, :string

    embeds_many :claims, Dran.Step.Claim, on_replace: :delete
    embeds_many :gates, Dran.Step.Gate, on_replace: :delete
    embeds_one :graph, Dran.Step.Graph, on_replace: :update
    embeds_many :context_snapshot, Dran.Step.ContextEntry, on_replace: :delete

    belongs_to :workspace, Dran.Workspace
    belongs_to :workflow, Dran.Workflow

    timestamps(type: :utc_datetime)
  end

  @doc "Valid contract statuses (draft → active → superseded)"
  def statuses, do: @statuses

  @doc "Changeset for creating or updating a step"
  def changeset(step, attrs) do
    step
    |> cast(attrs, [
      :workspace_id,
      :workflow_id,
      :title,
      :slug,
      :position,
      :pos_x,
      :pos_y,
      :intent,
      :status,
      :version,
      :history,
      :fingerprint,
      :model,
      :generated_by
    ])
    |> cast_embed(:claims)
    |> cast_embed(:gates)
    |> cast_embed(:graph)
    |> cast_embed(:context_snapshot)
    |> validate_required([:workspace_id, :workflow_id, :title, :slug])
    |> validate_length(:title, max: 500)
    |> validate_length(:slug, max: 500)
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> validate_number(:version, greater_than_or_equal_to: 1)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:workflow_id, :slug], name: :steps_workflow_id_slug_index)
  end

  @doc """
  Changeset for canvas persistence (drag / batch positions): casts ONLY the
  presentation columns and skips contract validation — a legacy step without
  intent yet can still be moved around. Mirrors `Dran.Task.move_changeset/2`.
  """
  def position_changeset(%__MODULE__{} = step, attrs) do
    step
    |> cast(attrs, [:position, :pos_x, :pos_y])
    |> validate_number(:position, greater_than_or_equal_to: 0)
  end

  # ── Embedded schemas for the contract ─────────────────────────────────

  defmodule Claim do
    @moduledoc "A verifiable claim of a step contract: id · claim · verify."

    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field :id, :string
      field :claim, :string
      field :verify, :string
    end

    def changeset(claim, attrs) do
      claim
      |> cast(attrs, [:id, :claim, :verify])
      |> validate_required([:id, :claim, :verify])
    end
  end

  defmodule Gate do
    @moduledoc "A gate of a step contract: name · cmd · expect · on_failure."

    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field :name, :string
      field :cmd, :string
      field :expect, :string
      field :on_failure, :string
    end

    def changeset(gate, attrs) do
      gate
      |> cast(attrs, [:name, :cmd, :expect, :on_failure])
      |> validate_required([:name, :cmd, :expect])
    end
  end

  defmodule Graph do
    @moduledoc """
    Graph of a step contract: node list (id · verb · label) and edges
    (from → to). The shape is identical to the legacy JSON
    (`%{nodes: [%{id, verb, label}], edges: [%{from, to}]}`), so the visual
    editor's serializer and `render_brief` keep working unchanged.
    """

    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      embeds_many :nodes, Dran.Step.Node, on_replace: :delete
      embeds_many :edges, Dran.Step.Edge, on_replace: :delete
    end

    def changeset(graph, attrs) do
      graph
      |> cast(attrs, [])
      |> cast_embed(:nodes)
      |> cast_embed(:edges)
    end
  end

  defmodule Node do
    @moduledoc "A node of the step's graph (verb + label)."

    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field :id, :string
      field :verb, :string
      field :label, :string
      # Canvas layout (mini-canvas de la tab Grafo): posición en el plano.
      # Opcionales — un nodo sin x/y entra en auto-layout al editar.
      field :x, :integer
      field :y, :integer
    end

    def changeset(node, attrs) do
      node
      |> cast(attrs, [:id, :verb, :label, :x, :y])
      |> validate_required([:id, :verb])
      |> validate_inclusion(:verb, ~w(READ EDIT CREATE RUN VERIFY ASK))
    end
  end

  defmodule Edge do
    @moduledoc "An edge of the step's graph (from → to)."

    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field :from, :string
      field :to, :string
      field :guard, :string
    end

    def changeset(edge, attrs) do
      edge
      |> cast(attrs, [:from, :to, :guard])
      |> validate_required([:from, :to])
    end
  end

  defmodule ContextEntry do
    @moduledoc "A pinned context entry of the step: type · id · why."

    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field :type, :string
      field :id, :string
      field :why, :string
    end

    def changeset(entry, attrs) do
      entry
      |> cast(attrs, [:type, :id, :why])
      |> validate_required([:type, :id])
    end
  end
end
