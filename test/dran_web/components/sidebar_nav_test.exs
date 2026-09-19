defmodule DranWeb.SidebarNavTest do
  use DranWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  defp t(msgid), do: Gettext.gettext(DranWeb.Gettext, msgid)

  alias DranWeb.Layouts

  describe "sidebar_nav (instance pages — no workspace)" do
    test "renders nothing (groups = [])" do
      html =
        render_component(&Layouts.sidebar_nav/1, %{
          active: "dashboard",
          is_owner: true,
          workspace_slug: nil
        })

      # No nav items — instance pages render instance_nav instead.
      refute html =~ t("Dashboard")
      refute html =~ ~s(href="/")
      refute html =~ ~s(href="/admin")
      refute html =~ ~s(href="/settings/account")
      refute html =~ ~s(href="/personal/settings")
      refute html =~ t("Workspace")
    end

    test "renders empty (no mt-auto needed — footer owns it)" do
      html =
        render_component(&Layouts.sidebar_nav/1, %{
          active: "dashboard",
          is_owner: true,
          workspace_slug: nil
        })

      assert html == ""
    end
  end

  describe "sidebar_nav grouping" do
    defp workspace_nav(active \\ "home") do
      render_component(&Layouts.sidebar_nav/1, %{
        active: active,
        is_owner: true,
        workspace_slug: "personal",
        workspace_role: "owner"
      })
    end

    defp pos(html, str) do
      {p, _len} = :binary.match(html, str)
      p
    end

    # Posiciones de cada header de grupo (`<summary>`) en orden de DOM.
    defp summary_positions(html) do
      Regex.scan(~r/<summary/, html, return: :index)
      |> List.flatten()
      |> Enum.map(fn {p, _len} -> p end)
    end

    # Etiquetas de grupo en orden, sin markup.
    defp group_labels(html) do
      Regex.scan(~r/<summary[^>]*>(.*?)<\/summary>/s, html, capture: :all_but_first)
      |> List.flatten()
      |> Enum.map(&(&1 |> String.replace(~r/<[^>]*>/, "") |> String.trim()))
    end

    test "no Objetivos/Workflows links remain outside any group" do
      html = workspace_nav()

      # Memory moved out of its own group: it now sits with the always-visible
      # entries, so Knowledge base is the only labelled group left.
      assert group_labels(html) == [t("Knowledge base")]

      [first_summary | _rest] = summary_positions(html)

      home_pos = pos(html, ~s(href="/personal"))
      graph_pos = pos(html, ~s(href="/personal/graph"))
      journey_pos = pos(html, ~s(href="/personal/journey"))
      memory_pos = pos(html, ~s(href="/personal/memory"))
      refute html =~ ~s(href="/personal/goals")
      refute html =~ ~s(href="/personal/workflows")

      # Inicio → Grafo → Journey → Memory, todos antes del primer grupo
      assert home_pos < graph_pos
      assert graph_pos < journey_pos
      assert journey_pos < memory_pos
      assert memory_pos < first_summary
    end

    test "Clusters sits below Referencias inside Knowledge base" do
      html = workspace_nav()

      labels = group_labels(html)
      summaries = summary_positions(html)
      kb_index = Enum.find_index(labels, &(&1 == t("Knowledge base")))

      assert refs_pos = pos(html, ~s(href="/personal/references"))
      assert clusters_pos = pos(html, ~s(href="/personal/clusters"))

      # clusters sigue dentro de Knowledge base: después de references.
      assert refs_pos < clusters_pos
      assert Enum.at(summaries, kb_index) < refs_pos
    end

    test "Inicio stays outside any group" do
      html = workspace_nav()
      [first_summary | _rest] = summary_positions(html)

      home_pos = pos(html, ~s(href="/personal"))
      assert home_pos < first_summary
    end

    test "active key highlights the right link" do
      html = workspace_nav("memory")

      p = pos(html, ~s(href="/personal/memory"))
      {end_pos, _len} = :binary.match(html, "</a>", scope: {p, byte_size(html) - p})
      anchor = binary_part(html, p, end_pos - p)
      assert anchor =~ ~s(aria-current="page")
      assert anchor =~ "bg-primary/15 text-primary"
    end
  end

  describe "workspace nav: Activity & Settings links (moved from footer icons)" do
    test "Activity link present for every workspace" do
      html =
        render_component(&Layouts.sidebar_nav/1, %{
          active: "activity",
          is_owner: false,
          workspace_slug: "personal",
          workspace_role: "viewer"
        })

      assert html =~ ~s(href="/personal/activity")
      assert html =~ t("Activity")
      # Active highlight on the activity link
      {pos, _} = :binary.match(html, ~s(href="/personal/activity"))
      {end_pos, _} = :binary.match(html, "</a>", scope: {pos, byte_size(html) - pos})
      anchor = binary_part(html, pos, end_pos - pos)
      assert anchor =~ ~s(aria-current="page")
      assert anchor =~ "bg-primary/15 text-primary"
    end

    test "Workspace settings link gated by role" do
      owner_html =
        render_component(&Layouts.sidebar_nav/1, %{
          active: "workspace_settings",
          is_owner: false,
          workspace_slug: "personal",
          workspace_role: "owner"
        })

      assert owner_html =~ ~s(href="/personal/settings")
      assert owner_html =~ t("Workspace settings")

      viewer_html =
        render_component(&Layouts.sidebar_nav/1, %{
          active: "home",
          is_owner: false,
          workspace_slug: "personal",
          workspace_role: "viewer"
        })

      refute viewer_html =~ ~s(href="/personal/settings")
    end

    test "instance owner sees workspace settings even without a workspace role" do
      html =
        render_component(&Layouts.sidebar_nav/1, %{
          active: "home",
          is_owner: true,
          workspace_slug: "personal",
          workspace_role: "viewer"
        })

      assert html =~ ~s(href="/personal/settings")
    end
  end
end
