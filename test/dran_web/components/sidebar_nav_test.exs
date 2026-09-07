defmodule DranWeb.SidebarNavTest do
  use DranWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  defp t(msgid), do: Gettext.gettext(DranWeb.Gettext, msgid)

  alias DranWeb.Layouts

  describe "sidebar_nav (empty — links moved to footer)" do
    test "renders nothing (groups = [])" do
      html =
        render_component(&Layouts.sidebar_nav/1, %{
          active: "dashboard",
          is_owner: true,
          workspace_slug: nil
        })

      # No nav items — all links live in the footer icons now.
      refute html =~ t("Dashboard")
      refute html =~ ~s(href="/")
      refute html =~ ~s(href="/admin")
      refute html =~ ~s(href="/settings/account")
      refute html =~ ~s(href="/docs")
      refute html =~ ~s(href="/personal/settings")
      refute html =~ t("Workspace")
    end

    test "empty inside a workspace too" do
      html =
        render_component(&Layouts.sidebar_nav/1, %{
          active: "dashboard",
          is_owner: true,
          workspace_slug: "personal",
          workspace_role: "owner"
        })

      refute html =~ t("Workspace")
      refute html =~ ~s(href="/personal/settings")
    end

    test "renders empty (no mt-auto needed — footer icons own it)" do
      html =
        render_component(&Layouts.sidebar_nav/1, %{
          active: "dashboard",
          is_owner: true,
          workspace_slug: nil
        })

      # sidebar_nav renders nothing; mt-auto lives in sidebar_footer_icons.
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

    test "goals and tasks live in the Planning group, workflows in its own" do
      html = workspace_nav()

      assert group_labels(html) == [
               t("Planning"),
               t("Workflows"),
               t("Knowledge base"),
               t("Memory"),
               "Insights"
             ]

      [planning, workflows | _rest] = summary_positions(html)

      # Objetivos y Tareas dentro del grupo Planning…
      assert planning < pos(html, ~s(href="/personal/goals"))
      assert planning < pos(html, ~s(href="/personal/tasks"))
      assert pos(html, ~s(href="/personal/tasks")) < workflows

      # …y Workflows en su propio grupo, después
      assert workflows < pos(html, ~s(href="/personal/workflows"))
    end

    test "Inicio stays outside any group" do
      html = workspace_nav()
      [first_summary | _rest] = summary_positions(html)

      home_pos = pos(html, ~s(href="/personal"))
      assert home_pos < first_summary
    end

    test "active key highlights the right link" do
      html = workspace_nav("workflows")

      p = pos(html, ~s(href="/personal/workflows"))
      {end_pos, _len} = :binary.match(html, "</a>", scope: {p, byte_size(html) - p})
      anchor = binary_part(html, p, end_pos - p)
      assert anchor =~ "bg-primary/10"
    end
  end

  describe "sidebar_footer_icons" do
    test "renders all 4 icons for owner" do
      html =
        render_component(&Layouts.sidebar_footer_icons/1, %{
          is_owner: true,
          workspace_slug: nil
        })

      assert html =~ ~s(href="/")
      assert html =~ ~s(href="/admin")
      assert html =~ ~s(href="/settings/account")
      assert html =~ ~s(href="/docs")
      assert html =~ "hero-squares-2x2"
      assert html =~ "hero-command-line"
      assert html =~ "hero-user"
      assert html =~ "hero-book-open"
    end

    test "hides admin icon for non-owner" do
      html =
        render_component(&Layouts.sidebar_footer_icons/1, %{
          is_owner: false,
          workspace_slug: nil
        })

      assert html =~ ~s(href="/")
      refute html =~ ~s(href="/admin")
      assert html =~ ~s(href="/settings/account")
      assert html =~ ~s(href="/docs")
    end

    test "shows workspace Config icon for workspace owner" do
      html =
        render_component(&Layouts.sidebar_footer_icons/1, %{
          is_owner: false,
          workspace_slug: "personal",
          workspace_role: "owner",
          active: "workspace_settings"
        })

      assert html =~ ~s(href="/personal/settings")
      assert html =~ "hero-cog-6-tooth"
      # Active highlight
      {pos, _} = :binary.match(html, ~s(href="/personal/settings"))
      {end_pos, _} = :binary.match(html, "</a>", scope: {pos, byte_size(html) - pos})
      anchor = binary_part(html, pos, end_pos - pos)
      assert anchor =~ "bg-primary/10"
    end

    test "hides workspace Config for viewer" do
      html =
        render_component(&Layouts.sidebar_footer_icons/1, %{
          is_owner: false,
          workspace_slug: "personal",
          workspace_role: "viewer"
        })

      refute html =~ ~s(href="/personal/settings")
      assert html =~ ~s(href="/")
      assert html =~ ~s(href="/docs")
    end

    test "border-t separator present" do
      html =
        render_component(&Layouts.sidebar_footer_icons/1, %{
          is_owner: true,
          workspace_slug: nil
        })

      assert html =~ "border-t"
      assert html =~ "mt-auto"
    end
  end
end
