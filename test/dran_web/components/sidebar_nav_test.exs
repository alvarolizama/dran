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

  describe "workspace nav: Activity & Workspace settings NO van en el nav" do
    test "Activity no longer renders as a nav link (vive en #user-menu)" do
      html =
        render_component(&Layouts.sidebar_nav/1, %{
          active: "activity",
          is_owner: false,
          workspace_slug: "personal",
          workspace_role: "viewer"
        })

      refute html =~ ~s(href="/personal/activity")
      refute html =~ t("Activity")
    end

    test "Workspace settings no longer renders as a nav link either" do
      html =
        render_component(&Layouts.sidebar_nav/1, %{
          active: "workspace_settings",
          is_owner: true,
          workspace_slug: "personal",
          workspace_role: "owner"
        })

      refute html =~ ~s(href="/personal/settings")
      refute html =~ t("Workspace settings")
    end
  end

  describe "user_footer menu (workspace-scoped entries)" do
    defp menu(assigns) do
      assigns =
        assigns
        |> Map.put_new(:current_user, "owner@test.dev")
        |> Map.put_new(:user, nil)

      render_component(&Layouts.user_footer/1, assigns)
    end

    test "Workspaces (back to the list) is always in the menu" do
      for assigns <- [
            %{workspace_slug: nil, is_owner: true},
            %{workspace_slug: "personal", workspace_role: "viewer", is_owner: false}
          ] do
        html = menu(assigns)

        assert html =~ ~s(href="/")
        assert html =~ t("Workspaces")
      end
    end

    test "Workspaces is marked active on the dashboard" do
      html = menu(%{workspace_slug: nil, is_owner: true, active: "dashboard"})

      {pos, _} = :binary.match(html, ~s(href="/"))
      {end_pos, _} = :binary.match(html, "</a>", scope: {pos, byte_size(html) - pos})
      anchor = binary_part(html, pos, end_pos - pos)
      assert anchor =~ ~s(aria-current="page")
    end

    test "workspace owner sees Activity + Workspace settings after a divider" do
      html = menu(%{workspace_slug: "personal", workspace_role: "owner", is_owner: false})

      assert html =~ ~s(href="/personal/activity")
      assert html =~ t("Activity")
      assert html =~ ~s(href="/personal/settings")
      assert html =~ t("Workspace settings")
      # account links siguen arriba
      assert html =~ ~s(href="/settings/account")
      assert html =~ ~s(href="/settings/api-keys")
      assert html =~ ~s(id="logout-form")
    end

    test "viewer sees Activity but not Workspace settings" do
      html = menu(%{workspace_slug: "personal", workspace_role: "viewer", is_owner: false})

      assert html =~ ~s(href="/personal/activity")
      refute html =~ ~s(href="/personal/settings")
    end

    test "instance owner sees Workspace settings regardless of role" do
      html = menu(%{workspace_slug: "personal", workspace_role: "viewer", is_owner: true})

      assert html =~ ~s(href="/personal/settings")
    end

    test "outside a workspace the menu has the account + Workspaces entries only" do
      html = menu(%{workspace_slug: nil, is_owner: true})

      refute html =~ "/activity"
      refute html =~ ~s(href="/personal/settings")
      assert html =~ ~s(href="/")
      assert html =~ ~s(href="/settings/account")
      assert html =~ ~s(href="/settings/api-keys")
    end

    test "the active workspace entry is marked" do
      html =
        menu(%{
          workspace_slug: "personal",
          workspace_role: "owner",
          active: "workspace_settings"
        })

      {pos, _} = :binary.match(html, ~s(href="/personal/settings"))
      {end_pos, _} = :binary.match(html, "</a>", scope: {pos, byte_size(html) - pos})
      anchor = binary_part(html, pos, end_pos - pos)
      assert anchor =~ ~s(aria-current="page")
    end
  end
end
