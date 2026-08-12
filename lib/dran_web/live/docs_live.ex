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
                const copied = () => {
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
                };
                if (navigator.clipboard && navigator.clipboard.writeText) {
                  navigator.clipboard.writeText(text).then(copied);
                } else {
                  this.copyFallback(text);
                  copied();
                }
              }
            });
          },
          copyFallback(text) {
            const ta = document.createElement("textarea");
            ta.value = text;
            ta.setAttribute("readonly", "");
            ta.style.position = "absolute";
            ta.style.left = "-9999px";
            document.body.appendChild(ta);
            ta.select();
            ta.setSelectionRange(0, text.length);
            try {
              document.execCommand("copy");
            } catch (_e) {
              // noop
            }
            document.body.removeChild(ta);
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
        <li>
          Organize work with projects, goals, plans and todos — all visible on the global kanban
        </li>
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
        {"planning-model", "Planning model"},
        {"graph-intelligence", "Graph intelligence"},
        {"props", "Custom props"},
        {"view-edit-modes", "View & edit modes"},
        {"graph-3d", "3D graph navigation"},
        {"real-time", "Real-time updates"},
        {"disabled-types", "Type disabling"}
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
        <li>
          <strong>query</strong>
          — questions with answers, linked semantically to concepts and entities
        </li>
        <li><strong>project</strong> — initiatives grouping goals, plans and todos</li>
        <li>
          <strong>report</strong>
          — system-created run logs (jobs and agent runs); detail view only at
          <code>/reports/:slug</code>
          — outside the graph, journey and embeddings
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
          — source embeds target (e.g. a note embeds a file via <code>![[slug]]</code>)
        </li>
        <li>
          <strong>semantic</strong>
          — auto-created by the PageAugmenter when two pages are semantically similar
        </li>
        <li>
          <strong>mentions</strong> — source mentions the target entity (created by the entity linker)
        </li>
      </ul>
      <p>
        Five more types are materialized automatically from <code>meta.props</code>
        (<code>works_in</code>, <code>has_tier</code>, <code>based_in</code>, <code>written_in</code>, <code>built_with</code>) — see
        <a href="#docs-props" class="text-primary hover:underline">Custom props</a>
        below.
      </p>

      <.h2_heading id="knowledge-graph" icon="hero-circle-stack" label="Knowledge graph" />
      <p>
        Pages and relations form a directed graph. The <code>/graph</code>
        view renders the full
        graph in 3D with zoom and pan. Each page detail view also has a <strong>Graph</strong>
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
        id="planning-model"
        icon="hero-clipboard-document-check"
        label="Planning model (independent links)"
      />
      <p>
        Dran has no rigid planning hierarchy — every page is an orphan by default and the
        three link slugs are independent: <code>meta.project_slug</code>, <code>meta.goal_slug</code>
        and <code>meta.plan_slug</code>. There is no precedence between them; each one
        materializes its own <code>part_of</code>
        relation when set, and a page may carry
        0, 1, 2 or all 3 slugs at once. Use <code>dran_list_pages</code>
        with the <code>project_slug</code>, <code>goal_slug</code>
        or <code>plan_slug</code>
        filters
        (value <code>"none"</code>
        returns orphans — the GTD inbox).
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
        Dran runs pure-Elixir structural algorithms over the relations
        table (<code>Dran.Graph</code>) — weighted <strong>PageRank</strong>,
        <strong>Label Propagation</strong>
        communities, and transitive <code>part_of</code>
        inference used by the
        Link Gardener. Results are persisted into each page's <code>meta</code>
        and refreshed nightly by the <code>pagerank_nightly</code>
        Quantum job (03:00 daily).
      </p>
      <.code_block
        id="graph-intelligence-doc"
        code={DranWeb.DocsContent.graph_intelligence_doc()}
      />

      <.h2_heading id="props" icon="hero-tag" label="Custom props (meta.props)" />
      <p>
        Every page may carry <code>meta.props</code>: a free-form key-value bag for
        metadata that doesn't fit the typed fields. Five prop keys auto-create
        typed graph relations during augmentation:
      </p>
      <ul>
        <li><code>role</code> → <code>works_in</code> → entity</li>
        <li><code>tier</code> → <code>has_tier</code> → concept</li>
        <li><code>location</code> → <code>based_in</code> → entity</li>
        <li><code>language</code> → <code>written_in</code> → entity</li>
        <li><code>framework</code> → <code>built_with</code> → entity</li>
      </ul>
      <p>
        Other keys are stored but generate no edge. Props are GIN-indexed and
        backfillable via Settings → Brain → "Run backfill".
      </p>

      <.h2_heading id="view-edit-modes" icon="hero-eye" label="Read-only view & edit mode" />
      <p>
        Page detail views show rendered markdown + mermaid diagrams by default
        (read-only mode). Click the <strong>Edit</strong> button to switch to
        the TipTap editor. In the editor, mermaid code blocks display as raw
        source (editable text) — click <strong>Preview</strong> on the block to
        see the SVG diagram. Click <strong>View</strong> to return to read-only.
      </p>

      <.h2_heading id="graph-3d" icon="hero-share" label="3D graph navigation" />
      <p>
        The graph at <code>/graph</code>
        renders the full knowledge graph in
        3D. Hover a node to highlight it and its direct neighbors — the rest
        of the graph dims after a brief (~300ms) delay; no text labels are
        rendered. Click a node to navigate to that page. Background click
        clears the selection. Per-page subgraphs at <code>/graph/:slug</code>
        show a page's neighborhood.
      </p>

      <.h2_heading id="real-time" icon="hero-bolt" label="Real-time updates" />
      <p>
        When a page changes (edited, created, deleted, archived) anywhere in
        the app — another tab, an agent, an MCP call — all open page detail
        views reload automatically via Phoenix PubSub. The 3D graph also
        debounces and re-fetches on changes.
      </p>

      <.h2_heading id="disabled-types" icon="hero-eye-slash" label="Per-context type disabling" />
      <p>
        Each context can disable page types via Settings → Contexts → "Page
        types". Disabled types are hidden from the sidebar, dashboard, command
        palette, and direct URL access is blocked by an <code>on_mount</code>
        hook that redirects to the dashboard. Creating a page of a disabled
        type is rejected in the web UI and via MCP (<code>page type 'X' is
        disabled in context 'Y'</code>), and disabled types are excluded from
        <code>Brain.list_pages</code>
        results.
      </p>
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
        Dran runs three autonomous ReAct agents that plan, act, and log every step. Some are
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
        The <code>/kanban</code> page is a global full-viewport kanban board with 6 columns
        (backlog, this_week, today, in_progress, done, cancelled) covering every todo in the
        context. You can drag and drop cards between columns to update their <code>kanban_status</code>, and combine the Project / Goal / Plan filters
        (each with All / None — orphans — / &lt;slug&gt;). Cards show link badges; click a
        badge to filter the board by that link. The board updates in real
        time — when an autonomous agent creates or moves a todo, the change is pushed to all
        connected clients via PubSub. The <code>/todos</code> page offers the same board
        scoped to the todo page type.
      </p>

      <.h2_heading
        id="using-dran-from-agents"
        icon="hero-command-line"
        label="Using Dran from agents"
      />
      <p>
        AI agents can connect to Dran via the MCP endpoint at <code>/api/mcp</code> using the
        Streamable HTTP transport. The repository includes a <code>skills/</code> directory with the
        full operational manual suite for agent integration (<code>skills/dran/SKILL.md</code> plus
        per-flow skills). To verify your MCP schema is live and
        correct, run <code>scripts/mcp_smoke.sh</code> — it exercises the tools list and validates
        the response schema.
      </p>
      <.code_block
        id="agent-connect-example"
        code={DranWeb.DocsContent.agent_connect_example()}
      />

      <.h2_heading id="settings" icon="hero-cog-6-tooth" label="Settings" />
      <p>
        The Settings page (<code>/settings/:tab</code>, admin only) is organized in tabs:
        <strong>Users</strong>
        (accounts and per-user API tokens), <strong>Contexts</strong>
        (context CRUD, member management, per-context page-type toggles), <strong>API keys</strong>
        (context-scoped keys for REST/MCP), <strong>Brain</strong>
        (runtime tuning — semantic thresholds, agent limits, entity-linker toggle, props
        backfill, and the scheduled-jobs panel with per-job toggles and "run now" buttons),
        <strong>Models</strong>
        (inference model overrides), <strong>System</strong>
        and <strong>Danger zone</strong>. Changes are stored in the database — no restart needed.
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
        Dran is multi-user. Web accounts live in the database: the first one is created
        by the <code>/setup</code>
        flow on first run (becomes the admin), and the admin
        creates additional users from Settings → Users. Optionally, "Sign in with Google"
        can be enabled via environment variables — it only logs in existing users, unless
        <code>GOOGLE_OAUTH_ALLOWED_DOMAINS</code>
        is set to auto-register trusted domains.
        The REST/MCP API is protected by bearer tokens (see below).
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
              <td class="px-4 py-2 font-mono text-primary">SECRET_KEY_BASE</td>
              <td class="px-4 py-2 font-mono text-base-content/60">(required)</td>
              <td class="px-4 py-2">Session signing — generate with mix phx.gen.secret</td>
            </tr>
            <tr class="hover:bg-base-200/50 transition-colors">
              <td class="px-4 py-2 font-mono text-primary">DATABASE_URL</td>
              <td class="px-4 py-2 font-mono text-base-content/60">
                ecto://postgres:postgres@localhost/dran_dev
              </td>
              <td class="px-4 py-2">Ecto connection URL</td>
            </tr>
            <tr class="hover:bg-base-200/50 transition-colors">
              <td class="px-4 py-2 font-mono text-primary">PHX_HOST / PHX_PORT / PHX_SCHEME</td>
              <td class="px-4 py-2 font-mono text-base-content/60">localhost / 443 / https</td>
              <td class="px-4 py-2">Public host, port and scheme for URL generation</td>
            </tr>
            <tr class="hover:bg-base-200/50 transition-colors">
              <td class="px-4 py-2 font-mono text-primary">DISABLE_FORCE_SSL</td>
              <td class="px-4 py-2 font-mono text-base-content/60">(unset)</td>
              <td class="px-4 py-2">
                Set to 1 at BUILD time when serving over plain HTTP (VPN tunnels)
              </td>
            </tr>
            <tr class="hover:bg-base-200/50 transition-colors">
              <td class="px-4 py-2 font-mono text-primary">DRAN_API_TOKEN</td>
              <td class="px-4 py-2 font-mono text-base-content/60">dran-token</td>
              <td class="px-4 py-2">Legacy admin bearer token for REST/MCP (full access)</td>
            </tr>
            <tr class="hover:bg-base-200/50 transition-colors">
              <td class="px-4 py-2 font-mono text-primary">DRAN_CONTEXT_SLUG / DRAN_CONTEXT_NAME</td>
              <td class="px-4 py-2 font-mono text-base-content/60">personal / Personal</td>
              <td class="px-4 py-2">Default context created on seed</td>
            </tr>
            <tr class="hover:bg-base-200/50 transition-colors">
              <td class="px-4 py-2 font-mono text-primary">
                GOOGLE_OAUTH_CLIENT_ID / GOOGLE_OAUTH_CLIENT_SECRET
              </td>
              <td class="px-4 py-2 font-mono text-base-content/60">(unset)</td>
              <td class="px-4 py-2">Enables "Sign in with Google" when both are set</td>
            </tr>
            <tr class="hover:bg-base-200/50 transition-colors">
              <td class="px-4 py-2 font-mono text-primary">GOOGLE_OAUTH_ALLOWED_DOMAINS</td>
              <td class="px-4 py-2 font-mono text-base-content/60">(empty)</td>
              <td class="px-4 py-2">Domains allowed to auto-register via Google</td>
            </tr>
            <tr class="hover:bg-base-200/50 transition-colors">
              <td class="px-4 py-2 font-mono text-primary">
                DRAN_INFERENCE_API_URL / DRAN_INFERENCE_API_KEY
              </td>
              <td class="px-4 py-2 font-mono text-base-content/60">(unset)</td>
              <td class="px-4 py-2">
                OpenAI-compatible inference endpoint — powers embeddings, summaries, agents, semantic search
              </td>
            </tr>
            <tr class="hover:bg-base-200/50 transition-colors">
              <td class="px-4 py-2 font-mono text-primary">
                DRAN_INFERENCE_CHAT_MODEL / DRAN_INFERENCE_EMBEDDING_MODEL / DRAN_INFERENCE_RERANK_MODEL
              </td>
              <td class="px-4 py-2 font-mono text-base-content/60">
                Ornith-1.0-9B / Qwen3-Embedding / Qwen3-Reranker
              </td>
              <td class="px-4 py-2">Optional model overrides per capability</td>
            </tr>
            <tr class="hover:bg-base-200/50 transition-colors">
              <td class="px-4 py-2 font-mono text-primary">
                SESSION_SIGNING_SALT / SESSION_ENCRYPTION_SALT
              </td>
              <td class="px-4 py-2 font-mono text-base-content/60">(dev defaults)</td>
              <td class="px-4 py-2">Required in production (mix phx.gen.secret 32)</td>
            </tr>
            <tr class="hover:bg-base-200/50 transition-colors">
              <td class="px-4 py-2 font-mono text-primary">UPLOADS_DIR</td>
              <td class="px-4 py-2 font-mono text-base-content/60">priv/static/uploads</td>
              <td class="px-4 py-2">File upload storage path</td>
            </tr>
          </tbody>
        </table>
      </div>

      <h3 id="web-ui-authentication" class="scroll-mt-20">Web UI authentication</h3>
      <p>
        The web UI is protected by a session-based login at <code>/login</code>.
        Unauthenticated requests are redirected there. On first run the app redirects to <code>/setup</code>, which creates the admin account (email + password). When
        Google OAuth is configured, a "Sign in with Google" button appears on the login
        page.
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
        header. Three kinds of token are accepted:
      </p>
      <ul>
        <li>
          <strong>DRAN_API_TOKEN</strong> (env) — legacy admin token, full access to
          every context.
        </li>
        <li>
          <strong>Per-user API tokens</strong> — created in Settings → Users; reach only
          the contexts assigned to that user.
        </li>
        <li>
          <strong>Context API keys</strong> — created in Settings → API keys; scoped to a
          single context.
        </li>
      </ul>
      <.code_block
        id="auth-api-curl"
        code={DranWeb.DocsContent.auth_api_curl()}
      />
      <p>
        An invalid or missing token gets <code>401 Unauthorized</code>; a valid token
        without access to the requested context gets <code>403 Forbidden</code>.
      </p>

      <h3 id="mcp-authentication" class="scroll-mt-20">MCP authentication</h3>
      <p>
        The MCP endpoint at <code>/api/mcp</code> accepts the same three bearer-token
        kinds (admin env token, per-user tokens, context API keys). MCP clients should
        send the token in the <code>Authorization</code> header of every request. The
        endpoint answers <code>401</code> for invalid tokens and <code>403</code> when
        the token has no access to the requested context:
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
        code={"{\"mcpServers\": {\"dran\": {\"url\": \"http://localhost:4000/api/mcp\", \"headers\": {\"Authorization\": \"Bearer <your-api-token>\"}}}}"}
      />

      <h3 id="runtime-settings" class="scroll-mt-20">Runtime Settings</h3>
      <p>
        Brain behavior can be tuned at runtime without restarting. Settings are stored
        in the database and managed from Settings → Brain. Available keys:
        <code>semantic_threshold_short</code>
        (0.15), <code>semantic_threshold_mid</code>
        (0.22), <code>semantic_threshold_long</code>
        (0.28), <code>agent_max_pages</code>
        (10), <code>agent_max_sources</code>
        (10), <code>pagerank_boost</code>
        (0.15) and <code>entity_linker_enabled</code>
        (true).
      </p>

      <h3 id="security-notes" class="scroll-mt-20">Security notes</h3>
      <.callout variant={:warning}>
        <ul class="space-y-1">
          <li>Change DRAN_API_TOKEN in production — the dev default is public.</li>
          <li>
            Per-user tokens and context API keys grant scoped access — protect them like passwords.
          </li>
          <li>Use HTTPS in production to prevent credential interception.</li>
          <li>
            Set SESSION_SIGNING_SALT / SESSION_ENCRYPTION_SALT in production — the dev defaults are committed to the repo.
          </li>
          <li>
            Google OAuth only logs in existing users; set GOOGLE_OAUTH_ALLOWED_DOMAINS to allow auto-registration.
          </li>
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
        {"maintenance-api", "Maintenance"},
        {"wiki-api", "Wiki"},
        {"export-api", "Export"}
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
        label: "GraphRAG (Q&A)",
        icon: "hero-chat-bubble-left-right",
        color: "text-violet-500 dark:text-violet-400",
        trigger: :manual,
        schedule: nil,
        description:
          "Answers a question using ONLY knowledge already in the brain — local/global/drift search over the graph. Persists the answer as a query page citing sources.",
        limits: "Max 10 searches, 5 expands, 3 community contexts; one query page per session."
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
        trigger: :scheduled,
        schedule: "Weekly Sun 07:00",
        description:
          "Reads orphaned and under-linked pages, proposes typed relations with justifications. Also startable manually via dran_start_agent.",
        limits: "Max 10 proposals per session; semantic type forbidden."
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
      %{
        group: "Search",
        method: "GET",
        path: "/api/search/semantic?q=...&context=...",
        desc: "Semantic (embedding) search"
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
        group: "Export",
        method: "GET",
        path: "/api/contexts/:slug/export",
        desc: "Single-context export (pages + relations)"
      },
      %{
        group: "Export",
        method: "GET",
        path: "/api/export/:context/full",
        desc: "Full brain export (all pages + relations + metadata as JSON)"
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
        {"context-query", "Context via URL"},
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
          to rename a page slug; all <code>![[slug]]</code>
          embeds in the context are rewritten automatically.
        </li>
        <li>
          <strong>Agents</strong>
          — use <code>dran_start_agent</code>
          to delegate tasks to autonomous agents (curator, link_gardener, graph_rag).
          Poll <code>dran_get_agent_session</code>
          for progress and results.
        </li>
        <li>
          <strong>Lint</strong> — use <code>dran_lint_brain</code> to find orphans and stale pages.
        </li>
        <li>
          <strong>Archive</strong>
          — stale pages can be <strong>archived</strong>
          instead of deleted: set <code>archived: true</code>
          via <code>dran_update_page</code>
          (or the Archive button in the page detail). Archived pages disappear
          from lists, stats, search and kanban boards but stay accessible by
          slug. Every list view shows a collapsible <strong>Archived</strong>
          section at the bottom, filterable by page type. Archiving is
          reversible; deletion is not.
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
              <td class="px-4 py-2 font-mono text-primary">goal</td>
              <td class="px-4 py-2">Objectives with target dates and health</td>
              <td class="px-4 py-2 text-xs">
                personal, coding, business, learning, health, finance, other
              </td>
              <td class="px-4 py-2 text-xs">
                health (green/yellow/red), target_date, start_date, team
              </td>
            </tr>
            <tr class="hover:bg-base-200/50 transition-colors">
              <td class="px-4 py-2 font-mono text-primary">plan</td>
              <td class="px-4 py-2">Time-horizoned plans</td>
              <td class="px-4 py-2 text-xs">
                personal, coding, business, learning, health, finance, other
              </td>
              <td class="px-4 py-2 text-xs">
                horizon (weekly/monthly/quarterly/yearly), status, period, goal_slug
              </td>
            </tr>
            <tr class="hover:bg-base-200/50 transition-colors">
              <td class="px-4 py-2 font-mono text-primary">todo</td>
              <td class="px-4 py-2">Actionable items with kanban status</td>
              <td class="px-4 py-2 text-xs">
                personal, coding, business, learning, health, finance, other
              </td>
              <td class="px-4 py-2 text-xs">
                kanban_status (backlog/this_week/today/in_progress/done/cancelled), priority (low/medium/high/urgent), assignee, goal_slug, plan_slug, due_date
              </td>
            </tr>
            <tr class="hover:bg-base-200/50 transition-colors">
              <td class="px-4 py-2 font-mono text-primary">query</td>
              <td class="px-4 py-2">Question with answer (LLM wiki style)</td>
              <td class="px-4 py-2 text-xs">factual, conceptual, how_to, opinion</td>
              <td class="px-4 py-2 text-xs">
                kind, difficulty (simple/intermediate/advanced), status (open/answered/verified), answered_by
              </td>
            </tr>
            <tr class="hover:bg-base-200/50 transition-colors">
              <td class="px-4 py-2 font-mono text-primary">project</td>
              <td class="px-4 py-2">Initiative grouping goals, plans and todos</td>
              <td class="px-4 py-2 text-xs">—</td>
              <td class="px-4 py-2 text-xs">
                status (draft/active/on_hold/done/archived), priority, health, health_source, start_date, target_date
              </td>
            </tr>
            <tr class="hover:bg-base-200/50 transition-colors">
              <td class="px-4 py-2 font-mono text-primary">report</td>
              <td class="px-4 py-2">System-created run logs (jobs and agent runs)</td>
              <td class="px-4 py-2 text-xs">log</td>
              <td class="px-4 py-2 text-xs">
                kind — not creatable via MCP; outside the graph, journey and embeddings
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <.h2_heading id="embeds" icon="hero-paper-clip" label="Embeds" />
      <p>
        Use <code>![[slug]]</code>
        in page bodies to embed a file (image, video, audio, PDF). Embeds
        are auto-resolved into <code>embeds</code>
        relations. Plain <code>[[slug]]</code>
        wikilinks are no longer supported — relations are
        created automatically via embeddings or explicitly via <code>dran_create_relation</code>.
      </p>

      <.h2_heading id="context-query" icon="hero-link" label="Context via URL" />
      <p>
        Page URLs accept a <code>?context=slug</code> query parameter to open a
        page in a specific context, regardless of the session's active context.
        This is useful for deep links from external tools (agents, bookmarks,
        shared links).
      </p>
      <div class="not-prose rounded-lg border border-base-300 bg-base-200/50 p-3">
        <pre class="text-sm font-mono text-primary overflow-x-auto"><code phx-no-curly-interpolation>{"\n/notes/my-note?context=work\n/goals/mrr-100k?context=business\n/todos/fix-bug?context=coding\n/projects/tokengate?context=personal"}</code></pre>
      </div>
      <p class="text-sm text-base-content/60 mt-2">
        If the context slug doesn't exist, the session's current context is used as fallback.
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
          <:param name="limit" type="integer" required="no" desc="Max results (default 20, max 100)" />
          <:param
            name="offset"
            type="integer"
            required="no"
            desc="Skip N results for pagination (default 0)"
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
            desc="note, concept, entity, reference, goal, plan, todo, query, project"
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
          <:param
            name="assignee"
            type="string"
            required="no"
            desc="Filter todos by assignee ('none' for unassigned)"
          />
          <:param name="limit" type="integer" required="no" desc="Max results (default 50, max 500)" />
          <:param
            name="offset"
            type="integer"
            required="no"
            desc="Skip N results for pagination (default 0)"
          />
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
            desc="note, concept, entity, reference, goal, plan, todo, query, project"
          />
          <:param
            name="body"
            type="string"
            required="no"
            desc="Markdown body. Use ![[slug]] for embeds."
          />
          <:param
            name="meta"
            type="object"
            required="no"
            desc="Type-specific metadata (see table above)"
          />
          <:param name="tags" type="array" required="no" desc="Tags (kebab-case)" />
          <:param name="summary" type="string" required="no" desc="One-line summary" />
          <:param
            name="owner"
            type="string"
            required="no"
            desc="Owner identity. Derived from API key name — not client-settable. Defaults to 'system'"
          />
          <:param
            name="created_by"
            type="string"
            required="no"
            desc="Who created this page. Defaults to authenticated identity (API key name or user email)"
          />
          <:param
            name="on_behalf_of"
            type="string"
            required="no"
            desc="Who an agent is acting on behalf of"
          />
        </.mcp_tool>

        <.mcp_tool
          name="dran_update_page"
          desc="Update any page field. Version auto-increments on body change. Meta is replaced (not merged) — use dran_update_todo for todos."
        >
          <:param name="context" type="string" required="yes" desc="Context slug" />
          <:param name="slug" type="string" required="yes" desc="Page slug to update" />
          <:param name="title" type="string" required="no" desc="New title" />
          <:param name="body" type="string" required="no" desc="New markdown body" />
          <:param name="tags" type="array" required="no" desc="New tags" />
          <:param name="meta" type="object" required="no" desc="Updated metadata (replaces existing)" />
          <:param name="summary" type="string" required="no" desc="New summary" />
          <:param name="owner" type="string" required="no" desc="New owner identity" />
          <:param name="created_by" type="string" required="no" desc="Override who created this page" />
          <:param name="on_behalf_of" type="string" required="no" desc="Set or clear on-behalf-of" />
          <:param name="archived" type="boolean" required="no" desc="Archive or unarchive the page" />
          <:param
            name="kb_confidence"
            type="string"
            required="no"
            desc="Knowledge-base confidence: low/medium/high/verified"
          />
          <:param name="kb_source_url" type="string" required="no" desc="Source URL for KB entry" />
          <:param name="kb_contested" type="boolean" required="no" desc="Mark knowledge as contested" />
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
          desc="Create a todo with kanban status and priority, optionally linked to a project, goal, and/or plan (independent links)."
        >
          <:param name="context" type="string" required="yes" desc="Context slug" />
          <:param name="title" type="string" required="yes" desc="Todo title" />
          <:param name="slug" type="string" required="yes" desc="Todo slug" />
          <:param name="goal_slug" type="string" required="no" desc="Goal this todo belongs to" />
          <:param
            name="plan_slug"
            type="string"
            required="no"
            desc="Plan this todo belongs to (independent link, no precedence)"
          />
          <:param
            name="kanban_status"
            type="string"
            required="no"
            desc="backlog, this_week, today, in_progress, done, cancelled"
          />
          <:param name="priority" type="string" required="no" desc="low, medium, high, urgent" />
          <:param name="due_date" type="string" required="no" desc="YYYY-MM-DD" />
          <:param
            name="assignee"
            type="string"
            required="no"
            desc="Who executes this todo (alvaro, hermes, claude-code...)"
          />
          <:param name="body" type="string" required="no" desc="Todo description (markdown)" />
          <:param
            name="owner"
            type="string"
            required="no"
            desc="Owner identity. Derived from API key name — not client-settable. Defaults to 'system'"
          />
          <:param
            name="created_by"
            type="string"
            required="no"
            desc="Who created this todo. Defaults to authenticated identity (API key name or user email)"
          />
          <:param
            name="on_behalf_of"
            type="string"
            required="no"
            desc="Who an agent is acting on behalf of"
          />
        </.mcp_tool>

        <.mcp_tool
          name="dran_update_todo"
          desc="Update a todo's status, priority, due date, assignee, goal, or plan. Merges meta — only pass changed fields."
        >
          <:param name="context" type="string" required="yes" desc="Context slug" />
          <:param name="slug" type="string" required="yes" desc="Todo slug to update" />
          <:param name="kanban_status" type="string" required="no" desc="New kanban status" />
          <:param name="priority" type="string" required="no" desc="New priority" />
          <:param name="due_date" type="string" required="no" desc="New due date YYYY-MM-DD" />
          <:param
            name="assignee"
            type="string"
            required="no"
            desc="Reassign todo (alvaro, hermes, claude-code...)"
          />
          <:param name="goal_slug" type="string" required="no" desc="New goal slug" />
          <:param name="plan_slug" type="string" required="no" desc="New plan slug" />
          <:param name="title" type="string" required="no" desc="New title" />
          <:param name="body" type="string" required="no" desc="New body (markdown)" />
          <:param name="tags" type="array" required="no" desc="New tags (replaces existing)" />
          <:param name="project_slug" type="string" required="no" desc="New project slug" />
          <:param name="owner" type="string" required="no" desc="New owner identity" />
          <:param name="created_by" type="string" required="no" desc="Override who created this todo" />
          <:param name="on_behalf_of" type="string" required="no" desc="Set or clear on-behalf-of" />
          <:param
            name="updated_by"
            type="string"
            required="no"
            desc="Who is updating (defaults to 'agent')"
          />
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
          name="dran_generate_community_summaries"
          desc="Generate or regenerate LLM summaries for all detected graph communities (Label Propagation clusters). Requires inference configured."
        >
          <:param name="context" type="string" required="yes" desc="Context slug" />
        </.mcp_tool>

        <.mcp_tool
          name="dran_rename_slug"
          desc="Rename a page's slug. All ![[old-slug]] embeds in the context are rewritten automatically."
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
          name="dran_start_agent"
          desc="Start an autonomous agent session. Returns immediately; poll dran_get_agent_session for progress."
        >
          <:param
            name="agent_type"
            type="string"
            required="yes"
            desc="curator, link_gardener, graph_rag"
          />
          <:param name="context" type="string" required="yes" desc="Context slug" />
          <:param
            name="input"
            type="string"
            required="yes"
            desc="Question for graph_rag; focus or instructions for curator / link_gardener"
          />
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
          <code class="font-mono text-primary">brainstorm</code>
          <span class="text-sm text-base-content/60 ml-2">Generate ideas around a topic. Args: topic, context.</span>
        </div>
        <div class="rounded-lg border border-base-300 p-3">
          <code class="font-mono text-primary">goal_review</code>
          <span class="text-sm text-base-content/60 ml-2">Review a goal's status, todos, and plans. Args: goal_slug, context.</span>
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
        code={"{\"mcpServers\": {\"dran\": {\"url\": \"http://localhost:4000/api/mcp\", \"headers\": {\"Authorization\": \"Bearer <your-api-token>\"}}}}"}
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
