defmodule DranWeb.SidebarNavTest do
  use DranWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  defp t(msgid), do: Gettext.gettext(DranWeb.Gettext, msgid)
  defp idx(html, str), do: :binary.match(html, str)

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
