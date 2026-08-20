defmodule Dran.Reports do
  @moduledoc """
  The Reports context — CRUD for reports (`Dran.Report`).

  Generated analysis documents per workspace. Leaf context: depends only
  on Repo + its schema.
  """

  import Ecto.Query, warn: false

  alias Dran.Repo
  alias Dran.Report

  # ──────────────────────────────────────────────────────────────────────────
  # Report CRUD
  # ──────────────────────────────────────────────────────────────────────────

  @doc "Get a report by slug within a workspace"
  def get_report_by_slug(slug, workspace_id) when is_binary(slug) and is_binary(workspace_id) do
    Repo.one(from r in Report, where: r.slug == ^slug and r.workspace_id == ^workspace_id)
  end

  @doc "Get a report by id, returns nil if not found"
  def get_report(id), do: Repo.get(Report, id)

  @doc "Create a new report"
  def create_report(attrs) do
    %Report{}
    |> Report.changeset(attrs)
    |> Repo.insert()
  end

  @doc "List reports in a workspace"
  def list_reports(workspace_id) when is_binary(workspace_id) do
    Repo.all(
      from r in Report, where: r.workspace_id == ^workspace_id, order_by: [desc: r.inserted_at]
    )
  end
end
