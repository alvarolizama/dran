defmodule Dran.Agent.Ingest do
  @moduledoc """
  Ingest agent: validates, inspects, downloads, and creates pages from URLs.
  """

  @behaviour Dran.Agent.Engine.Behaviour

  alias Dran.{Brain, TagEnricher}
  alias Dran.Agent.Ingest.Utils

  @agent_type "ingest"

  @doc """
  Start an ingest session for a URL.
  """
  @spec run(String.t(), Ecto.UUID.t(), keyword()) :: {:ok, Dran.Agent.Session.t()}
  def run(input, context_id, opts \\ []) do
    Dran.Agent.Engine.run(__MODULE__, input, context_id, opts)
  end

  @impl true
  def agent_type, do: @agent_type

  @impl true
  def tools do
    [
      %{
        "type" => "function",
        "function" => %{
          "name" => "validate_url",
          "description" => "Check that a URL is safe to fetch (SSRF protection).",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "url" => %{"type" => "string", "description" => "URL to validate"}
            },
            "required" => ["url"]
          }
        }
      },
      %{
        "type" => "function",
        "function" => %{
          "name" => "inspect_url",
          "description" => "Fetch headers to discover content type / filename.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "url" => %{"type" => "string", "description" => "URL to inspect"}
            },
            "required" => ["url"]
          }
        }
      },
      %{
        "type" => "function",
        "function" => %{
          "name" => "download_file",
          "description" => "Download the body of a URL as binary. Returns base64-encoded data.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "url" => %{"type" => "string", "description" => "URL to download"}
            },
            "required" => ["url"]
          }
        }
      },
      %{
        "type" => "function",
        "function" => %{
          "name" => "create_page",
          "description" => "Create a reference page from a URL or file URL.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "url" => %{"type" => "string", "description" => "URL to ingest"},
              "tags" => %{
                "type" => "array",
                "items" => %{"type" => "string"},
                "description" => "Tags"
              },
              "slug" => %{"type" => "string", "description" => "Custom slug"}
            },
            "required" => ["url"]
          }
        }
      },
      %{
        "type" => "function",
        "function" => %{
          "name" => "enrich_page",
          "description" => "Enrich an existing reference page with web-sourced content.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "slug" => %{"type" => "string", "description" => "Slug of the page to enrich"}
            },
            "required" => ["slug"]
          }
        }
      },
      %{
        "type" => "function",
        "function" => %{
          "name" => "done",
          "description" => "Finish the ingest session.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "summary" => %{"type" => "string", "description" => "Short summary"}
            },
            "required" => ["summary"]
          }
        }
      }
    ]
  end

  @impl true
  def system_prompt do
    """
    You are an ingest agent for Dran. Your job is to save URLs into the brain.

    - Use `validate_url` first, then `inspect_url`.
    - If the URL points to a file, use `download_file` and then `create_page`.
    - If the URL is HTML, use `create_page` directly.
    - Optionally use `enrich_page` after creating a page.
    - Call `done` when finished.
    """
  end

  @impl true
  def build_messages(input, session) do
    [
      %{"role" => "system", "content" => system_prompt()},
      %{"role" => "user", "content" => "Ingest URL: #{input}\nSession: #{session.id}"}
    ]
  end

  @impl true
  def execute_tool(tool, args, state)

  @impl true
  def execute_tool("validate_url", args, state) do
    {Utils.validate_url(args["url"] || ""), state}
  end

  @impl true
  def execute_tool("inspect_url", args, state) do
    {Utils.fetch_url_head(args["url"] || ""), state}
  end

  @impl true
  def execute_tool("download_file", args, state) do
    case Utils.download_file(args["url"] || "") do
      {:ok, binary} ->
        {{:ok, %{size: byte_size(binary), encoded: Base.encode64(binary)}}, state}

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  @impl true
  def execute_tool("create_page", args, state) do
    context = Brain.get_context!(state.session.context_id)

    params = %{
      "tags" => args["tags"] || [],
      "slug" => args["slug"]
    }

    case Utils.do_ingest(context, args["url"] || "", params) do
      {:ok, page} ->
        Phoenix.PubSub.broadcast(
          Dran.PubSub,
          "agents:#{state.session.id}",
          {:page_created, page}
        )

        {{:ok, %{slug: page.slug, id: page.id, title: page.title}},
         %{state | pages_created: state.pages_created + 1}}

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  @impl true
  def execute_tool("enrich_page", args, state) do
    context = Brain.get_context!(state.session.context_id)

    result =
      case Brain.get_page_by_slug(args["slug"] || "", context.id) do
        nil ->
          {:error, :page_not_found}

        page ->
          TagEnricher.enrich_page(page)
      end

    {result, state}
  end

  @impl true
  def execute_tool("done", _args, state), do: {{:ok, :done}, state}

  @impl true
  def execute_tool(_tool, _args, state), do: {{:error, :unknown_tool}, state}

  @impl true
  def summarize_result(result)

  def summarize_result({:ok, %{slug: slug, title: title}}),
    do: %{status: "ok", slug: slug, title: title}

  def summarize_result({:ok, %{size: size}}),
    do: %{status: "ok", size: size}

  def summarize_result({:ok, :done}), do: %{status: "done"}
  def summarize_result({:error, reason}), do: %{status: "error", error: inspect(reason)}
  def summarize_result(other), do: %{status: "ok", data: other}
end
