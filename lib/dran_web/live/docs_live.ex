defmodule DranWeb.DocsLive do
  @moduledoc """
  Documentation pages for Dran: Getting started, Concepts, Guides, REST API, and MCP integration.
  """

  use DranWeb, :live_view

  alias DranWeb.Plugs.Auth

  @tabs [
    {"getting-started", "getting-started"},
    {"concepts", "concepts"},
    {"guides", "guides"},
    {"api", "api"},
    {"mcp", "mcp"},
    {"auth", "auth"}
  ]

  defp tab_label("getting-started"), do: gettext("Getting started")
  defp tab_label("concepts"), do: gettext("Concepts")
  defp tab_label("guides"), do: gettext("Guides")
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
      <div class="p-6 w-full">
        <h1 class="text-2xl font-bold mb-6">{gettext("Documentation")}</h1>

        <.tabs_bar tabs={translated_tabs()} active_tab={@active_tab} />

        <%= if @active_tab == "getting-started" do %>
          <.getting_started />
        <% end %>

        <%= if @active_tab == "concepts" do %>
          <.concepts />
        <% end %>

        <%= if @active_tab == "guides" do %>
          <.guides />
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

      <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyCode">
        export default {
          mounted() {
            this.el.addEventListener("click", () => {
              const pre = this.el.parentElement.querySelector("pre");
              if (pre) {
                const text = pre.textContent.trim();
                navigator.clipboard.writeText(text).then(() => {
                  const icon = this.el.querySelector("[data-copy-icon]");
                  const check = this.el.querySelector("[data-check-icon]");
                  if (icon && check) {
                    icon.classList.add("hidden");
                    check.classList.remove("hidden");
                    setTimeout(() => {
                      icon.classList.remove("hidden");
                      check.classList.add("hidden");
                    }, 1500);
                  }
                });
              }
            });
          }
        }
      </script>
    </Layouts.app>
    """
  end

  def mount(_params, session, socket) do
    {socket, _context} = Auth.assign_to_socket(socket, session)

    {:ok,
     assign(socket,
       active_nav: "docs",
       tabs: @tabs,
       active_tab: "getting-started",
       page_title: gettext("Docs")
     )}
  end

  def handle_params(params, _url, socket) do
    tab = params["tab"] || "getting-started"

    {:noreply,
     assign(socket,
       active_tab: tab,
       page_title: gettext("Docs · %{tab}", tab: tab |> String.capitalize())
     )}
  end

  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, active_tab: tab)}
  end

  # ── Shared Components ──

  attr :items, :list, required: true, doc: "list of {slug, label} tuples"

  defp toc(assigns) do
    ~H"""
    <div class="surface-1 rounded-lg p-4 mb-6 not-prose">
      <p class="text-xs font-semibold uppercase tracking-wide text-base-content/50 mb-2">
        {gettext("On this page")}
      </p>
      <ul class="space-y-1">
        <li :for={{slug, label} <- @items}>
          <a href={"#docs-#{slug}"} class="text-primary hover:underline text-sm">
            {label}
          </a>
        </li>
      </ul>
    </div>
    """
  end

  attr :variant, :atom, default: :info
  slot :inner_block, required: true

  defp callout(assigns) do
    ~H"""
    <div class={[
      "not-prose flex gap-3 rounded-lg border-l-4 p-4 my-4",
      callout_classes(@variant)
    ]}>
      <.icon name={callout_icon(@variant)} class="w-5 h-5 shrink-0 mt-0.5" />
      <div class="text-sm">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  defp callout_icon(:info), do: "hero-information-circle"
  defp callout_icon(:warning), do: "hero-exclamation-triangle"
  defp callout_icon(:tip), do: "hero-light-bulb"

  defp callout_classes(:info),
    do: "border-blue-500 bg-blue-500/10 text-blue-700 dark:text-blue-300"

  defp callout_classes(:warning),
    do: "border-amber-500 bg-amber-500/10 text-amber-700 dark:text-amber-300"

  defp callout_classes(:tip),
    do: "border-green-500 bg-green-500/10 text-green-700 dark:text-green-300"

  attr :id, :string, required: true
  attr :code, :string, required: true

  defp code_block(assigns) do
    ~H"""
    <div class="relative not-prose my-4 group">
      <button
        type="button"
        id={"#{@id}-copy-btn"}
        phx-hook=".CopyCode"
        class="absolute top-2 right-2 p-1.5 rounded-md bg-base-200/80 hover:bg-base-300 transition opacity-0 group-hover:opacity-100"
        aria-label={gettext("Copy")}
      >
        <span data-copy-icon>
          <.icon name="hero-clipboard-document" class="w-4 h-4 text-base-content/60" />
        </span>
        <span data-check-icon class="hidden">
          <.icon name="hero-check" class="w-4 h-4 text-green-500" />
        </span>
      </button>
      <pre id={@id} class="overflow-x-auto rounded-lg bg-base-200 p-4 text-sm"><code>{@code}</code></pre>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true

  defp h2_heading(assigns) do
    ~H"""
    <h2 id={"docs-#{@id}"} class="scroll-mt-20 flex items-center gap-2 text-xl font-bold mt-8 mb-4">
      <.icon name={@icon} class="w-6 h-6 text-primary" />
      {@label}
    </h2>
    """
  end

  # ── Getting Started ──

  def getting_started(assigns) do
    ~H"""
    <div class="prose prose-base dark:prose-invert max-w-none space-y-6">
      <.toc items={[
        {"what-is-dran", "What is Dran?"},
        {"architecture", "Architecture"},
        {"getting-started", "Getting started"},
        {"next-steps", "Next steps"}
      ]} />

      <.h2_heading id="what-is-dran" icon="hero-book-open" label="What is Dran?" />
      <p>
        Dran is a personal second-brain application built with Phoenix LiveView. It stores
        your knowledge as typed pages (notes, concepts, entities, references) and links them
        with relations, forming a queryable knowledge graph.
      </p>

      <.h2_heading id="architecture" icon="hero-cube" label="Architecture" />
      <p>
        Dran is a Phoenix 1.8 application using LiveView for real-time UI, Ecto + PostgreSQL for
        persistence, and a JSON REST API at <code>/api</code>. It also exposes an MCP
        (Model Context Protocol) endpoint for AI agent integration.
      </p>

      <.h2_heading id="getting-started" icon="hero-rocket-launch" label="Getting started" />
      <ol>
        <li>Create pages from the UI or the API</li>
        <li>Link pages with relations</li>
        <li>Explore the graph to discover connections</li>
        <li>Use goals to group related pages and track progress</li>
      </ol>

      <.h2_heading id="next-steps" icon="hero-sparkles" label="Next steps" />
      <div class="not-prose grid grid-cols-1 md:grid-cols-3 gap-4">
        <a
          href="#"
          phx-click="switch_tab"
          phx-value-tab="concepts"
          class="surface-1 lift rounded-lg p-4 block hover:border-primary transition"
        >
          <.icon name="hero-cube" class="w-8 h-8 text-primary mb-2" />
          <h3 class="font-semibold">{gettext("Concepts")}</h3>
          <p class="text-sm text-base-content/60">
            Contexts, pages, relations, knowledge graph, and more.
          </p>
        </a>
        <a
          href="#"
          phx-click="switch_tab"
          phx-value-tab="guides"
          class="surface-1 lift rounded-lg p-4 block hover:border-primary transition"
        >
          <.icon name="hero-chat-bubble-left-right" class="w-8 h-8 text-primary mb-2" />
          <h3 class="font-semibold">{gettext("Guides")}</h3>
          <p class="text-sm text-base-content/60">
            AI chat, autonomous agents, kanban board, and settings.
          </p>
        </a>
        <a
          href="#"
          phx-click="switch_tab"
          phx-value-tab="mcp"
          class="surface-1 lift rounded-lg p-4 block hover:border-primary transition"
        >
          <.icon name="hero-command-line" class="w-8 h-8 text-primary mb-2" />
          <h3 class="font-semibold">{gettext("MCP")}</h3>
          <p class="text-sm text-base-content/60">
            Model Context Protocol integration for AI agents.
          </p>
        </a>
      </div>
    </div>
    """
  end

  # ── Concepts ──

  def concepts(assigns) do
    ~H"""
    <div class="prose prose-base dark:prose-invert max-w-none space-y-6">
      <.toc items={[
        {"contexts", "Contexts"},
        {"pages", "Pages"},
        {"relations", "Relations"},
        {"knowledge-graph", "Knowledge graph"},
        {"backlinks", "Backlinks"},
        {"smart-collections", "Smart Collections"},
        {"planning-hierarchy", "Planning hierarchy"},
        {"graph-intelligence", "Graph intelligence"}
      ]} />

      <.h2_heading id="contexts" icon="hero-squares-2x2" label="Contexts" />
      <p>
        A context is a self-contained workspace (e.g. "personal", "work"). All pages, relations,
        and logs belong to a single context. Most operations require a context, identified by
        its slug.
      </p>

      <.h2_heading id="pages" icon="hero-document-text" label="Pages" />
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

      <.h2_heading id="relations" icon="hero-link" label="Relations" />
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

      <.h2_heading id="knowledge-graph" icon="hero-circle-stack" label="Knowledge graph" />
      <p>
        Pages and relations form a directed graph. The <code>/graph</code>
        view renders the full
        graph in 2D or 3D with zoom and pan. Each page detail view also has a <strong>Graph</strong>
        tab
        showing the page as the center with its direct neighbors. Relations carry a
        <code>weight</code>
        that reflects semantic similarity strength.
      </p>

      <.h2_heading id="backlinks" icon="hero-arrow-uturn-left" label="Backlinks" />
      <p>
        Every page shows a collapsible backlinks section listing all pages that reference it,
        grouped by relation type with badges. This makes it easy to discover reverse connections.
      </p>

      <.h2_heading id="smart-collections" icon="hero-squares-2x2" label="Smart Collections" />
      <p>
        Dynamic page groupings based on filters (type, tags, date ranges). Collections auto-update
        as pages change, giving you live views like "All todos from this week" or "Concepts tagged AI".
      </p>

      <.h2_heading
        id="planning-hierarchy"
        icon="hero-clipboard-document-check"
        label="Planning hierarchy"
      />
      <p>
        Dran organizes planning into a three-level hierarchy: <strong>goals</strong>
        → <strong>plans</strong>
        → <strong>todos</strong>.
        Plans link to goals via <code>meta.goal_slug</code>, and todos link to plans via
        <code>meta.plan_slug</code>
        (the goal is derived from the plan). Todos and plans can be orphans — i.e. not linked to any
        parent. The <code>part_of</code>
        relation is materialized automatically when these links exist.
        Use <code>dran_list_pages</code>
        with <code>goal_slug</code>
        or <code>plan_slug</code>
        filters
        (value <code>"none"</code>
        returns orphans).
      </p>
      <.code_block
        id="planning-hierarchy-diagram"
        code={DranWeb.DocsContent.planning_hierarchy_diagram()}
      />

      <.h2_heading
        id="graph-intelligence"
        icon="hero-chart-bar-square"
        label="Graph intelligence"
      />
      <p>
        Dran runs three pure-Elixir structural algorithms over the relations
        table (<code>Dran.Graph</code>) — weighted <strong>PageRank</strong>,
        <strong>Label Propagation</strong>
        communities, and the <strong>GraphRAG</strong> <code>expand_neighbors</code>
        tool used by the
        QA agent — plus transitive <code>part_of</code>
        inference used by the
        Link Gardener. Results are persisted into each page's <code>meta</code>
        and refreshed nightly by the <code>pagerank_nightly</code>
        Quantum job (03:00 daily).
      </p>
      <.code_block
        id="graph-intelligence-doc"
        code={DranWeb.DocsContent.graph_intelligence_doc()}
      />
    </div>
    """
  end

  # ── Guides ──

  def guides(assigns) do
    ~H"""
    <div class="prose prose-base dark:prose-invert max-w-none space-y-6">
      <.toc items={[
        {"autonomous-agents", "Autonomous agents"},
        {"kanban-board", "Kanban board"},
        {"using-dran-from-agents", "Using Dran from agents"},
        {"settings", "Settings"}
      ]} />

      <.h2_heading id="autonomous-agents" icon="hero-cpu-chip" label="Autonomous agents" />
      <p>
        Dran runs six autonomous ReAct agents that plan, act, and log every step. Some are
        triggered on demand; others run on a fixed schedule.
      </p>
      <div class="not-prose grid grid-cols-1 md:grid-cols-2 gap-4 my-4">
        <%= for agent <- agents_data() do %>
          <div class="surface-1 lift rounded-lg p-4 border border-base-300/60 transition">
            <div class="flex items-start justify-between gap-3 mb-2">
              <div class="flex items-center gap-2.5">
                <.icon name={agent.icon} class={["w-7 h-7", agent.color]} />
                <h3 class="font-semibold text-base-content">{agent.label}</h3>
              </div>
              <%= if agent.trigger == :manual do %>
                <span class="shrink-0 inline-flex items-center gap-1 rounded-full bg-primary/10 text-primary text-xs font-medium px-2.5 py-0.5 border border-primary/20">
                  <.icon name="hero-hand-raised" class="w-3 h-3" />Manual
                </span>
              <% else %>
                <span class="shrink-0 inline-flex items-center gap-1 rounded-full bg-emerald-500/10 text-emerald-600 dark:text-emerald-400 text-xs font-medium px-2.5 py-0.5 border border-emerald-500/20">
                  <.icon name="hero-clock" class="w-3 h-3" />{agent.schedule}
                </span>
              <% end %>
            </div>
            <p class="text-sm text-base-content/70 leading-relaxed mb-3">
              {agent.description}
            </p>
            <p class="text-xs text-base-content/50 flex items-center gap-1.5">
              <.icon name="hero-adjustments-horizontal" class="w-3.5 h-3.5" />
              {agent.limits}
            </p>
          </div>
        <% end %>
      </div>
      <.callout variant={:info}>
        <p>
          <strong>Dispatch &amp; tracking:</strong>
          Agents run asynchronously under a <code>DynamicSupervisor</code>, persist every step
          to <code>agent_sessions</code>
          / <code>agent_steps</code>, and broadcast live updates
          via PubSub (<code>agents:&lt;session_id&gt;</code>). Use <code>dran_start_agent</code>
          to launch and <code>dran_get_agent_session</code>
          to poll
          for status, summary, and step-by-step progress.
        </p>
      </.callout>

      <.h2_heading id="kanban-board" icon="hero-view-columns" label="Kanban board" />
      <p>
        The <code>/todos</code> page is a full-viewport kanban board with 6 columns
        (backlog, this_week, today, in_progress, done, cancelled). You can drag and drop cards
        between columns to update their <code>kanban_status</code>. The board updates in real
        time — when an autonomous agent creates or moves a todo, the change is pushed to all
        connected clients via PubSub.
      </p>

      <.h2_heading
        id="using-dran-from-agents"
        icon="hero-command-line"
        label="Using Dran from agents"
      />
      <p>
        AI agents can connect to Dran via the MCP endpoint at <code>/api/mcp</code> using the
        Streamable HTTP transport. The repository includes a <code>SKILL.md</code> file with the
        full operational manual for agent integration. To verify your MCP schema is live and
        correct, run <code>scripts/mcp_smoke.sh</code> — it exercises the tools list and validates
        the response schema.
      </p>
      <.code_block
        id="agent-connect-example"
        code={DranWeb.DocsContent.agent_connect_example()}
      />

      <.h2_heading id="settings" icon="hero-cog-6-tooth" label="Settings" />
      <p>
        The Settings page (<code>/settings</code>) lets you tune brain behavior at runtime:
        semantic similarity threshold, auto-linking, page augmenter on/off, and more — stored
        in the database, no restart needed.
      </p>
    </div>
    """
  end

  # ── Auth Reference ──

  def auth_reference(assigns) do
    ~H"""
    <div class="prose prose-base dark:prose-invert max-w-none space-y-6">
      <.toc items={[
        {"authentication", "Authentication"},
        {"environment-variables", "Environment variables"},
        {"web-ui-authentication", "Web UI authentication"},
        {"api-authentication", "API authentication"},
        {"mcp-authentication", "MCP authentication"},
        {"configuring-mcp-client", "Configuring an MCP client"},
        {"runtime-settings", "Runtime Settings"},
        {"security-notes", "Security notes"}
      ]} />

      <.h2_heading id="authentication" icon="hero-key" label="Authentication" />
      <p>
        Dran uses single-user authentication. The same credentials protect both the
        web UI (session-based) and the REST/MCP API (bearer token). Credentials are
        read from environment variables at startup.
      </p>

      <.h2_heading id="environment-variables" icon="hero-cog-6-tooth" label="Environment variables" />
      <div class="not-prose overflow-x-auto rounded-lg border border-base-300">
        <table class="w-full text-sm">
          <thead class="bg-base-200 text-left">
            <tr>
              <th class="px-4 py-2 font-semibold">{gettext("Variable")}</th>
              <th class="px-4 py-2 font-semibold">{gettext("Default")}</th>
              <th class="px-4 py-2 font-semibold">{gettext("Purpose")}</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-base-300">
            <tr class="hover:bg-base-200/50 transition-colors">
              <td class="px-4 py-2 font-mono text-primary">DRAN_USERNAME</td>
              <td class="px-4 py-2 font-mono text-base-content/60">admin</td>
              <td class="px-4 py-2">Web login username</td>
            </tr>
            <tr class="hover:bg-base-200/50 transition-colors">
              <td class="px-4 py-2 font-mono text-primary">DRAN_PASSWORD</td>
              <td class="px-4 py-2 font-mono text-base-content/60">dran</td>
              <td class="px-4 py-2">Web login password</td>
            </tr>
            <tr class="hover:bg-base-200/50 transition-colors">
              <td class="px-4 py-2 font-mono text-primary">DRAN_API_TOKEN</td>
              <td class="px-4 py-2 font-mono text-base-content/60">dran-token</td>
              <td class="px-4 py-2">Bearer token for API and MCP</td>
            </tr>
            <tr class="hover:bg-base-200/50 transition-colors">
              <td class="px-4 py-2 font-mono text-primary">DRAN_INFERENCE_URL</td>
              <td class="px-4 py-2 font-mono text-base-content/60">http://localhost:8080/v1</td>
              <td class="px-4 py-2">LLM inference endpoint</td>
            </tr>
            <tr class="hover:bg-base-200/50 transition-colors">
              <td class="px-4 py-2 font-mono text-primary">DRAN_INFERENCE_API_KEY</td>
              <td class="px-4 py-2 font-mono text-base-content/60">(empty)</td>
              <td class="px-4 py-2">API key for inference endpoint</td>
            </tr>
            <tr class="hover:bg-base-200/50 transition-colors">
              <td class="px-4 py-2 font-mono text-primary">DRAN_EMBEDDING_MODEL</td>
              <td class="px-4 py-2 font-mono text-base-content/60">nomic-embed-text</td>
              <td class="px-4 py-2">Embedding model name</td>
            </tr>
            <tr class="hover:bg-base-200/50 transition-colors">
              <td class="px-4 py-2 font-mono text-primary">DRAN_CHAT_MODEL</td>
              <td class="px-4 py-2 font-mono text-base-content/60">qwen3</td>
              <td class="px-4 py-2">Chat/LLM model name</td>
            </tr>
          </tbody>
        </table>
      </div>

      <h3 id="web-ui-authentication" class="scroll-mt-20">Web UI authentication</h3>
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

      <h3 id="api-authentication" class="scroll-mt-20">API authentication</h3>
      <p>
        All endpoints under <code>/api</code>
        require a Bearer token in the <code>Authorization</code>
        header:
      </p>
      <.code_block
        id="auth-api-curl"
        code={DranWeb.DocsContent.auth_api_curl()}
      />
      <p>
        Without a valid token, the API responds with <code>401 Unauthorized</code>.
      </p>

      <h3 id="mcp-authentication" class="scroll-mt-20">MCP authentication</h3>
      <p>
        The MCP endpoint at <code>/api/mcp</code> uses the same Bearer token.
        MCP clients should send the token in the <code>Authorization</code> header
        of every request:
      </p>
      <.code_block
        id="auth-mcp-headers"
        code="POST /api/mcp\nAuthorization: Bearer ***\nContent-Type: application/json"
      />

      <h3 id="configuring-mcp-client" class="scroll-mt-20">Configuring an MCP client</h3>
      <p>
        To use Dran with an MCP-compatible client (e.g. Claude Desktop), add this
        to your client config, including the bearer token:
      </p>
      <.code_block
        id="auth-mcp-config"
        code={"{\"mcpServers\": {\"dran\": {\"url\": \"http://localhost:4000/api/mcp\", \"headers\": {\"Authorization\": \"Bearer dran-token\"}}}}"}
      />

      <h3 id="runtime-settings" class="scroll-mt-20">Runtime Settings</h3>
      <p>
        Brain behavior can be tuned at runtime without restarting. Settings are stored
        in the database and managed via the Settings page (/settings) or the API.
        Key settings include similarity threshold, page augmenter toggle, and auto-linking.
      </p>

      <h3 id="security-notes" class="scroll-mt-20">Security notes</h3>
      <.callout variant={:warning}>
        <ul class="space-y-1">
          <li>Change the default credentials in production via environment variables.</li>
          <li>The API token grants full read/write access — protect it like a password.</li>
          <li>Use HTTPS in production to prevent credential interception.</li>
          <li>There is no multi-user support; the same credentials are used by everyone.</li>
        </ul>
      </.callout>
    </div>
    """
  end

  # ── API Reference ──

  def api_reference(assigns) do
    ~H"""
    <div class="prose prose-base dark:prose-invert max-w-none space-y-6">
      <.toc items={[
        {"rest-api", "REST API"},
        {"contexts-api", "Contexts"},
        {"pages-api", "Pages"},
        {"relations-api", "Relations"},
        {"search-api", "Search"},
        {"goals-api", "Goals"},
        {"todos-api", "Todos"},
        {"ingest-api", "Ingest"},
        {"maintenance-api", "Maintenance"},
        {"wiki-api", "Wiki"},
        {"export-api", "Export"},
        {"settings-api", "Settings"}
      ]} />

      <.h2_heading id="rest-api" icon="hero-command-line" label="REST API" />
      <p>
        All endpoints are served under <code>/api</code> and return JSON. Most endpoints
        accept a <code>context</code> query parameter (context slug) to scope the operation.
      </p>

      <div class="not-prose overflow-x-auto rounded-lg border border-base-300">
        <table class="w-full text-sm">
          <thead class="bg-base-200 text-left">
            <tr>
              <th class="px-4 py-2 font-semibold">{gettext("Method")}</th>
              <th class="px-4 py-2 font-semibold">{gettext("Endpoint")}</th>
              <th class="px-4 py-2 font-semibold">{gettext("Description")}</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-base-300">
            <tr :for={ep <- api_endpoints()} class="hover:bg-base-200/50 transition-colors">
              <td class="px-4 py-2">
                <span class={[
                  "rounded px-1.5 py-0.5 text-xs font-mono font-semibold",
                  method_class(ep.method)
                ]}>
                  {ep.method}
                </span>
              </td>
              <td class="px-4 py-2 font-mono text-primary break-all">{ep.path}</td>
              <td class="px-4 py-2 text-base-content/60">{ep.desc}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  defp agents_data do
    [
      %{
        label: "Research",
        icon: "hero-magnifying-glass-circle",
        color: "text-blue-500 dark:text-blue-400",
        trigger: :manual,
        schedule: nil,
        description:
          "Explores a topic: searches the web, scrapes sources, and creates note/reference pages with citations.",
        limits: "Max 10 sources, 10 pages, 10 searches (configurable via Settings)."
      },
      %{
        label: "Ingest",
        icon: "hero-arrow-down-on-square",
        color: "text-cyan-500 dark:text-cyan-400",
        trigger: :manual,
        schedule: nil,
        description:
          "Validates, inspects, and downloads a single URL to create a reference page.",
        limits: "File download limit 100 MiB."
      },
      %{
        label: "Ask (Q&A)",
        icon: "hero-chat-bubble-left-right",
        color: "text-violet-500 dark:text-violet-400",
        trigger: :manual,
        schedule: nil,
        description:
          "Answers a question using ONLY knowledge already in the brain. Persists the answer as a query page citing sources.",
        limits: "Max 5 searches; one query page per session."
      },
      %{
        label: "Curator",
        icon: "hero-shield-check",
        color: "text-amber-500 dark:text-amber-400",
        trigger: :scheduled,
        schedule: "Daily 06:00",
        description:
          "Reviews page pairs with very similar embeddings, flags duplicates and contested knowledge, writes a cleanup report.",
        limits: "Max 20 flags per session; duplicate threshold 0.05."
      },
      %{
        label: "Link Gardener",
        icon: "hero-link",
        color: "text-emerald-500 dark:text-emerald-400",
        trigger: :manual,
        schedule: nil,
        description:
          "Reads orphaned and under-linked pages, proposes typed relations with justifications.",
        limits: "Max 10 proposals per session; semantic type forbidden."
      },
      %{
        label: "Weekly Review",
        icon: "hero-calendar-days",
        color: "text-rose-500 dark:text-rose-400",
        trigger: :scheduled,
        schedule: "Sun 08:00",
        description:
          "Gathers brain stats and writes a weekly review journal page with activity, goals progress, and highlights.",
        limits: "Window: pages created in last 7 days. Output in Spanish."
      }
    ]
  end

  defp api_endpoints do
    [
      %{group: "Contexts", method: "GET", path: "/api/contexts", desc: "List all contexts"},
      %{group: "Contexts", method: "POST", path: "/api/contexts", desc: "Create a context"},
      %{
        group: "Contexts",
        method: "GET",
        path: "/api/contexts/:slug",
        desc: "Get a context by slug"
      },
      %{group: "Contexts", method: "PUT", path: "/api/contexts/:slug", desc: "Update a context"},
      %{
        group: "Contexts",
        method: "DELETE",
        path: "/api/contexts/:slug",
        desc: "Delete a context"
      },
      %{
        group: "Pages",
        method: "GET",
        path: "/api/pages",
        desc: "List pages (filters: context, type, tag, status, owner, limit)"
      },
      %{group: "Pages", method: "POST", path: "/api/pages", desc: "Create a page"},
      %{group: "Pages", method: "GET", path: "/api/pages/:slug", desc: "Get a page"},
      %{group: "Pages", method: "PUT", path: "/api/pages/:slug", desc: "Update a page"},
      %{group: "Pages", method: "DELETE", path: "/api/pages/:slug", desc: "Delete a page"},
      %{
        group: "Pages",
        method: "GET",
        path: "/api/pages/:slug/links",
        desc: "Inbound + outbound relations"
      },
      %{
        group: "Pages",
        method: "GET",
        path: "/api/pages/:slug/graph",
        desc: "Subgraph centered on a page"
      },
      %{
        group: "Pages",
        method: "GET",
        path: "/api/pages/:slug/backlinks",
        desc: "Pages that reference this page, grouped by relation type"
      },
      %{
        group: "Pages",
        method: "GET",
        path: "/api/pages/:slug/diff?v1=N&v2=M",
        desc: "Version diff between two versions"
      },
      %{
        group: "Relations",
        method: "POST",
        path: "/api/relations",
        desc: "Create a relation (source, target, relation_type)"
      },
      %{
        group: "Relations",
        method: "DELETE",
        path: "/api/relations/:id",
        desc: "Delete a relation"
      },
      %{
        group: "Search",
        method: "GET",
        path: "/api/search?q=...&context=...&type=...",
        desc: "Full-text search"
      },
      %{
        group: "Search",
        method: "GET",
        path: "/api/search/fuzzy?q=...&context=...",
        desc: "Fuzzy search"
      },
      %{group: "Goals", method: "GET", path: "/api/goals?context=...", desc: "List goals"},
      %{
        group: "Goals",
        method: "GET",
        path: "/api/goals/:slug?context=...",
        desc: "Goal detail with todos and plans"
      },
      %{
        group: "Todos",
        method: "GET",
        path: "/api/todos?context=...&status=...",
        desc: "List todos (filterable by kanban status)"
      },
      %{group: "Todos", method: "POST", path: "/api/todos", desc: "Create a todo"},
      %{
        group: "Todos",
        method: "PUT",
        path: "/api/todos/:id",
        desc: "Update a todo (e.g. change status)"
      },
      %{group: "Ingest", method: "POST", path: "/api/ingest", desc: "Ingest a URL as a raw page"},
      %{
        group: "Maintenance",
        method: "GET",
        path: "/api/lint?context=...",
        desc: "Lint pages for quality issues"
      },
      %{
        group: "Maintenance",
        method: "GET",
        path: "/api/log?context=...&action=...&limit=...",
        desc: "Activity log"
      },
      %{
        group: "Wiki",
        method: "GET",
        path: "/api/index?context=...",
        desc: "Wiki index (all page slugs + titles)"
      },
      %{
        group: "Wiki",
        method: "GET",
        path: "/api/graph?context=...",
        desc: "Full graph (nodes + edges)"
      },
      %{
        group: "Wiki",
        method: "GET",
        path: "/api/graph/3d?context=...",
        desc: "3D graph data (nodes with x,y,z coords)"
      },
      %{
        group: "Export",
        method: "GET",
        path: "/api/export/:context/full",
        desc: "Full brain export (all pages + relations + metadata as JSON)"
      },
      %{
        group: "Settings",
        method: "GET",
        path: "/api/settings",
        desc: "List all runtime settings"
      },
      %{
        group: "Settings",
        method: "PUT",
        path: "/api/settings/:key",
        desc: "Update a setting value"
      }
    ]
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
      <.toc items={[
        {"mcp-endpoint", "MCP (Model Context Protocol)"},
        {"session-management", "Session management"},
        {"agent-quick-start", "Agent Quick Start"},
        {"page-types", "Page Types & Subtypes"},
        {"embeds", "Embeds"},
        {"available-tools", "Available tools"},
        {"resources", "Resources"},
        {"prompts", "Prompts"},
        {"example-initialize", "Example: initialize session"}
      ]} />

      <.h2_heading id="mcp-endpoint" icon="hero-command-line" label="MCP (Model Context Protocol)" />
      <p>
        Dran exposes an MCP endpoint at <code>/api/mcp</code> using the Streamable HTTP
        transport. AI agents can connect to Dran and use it as a knowledge tool.
      </p>

      <h3 id="mcp-endpoint-methods">Endpoint</h3>
      <.code_block
        id="mcp-endpoint-list"
        code="POST /api/mcp   - send JSON-RPC message\nGET /api/mcp    - open SSE stream (optional, returns 405 if unsupported)\nDELETE /api/mcp - terminate session"
      />

      <h3 id="session-management" class="scroll-mt-20">Session management</h3>
      <p>
        The server returns a <code>Mcp-Session-Id</code> header on the first request. Include
        this header in subsequent requests to maintain session state.
      </p>

      <.h2_heading id="agent-quick-start" icon="hero-rocket-launch" label="Agent Quick Start" />
      <p>
        When an agent connects to Dran, it should follow this workflow:
      </p>
      <ol>
        <li>
          <strong>Search</strong>
          — use <code>dran_search</code>
          to find existing pages before creating new ones.
        </li>
        <li>
          <strong>Read</strong>
          — use <code>dran_get_page</code>
          to read full content, or <code>dran_list_pages</code>
          for a filtered overview.
        </li>
        <li>
          <strong>Create</strong>
          — use <code>dran_create_page</code>
          with the appropriate <code>page_type</code>
          and <code>meta</code>. Use <code>dran_create_todo</code>
          for action items.
        </li>
        <li>
          <strong>Update</strong>
          — use <code>dran_update_page</code>
          to refine content. Use <code>dran_update_todo</code>
          to change a todo's status (merges meta).
        </li>
        <li>
          <strong>Delete</strong>
          — use <code>dran_delete_page</code>
          to remove a page (cascades to relations + versions).
        </li>
        <li>
          <strong>Relate</strong>
          — use <code>dran_create_relation</code>
          for typed relationships. Use <code>dran_delete_relation</code>
          to remove. Embeds (<code>![[slug]]</code>) auto-create <code>embeds</code>
          relations.
        </li>
        <li>
          <strong>Inspect</strong>
          — use <code>dran_get_links</code>
          to see inbound + outbound relations for a page.
        </li>
        <li>
          <strong>Stats</strong>
          — use <code>dran_get_stats</code>
          for a context overview (page counts, todos by status, orphans).
        </li>
        <li>
          <strong>Rename</strong>
          — use <code>dran_rename_slug</code>
          to rename a page slug. Update existing <code>![[slug]]</code>
          embeds manually if needed.
        </li>
        <li>
          <strong>Agents</strong>
          — use <code>dran_start_agent</code>
          to delegate tasks to autonomous agents (research, ingest, ask, curator, link_gardener, weekly_review).
          Poll <code>dran_get_agent_session</code>
          for progress and results.
        </li>
        <li>
          <strong>Files Ingest</strong>
          — use <code>dran_ingest_url</code>
          to save web pages or download files as references.
        </li>
        <li>
          <strong>Lint</strong> — use <code>dran_lint_brain</code> to find orphans and stale pages.
        </li>
      </ol>

      <.h2_heading id="page-types" icon="hero-document-text" label="Page Types & Subtypes" />
      <p>
        Every page has a <code>page_type</code>
        that determines its purpose. Some types have a <code>kind</code>
        sub-type (set in <code>meta.kind</code>). Knowing the right type helps
        the agent structure knowledge correctly.
      </p>

      <div class="not-prose overflow-x-auto rounded-lg border border-base-300">
        <table class="w-full text-sm">
          <thead class="bg-base-200 text-left">
            <tr>
              <th class="px-4 py-2 font-semibold">{gettext("Type")}</th>
              <th class="px-4 py-2 font-semibold">{gettext("Purpose")}</th>
              <th class="px-4 py-2 font-semibold">{gettext("Subtypes (meta.kind)")}</th>
              <th class="px-4 py-2 font-semibold">{gettext("Key meta fields")}</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-base-300">
            <tr class="hover:bg-base-200/50 transition-colors">
              <td class="px-4 py-2 font-mono text-primary">note</td>
              <td class="px-4 py-2">Ephemeral thoughts, journal, ideas</td>
              <td class="px-4 py-2 text-xs">thought, journal, idea, meeting, question, quote</td>
              <td class="px-4 py-2 text-xs">kind, date, attendees, author</td>
            </tr>
            <tr class="hover:bg-base-200/50 transition-colors">
              <td class="px-4 py-2 font-mono text-primary">concept</td>
              <td class="px-4 py-2">Abstract ideas, techniques, theories</td>
              <td class="px-4 py-2 text-xs">technique, pattern, discipline, theory</td>
              <td class="px-4 py-2 text-xs">kind, domain, parent_concept</td>
            </tr>
            <tr class="hover:bg-base-200/50 transition-colors">
              <td class="px-4 py-2 font-mono text-primary">entity</td>
              <td class="px-4 py-2">Concrete things (people, companies, tools)</td>
              <td class="px-4 py-2 text-xs">person, company, product, tool, place, event</td>
              <td class="px-4 py-2 text-xs">kind, aliases, external_url, location</td>
            </tr>
            <tr class="hover:bg-base-200/50 transition-colors">
              <td class="px-4 py-2 font-mono text-primary">reference</td>
              <td class="px-4 py-2">External sources (articles, papers, videos)</td>
              <td class="px-4 py-2 text-xs">article, paper, video, podcast, book</td>
              <td class="px-4 py-2 text-xs">kind, source_url, published_at</td>
            </tr>
            <tr class="hover:bg-base-200/50 transition-colors">
              <td class="px-4 py-2 font-mono text-primary">artifact</td>
              <td class="px-4 py-2">Files and deliverables (uploaded via UI)</td>
              <td class="px-4 py-2 text-xs">document, code, design, deliverable, file</td>
              <td class="px-4 py-2 text-xs">kind, filename, mime_type, storage_path, sha256</td>
            </tr>
            <tr class="hover:bg-base-200/50 transition-colors">
              <td class="px-4 py-2 font-mono text-primary">goal</td>
              <td class="px-4 py-2">Objectives with target dates and health</td>
              <td class="px-4 py-2 text-xs text-base-content/40">—</td>
              <td class="px-4 py-2 text-xs">
                health (green/yellow/red), target_date, start_date, team
              </td>
            </tr>
            <tr class="hover:bg-base-200/50 transition-colors">
              <td class="px-4 py-2 font-mono text-primary">plan</td>
              <td class="px-4 py-2">Time-horizoned plans</td>
              <td class="px-4 py-2 text-xs text-base-content/40">—</td>
              <td class="px-4 py-2 text-xs">
                horizon (weekly/monthly/quarterly/yearly), status, period, goal_slug
              </td>
            </tr>
            <tr class="hover:bg-base-200/50 transition-colors">
              <td class="px-4 py-2 font-mono text-primary">todo</td>
              <td class="px-4 py-2">Actionable items with kanban status</td>
              <td class="px-4 py-2 text-xs text-base-content/40">—</td>
              <td class="px-4 py-2 text-xs">
                kanban_status (backlog/this_week/today/in_progress/done/cancelled), priority (low/medium/high/urgent), goal_slug, plan_slug, due_date
              </td>
            </tr>
            <tr class="hover:bg-base-200/50 transition-colors">
              <td class="px-4 py-2 font-mono text-primary">comparison</td>
              <td class="px-4 py-2">Side-by-side comparison of entities</td>
              <td class="px-4 py-2 text-xs text-base-content/40">—</td>
              <td class="px-4 py-2 text-xs">entities, criteria, verdict</td>
            </tr>
            <tr class="hover:bg-base-200/50 transition-colors">
              <td class="px-4 py-2 font-mono text-primary">query</td>
              <td class="px-4 py-2">Question with answer (LLM wiki style)</td>
              <td class="px-4 py-2 text-xs">factual, conceptual, how_to, opinion</td>
              <td class="px-4 py-2 text-xs">
                kind, difficulty (simple/intermediate/advanced), status (open/answered/verified), answered_by
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <.h2_heading id="embeds" icon="hero-paper-clip" label="Embeds" />
      <p>
        Use <code>![[slug]]</code>
        in page bodies to embed an artifact (image, video, audio, PDF). Embeds
        are auto-resolved into <code>embeds</code>
        relations. Plain <code>[[slug]]</code>
        wikilinks are no longer supported — relations are
        created automatically via embeddings or explicitly via <code>dran_create_relation</code>.
      </p>

      <.h2_heading id="available-tools" icon="hero-wrench-screwdriver" label="Available tools" />
      <p>
        Once connected, the MCP server exposes the following tools that agents can call:
      </p>

      <div class="not-prose space-y-3">
        <.mcp_tool
          name="dran_search"
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
          name="dran_get_page"
          desc="Get a page by slug. Returns full markdown content + metadata."
        >
          <:param name="slug" type="string" required="yes" desc="Page slug" />
          <:param name="context" type="string" required="yes" desc="Context slug" />
        </.mcp_tool>

        <.mcp_tool
          name="dran_list_pages"
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
          <:param
            name="goal_slug"
            type="string"
            required="no"
            desc="Filter by goal slug ('none' for orphans)"
          />
          <:param
            name="plan_slug"
            type="string"
            required="no"
            desc="Filter by plan slug ('none' for orphans)"
          />
          <:param name="limit" type="integer" required="no" desc="Max results (default 50, max 500)" />
        </.mcp_tool>

        <.mcp_tool
          name="dran_create_page"
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
          name="dran_update_page"
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
          name="dran_delete_page"
          desc="Delete a page by slug. Cascades to relations and page versions. Irreversible."
        >
          <:param name="context" type="string" required="yes" desc="Context slug" />
          <:param name="slug" type="string" required="yes" desc="Slug of the page to delete" />
        </.mcp_tool>

        <.mcp_tool
          name="dran_create_todo"
          desc="Create a todo with kanban status and priority, optionally linked to a goal and/or plan."
        >
          <:param name="context" type="string" required="yes" desc="Context slug" />
          <:param name="title" type="string" required="yes" desc="Todo title" />
          <:param name="slug" type="string" required="yes" desc="Todo slug" />
          <:param name="goal_slug" type="string" required="no" desc="Goal this todo belongs to" />
          <:param
            name="plan_slug"
            type="string"
            required="no"
            desc="Plan this todo belongs to (goal derived from plan)"
          />
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
          name="dran_update_todo"
          desc="Update a todo's status, priority, due date, goal, or plan. Merges meta — only pass changed fields."
        >
          <:param name="context" type="string" required="yes" desc="Context slug" />
          <:param name="slug" type="string" required="yes" desc="Todo slug to update" />
          <:param name="kanban_status" type="string" required="no" desc="New kanban status" />
          <:param name="priority" type="string" required="no" desc="New priority" />
          <:param name="due_date" type="string" required="no" desc="New due date YYYY-MM-DD" />
          <:param name="goal_slug" type="string" required="no" desc="New goal slug" />
          <:param name="plan_slug" type="string" required="no" desc="New plan slug" />
          <:param name="title" type="string" required="no" desc="New title" />
          <:param name="body" type="string" required="no" desc="New body (markdown)" />
          <:param name="tags" type="array" required="no" desc="New tags (replaces existing)" />
        </.mcp_tool>

        <.mcp_tool
          name="dran_create_relation"
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
          name="dran_delete_relation"
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
          name="dran_get_links"
          desc="Get all inbound + outbound relations for a page. Shows inbound and outbound graph connections."
        >
          <:param name="context" type="string" required="yes" desc="Context slug" />
          <:param name="slug" type="string" required="yes" desc="Page slug" />
        </.mcp_tool>

        <.mcp_tool
          name="dran_get_stats"
          desc="Aggregate statistics for a context. Returns page counts, todos by status, orphans, and total relations."
        >
          <:param name="context" type="string" required="yes" desc="Context slug" />
        </.mcp_tool>

        <.mcp_tool
          name="dran_lint_brain"
          desc="Quality report: orphans, stale pages, and contested knowledge."
        >
          <:param name="context" type="string" required="yes" desc="Context slug" />
        </.mcp_tool>

        <.mcp_tool
          name="dran_rename_slug"
          desc="Rename a page's slug. Existing ![[slug]] embeds are not updated automatically."
        >
          <:param name="context" type="string" required="yes" desc="Context slug" />
          <:param name="old_slug" type="string" required="yes" desc="Current slug to rename" />
          <:param name="new_slug" type="string" required="yes" desc="New slug (kebab-case)" />
        </.mcp_tool>

        <.mcp_tool
          name="dran_reaugment_page"
          desc="Re-run the augmentation pipeline (summary/tags/embedding/relations) for a page. Use after major edits."
        >
          <:param name="context" type="string" required="yes" desc="Context slug" />
          <:param name="slug" type="string" required="yes" desc="Slug of the page to reaugment" />
        </.mcp_tool>

        <.mcp_tool
          name="dran_ingest_url"
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
          name="dran_start_agent"
          desc="Start an autonomous agent session. Returns immediately; poll dran_get_agent_session for progress."
        >
          <:param
            name="agent_type"
            type="string"
            required="yes"
            desc="research, ingest, ask, curator, link_gardener, weekly_review"
          />
          <:param name="context" type="string" required="yes" desc="Context slug" />
          <:param name="input" type="string" required="yes" desc="Topic, URL, or query" />
          <:param name="opts" type="object" required="no" desc="Optional agent options" />
        </.mcp_tool>

        <.mcp_tool
          name="dran_get_agent_session"
          desc="Poll an agent session for status, summary, and steps."
        >
          <:param name="session_id" type="string" required="yes" desc="Agent session UUID" />
        </.mcp_tool>
      </div>

      <.h2_heading id="resources" icon="hero-archive-box" label="Resources" />
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
      </div>

      <.h2_heading id="prompts" icon="hero-sparkles" label="Prompts" />
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

      <.h2_heading
        id="example-initialize"
        icon="hero-code-bracket"
        label="Example: initialize session"
      />
      <.code_block
        id="mcp-example-init"
        code={"{\"jsonrpc\": \"2.0\", \"id\": 1, \"method\": \"initialize\",\n \"params\": {\"protocolVersion\": \"2025-03-26\", \"capabilities\": {},\n            \"clientInfo\": {\"name\": \"my-agent\", \"version\": \"1.0\"}}}"}
      />
      <p>
        The response includes a <code>Mcp-Session-Id</code> header. Use it in subsequent requests:
      </p>
      <.code_block
        id="mcp-example-call"
        code={"{\"jsonrpc\": \"2.0\", \"id\": 2, \"method\": \"tools/call\",\\n \"params\": {\"name\": \"dran_search\",\\n            \"arguments\": {\"query\": \"elixir\", \"context\": \"personal\"}}}"}
      />

      <h3 id="mcp-client-configuration" class="scroll-mt-20">Client configuration</h3>
      <p>
        To use Dran with an MCP-compatible client (e.g. Claude Desktop), add this to your
        client config:
      </p>
      <.code_block
        id="mcp-client-config"
        code={"{\"mcpServers\": {\"dran\": {\"url\": \"http://localhost:4000/api/mcp\", \"headers\": {\"Authorization\": \"Bearer dran-token\"}}}}"}
      />
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
