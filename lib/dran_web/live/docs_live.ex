defmodule DranWeb.DocsLive do
  @moduledoc """
  Documentation pages for Dran: Overview, API reference, and MCP integration.
  """

  use DranWeb, :live_view

  alias DranWeb.Plugs.Auth

  @tabs [
    {"overview", "overview"},
    {"api", "api"},
    {"mcp", "mcp"},
    {"auth", "auth"}
  ]

  defp tab_label("overview"), do: gettext("Overview")
  defp tab_label("api"), do: gettext("API")
  defp tab_label("mcp"), do: gettext("MCP")
  defp tab_label("auth"), do: gettext("Auth")
  defp tab_label(other), do: other

  defp translated_tabs do
    Enum.map(@tabs, fn {key, _} -> {key, tab_label(key)} end)
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_user={@current_user}
      context_slug={@context_slug}
      contexts={@contexts}
      active_nav="docs"
    >
      <div class="p-6 w-full overflow-y-auto h-full">
        <h1 class="text-2xl font-bold mb-6">{gettext("Documentation")}</h1>

        <.tabs_bar tabs={translated_tabs()} active_tab={@active_tab} />

        <%= if @active_tab == "overview" do %>
          <.overview />
        <% end %>

        <%= if @active_tab == "api" do %>
          <.api_reference />
        <% end %>

        <%= if @active_tab == "mcp" do %>
          <.mcp_reference />
        <% end %>

        <%= if @active_tab == "auth" do %>
          <.auth_reference />
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  def mount(_params, session, socket) do
    {socket, _context} = Auth.assign_to_socket(socket, session)

    {:ok,
     assign(socket,
       active_nav: "docs",
       tabs: @tabs,
       active_tab: "overview",
       page_title: gettext("Docs")
     )}
  end

  def handle_params(params, _url, socket) do
    tab = params["tab"] || "overview"

    {:noreply,
     assign(socket,
       active_tab: tab,
       page_title: gettext("Docs · %{tab}", tab: tab |> String.capitalize())
     )}
  end

  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, active_tab: tab)}
  end

  # ── Overview ──

  def overview(assigns) do
    ~H"""
    <div class="prose prose-base dark:prose-invert max-w-none space-y-6">
      <h2>What is Dran?</h2>
      <p>
        Dran is a personal second-brain application built with Phoenix LiveView. It stores
        your knowledge as typed pages (notes, concepts, entities, references) and links them
        with relations, forming a queryable knowledge graph.
      </p>

      <h2>Core concepts</h2>

      <h3>Contexts</h3>
      <p>
        A context is a self-contained workspace (e.g. "personal", "work"). All pages, relations,
        and logs belong to a single context. Most operations require a context, identified by
        its slug.
      </p>

      <h3>Pages</h3>
      <p>
        Every piece of knowledge is a page with a <code>page_type</code>. The built-in types are:
      </p>
      <ul>
        <li><strong>note</strong> — free-form text entries</li>
        <li><strong>concept</strong> — definitions or ideas</li>
        <li><strong>entity</strong> — people, organizations, tools</li>
        <li><strong>reference</strong> — external sources (URLs, books)</li>
        <li><strong>goal</strong> — outcomes you want to achieve</li>
        <li><strong>plan</strong> — steps or roadmaps</li>
        <li><strong>todo</strong> — actionable items with kanban status</li>
        <li><strong>artifact</strong> — deliverables or files</li>
        <li><strong>comparison</strong> — side-by-side analyses</li>
        <li>
          <strong>query</strong>
          — questions with answers, linked semantically to concepts and entities
        </li>
      </ul>
      <p>
        Pages store a body (Markdown), summary, tags, and an arbitrary <code>meta</code> map
        for type-specific metadata (e.g. kanban status, priority, horizon).
      </p>

      <h3>Relations</h3>
      <p>
        Relations connect pages with a <code>relation_type</code>:
      </p>
      <ul>
        <li><strong>related</strong> — generic association</li>
        <li><strong>part_of</strong> — hierarchy (A is part of B)</li>
        <li><strong>supersedes</strong> — replacement (A replaces B)</li>
        <li><strong>contradicts</strong> — conflict (A contradicts B)</li>
        <li>
          <strong>embeds</strong>
          — source embeds target (e.g. a note embeds an artifact via <code>![[slug]]</code>)
        </li>
        <li>
          <strong>semantic</strong>
          — auto-created by the PageAugmenter when two pages are semantically similar
        </li>
      </ul>

      <h3>Knowledge graph</h3>
      <p>
        Pages and relations form a directed graph. The <code>/graph</code>
        view renders the full
        graph in 2D or 3D with zoom and pan. Each page detail view also has a <strong>Graph</strong>
        tab
        showing the page as the center with its direct neighbors. Relations carry a
        <code>weight</code>
        that reflects semantic similarity strength.
      </p>

      <h3>AI Chat</h3>
      <p>
        Dran includes a built-in AI chat assistant (bottom-right FAB on every page). The chat
        has full context of your brain — it can search pages, create content, answer questions
        with citations, and suggest related actions. Chat sessions are persisted per context.
      </p>

      <h3>Autonomous agents</h3>
      <p>Beyond the interactive Research and Ingest agents, Dran runs scheduled batch agents:</p>
      <ul>
        <li>
          <strong>QA</strong> — audits pages for missing frontmatter, broken links, empty content
        </li>
        <li>
          <strong>Curator</strong>
          — consolidates duplicates, generates summaries, cleans the graph (daily)
        </li>
        <li>
          <strong>Link Gardener</strong>
          — resolves broken <code>[[links]]</code>, suggests backlinks via embeddings
        </li>
        <li>
          <strong>Weekly Review</strong>
          — auto-generates a weekly summary note with activity, goals progress, and stats (Mondays)
        </li>
      </ul>
      <p>
        All agents can also be triggered manually via MCP with <code>start_agent</code>.
      </p>

      <h3>Backlinks</h3>
      <p>
        Every page shows a collapsible backlinks section listing all pages that reference it,
        grouped by relation type with badges. This makes it easy to discover reverse connections.
      </p>

      <h3>Smart Collections</h3>
      <p>
        Dynamic page groupings based on filters (type, tags, date ranges). Collections auto-update
        as pages change, giving you live views like "All todos from this week" or "Concepts tagged AI".
      </p>

      <h3>Full Export</h3>
      <p>
        Export your entire brain as a structured JSON snapshot via <code>GET /api/export/:context/full</code>.
        Includes all pages, relations, and metadata — useful for backups or migrations.
      </p>

      <h3>Settings</h3>
      <p>
        The Settings page (<code>/settings</code>) lets you tune brain behavior at runtime:
        semantic similarity threshold, auto-linking, page augmenter on/off, and more — stored
        in the database, no restart needed.
      </p>

      <h2>Architecture</h2>
      <p>
        Dran is a Phoenix 1.8 application using LiveView for real-time UI, Ecto + PostgreSQL for
        persistence, and a JSON REST API at <code>/api</code>. It also exposes an MCP
        (Model Context Protocol) endpoint for AI agent integration.
      </p>

      <h2>Getting started</h2>
      <ol>
        <li>Create pages from the UI or the API</li>
        <li>Link pages with relations</li>
        <li>Explore the graph to discover connections</li>
        <li>Use goals to group related pages and track progress</li>
      </ol>
    </div>
    """
  end

  # ── Auth Reference ──

  def auth_reference(assigns) do
    ~H"""
    <div class="prose prose-base dark:prose-invert max-w-none space-y-6">
      <h2>Authentication</h2>
      <p>
        Dran uses single-user authentication. The same credentials protect both the
        web UI (session-based) and the REST/MCP API (bearer token). Credentials are
        read from environment variables at startup.
      </p>

      <h3>Environment variables</h3>
      <div class="not-prose overflow-hidden rounded-lg border border-base-300">
        <table class="w-full text-sm">
          <thead>
            <tr class="text-xs text-base-content/40 uppercase border-b border-base-300">
              <th class="text-left px-4 py-2 font-medium">{gettext("Variable")}</th>
              <th class="text-left px-4 py-2 font-medium">{gettext("Default")}</th>
              <th class="text-left px-4 py-2 font-medium">{gettext("Purpose")}</th>
            </tr>
          </thead>
          <tbody>
            <tr class="border-b border-base-300">
              <td class="px-4 py-2 font-mono text-primary">DRAN_USERNAME</td>
              <td class="px-4 py-2 font-mono text-base-content/60">admin</td>
              <td class="px-4 py-2">Web login username</td>
            </tr>
            <tr class="border-b border-base-300">
              <td class="px-4 py-2 font-mono text-primary">DRAN_PASSWORD</td>
              <td class="px-4 py-2 font-mono text-base-content/60">dran</td>
              <td class="px-4 py-2">Web login password</td>
            </tr>
            <tr class="border-b border-base-300">
              <td class="px-4 py-2 font-mono text-primary">DRAN_API_TOKEN</td>
              <td class="px-4 py-2 font-mono text-base-content/60">dran-token</td>
              <td class="px-4 py-2">Bearer token for API and MCP</td>
            </tr>
            <tr class="border-b border-base-300">
              <td class="px-4 py-2 font-mono text-primary">DRAN_INFERENCE_URL</td>
              <td class="px-4 py-2 font-mono text-base-content/60">http://localhost:8080/v1</td>
              <td class="px-4 py-2">LLM inference endpoint</td>
            </tr>
            <tr class="border-b border-base-300">
              <td class="px-4 py-2 font-mono text-primary">DRAN_INFERENCE_API_KEY</td>
              <td class="px-4 py-2 font-mono text-base-content/60">(empty)</td>
              <td class="px-4 py-2">API key for inference endpoint</td>
            </tr>
            <tr class="border-b border-base-300">
              <td class="px-4 py-2 font-mono text-primary">DRAN_EMBEDDING_MODEL</td>
              <td class="px-4 py-2 font-mono text-base-content/60">nomic-embed-text</td>
              <td class="px-4 py-2">Embedding model name</td>
            </tr>
            <tr>
              <td class="px-4 py-2 font-mono text-primary">DRAN_CHAT_MODEL</td>
              <td class="px-4 py-2 font-mono text-base-content/60">qwen3</td>
              <td class="px-4 py-2">Chat/LLM model name</td>
            </tr>
          </tbody>
        </table>
      </div>

      <h3>Web UI authentication</h3>
      <p>
        The web UI is protected by a session-based login at <code>/login</code>.
        Unauthenticated requests are redirected there. After a successful login,
        a session cookie is set and the user is redirected back to the requested page.
      </p>
      <p>
        A context selector in the sidebar lets you switch between contexts. The
        selection persists via a signed cookie (dran_last_context) and is restored
        on next visit. The selector also shows page counts per context.
      </p>

      <h3>API authentication</h3>
      <p>
        All endpoints under <code>/api</code>
        require a Bearer token in the <code>Authorization</code>
        header:
      </p>
      <pre phx-no-curly-interpolation><code>
        curl -H "Authorization: Bearer dran-token" \\
             http://localhost:4000/api/pages?context=personal
      </code></pre>
      <p>
        Without a valid token, the API responds with <code>401 Unauthorized</code>.
      </p>

      <h3>MCP authentication</h3>
      <p>
        The MCP endpoint at <code>/api/mcp</code> uses the same Bearer token.
        MCP clients should send the token in the <code>Authorization</code> header
        of every request:
      </p>
      <pre phx-no-curly-interpolation><code>
        POST /api/mcp
        Authorization: Bearer dran-token
        Content-Type: application/json
      </code></pre>

      <h3>Configuring an MCP client</h3>
      <p>
        To use Dran with an MCP-compatible client (e.g. Claude Desktop), add this
        to your client config, including the bearer token:
      </p>
      <pre phx-no-curly-interpolation><code>
        {
          "mcpServers": {
            "dran": {
              "url": "http://localhost:4000/api/mcp",
              "headers": {
                "Authorization": "Bearer dran-token"
              }
            }
          }
        }
      </code></pre>

      <h3>Runtime Settings</h3>
      <p>
        Brain behavior can be tuned at runtime without restarting. Settings are stored
        in the database and managed via the Settings page (/settings) or the API.
        Key settings include similarity threshold, page augmenter toggle, and auto-linking.
      </p>

      <h3>Security notes</h3>
      <ul>
        <li>Change the default credentials in production via environment variables.</li>
        <li>The API token grants full read/write access — protect it like a password.</li>
        <li>Use HTTPS in production to prevent credential interception.</li>
        <li>There is no multi-user support; the same credentials are used by everyone.</li>
      </ul>
    </div>
    """
  end

  # ── API Reference ──

  def api_reference(assigns) do
    ~H"""
    <div class="space-y-8">
      <div class="prose prose-base dark:prose-invert max-w-none">
        <h2>REST API</h2>
        <p>
          All endpoints are served under <code>/api</code> and return JSON. Most endpoints
          accept a <code>context</code> query parameter (context slug) to scope the operation.
        </p>
      </div>

      <.api_group title="Contexts">
        <:endpoint method="GET" path="/api/contexts" desc="List all contexts" />
        <:endpoint method="POST" path="/api/contexts" desc="Create a context" />
        <:endpoint method="GET" path="/api/contexts/:slug" desc="Get a context by slug" />
        <:endpoint method="PUT" path="/api/contexts/:slug" desc="Update a context" />
        <:endpoint method="DELETE" path="/api/contexts/:slug" desc="Delete a context" />
      </.api_group>

      <.api_group title="Pages">
        <:endpoint
          method="GET"
          path="/api/pages"
          desc="List pages (filters: context, type, tag, status, owner, limit)"
        />
        <:endpoint method="POST" path="/api/pages" desc="Create a page" />
        <:endpoint method="GET" path="/api/pages/:slug" desc="Get a page" />
        <:endpoint method="PUT" path="/api/pages/:slug" desc="Update a page" />
        <:endpoint method="DELETE" path="/api/pages/:slug" desc="Delete a page" />
        <:endpoint method="GET" path="/api/pages/:slug/links" desc="Inbound + outbound relations" />
        <:endpoint method="GET" path="/api/pages/:slug/graph" desc="Subgraph centered on a page" />
        <:endpoint
          method="GET"
          path="/api/pages/:slug/backlinks"
          desc="Pages that reference this page, grouped by relation type"
        />
        <:endpoint
          method="GET"
          path="/api/pages/:slug/diff?v1=N&v2=M"
          desc="Version diff between two versions"
        />
      </.api_group>

      <.api_group title="Relations">
        <:endpoint
          method="POST"
          path="/api/relations"
          desc="Create a relation (source, target, relation_type)"
        />
        <:endpoint method="DELETE" path="/api/relations/:id" desc="Delete a relation" />
      </.api_group>

      <.api_group title="Search">
        <:endpoint method="GET" path="/api/search?q=...&context=...&type=..." desc="Full-text search" />
        <:endpoint method="GET" path="/api/search/fuzzy?q=...&context=..." desc="Fuzzy search" />
      </.api_group>

      <.api_group title="Goals">
        <:endpoint method="GET" path="/api/goals?context=..." desc="List goals" />
        <:endpoint
          method="GET"
          path="/api/goals/:slug?context=..."
          desc="Goal detail with todos and plans"
        />
      </.api_group>

      <.api_group title="Todos">
        <:endpoint
          method="GET"
          path="/api/todos?context=...&status=..."
          desc="List todos (filterable by kanban status)"
        />
        <:endpoint method="POST" path="/api/todos" desc="Create a todo" />
        <:endpoint method="PUT" path="/api/todos/:id" desc="Update a todo (e.g. change status)" />
      </.api_group>

      <.api_group title="Ingest">
        <:endpoint method="POST" path="/api/ingest" desc="Ingest a URL as a raw page" />
      </.api_group>

      <.api_group title="Maintenance">
        <:endpoint method="GET" path="/api/lint?context=..." desc="Lint pages for quality issues" />
        <:endpoint method="GET" path="/api/log?context=...&action=...&limit=..." desc="Activity log" />
      </.api_group>

      <.api_group title="Wiki">
        <:endpoint
          method="GET"
          path="/api/index?context=..."
          desc="Wiki index (all page slugs + titles)"
        />
        <:endpoint method="GET" path="/api/graph?context=..." desc="Full graph (nodes + edges)" />
        <:endpoint
          method="GET"
          path="/api/graph/3d?context=..."
          desc="3D graph data (nodes with x,y,z coords)"
        />
      </.api_group>

      <.api_group title="Export">
        <:endpoint
          method="GET"
          path="/api/export/:context/full"
          desc="Full brain export (all pages + relations + metadata as JSON)"
        />
      </.api_group>

      <.api_group title="Settings">
        <:endpoint method="GET" path="/api/settings" desc="List all runtime settings" />
        <:endpoint method="PUT" path="/api/settings/:key" desc="Update a setting value" />
      </.api_group>

      <.api_group title="Chat">
        <:endpoint method="POST" path="/api/chat/sessions" desc="Create a chat session" />
        <:endpoint method="GET" path="/api/chat/sessions/:id" desc="Get session + messages" />
        <:endpoint method="POST" path="/api/chat/sessions/:id/messages" desc="Send a message" />
      </.api_group>
    </div>
    """
  end

  attr :title, :string, required: true

  slot :endpoint, required: true do
    attr :method, :string, required: true
    attr :path, :string, required: true
    attr :desc, :string, required: true
  end

  def api_group(assigns) do
    ~H"""
    <div>
      <h3 class="text-lg font-semibold mb-3">{@title}</h3>
      <div class="rounded-lg border border-base-300 overflow-hidden">
        <div
          :for={ep <- @endpoint}
          class="flex items-start gap-3 px-4 py-2.5 border-b border-base-300 last:border-b-0 hover:bg-base-200/50 transition"
        >
          <span class={[
            "font-mono text-xs font-bold px-2 py-0.5 rounded shrink-0",
            method_class(ep.method)
          ]}>
            {ep.method}
          </span>
          <code class="text-sm text-primary flex-1 break-all">{ep.path}</code>
          <span class="text-xs text-base-content/60 shrink-0 max-w-xs text-right">{ep.desc}</span>
        </div>
      </div>
    </div>
    """
  end

  defp method_class("GET"), do: "bg-blue-500/20 text-blue-700"
  defp method_class("POST"), do: "bg-green-500/20 text-green-700"
  defp method_class("PUT"), do: "bg-amber-500/20 text-amber-700"
  defp method_class("DELETE"), do: "bg-red-500/20 text-red-700"
  defp method_class(_), do: "bg-base-300 text-base-content/60"

  # ── MCP Reference ──

  def mcp_reference(assigns) do
    ~H"""
    <div class="prose prose-base dark:prose-invert max-w-none space-y-6">
      <h2>MCP (Model Context Protocol)</h2>
      <p>
        Dran exposes an MCP endpoint at <code>/api/mcp</code> using the Streamable HTTP
        transport. AI agents can connect to Dran and use it as a knowledge tool.
      </p>

      <h3>Endpoint</h3>
      <pre phx-no-curly-interpolation><code>
        POST /api/mcp   - send JSON-RPC message
        GET /api/mcp    - open SSE stream (optional, returns 405 if unsupported)
        DELETE /api/mcp - terminate session
      </code></pre>

      <h3>Session management</h3>
      <p>
        The server returns a <code>Mcp-Session-Id</code> header on the first request. Include
        this header in subsequent requests to maintain session state.
      </p>

      <h3>Agent Quick Start</h3>
      <p>
        When an agent connects to Dran, it should follow this workflow:
      </p>
      <ol>
        <li>
          <strong>Search</strong>
          — use <code>search</code>
          to find existing pages before creating new ones.
        </li>
        <li>
          <strong>Read</strong>
          — use <code>get_page</code>
          to read full content, or <code>list_pages</code>
          for a filtered overview.
        </li>
        <li>
          <strong>Create</strong>
          — use <code>create_page</code>
          with the appropriate <code>page_type</code>
          and <code>meta</code>. Use <code>create_todo</code>
          for action items.
        </li>
        <li>
          <strong>Update</strong>
          — use <code>update_page</code>
          to refine content. Use <code>update_todo</code>
          to change a todo's status (merges meta).
        </li>
        <li>
          <strong>Delete</strong>
          — use <code>delete_page</code>
          to remove a page (cascades to relations + versions).
        </li>
        <li>
          <strong>Relate</strong>
          — use <code>create_relation</code>
          for typed relationships. Use <code>delete_relation</code>
          to remove. Embeds (<code>![[slug]]</code>) auto-create <code>embeds</code>
          relations.
        </li>
        <li>
          <strong>Inspect</strong>
          — use <code>get_links</code>
          to see inbound + outbound relations for a page.
        </li>
        <li>
          <strong>Stats</strong>
          — use <code>stats</code>
          for a context overview (page counts, todos by status, orphans).
        </li>
        <li>
          <strong>Rename</strong>
          — use <code>rename_slug</code>
          to rename a page slug. Update existing <code>![[slug]]</code>
          embeds manually if needed.
        </li>
        <li>
          <strong>Agents</strong>
          — use <code>start_agent</code>
          to delegate tasks to autonomous agents (research, ingest, qa, curator, link_gardener, weekly_review).
          Poll <code>get_agent_session</code>
          for progress and results.
        </li>
        <li>
          <strong>Files Ingest</strong>
          — use <code>ingest_url</code>
          to save web pages or download files as references.
        </li>
        <li>
          <strong>Lint</strong> — use <code>lint</code> to find orphans and stale pages.
        </li>
      </ol>

      <h3>Page Types &amp; Subtypes</h3>
      <p>
        Every page has a <code>page_type</code>
        that determines its purpose. Some types have a <code>kind</code>
        sub-type (set in <code>meta.kind</code>). Knowing the right type helps
        the agent structure knowledge correctly.
      </p>

      <div class="not-prose overflow-x-auto">
        <table class="w-full text-sm border border-base-300 rounded-lg">
          <thead class="bg-base-200">
            <tr>
              <th class="text-left p-2 font-semibold">{gettext("Type")}</th>
              <th class="text-left p-2 font-semibold">{gettext("Purpose")}</th>
              <th class="text-left p-2 font-semibold">{gettext("Subtypes (meta.kind)")}</th>
              <th class="text-left p-2 font-semibold">{gettext("Key meta fields")}</th>
            </tr>
          </thead>
          <tbody>
            <tr class="border-t border-base-300">
              <td class="p-2 font-mono text-primary">note</td>
              <td class="p-2">Ephemeral thoughts, journal, ideas</td>
              <td class="p-2 text-xs">thought, journal, idea, meeting, question, quote</td>
              <td class="p-2 text-xs">kind, date, attendees, author</td>
            </tr>
            <tr class="border-t border-base-300">
              <td class="p-2 font-mono text-primary">concept</td>
              <td class="p-2">Abstract ideas, techniques, theories</td>
              <td class="p-2 text-xs">technique, pattern, discipline, theory</td>
              <td class="p-2 text-xs">kind, domain, parent_concept</td>
            </tr>
            <tr class="border-t border-base-300">
              <td class="p-2 font-mono text-primary">entity</td>
              <td class="p-2">Concrete things (people, companies, tools)</td>
              <td class="p-2 text-xs">person, company, product, tool, place, event</td>
              <td class="p-2 text-xs">kind, aliases, external_url, location</td>
            </tr>
            <tr class="border-t border-base-300">
              <td class="p-2 font-mono text-primary">reference</td>
              <td class="p-2">External sources (articles, papers, videos)</td>
              <td class="p-2 text-xs">article, paper, video, podcast, book</td>
              <td class="p-2 text-xs">kind, source_url, published_at</td>
            </tr>
            <tr class="border-t border-base-300">
              <td class="p-2 font-mono text-primary">artifact</td>
              <td class="p-2">Files and deliverables (uploaded via UI)</td>
              <td class="p-2 text-xs">document, code, design, deliverable, file</td>
              <td class="p-2 text-xs">kind, filename, mime_type, storage_path, sha256</td>
            </tr>
            <tr class="border-t border-base-300">
              <td class="p-2 font-mono text-primary">goal</td>
              <td class="p-2">Objectives with target dates and health</td>
              <td class="p-2 text-xs text-base-content/40">—</td>
              <td class="p-2 text-xs">health (green/yellow/red), target_date, start_date, team</td>
            </tr>
            <tr class="border-t border-base-300">
              <td class="p-2 font-mono text-primary">plan</td>
              <td class="p-2">Time-horizoned plans</td>
              <td class="p-2 text-xs text-base-content/40">—</td>
              <td class="p-2 text-xs">horizon (weekly/monthly/quarterly/yearly), status, period</td>
            </tr>
            <tr class="border-t border-base-300">
              <td class="p-2 font-mono text-primary">todo</td>
              <td class="p-2">Actionable items with kanban status</td>
              <td class="p-2 text-xs text-base-content/40">—</td>
              <td class="p-2 text-xs">
                kanban_status (backlog/this_week/today/in_progress/done/cancelled), priority (low/medium/high/urgent), goal_slug, due_date
              </td>
            </tr>
            <tr class="border-t border-base-300">
              <td class="p-2 font-mono text-primary">comparison</td>
              <td class="p-2">Side-by-side comparison of entities</td>
              <td class="p-2 text-xs text-base-content/40">—</td>
              <td class="p-2 text-xs">entities, criteria, verdict</td>
            </tr>
            <tr class="border-t border-base-300">
              <td class="p-2 font-mono text-primary">query</td>
              <td class="p-2">Question with answer (LLM wiki style)</td>
              <td class="p-2 text-xs">factual, conceptual, how_to, opinion</td>
              <td class="p-2 text-xs">
                kind, difficulty (simple/intermediate/advanced), status (open/answered/verified), answered_by
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <h3>Embeds</h3>
      <p>
        Use <code>![[slug]]</code>
        in page bodies to embed an artifact (image, video, audio, PDF). Embeds
        are auto-resolved into <code>embeds</code>
        relations. Plain <code>[[slug]]</code>
        wikilinks are no longer supported — relations are
        created automatically via embeddings or explicitly via <code>create_relation</code>.
      </p>

      <h3>Available tools</h3>
      <p>
        Once connected, the MCP server exposes the following tools that agents can call:
      </p>

      <div class="not-prose space-y-3">
        <.mcp_tool
          name="search"
          desc="Unified search across pages. Auto picks full-text, fuzzy, semantic or hybrid."
        >
          <:param name="query" type="string" required="yes" desc="Search query (natural language)" />
          <:param name="context" type="string" required="yes" desc="Context slug" />
          <:param name="type" type="string" required="no" desc="Filter by page type" />
          <:param
            name="strategy"
            type="string"
            required="no"
            desc="auto, fts, fuzzy, semantic, hybrid"
          />
        </.mcp_tool>

        <.mcp_tool
          name="semantic_search"
          desc="Deprecated alias for search with strategy=semantic. Use search instead."
        >
          <:param name="query" type="string" required="yes" desc="Search query (natural language)" />
          <:param name="context" type="string" required="yes" desc="Context slug" />
          <:param name="type" type="string" required="no" desc="Filter by page type" />
          <:param
            name="hybrid"
            type="boolean"
            required="no"
            desc="Use hybrid strategy instead of semantic"
          />
        </.mcp_tool>

        <.mcp_tool
          name="get_page"
          desc="Get a page by slug. Returns full markdown content + metadata."
        >
          <:param name="slug" type="string" required="yes" desc="Page slug" />
          <:param name="context" type="string" required="yes" desc="Context slug" />
        </.mcp_tool>

        <.mcp_tool
          name="create_page"
          desc="Create a new page. See Page Types table above for type-specific meta fields."
        >
          <:param name="context" type="string" required="yes" desc="Context slug" />
          <:param name="title" type="string" required="yes" desc="Page title" />
          <:param name="slug" type="string" required="yes" desc="URL-friendly slug (kebab-case)" />
          <:param
            name="page_type"
            type="string"
            required="yes"
            desc="note, concept, entity, reference, goal, plan, todo, artifact, comparison, query"
          />
          <:param
            name="body"
            type="string"
            required="no"
            desc="Markdown body. Use ![[slug]] for artifact embeds."
          />
          <:param
            name="meta"
            type="object"
            required="no"
            desc="Type-specific metadata (see table above)"
          />
          <:param name="tags" type="array" required="no" desc="Tags (kebab-case)" />
          <:param name="summary" type="string" required="no" desc="One-line summary" />
        </.mcp_tool>

        <.mcp_tool
          name="update_page"
          desc="Update an existing page. Version auto-increments on body change."
        >
          <:param name="context" type="string" required="yes" desc="Context slug" />
          <:param name="slug" type="string" required="yes" desc="Page slug to update" />
          <:param name="title" type="string" required="no" desc="New title" />
          <:param name="body" type="string" required="no" desc="New markdown body" />
          <:param name="tags" type="array" required="no" desc="New tags" />
          <:param name="meta" type="object" required="no" desc="Updated metadata" />
        </.mcp_tool>

        <.mcp_tool
          name="delete_page"
          desc="Delete a page by slug. Cascades to relations and page versions. Irreversible."
        >
          <:param name="context" type="string" required="yes" desc="Context slug" />
          <:param name="slug" type="string" required="yes" desc="Slug of the page to delete" />
        </.mcp_tool>

        <.mcp_tool
          name="create_todo"
          desc="Create a todo with kanban status and priority, optionally linked to a goal."
        >
          <:param name="context" type="string" required="yes" desc="Context slug" />
          <:param name="title" type="string" required="yes" desc="Todo title" />
          <:param name="slug" type="string" required="yes" desc="Todo slug" />
          <:param name="goal_slug" type="string" required="no" desc="Goal this todo belongs to" />
          <:param
            name="kanban_status"
            type="string"
            required="no"
            desc="backlog, this_week, today, in_progress, done, cancelled"
          />
          <:param name="priority" type="string" required="no" desc="low, medium, high, urgent" />
          <:param name="due_date" type="string" required="no" desc="YYYY-MM-DD" />
          <:param name="body" type="string" required="no" desc="Todo description (markdown)" />
        </.mcp_tool>

        <.mcp_tool
          name="update_todo"
          desc="Update a todo's status, priority, due date, or goal. Merges meta — only pass changed fields."
        >
          <:param name="context" type="string" required="yes" desc="Context slug" />
          <:param name="slug" type="string" required="yes" desc="Todo slug to update" />
          <:param name="kanban_status" type="string" required="no" desc="New kanban status" />
          <:param name="priority" type="string" required="no" desc="New priority" />
          <:param name="due_date" type="string" required="no" desc="New due date YYYY-MM-DD" />
          <:param name="goal_slug" type="string" required="no" desc="New goal slug" />
          <:param name="title" type="string" required="no" desc="New title" />
          <:param name="body" type="string" required="no" desc="New body (markdown)" />
          <:param name="tags" type="array" required="no" desc="New tags (replaces existing)" />
        </.mcp_tool>

        <.mcp_tool
          name="create_relation"
          desc="Create a typed relation between two pages. Use for contradicts, supersedes, part_of, embeds."
        >
          <:param name="context" type="string" required="yes" desc="Context slug" />
          <:param name="source_slug" type="string" required="yes" desc="Source page slug" />
          <:param name="target_slug" type="string" required="yes" desc="Target page slug" />
          <:param
            name="relation_type"
            type="string"
            required="no"
            desc="related, contradicts, supersedes, part_of, embeds (default: related)"
          />
        </.mcp_tool>

        <.mcp_tool
          name="delete_relation"
          desc="Delete a relation between two pages. Without relation_type, deletes ALL relations between them."
        >
          <:param name="context" type="string" required="yes" desc="Context slug" />
          <:param name="source_slug" type="string" required="yes" desc="Source page slug" />
          <:param name="target_slug" type="string" required="yes" desc="Target page slug" />
          <:param
            name="relation_type"
            type="string"
            required="no"
            desc="Only delete this type (optional, deletes all if omitted)"
          />
        </.mcp_tool>

        <.mcp_tool
          name="get_links"
          desc="Get all inbound + outbound relations for a page. Shows inbound and outbound graph connections."
        >
          <:param name="context" type="string" required="yes" desc="Context slug" />
          <:param name="slug" type="string" required="yes" desc="Page slug" />
        </.mcp_tool>

        <.mcp_tool
          name="list_pages"
          desc="List pages with optional filters. Returns lightweight metadata (no body)."
        >
          <:param name="context" type="string" required="yes" desc="Context slug" />
          <:param
            name="type"
            type="string"
            required="no"
            desc="note, concept, entity, reference, goal, plan, todo, artifact, comparison, query"
          />
          <:param name="tag" type="string" required="no" desc="Filter by tag" />
          <:param name="status" type="string" required="no" desc="Filter by kanban_status (todos)" />
          <:param name="limit" type="integer" required="no" desc="Max results (default 50, max 500)" />
        </.mcp_tool>

        <.mcp_tool
          name="stats"
          desc="Aggregate statistics for a context. Returns page counts, todos by status, orphans, and total relations."
        >
          <:param name="context" type="string" required="yes" desc="Context slug" />
        </.mcp_tool>

        <.mcp_tool
          name="rename_slug"
          desc="Rename a page's slug. Existing ![[slug]] embeds are not updated automatically."
        >
          <:param name="context" type="string" required="yes" desc="Context slug" />
          <:param name="old_slug" type="string" required="yes" desc="Current slug to rename" />
          <:param name="new_slug" type="string" required="yes" desc="New slug (kebab-case)" />
        </.mcp_tool>

        <.mcp_tool
          name="lint"
          desc="Quality report: orphans, stale pages, and contested knowledge."
        >
          <:param name="context" type="string" required="yes" desc="Context slug" />
        </.mcp_tool>

        <.mcp_tool
          name="ingest_url"
          desc="Save a URL as a reference page. HTML → saves URL (agent reads later). Files → downloads & stores with download link."
        >
          <:param name="context" type="string" required="yes" desc="Context slug" />
          <:param name="url" type="string" required="yes" desc="URL to ingest (HTML or PDF)" />
          <:param
            name="slug"
            type="string"
            required="no"
            desc="Custom slug (auto from title if omitted)"
          />
          <:param name="tags" type="array" required="no" desc="Tags" />
        </.mcp_tool>

        <.mcp_tool
          name="start_agent"
          desc="Start an autonomous agent session. Returns immediately; poll get_agent_session for progress."
        >
          <:param
            name="agent_type"
            type="string"
            required="yes"
            desc="research, ingest, qa, curator, link_gardener, weekly_review"
          />
          <:param name="context" type="string" required="yes" desc="Context slug" />
          <:param name="input" type="string" required="yes" desc="Topic, URL, or query" />
          <:param name="opts" type="object" required="no" desc="Optional agent options" />
        </.mcp_tool>

        <.mcp_tool
          name="get_agent_session"
          desc="Poll an agent session for status, summary, and steps."
        >
          <:param name="session_id" type="string" required="yes" desc="Agent session UUID" />
        </.mcp_tool>

        <.mcp_tool
          name="get_settings"
          desc="Get all runtime brain settings (similarity threshold, augmenter on/off, etc)."
        >
          <:param name="context" type="string" required="yes" desc="Context slug" />
        </.mcp_tool>

        <.mcp_tool
          name="update_setting"
          desc="Update a runtime brain setting. Persisted in DB, takes effect immediately."
        >
          <:param name="key" type="string" required="yes" desc="Setting key" />
          <:param name="value" type="string" required="yes" desc="New value" />
        </.mcp_tool>
      </div>

      <h3>Resources</h3>
      <p>
        Agents can also read resources for structured access:
      </p>
      <div class="not-prose space-y-2">
        <div class="rounded-lg border border-base-300 p-3">
          <code class="font-mono text-primary">page://&#123;context&#125;/&#123;slug&#125;</code>
          <span class="text-sm text-base-content/60 ml-2">Full page content as markdown</span>
        </div>
        <div class="rounded-lg border border-base-300 p-3">
          <code class="font-mono text-primary">goal://&#123;context&#125;/&#123;slug&#125;</code>
          <span class="text-sm text-base-content/60 ml-2">Goal detail with related todos and plans (JSON)</span>
        </div>
        <div class="rounded-lg border border-base-300 p-3">
          <code class="font-mono text-primary">wiki://&#123;context&#125;/index</code>
          <span class="text-sm text-base-content/60 ml-2">All pages in a context (slug + title + type)</span>
        </div>
        <div class="rounded-lg border border-base-300 p-3">
          <code class="font-mono text-primary">settings://current</code>
          <span class="text-sm text-base-content/60 ml-2">Current runtime brain settings (JSON)</span>
        </div>
      </div>

      <h3>Prompts</h3>
      <p>
        Pre-built prompt templates for common agent workflows:
      </p>
      <div class="not-prose space-y-2">
        <div class="rounded-lg border border-base-300 p-3">
          <code class="font-mono text-primary">research_topic</code>
          <span class="text-sm text-base-content/60 ml-2">Scaffold a research page with outline, sources, and questions. Args: topic, context.</span>
        </div>
        <div class="rounded-lg border border-base-300 p-3">
          <code class="font-mono text-primary">brainstorm</code>
          <span class="text-sm text-base-content/60 ml-2">Generate ideas around a topic. Args: topic, context.</span>
        </div>
        <div class="rounded-lg border border-base-300 p-3">
          <code class="font-mono text-primary">goal_review</code>
          <span class="text-sm text-base-content/60 ml-2">Review a goal's status, todos, and plans. Args: goal_slug, context.</span>
        </div>
        <div class="rounded-lg border border-base-300 p-3">
          <code class="font-mono text-primary">weekly_review</code>
          <span class="text-sm text-base-content/60 ml-2">Generate a weekly review summary. Args: context.</span>
        </div>
      </div>

      <h3>Example: initialize session</h3>
      <pre phx-no-curly-interpolation><code>
        POST /api/mcp
        Content-Type: application/json

        {"jsonrpc": "2.0", "id": 1, "method": "initialize",
         "params": {"protocolVersion": "2025-03-26", "capabilities": {},
                    "clientInfo": {"name": "my-agent", "version": "1.0"}}}
      </code></pre>

      <p>
        The response includes a <code>Mcp-Session-Id</code> header. Use it in subsequent requests:
      </p>

      <pre phx-no-curly-interpolation><code>
        POST /api/mcp
        Content-Type: application/json
        Mcp-Session-Id: your-session-id

        {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
         "params": {"name": "search",
                    "arguments": {"query": "elixir", "context": "personal"}}}
      </code></pre>

      <h3>Client configuration</h3>
      <p>
        To use Dran with an MCP-compatible client (e.g. Claude Desktop), add this to your
        client config:
      </p>
      <pre phx-no-curly-interpolation><code>
        {"mcpServers": {"dran": {"url": "http://localhost:4000/api/mcp", "headers": {"Authorization": "Bearer dran-token"}}}}
      </code></pre>
    </div>
    """
  end

  attr :name, :string, required: true
  attr :desc, :string, required: true

  slot :param, required: true do
    attr :name, :string, required: true
    attr :type, :string, required: true
    attr :required, :string, required: true
    attr :desc, :string, required: true
  end

  def mcp_tool(assigns) do
    ~H"""
    <div class="rounded-lg border border-base-300 p-4">
      <div class="flex items-baseline gap-2 mb-2">
        <code class="font-mono font-semibold text-primary">{@name}</code>
        <span class="text-sm text-base-content/60">{@desc}</span>
      </div>
      <table class="w-full text-sm">
        <thead>
          <tr class="text-xs text-base-content/40 uppercase">
            <th class="text-left py-1 font-medium">{gettext("Parameter")}</th>
            <th class="text-left py-1 font-medium">{gettext("Type")}</th>
            <th class="text-left py-1 font-medium">{gettext("Required")}</th>
            <th class="text-left py-1 font-medium">{gettext("Description")}</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={p <- @param} class="border-t border-base-300">
            <td class="py-1.5 font-mono text-primary">{p.name}</td>
            <td class="py-1.5 text-base-content/60">{p.type}</td>
            <td class="py-1.5">
              <span class={[
                "text-xs px-1.5 py-0.5 rounded",
                p.required == "yes" && "bg-red-500/20 text-red-700",
                p.required != "yes" && "bg-base-300 text-base-content/60"
              ]}>
                {p.required}
              </span>
            </td>
            <td class="py-1.5 text-base-content/60">{p.desc}</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end
end
