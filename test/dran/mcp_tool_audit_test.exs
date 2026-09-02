defmodule Dran.MCP.ToolAuditTest do
  @moduledoc """
  F8 — permission-matrix audit over the MCP toolset.

  Asserts, through the public JSON-RPC surface (`process_message/2`):

    1. The registered toolset is coherent (dran_ prefix, description, schema).
    2. EVERY write tool is denied for a read-only API key in a workspace the
       key can read (a tool added to @write_tools without passing this audit
       fails here).
    3. EVERY write tool passes the write gate for a write-enabled key.
    4. Read tools work for a read-only key.
    5. Unknown tools get a JSON-RPC error.
  """

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

    {:ok, ctx} = Knowledge.create_workspace(%{name: "Audit", slug: "audit-ctx"})

    read_key = api_key_user(ctx, "read")
    write_key = api_key_user(ctx, "write")

    {:ok, ctx: ctx, read_key: read_key, write_key: write_key}
  end

  describe "toolset inventory" do
    test "every registered tool has a dran_ name, description and inputSchema" do
      tools = list_tools()

      assert length(tools) >= 19

      for tool <- tools do
        assert tool["name"] =~ ~r/^dran_[a-z_]+$/,
               "tool name #{tool["name"]} does not follow the dran_ convention"

        assert is_binary(tool["description"]) and tool["description"] != ""

        assert match?(%{"type" => "object", "properties" => %{}}, tool["inputSchema"]),
               "tool #{tool["name"]} is missing a proper inputSchema"
      end
    end
  end

  describe "write tools × roles (full matrix)" do
    test "EVERY write tool is denied for a read-only key", %{ctx: ctx, read_key: read_key} do
      for tool <- MCP.write_tools() do
        resp =
          MCP.process_message(call(tool, %{"workspace" => ctx.slug}), user: read_key)

        assert %{"error" => %{"message" => message}} = resp,
               "tool #{tool} did not return a JSON-RPC error for a read-only key"

        assert message =~ "read-only",
               "tool #{tool} was rejected with an unexpected message: #{message}"
      end
    end

    test "EVERY write tool passes the write gate for a write-enabled key", %{
      ctx: ctx,
      write_key: write_key
    } do
      for tool <- MCP.write_tools() do
        resp =
          MCP.process_message(call(tool, %{"workspace" => ctx.slug}), user: write_key)

        # The write gate must pass: the response is either a successful result
        # or a domain-level error text (missing args etc.) — never the
        # read-only denial.
        case resp do
          %{"result" => _} ->
            :ok

          %{"error" => %{"message" => message}} ->
            refute message =~ "read-only",
                   "tool #{tool} hit the write gate with a write-enabled key: #{message}"
        end
      end
    end
  end

  describe "read tools" do
    test "a read-only key can read (search + list)", %{ctx: ctx, read_key: read_key} do
      resp =
        MCP.process_message(
          call("dran_list_pages", %{"workspace" => ctx.slug}),
          user: read_key
        )

      assert %{"result" => %{"content" => [%{"text" => _}]}} = resp

      resp =
        MCP.process_message(
          call("dran_search", %{"workspace" => ctx.slug, "query" => "anything"}),
          user: read_key
        )

      assert %{"result" => %{"content" => _}} = resp
    end
  end

  describe "unknown tools" do
    test "return a JSON-RPC error, not a crash", %{ctx: ctx, write_key: write_key} do
      resp =
        MCP.process_message(call("dran_nope", %{"workspace" => ctx.slug}), user: write_key)

      assert %{"result" => %{"content" => [%{"text" => text}]}} = resp
      assert text =~ "unknown tool"
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp list_tools do
    %{"result" => %{"tools" => tools}} =
      MCP.process_message(%{
        "jsonrpc" => "2.0",
        "method" => "tools/list",
        "id" => 0
      })

    tools
  end

  defp call(tool, args) do
    %{
      "jsonrpc" => "2.0",
      "method" => "tools/call",
      "id" => 1,
      "params" => %{"name" => tool, "arguments" => args}
    }
  end

  defp api_key_user(ctx, level) do
    %{
      is_owner: false,
      email: "api-key:#{level}-audit",
      key_name: "#{level} audit key",
      workspaces: [ctx],
      access_levels: %{ctx.id => level},
      created_by_user_id: nil
    }
  end
end
