defmodule Dran.Reports do
  @moduledoc """
  The Reports context — CRUD for reports (`Dran.Reports.Report`).

  Generated analysis documents per workspace. Leaf context: depends only
  on Repo + its schema.
  """

  import Ecto.Query, warn: false

  alias Dran.Repo
  alias Dran.Reports.Report

  # ──────────────────────────────────────────────────────────────────────────
  # Report CRUD
  # ──────────────────────────────────────────────────────────────────────────

  @doc """
  Get a report by slug within a workspace.

  Unscoped on purpose: for internal/system callers. Read surfaces use the
  `scope:` clause below.
  """
  def get_report_by_slug(slug, workspace_id) when is_binary(slug) and is_binary(workspace_id) do
    Repo.one(from r in Report, where: r.slug == ^slug and r.workspace_id == ^workspace_id)
  end

  @doc """
  Scope-aware fetch (W2): a report outside the reader's scope reads as a
  missing row (the caller redirects), the same shape as
  `Knowledge.get_page_by_slug/3`.
  """
  def get_report_by_slug(slug, workspace_id, scope: scope)
      when is_binary(slug) and is_binary(workspace_id) do
    Report
    |> where(slug: ^slug, workspace_id: ^workspace_id)
    |> Dran.ContentVisibility.filter(scope, :report)
    |> Repo.one()
  end

  @doc "Get a report by id, returns nil if not found"
  def get_report(id), do: Repo.get(Report, id)

  @doc "Scope-aware fetch by id (W2) — see `get_report_by_slug/3`."
  def get_report(id, scope: scope) when is_binary(id) do
    Report
    |> where(id: ^id)
    |> Dran.ContentVisibility.filter(scope, :report)
    |> Repo.one()
  end

  @doc """
  Create a new report.

  `visibility` is stated by the PRODUCER, and both producers are legitimate:
  a report written by a person is `private` (the schema default) with that
  person as owner, while workspace-wide output (job runs, the curator) is
  written `public` with a NULL owner — the same meaning a NULL owner carries
  on pages (`Dran.Auth.resolve_owner_user_id/1`).
  """
  def create_report(attrs) do
    %Report{}
    |> Report.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  List reports in a workspace.

  Opts: `:scope` — the reader's `Dran.ContentVisibility` scope, defaulting to
  `:all` for internal/system callers (see `Dran.Collections.list_collections/2`).
  """
  def list_reports(workspace_id, opts \\ []) when is_binary(workspace_id) do
    from(r in Report, where: r.workspace_id == ^workspace_id, order_by: [desc: r.inserted_at])
    |> Dran.ContentVisibility.filter(Keyword.get(opts, :scope, :all), :report)
    |> Repo.all()
  end
end
