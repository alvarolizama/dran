defmodule Dran.MCP.SyntheticUserContextAccessTest do
  use Dran.DataCase, async: false

  alias Dran.{Knowledge, MCP}

  setup do
    original = Application.get_env(:dran, :inference)

    Application.put_env(:dran, :inference,
      base_url: nil,
      api_key: nil,
      embedding_model: nil,
      rerank_model: nil,
      timeout: 100,
      schedule_async: false
    )

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:dran, :inference)
      else
        Application.put_env(:dran, :inference, original)
      end
    end)

    {:ok, ctx} =
      Knowledge.create_workspace(%{name: "Test Context", slug: "test-ctx-syn"})

    {:ok, ctx: ctx}
  end

  test "read-only synthetic API key is blocked from write tools (dran_create_page)", %{
    ctx: ctx
  } do
    user = %{
      is_owner: false,
      email: "api-key:***",
      key_name: "Reader",
      workspaces: [ctx],
      access_levels: %{ctx.id => "read"},
      created_by_user_id: nil
    }

    msg = %{
      "jsonrpc" => "2.0",
      "method" => "tools/call",
      "id" => 1,
      "params" => %{
        "name" => "dran_create_page",
        "arguments" => %{
          "workspace" => ctx.slug,
          "page_type" => "note",
          "title" => "Forbidden",
          "slug" => "forbidden-read-only"
        }
      }
    }

    resp = MCP.process_message(msg, user: user)
    assert %{"error" => %{"message" => message}} = resp
    assert message =~ "read-only"
  end

  test "write-enabled synthetic API key can call write tools", %{ctx: ctx} do
    user = %{
      is_owner: false,
      email: "api-key:***",
      key_name: "Writer",
      workspaces: [ctx],
      access_levels: %{ctx.id => "write"},
      created_by_user_id: nil
    }

    msg = %{
      "jsonrpc" => "2.0",
      "method" => "tools/call",
      "id" => 1,
      "params" => %{
        "name" => "dran_create_page",
        "arguments" => %{
          "workspace" => ctx.slug,
          "page_type" => "note",
          "title" => "Writer note",
          "slug" => "writer-note-#{System.unique_integer([:positive])}"
        }
      }
    }

    resp = MCP.process_message(msg, user: user)
    assert %{"result" => %{"content" => _}} = resp
  end

  test "synthetic API key denied for workspace not in workspaces list", %{ctx: ctx} do
    {:ok, other_ctx} =
      Knowledge.create_workspace(%{name: "Other", slug: "other-ctx-syn"})

    user = %{
      is_owner: false,
      email: "api-key:***",
      key_name: "Restricted",
      workspaces: [ctx],
      access_levels: %{ctx.id => "read"},
      created_by_user_id: nil
    }

    msg = %{
      "jsonrpc" => "2.0",
      "method" => "tools/call",
      "id" => 1,
      "params" => %{
        "name" => "dran_search",
        "arguments" => %{"query" => "x", "workspace" => other_ctx.slug}
      }
    }

    resp = MCP.process_message(msg, user: user)
    assert %{"error" => %{"message" => message}} = resp
    assert message =~ "denied"
  end
end
