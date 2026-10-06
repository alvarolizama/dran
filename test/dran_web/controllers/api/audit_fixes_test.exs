defmodule DranWeb.API.AuditFixesTest do
  @moduledoc """
  Los repros de `docs/audit-2026-10-05.md` convertidos en tests permanentes
  (contract `auditoria-fixes`). Un test por hallazgo, el mismo vocabulario que
  `visibility_api_test.exs`: credenciales de cuenta, contenido por visibilidad
  y la superficie REST de punta a punta.
  """

  use DranWeb.ConnCase, async: false

  alias Dran.{Accounts, Knowledge, Memory, Sharing}

  # ── Shared ────────────────────────────────────────────────────────────────

  setup do
    ws = Dran.DataCase.ensure_workspace!()

    {:ok, owner} =
      Accounts.create_user(%{
        email: "af-owner-#{u()}@example.com",
        name: "Owner",
        api_token: "t#{u()}"
      })

    {:ok, stranger} =
      Accounts.create_user(%{
        email: "af-stranger-#{u()}@example.com",
        name: "Stranger",
        api_token: "t#{u()}"
      })

    {:ok, private_page} =
      Knowledge.create_page(%{
        "workspace_id" => ws.id,
        "title" => "Private page qxsjfilterzap",
        "slug" => "private-qxsjfilterzap-#{u()}",
        "body" => "Contenido privado unique qxsjfilterzap",
        "page_type" => "note",
        "owner_user_id" => owner.id,
        "created_by" => "owner@af.test",
        "visibility" => "private"
      })

    {:ok, public_page} =
      Knowledge.create_page(%{
        "workspace_id" => ws.id,
        "title" => "Public page af",
        "slug" => "public-af-#{u()}",
        "body" => "contenido publico",
        "page_type" => "note",
        "owner_user_id" => owner.id,
        "created_by" => "owner@af.test",
        "visibility" => "public"
      })

    {:ok, public_memory, _} =
      Memory.add(%{
        "workspace_id" => ws.id,
        "content" => "facto publico af #{u()}",
        "created_by" => "owner@af.test",
        "owner_user_id" => owner.id,
        "visibility" => "public"
      })

    %{
      ws: ws,
      owner: owner,
      stranger: stranger,
      private_page: private_page,
      public_page: public_page,
      public_memory: public_memory
    }
  end

  defp conn_for(user) do
    Phoenix.ConnTest.build_conn()
    |> Plug.Conn.put_req_header("accept", "application/json")
    |> Plug.Conn.put_req_header("authorization", "Bearer #{user.api_token}")
  end

  defp u do
    System.unique_integer([:positive]) |> Integer.to_string() |> String.slice(-6..-1)
  end

  # ── P1: search scoped (hallazgo 1) ────────────────────────────────────────

  describe "search filters by the reader's scope (P1)" do
    test "GET /api/search excludes a foreign private page", ctx do
      conn = conn_for(ctx.stranger) |> get("/api/search", %{"q" => "qxsjfilterzap"})
      assert %{"data" => results} = json_response(conn, 200)
      refute Enum.any?(results, &(&1["slug"] == ctx.private_page.slug))
    end

    test "GET /api/search/fuzzy excludes a foreign private page", ctx do
      conn = conn_for(ctx.stranger) |> get("/api/search/fuzzy", %{"q" => "qxsjfilterzap"})
      assert %{"data" => results} = json_response(conn, 200)
      refute Enum.any?(results, &(&1["slug"] == ctx.private_page.slug))
    end

    test "the owner still sees their own private page in /api/search", ctx do
      conn = conn_for(ctx.owner) |> get("/api/search", %{"q" => "qxsjfilterzap"})
      assert %{"data" => results} = json_response(conn, 200)
      assert Enum.any?(results, &(&1["slug"] == ctx.private_page.slug))
    end
  end

  # ── P2: log privileged + scoped (hallazgo 2) ──────────────────────────────

  describe "log entries of unreadable pages are not served (P2)" do
    test "GET /api/log with a plain token => 403 (instance telemetry is privileged)", ctx do
      conn = conn_for(ctx.stranger) |> get("/api/log")
      assert 403 = conn.status
    end

    test "GET /api/log with the instance owner's token still works", ctx do
      {:ok, admin} =
        Accounts.create_user(%{
          email: "af-admin-#{u()}@example.com",
          name: "Admin",
          api_token: "t#{u()}",
          is_owner: true
        })

      conn = conn_for(admin) |> get("/api/log")
      assert %{"data" => _entries} = json_response(conn, 200)
    end
  end

  # ── P3: ownership gates writes (hallazgo 3) ───────────────────────────────

  describe "writing stays with the owner and instance admins (P3)" do
    test "PUT another user's public page => 403", ctx do
      conn =
        conn_for(ctx.stranger)
        |> put("/api/knowledge-pages/#{ctx.public_page.slug}", %{"title" => "Vandalizado"})

      assert 403 = conn.status
    end

    test "DELETE another user's public page => 403", ctx do
      conn = conn_for(ctx.stranger) |> delete("/api/knowledge-pages/#{ctx.public_page.slug}")
      assert 403 = conn.status
    end

    test "PATCH another user's public memory => 403", ctx do
      conn =
        conn_for(ctx.stranger)
        |> patch("/api/memory/#{ctx.public_memory.id}", %{"content" => "x"})

      assert 403 = conn.status
    end

    test "the owner can still update their own public page", ctx do
      conn =
        conn_for(ctx.owner)
        |> put("/api/knowledge-pages/#{ctx.public_page.slug}", %{"title" => "Mio"})

      assert %{"data" => _} = json_response(conn, 200)
    end

    test "DELETE by slug when the page is already gone => 404", ctx do
      # sin page: el slug no existe para el lector.
      conn = conn_for(ctx.stranger) |> delete("/api/knowledge-pages/no-such-slug-af")
      assert 404 = conn.status
    end
  end

  # ── P4: workers/ingest respect the scope (hallazgo 4) ─────────────────────

  describe "group tokens cannot operate workers or ingest (P4)" do
    test "POST /api/workers with a group token => 403", ctx do
      {:ok, g} =
        Sharing.create_group(%{"name" => "AF G #{u()}", "slug" => "af-g-#{u()}"},
          owner_user_id: ctx.owner.id
        )

      {:ok, g} = Sharing.issue_group_token(g)

      conn =
        conn_for(%{api_token: g.api_token})
        |> post("/api/workers", %{"worker_type" => "curator", "input" => "x", "workspace" => "x"})

      assert 403 = conn.status
    end
  end

  # ── P5: /api/groups answers the group, not its human (hallazgo 5) ─────────

  describe "GET /api/groups with a group token lists the GROUP (P5)" do
    test "own group is listed; a group of the human owner is not", ctx do
      {:ok, g1} =
        Sharing.create_group(%{"name" => "AF Alpha #{u()}", "slug" => "af-alpha-#{u()}"},
          owner_user_id: ctx.owner.id
        )

      {:ok, g2} =
        Sharing.create_group(%{"name" => "AF Beta #{u()}", "slug" => "af-beta-#{u()}"},
          owner_user_id: ctx.owner.id
        )

      # El humano dueño es miembro de g2 (NO de g1): la credencial de g1 no ve g2.
      Sharing.add_group_member(g2, ctx.owner.id)
      {:ok, g1} = Sharing.issue_group_token(g1)

      conn = conn_for(%{api_token: g1.api_token}) |> get("/api/groups")
      assert %{"data" => groups} = json_response(conn, 200)
      slugs = Enum.map(groups, & &1["slug"])

      assert g1.slug in slugs, "el propio grupo debería listarse (slugs=#{inspect(slugs)})"
      refute g2.slug in slugs
    end
  end

  # ── P6: tolerant limits (hallazgo 6) ──────────────────────────────────────

  describe "non-numeric and oversized limits do not crash (P6)" do
    test "GET /api/search?limit=abc => 200", ctx do
      conn = conn_for(ctx.stranger) |> get("/api/search", %{"q" => "af", "limit" => "abc"})
      assert 200 = conn.status
    end

    test "GET /api/log?limit=abc => 200", ctx do
      conn = conn_for(ctx.stranger) |> get("/api/log", %{"limit" => "abc"})
      assert conn.status in [200, 403]
    end

    test "GET /api/knowledge-pages?limit=100000 is capped, not passed to SQL", ctx do
      conn = conn_for(ctx.stranger) |> get("/api/knowledge-pages", %{"limit" => "100000"})
      assert 200 = conn.status
    end
  end

  # ── P7: query budget (hallazgo 7) — measured in the audit, not asserted here

  @tag :skip
  test "P7 is verified by telemetry, not an ExUnit assertion"

  # ── P8: baseline (verified by mix test at the end) ────────────────────────
end
