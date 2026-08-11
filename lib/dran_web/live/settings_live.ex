defmodule DranWeb.SettingsLive do
  @moduledoc """
  Settings page showing an editable "Brain tuning" section backed by
  `Dran.Settings`, an editable "Modelos" section for per-purpose model
  overrides (also backed by `Dran.Settings`), followed by read-only
  environment configuration (agents, inference API, and uploads).
  """

  use DranWeb, :live_view

  alias Dran.Brain.Context
  alias Dran.Inference.Client
  alias Dran.Inference.Config
  alias Dran.Jobs
  alias Dran.Settings
  alias Dran.Slug
  alias DranWeb.PageTypes
  alias DranWeb.Plugs.Auth

  # Keys managed by the "Brain tuning" form.
  @brain_keys ~w(agent_max_pages entity_linker_enabled)
  @advanced_keys ~w(semantic_threshold_short semantic_threshold_mid semantic_threshold_long)

  # Purposes shown in the "Modelos" card. Each entry is:
  #   {settings_key, label_gettext_fn, description_gettext_fn}
  # Models come exclusively from the provider's `/v1/models` list — there are
  # no env-var model defaults anymore.
  defp model_purposes do
    [
      {"model_chat", fn -> gettext("Chat / agentes") end,
       fn ->
         gettext("Model used for chat completions, agent reasoning, and title generation.")
       end},
      {"model_embedding", fn -> gettext("Embeddings") end,
       fn -> gettext("Model used to vectorize page bodies for semantic search and relations.") end},
      {"model_rerank", fn -> gettext("Re-ranking") end,
       fn ->
         gettext("Model used to re-rank semantic search results by relevance to the query.")
       end}
    ]
  end

  @impl true
  def mount(_params, session, socket) do
    {socket, _context} = Auth.assign_to_socket(socket, session)

    socket =
      socket
      |> assign(active_nav: "settings", page_title: gettext("Settings"))
      |> assign(inference_test: nil)
      |> assign(model_test_status: %{})
      |> assign_users()
      |> assign_contexts()
      |> assign_new_user_form()
      |> assign_new_context_form()
      |> assign(
        confirm_delete_context_id: nil,
        slug_touched: false,
        managing_context_id: nil,
        page_types_context_id: nil,
        api_keys: Dran.Accounts.list_api_keys(),
        new_api_key_form: to_form(%{}, as: :api_key),
        revealed_api_key: nil,
        props_backfill: :idle,
        running_jobs: MapSet.new(),
        wiki_google_open_signup: Settings.get("wiki_google_open_signup") == true
      )
      |> assign_brain_form()
      |> assign_models()
      |> assign_jobs()
      # SEC-004: defense-in-depth — halt every event for non-admins
      |> attach_hook(:require_admin, :handle_event, fn _event, _params, socket ->
        if socket.assigns[:is_admin] do
          {:cont, socket}
        else
          {:halt, put_flash(socket, :error, gettext("No autorizado."))}
        end
      end)

    {:ok, socket}
  end

  # -- Admin: user & context management ---------------------------------------

  defp assign_users(socket) do
    users = Dran.Accounts.list_users()
    assign(socket, users: users)
  end

  defp assign_contexts(socket) do
    contexts = Dran.Brain.list_contexts()
    assign(socket, all_contexts: contexts)
  end

  # Short human-readable hint shown next to each page type toggle in Settings.
  defp page_type_impact("todo"), do: gettext("Kanban, tasks, todos list")
  defp page_type_impact("goal"), do: gettext("Goals, goal filters, goal badges")
  defp page_type_impact("plan"), do: gettext("Plans, plan filters, plan badges")
  defp page_type_impact("project"), do: gettext("Projects, project filters, project badges")
  defp page_type_impact("note"), do: gettext("Notes, notes list")
  defp page_type_impact("concept"), do: gettext("Concepts, concepts list")
  defp page_type_impact("entity"), do: gettext("Entities, entities list")
  defp page_type_impact("reference"), do: gettext("References, references list")
  defp page_type_impact("query"), do: gettext("Smart collections, queries")
  defp page_type_impact(_), do: ""

  defp assign_new_user_form(socket) do
    assign(socket, new_user_form: to_form(%{}, as: :user))
  end

  defp assign_new_context_form(socket) do
    assign(socket, new_context_form: to_form(Context.changeset(%Context{}, %{}), as: :context))
  end

  @tabs ~w(users contexts api_keys brain models system danger)

  @impl true
  def handle_params(params, _url, socket) do
    tab =
      case params["tab"] do
        t when t in @tabs -> t
        _ -> "users"
      end

    {:noreply, assign(socket, active_tab: tab)}
  end

  # -- Admin: user & context management ---------------------------------------

  @impl true
  def handle_event("create_user", %{"user" => params}, socket) do
    email = Map.get(params, "email", "")
    name = Map.get(params, "name", "")
    context_ids = Map.get(params, "context_ids", []) |> List.wrap()

    case Dran.Accounts.create_user(%{email: email, name: name}) do
      {:ok, user} ->
        # Add to selected contexts
        for context_id <- context_ids do
          context = Dran.Brain.get_context!(context_id)
          Dran.Accounts.add_user_to_context(user, context)
        end

        socket
        |> assign_users()
        |> assign_new_user_form()
        |> put_flash(:info, "User created: #{email}")

      {:error, changeset} ->
        put_flash(socket, :error, "Could not create user: #{inspect(changeset.errors)}")
    end
    |> then(&{:noreply, &1})
  end

  @impl true
  def handle_event("delete_user", %{"id" => id}, socket) do
    user = Dran.Accounts.get_user!(id)

    case Dran.Accounts.delete_user(user) do
      {:ok, _} ->
        socket
        |> assign_users()
        |> put_flash(:info, "User deleted")

      {:error, _} ->
        put_flash(socket, :error, "Could not delete user")
    end
    |> then(&{:noreply, &1})
  end

  @impl true
  def handle_event(
        "toggle_context_user",
        %{"context_id" => context_id, "user_id" => user_id},
        socket
      ) do
    user = Dran.Accounts.get_user!(user_id)
    context = Dran.Brain.get_context!(context_id)

    if Dran.Accounts.user_in_context?(user, context) do
      Dran.Accounts.remove_user_from_context(user, context)
    else
      Dran.Accounts.add_user_to_context(user, context)
    end

    {:noreply, assign_users(socket)}
  end

  # -- Admin: context-scoped API keys ------------------------------------------

  @impl true
  def handle_event("create_api_key", %{"api_key" => params}, socket) do
    name = Map.get(params, "name", "") |> String.trim()
    context_id = Map.get(params, "context_id", "")

    case Dran.Accounts.create_api_key(%{name: name, context_id: context_id}) do
      {:ok, key} ->
        socket =
          socket
          |> assign(
            api_keys: Dran.Accounts.list_api_keys(),
            new_api_key_form: to_form(%{}, as: :api_key),
            revealed_api_key: %{id: key.id, token: key.token}
          )
          |> put_flash(:info, gettext("API key created — copy it now, it won't be shown again"))

        {:noreply, socket}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(new_api_key_form: to_form(changeset, as: :api_key))
         |> put_flash(:error, gettext("Could not create the API key"))}
    end
  end

  @impl true
  def handle_event("dismiss_revealed_key", _params, socket) do
    {:noreply, assign(socket, revealed_api_key: nil)}
  end

  @impl true
  def handle_event("revoke_api_key", %{"id" => id}, socket) do
    key = Dran.Repo.get!(Dran.Accounts.ApiKey, id)
    {:ok, _} = Dran.Accounts.revoke_api_key(key)

    {:noreply,
     socket
     |> assign(api_keys: Dran.Accounts.list_api_keys())
     |> put_flash(:info, gettext("API key revoked"))}
  end

  @impl true
  def handle_event("restore_api_key", %{"id" => id}, socket) do
    key = Dran.Repo.get!(Dran.Accounts.ApiKey, id)
    {:ok, _} = Dran.Accounts.restore_api_key(key)

    {:noreply,
     socket
     |> assign(api_keys: Dran.Accounts.list_api_keys())
     |> put_flash(:info, gettext("API key restored"))}
  end

  @impl true
  def handle_event("regenerate_api_key", %{"id" => id}, socket) do
    key = Dran.Repo.get!(Dran.Accounts.ApiKey, id)

    case Dran.Accounts.regenerate_api_key(key) do
      {:ok, key} ->
        {:noreply,
         socket
         |> assign(
           api_keys: Dran.Accounts.list_api_keys(),
           revealed_api_key: %{id: key.id, token: key.token}
         )
         |> put_flash(:info, gettext("API key regenerated — copy the new token now"))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not regenerate the key"))}
    end
  end

  @impl true
  def handle_event("delete_api_key", %{"id" => id}, socket) do
    key = Dran.Repo.get!(Dran.Accounts.ApiKey, id)
    {:ok, _} = Dran.Accounts.delete_api_key(key)

    {:noreply,
     socket
     |> assign(api_keys: Dran.Accounts.list_api_keys())
     |> put_flash(:info, gettext("API key deleted"))}
  end

  @impl true
  def handle_event("set_default_context", %{"user_id" => id, "slug" => slug}, socket) do
    user = Dran.Accounts.get_user!(id)

    case Dran.Accounts.set_default_context(user, slug) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign_users()
         |> put_flash(:info, gettext("Default context updated"))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not update default context"))}
    end
  end

  # -- Admin: context CRUD (create / delete) -----------------------------------

  @impl true
  def handle_event("manage_context_users", %{"id" => id}, socket) do
    {:noreply, assign(socket, :managing_context_id, id)}
  end

  @impl true
  def handle_event("close_context_users", _params, socket) do
    {:noreply, assign(socket, :managing_context_id, nil)}
  end

  @impl true
  def handle_event("manage_page_types", %{"id" => id}, socket) do
    {:noreply, assign(socket, :page_types_context_id, id)}
  end

  @impl true
  def handle_event("close_page_types", _params, socket) do
    {:noreply, assign(socket, :page_types_context_id, nil)}
  end

  @impl true
  def handle_event(
        "toggle_page_type",
        %{"context_id" => context_id, "page_type" => page_type},
        socket
      ) do
    context = Dran.Brain.get_context!(context_id)
    disabled = context.disabled_page_types || []

    new_disabled =
      if page_type in disabled do
        List.delete(disabled, page_type)
      else
        disabled ++ [page_type]
      end

    case Dran.Brain.update_context_settings(context, %{disabled_page_types: new_disabled}) do
      {:ok, _} -> {:noreply, assign_contexts(socket)}
      {:error, _} -> {:noreply, put_flash(socket, :error, gettext("Could not update page types"))}
    end
  end

  @impl true
  def handle_event("toggle_wiki", %{"context_id" => context_id}, socket) do
    context = Dran.Brain.get_context!(context_id)
    new_wiki = !context.wiki_enabled

    case Dran.Brain.update_context_settings(context, %{wiki_enabled: new_wiki}) do
      {:ok, _} ->
        {:noreply, assign_contexts(socket)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not update wiki setting"))}
    end
  end

  @impl true
  def handle_event(
        "update_wiki_description",
        %{"context_id" => context_id, "value" => value},
        socket
      ) do
    context = Dran.Brain.get_context!(context_id)

    case Dran.Brain.update_context_settings(context, %{wiki_description: value}) do
      {:ok, _} ->
        {:noreply, assign_contexts(socket)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not update wiki description"))}
    end
  end

  @impl true
  def handle_event("update_wiki_description", params, socket) do
    # textarea blur sends raw text value differently — extract from params
    context_id = params["context_id"]
    value = (params["_target"] && params[params["_target"]]) || ""
    context = Dran.Brain.get_context!(context_id)

    case Dran.Brain.update_context_settings(context, %{wiki_description: value}) do
      {:ok, _} ->
        {:noreply, assign_contexts(socket)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not update wiki description"))}
    end
  end

  @impl true
  def handle_event("validate_context", %{"context" => params, "_target" => target}, socket) do
    name = params["name"] || ""
    slug_touched = socket.assigns[:slug_touched] || false

    slug_touched =
      if target == ["context", "slug"], do: true, else: slug_touched

    params =
      if slug_touched do
        params
      else
        Map.put(params, "slug", Slug.slugify(name))
      end

    form = %Context{} |> Context.changeset(params) |> to_form(as: :context)
    {:noreply, assign(socket, new_context_form: form, slug_touched: slug_touched)}
  end

  @impl true
  def handle_event("create_context", %{"context" => params}, socket) do
    case Dran.Brain.create_context(params) do
      {:ok, _context} ->
        {:noreply,
         socket
         |> assign_contexts()
         |> assign_new_context_form()
         |> assign(:slug_touched, false)
         |> put_flash(:info, gettext("Context created"))}

      {:error, changeset} ->
        {:noreply, assign(socket, new_context_form: to_form(changeset, as: :context))}
    end
  end

  @impl true
  def handle_event("ask_delete_context", %{"id" => id}, socket) do
    {:noreply, assign(socket, :confirm_delete_context_id, id)}
  end

  @impl true
  def handle_event("cancel_delete_context", _params, socket) do
    {:noreply, assign(socket, :confirm_delete_context_id, nil)}
  end

  @impl true
  def handle_event("delete_context", %{"id" => id}, socket) do
    context = Enum.find(socket.assigns.all_contexts, &(&1.id == id))

    if context do
      case Dran.Brain.delete_context(context) do
        {:ok, _} ->
          {:noreply,
           socket
           |> assign_contexts()
           |> assign(:confirm_delete_context_id, nil)
           |> put_flash(:info, gettext("Context \"%{name}\" deleted", name: context.name))}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Could not delete context"))}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("save", %{"settings" => params}, socket) do
    casts = %{
      "semantic_threshold_short" => &cast_float/1,
      "semantic_threshold_mid" => &cast_float/1,
      "semantic_threshold_long" => &cast_float/1,
      "agent_max_pages" => &cast_int/1,
      "entity_linker_enabled" => fn val -> val == "true" end
    }

    for key <- @brain_keys ++ @advanced_keys do
      raw = Map.get(params, key, "")
      cast = Map.fetch!(casts, key)
      Settings.put(key, cast.(raw))
    end

    socket =
      socket
      |> assign_brain_form()
      |> put_flash(:info, gettext("Settings saved"))

    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_wiki_google_signup", _params, socket) do
    current = Settings.get("wiki_google_open_signup") == true
    Settings.put("wiki_google_open_signup", !current)
    {:noreply, assign(socket, wiki_google_open_signup: !current)}
  end

  @impl true
  def handle_event("save_models", %{"models" => params}, socket) do
    for {key, _label, _desc} <- model_purposes() do
      raw = Map.get(params, key, "")
      value = if raw == "", do: nil, else: raw
      Settings.put(key, value)
    end

    socket =
      socket
      |> assign_models()
      |> put_flash(:info, gettext("Settings saved"))

    {:noreply, socket}
  end

  @impl true
  def handle_event("reset_context", %{"danger" => %{"confirmation" => confirmation}}, socket) do
    expected = socket.assigns.context_slug || ""

    if confirmation == expected do
      context = Dran.Brain.get_context_by_slug(socket.assigns.context_slug)

      case Dran.Brain.reset_context(context.id) do
        {:ok, counts} ->
          socket =
            socket
            |> put_flash(
              :info,
              gettext(
                "Brain reset: deleted %{pages} pages, %{relations} relations, %{versions} versions, %{logs} logs.",
                pages: counts.pages,
                relations: counts.relations,
                versions: counts.versions,
                logs: counts.logs
              )
            )
            |> push_navigate(to: ~p"/")

          {:noreply, socket}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Could not reset brain. Check the logs."))}
      end
    else
      {:noreply,
       put_flash(socket, :error, gettext("Confirmation text does not match the context slug."))}
    end
  end

  # -- Inference connection test ---------------------------------------------

  @impl true
  def handle_event("run_props_backfill", _params, socket) do
    if socket.assigns.props_backfill == :running do
      {:noreply, socket}
    else
      socket = assign(socket, props_backfill: :running)
      parent = self()

      Task.start(fn ->
        result = Dran.PropsBackfill.run()
        send(parent, {:props_backfill_done, result})
      end)

      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("test_inference", _params, socket) do
    pid = self()

    Task.start(fn ->
      result = Client.ping()
      send(pid, {:inference_test_result, result})
    end)

    {:noreply, assign(socket, inference_test: :testing)}
  end

  @impl true
  def handle_event("test_model", %{"key" => key, "model" => model}, socket) do
    with true <- test_model_key?(key),
         false <- Map.get(socket.assigns.model_test_status, key) == :testing do
      pid = self()

      Task.start(fn ->
        result = run_model_test(key, model)
        send(pid, {:model_test_done, key, result})
      end)

      status = Map.put(socket.assigns.model_test_status, key, :testing)
      {:noreply, assign(socket, model_test_status: status)}
    else
      _ -> {:noreply, socket}
    end
  end

  # -- Jobs panel -------------------------------------------------------------

  @impl true
  def handle_event("toggle_job", %{"key" => key}, socket) do
    case job_key_from_param(key) do
      {:ok, key} ->
        Jobs.set_enabled(key, not Jobs.enabled?(key))
        {:noreply, assign_jobs(socket)}

      :error ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("run_job", %{"key" => key}, socket) do
    with {:ok, key} <- job_key_from_param(key),
         false <- MapSet.member?(socket.assigns.running_jobs, key) do
      parent = self()

      Task.start(fn ->
        result = Jobs.run_now(key)
        send(parent, {:job_run_done, key, result})
      end)

      {:noreply, assign(socket, running_jobs: MapSet.put(socket.assigns.running_jobs, key))}
    else
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:inference_test_result, result}, socket) do
    {:noreply, assign(socket, inference_test: result)}
  end

  @impl true
  def handle_info({:model_test_done, key, result}, socket) do
    status = Map.put(socket.assigns.model_test_status, key, result)
    {:noreply, assign(socket, model_test_status: status)}
  end

  @impl true
  def handle_info({:props_backfill_done, {:ok, stats}}, socket) do
    socket =
      socket
      |> assign(props_backfill: :idle)
      |> put_flash(
        :info,
        gettext(
          "Props backfill complete: %{pages} pages processed, %{edges} relations created.",
          pages: stats.pages,
          edges: stats.edges
        )
      )

    {:noreply, socket}
  end

  def handle_info({:props_backfill_done, {:error, reason}}, socket) do
    socket =
      socket
      |> assign(props_backfill: :idle)
      |> put_flash(:error, gettext("Props backfill failed: %{reason}", reason: inspect(reason)))

    {:noreply, socket}
  end

  @impl true
  def handle_info({:job_run_done, key, {:ok, _report}}, socket) do
    socket =
      socket
      |> assign(running_jobs: MapSet.delete(socket.assigns.running_jobs, key))
      |> assign_jobs()
      |> put_flash(:info, gettext("Job completado: %{label}", label: job_label(key)))

    {:noreply, socket}
  end

  @impl true
  def handle_info({:job_run_done, key, {:error, _reason}}, socket) do
    socket =
      socket
      |> assign(running_jobs: MapSet.delete(socket.assigns.running_jobs, key))
      |> assign_jobs()
      |> put_flash(:error, gettext("Job falló: %{label}", label: job_label(key)))

    {:noreply, socket}
  end

  # -- Brain tuning form ------------------------------------------------------

  defp assign_brain_form(socket) do
    values =
      Settings.all()
      |> Map.take(@brain_keys ++ @advanced_keys)

    assign(socket, brain_form: to_form(values, as: :settings))
  end

  # -- Jobs panel helpers -------------------------------------------------------

  defp assign_jobs(socket) do
    assign(socket, jobs: Jobs.list())
  end

  # Validates a phx-value-key param against the job registry — never casts
  # arbitrary strings to atoms.
  defp job_key_from_param(param) when is_binary(param) do
    case Enum.find(Jobs.list_keys(), &(Atom.to_string(&1) == param)) do
      nil -> :error
      key -> {:ok, key}
    end
  end

  defp job_key_from_param(_), do: :error

  defp job_label(key) do
    case Jobs.get(key) do
      %{label: label} -> label
      nil -> to_string(key)
    end
  end

  defp cast_float(str) when is_binary(str) do
    case Float.parse(str) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp cast_int(str) when is_binary(str) do
    case Integer.parse(str) do
      {i, _} -> i
      :error -> nil
    end
  end

  # -- Models section ----------------------------------------------------------

  # Fetches the available model ids from the inference API once on mount.
  # Stores `{:ok, ids}` or `{:error, reason}` so the UI can show a note when
  # the API is unavailable. Also builds the current-values map (Settings
  # override or env default) per purpose.
  defp assign_models(socket) do
    models =
      case Client.models() do
        {:ok, list} when is_list(list) ->
          ids = list |> Enum.map(&extract_model_id/1) |> Enum.reject(&is_nil/1)
          {:ok, ids}

        {:error, _} = err ->
          err
      end

    current =
      model_purposes()
      |> Enum.map(fn {key, _label, _desc} ->
        {key, current_model_value(key)}
      end)
      |> Map.new()

    assign(socket, models_result: models, model_values: current)
  end

  defp extract_model_id(%{"id" => id}) when is_binary(id), do: id
  defp extract_model_id(%{id: id}) when is_binary(id), do: id
  defp extract_model_id(_), do: nil

  # Effective value for a purpose: the Settings override, if set. Models come
  # exclusively from the provider's model list — no env fallback.
  defp current_model_value(key) do
    case read_setting_safe(key) do
      nil -> nil
      "" -> nil
      value -> value
    end
  end

  defp read_setting_safe(key) do
    Settings.get(key)
  rescue
    _ -> nil
  end

  # -- Per-model test ----------------------------------------------------------

  defp test_model_key?(key) do
    Enum.any?(model_purposes(), fn {k, _label, _desc} -> k == key end)
  end

  # Runs a real inference call against the given model. `model` is the raw
  # select value: "" (default/env) resolves to the effective configured model.
  # Returns {:ok, latency_ms} or {:error, reason}.
  defp run_model_test(key, model) do
    model =
      case model do
        "" -> effective_model(key)
        nil -> effective_model(key)
        m -> m
      end

    start = System.monotonic_time(:millisecond)

    result =
      case key do
        "model_chat" ->
          Client.chat(%{
            "model" => model,
            "messages" => [%{"role" => "user", "content" => "Say OK"}],
            "max_tokens" => 5
          })

        "model_embedding" ->
          Client.embeddings(model, ["test"])

        "model_rerank" ->
          Client.rerank(model, "test", ["test doc"])

        _ ->
          {:error, :unknown_model_key}
      end

    case result do
      {:ok, _} -> {:ok, System.monotonic_time(:millisecond) - start}
      {:error, reason} -> {:error, reason}
    end
  end

  defp effective_model("model_chat"), do: Config.chat_model()
  defp effective_model("model_embedding"), do: Config.embedding_model()
  defp effective_model("model_rerank"), do: Config.rerank_model()
  defp effective_model(_), do: nil

  # Compact, human-readable reason for the UI.
  defp format_model_error({:http_error, status, _body}), do: "HTTP #{status}"
  defp format_model_error(%Req.TransportError{reason: reason}), do: inspect(reason)
  defp format_model_error(:not_configured), do: "inference no configurado"
  defp format_model_error(other), do: inspect(other)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_user={@current_user}
      context_slug={@context_slug}
      contexts={@contexts}
      active_nav={@active_nav}
    >
      <div class="flex-1 overflow-y-auto">
        <div class="w-full p-6 space-y-8">
          <%!-- Page header --%>
          <div>
            <h1 class="text-title">{gettext("Settings")}</h1>
            <p class="text-caption mt-1">
              {gettext("Personalize your brain and review the environment configuration.")}
            </p>
          </div>

          <%!-- Tabs navigation --%>
          <div class="tabs tabs-border">
            <.link
              :for={tab <- ~w(users contexts api_keys brain models system danger)}
              patch={~p"/panel/settings/#{tab}"}
              class={["tab", @active_tab == tab && "tab-active"]}
            >
              {tab_label(tab)}
            </.link>
          </div>

          <%!-- Tab content --%>
          <div :if={@active_tab == "users"}>
            <.users_section users={@users} all_contexts={@all_contexts} form={@new_user_form} />
          </div>

          <div :if={@active_tab == "contexts"}>
            <.contexts_section
              contexts={@all_contexts}
              users={@users}
              form={@new_context_form}
              confirm_delete_context_id={@confirm_delete_context_id}
              managing_context_id={@managing_context_id}
              page_types_context_id={@page_types_context_id}
              context_slug={@context_slug}
            />
          </div>

          <div :if={@active_tab == "api_keys"}>
            <.api_keys_section
              api_keys={@api_keys}
              all_contexts={@all_contexts}
              form={@new_api_key_form}
              revealed_api_key={@revealed_api_key}
            />
          </div>

          <div :if={@active_tab == "brain"}>
            <.brain_tuning_section form={@brain_form} props_backfill={@props_backfill} />
            <.jobs_section jobs={@jobs} running_jobs={@running_jobs} />
          </div>

          <div :if={@active_tab == "models"} class="space-y-6">
            <.models_section
              models_result={@models_result}
              model_values={@model_values}
              model_test_status={@model_test_status}
            />
          </div>

          <div :if={@active_tab == "system"} class="space-y-6">
            <div>
              <h2 class="text-heading">{gettext("Entorno")}</h2>
              <p class="text-caption mt-0.5">
                {gettext("Read-only — loaded from environment variables at startup.")}
              </p>
            </div>

            <.config_section
              icon="hero-cpu-chip"
              title={gettext("Inference API")}
              subtitle={gettext("LLM, embeddings, and reranking")}
            >
              <.config_row
                label={gettext("Status")}
                env="DRAN_INFERENCE_API_URL"
                description={
                  gettext(
                    "Whether the inference API is configured. Read-only — set via environment variable."
                  )
                }
              >
                <div class="flex items-center gap-3 flex-wrap">
                  <.inference_status_badge
                    test={@inference_test}
                    configured={Config.enabled?()}
                  />
                  <button
                    phx-click="test_inference"
                    disabled={@inference_test == :testing}
                    class={[
                      "btn btn-xs gap-2 transition-all duration-150",
                      @inference_test == :testing && "btn-ghost opacity-60",
                      @inference_test != :testing && "btn-ghost hover:bg-primary/10"
                    ]}
                  >
                    <.icon
                      name={if @inference_test == :testing, do: "hero-arrow-path", else: "hero-bolt"}
                      class={"size-4 #{if @inference_test == :testing, do: "animate-spin", else: ""}"}
                    />
                    {if @inference_test == :testing,
                      do: gettext("Probando..."),
                      else: gettext("Probar conexión")}
                  </button>
                </div>
              </.config_row>
              <.config_row
                label={gettext("API URL")}
                env="DRAN_INFERENCE_API_URL"
                description={
                  gettext(
                    "Base URL of the OpenAI-compatible inference server. Read-only — set via environment variable."
                  )
                }
              >
                <code class="text-sm font-mono text-primary">
                  {Config.base_url() || "—"}
                </code>
              </.config_row>
              <.config_row
                label={gettext("API Key")}
                env="DRAN_INFERENCE_API_KEY"
                description={
                  gettext(
                    "Bearer token sent to the inference API. Read-only — set via environment variable."
                  )
                }
              >
                <span class="text-sm text-base-content/60">
                  {if Config.api_key(), do: "••••••••", else: "—"}
                </span>
              </.config_row>
              <.config_row
                label={gettext("Chat model")}
                env="DRAN_INFERENCE_CHAT_MODEL"
                description={
                  gettext(
                    "Effective model for chat and agents (web override or env default). See “Modelos” above to override."
                  )
                }
              >
                <code class="text-sm font-mono text-primary">
                  {Config.chat_model() || "—"}
                </code>
              </.config_row>
              <.config_row
                label={gettext("Embedding model")}
                env="DRAN_INFERENCE_EMBEDDING_MODEL"
                description={
                  gettext(
                    "Effective model for embeddings (web override or env default). See “Modelos” above to override."
                  )
                }
              >
                <code class="text-sm font-mono text-primary">
                  {Config.embedding_model() || "—"}
                </code>
              </.config_row>
              <.config_row
                label={gettext("Embedding dimensions")}
                description={
                  gettext(
                    "Vector dimensionality returned by the embedding model. Read-only — fixed at 1024."
                  )
                }
              >
                <span class="text-sm text-base-content/60">{Config.embedding_dimensions()}</span>
              </.config_row>
              <.config_row
                label={gettext("Embedding body limit")}
                env="DRAN_EMBEDDING_BODY_LIMIT"
                description={
                  gettext(
                    "Maximum text length (in characters) sent to the embedding API per call. Read-only — set via environment variable."
                  )
                }
              >
                <span class="text-sm text-base-content/60">
                  {Config.embedding_body_limit()} {gettext("chars")}
                </span>
              </.config_row>
              <.config_row
                label={gettext("Rerank model")}
                env="DRAN_INFERENCE_RERANK_MODEL"
                description={
                  gettext(
                    "Effective model for re-ranking search results (web override or env default). See “Modelos” above to override."
                  )
                }
              >
                <code class="text-sm font-mono text-primary">
                  {Config.rerank_model() || "—"}
                </code>
              </.config_row>
              <.config_row
                label={gettext("Rerank enabled")}
                env="DRAN_INFERENCE_USE_RERANK"
                description={
                  gettext(
                    "Whether semantic search results are re-ranked by relevance. Read-only — set via environment variable."
                  )
                }
              >
                <.status_badge active={Config.use_rerank?()} />
              </.config_row>
              <.config_row
                label={gettext("Request timeout")}
                env="DRAN_INFERENCE_TIMEOUT"
                description={
                  gettext(
                    "HTTP timeout for inference API requests, in milliseconds. Read-only — set via environment variable."
                  )
                }
              >
                <span class="text-sm text-base-content/60">{Config.timeout()} {gettext("ms")}</span>
              </.config_row>
            </.config_section>

            <.config_section
              icon="hero-bolt"
              title={gettext("Agents")}
              subtitle={gettext("Autonomous agents")}
            >
              <.config_row
                label={gettext("Max steps")}
                env="AGENT_MAX_STEPS"
                description={
                  gettext(
                    "Maximum number of steps an autonomous agent can take in a single run. Read-only — set via environment variable."
                  )
                }
              >
                <span class="text-sm text-base-content/60">
                  {Application.get_env(:dran, :agent_max_steps, 150)}
                </span>
              </.config_row>
              <.config_row
                label={gettext("Per-step timeout")}
                env="AGENT_PER_STEP_TIMEOUT"
                description={
                  gettext(
                    "Maximum wall-clock time per agent step, in milliseconds. Read-only — set via environment variable."
                  )
                }
              >
                <span class="text-sm text-base-content/60">
                  {Application.get_env(:dran, :agent_per_step_timeout, 120_000)} {gettext("ms")}
                </span>
              </.config_row>
            </.config_section>

            <.config_section
              icon="hero-paper-clip"
              title={gettext("Uploads")}
              subtitle={gettext("File attachment storage")}
            >
              <.config_row
                label={gettext("Directory")}
                env="UPLOADS_DIR"
                description={
                  gettext(
                    "Filesystem directory where uploaded attachments are stored. Read-only — set via environment variable."
                  )
                }
              >
                <code class="text-sm font-mono text-primary">
                  {Application.get_env(:dran, :uploads, [])
                  |> Keyword.get(:dir, "priv/static/uploads")}
                </code>
              </.config_row>
              <.config_row
                label={gettext("Max file size")}
                env="UPLOADS_MAX_SIZE"
                description={
                  gettext(
                    "Maximum allowed size for a single uploaded file. Read-only — set via environment variable."
                  )
                }
              >
                <span class="text-sm text-base-content/60">
                  {Application.get_env(:dran, :uploads, [])
                  |> Keyword.get(:max_size, 104_857_600)
                  |> format_bytes()}
                </span>
              </.config_row>
            </.config_section>
          </div>

          <%!-- Danger zone — destructive operations --%>
          <div :if={@active_tab == "danger"}>
            <.danger_zone_section context_slug={@context_slug} />
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # -- View components --------------------------------------------------------

  attr :icon, :string, default: nil
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  slot :inner_block, required: true

  defp config_section(assigns) do
    ~H"""
    <section class="surface-2 rounded-2xl overflow-hidden">
      <header class="flex items-start gap-3 px-5 py-4 border-b border-base-content/10">
        <div
          :if={@icon}
          class="shrink-0 size-8 rounded-lg flex items-center justify-center bg-primary/10"
        >
          <.icon name={@icon} class="size-4 text-primary" />
        </div>
        <div class="min-w-0">
          <h2 class="text-heading">{@title}</h2>
          <p :if={@subtitle} class="text-caption mt-0.5">{@subtitle}</p>
        </div>
      </header>
      <div class="divide-y divide-base-content/10">
        {render_slot(@inner_block)}
      </div>
    </section>
    """
  end

  attr :label, :string, required: true
  attr :env, :string, default: nil
  attr :description, :string, default: nil
  slot :inner_block, required: true

  defp config_row(assigns) do
    ~H"""
    <div class="flex items-start justify-between px-5 py-3 gap-4">
      <div class="min-w-0 flex-1">
        <div class="flex items-baseline gap-2">
          <span class="text-sm text-base-content/70 shrink-0">{@label}</span>
          <code :if={@env} class="text-xs font-mono text-base-content/40 truncate">
            {@env}
          </code>
        </div>
        <p :if={@description} class="text-xs text-base-content/60 mt-1">
          {@description}
        </p>
      </div>
      <div class="shrink-0 text-right pt-0.5">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  attr :form, :any, required: true
  attr :props_backfill, :atom, default: :idle

  defp brain_tuning_section(assigns) do
    ~H"""
    <section class="surface-2 rounded-2xl overflow-hidden">
      <header class="flex items-start gap-3 px-5 py-4 border-b border-base-content/10">
        <div class="shrink-0 size-8 rounded-lg flex items-center justify-center bg-accent/10">
          <.icon name="hero-adjustments-horizontal" class="size-4 text-accent" />
        </div>
        <div class="min-w-0 flex-1">
          <h2 class="text-heading">{gettext("Brain tuning")}</h2>
          <p class="text-caption mt-0.5">
            {gettext("Semantic thresholds and agent limits")}
          </p>
        </div>
      </header>

      <.form
        for={@form}
        id="brain-tuning-form"
        phx-submit="save"
        class="px-5 py-5 space-y-5"
      >
        <%!-- Agent limits --%>
        <div class="space-y-2">
          <h3 class="text-caption font-semibold text-base-content/60 uppercase tracking-wider">
            {gettext("Agent limits")}
          </h3>
          <div class="space-y-4">
            <div>
              <.input
                field={@form[:agent_max_pages]}
                type="number"
                label={gettext("Max pages per run")}
              />
              <p class="text-xs text-base-content/60 mt-1.5">
                {gettext(
                  "Maximum number of pages the autonomous agents will create in a single run. Higher values mean longer runs and more content per run. Default: 10."
                )}
              </p>
            </div>
            <div>
              <.input
                field={@form[:entity_linker_enabled]}
                type="checkbox"
                label={gettext("Entity linker (auto-create entities from page mentions)")}
              />
              <p class="text-xs text-base-content/60 mt-1.5">
                {gettext(
                  "When enabled, the augmenter auto-creates entity pages for named things (people, companies, tools) mentioned in page bodies. Disable for manual-only entity creation."
                )}
              </p>
            </div>
          </div>
        </div>

        <%!-- Advanced: semantic thresholds --%>
        <details class="group rounded-xl border border-base-content/10 px-4 py-3">
          <summary class="flex items-center gap-2 cursor-pointer select-none">
            <.icon
              name="hero-chevron-right"
              class="size-4 shrink-0 text-base-content/40 transition-transform duration-150 group-open:rotate-90"
            />
            <.icon name="hero-adjustments-horizontal" class="size-4 text-base-content/40" />
            <span class="text-sm font-semibold text-base-content/70">
              {gettext("Avanzado")}
            </span>
          </summary>
          <div class="mt-4 space-y-2">
            <h3 class="text-caption font-semibold text-base-content/60 uppercase tracking-wider">
              {gettext("Semantic thresholds")}
            </h3>
            <div class="grid grid-cols-1 sm:grid-cols-3 gap-4">
              <.input
                field={@form[:semantic_threshold_short]}
                type="number"
                step="0.01"
                label={gettext("Short")}
              />
              <.input
                field={@form[:semantic_threshold_mid]}
                type="number"
                step="0.01"
                label={gettext("Mid")}
              />
              <.input
                field={@form[:semantic_threshold_long]}
                type="number"
                step="0.01"
                label={gettext("Long")}
              />
            </div>
            <p class="text-xs text-base-content/60">
              {gettext(
                "Minimum cosine similarity (0.0–1.0) required for a semantic relation between pages to be created or kept. Higher values produce fewer, stronger relations. Applied by text length bucket (short/mid/long body)."
              )}
            </p>
          </div>
        </details>

        <%!-- Save row --%>
        <div class="flex justify-end pt-3 border-t border-base-content/10">
          <button
            type="submit"
            class="btn btn-primary btn-sm transition-colors active:scale-95"
            phx-disable-with={gettext("Saving…")}
          >
            <.icon name="hero-check" class="size-4" />
            {gettext("Save")}
          </button>
        </div>
      </.form>
    </section>

    <%!-- Props backfill --%>
    <section class="surface-2 rounded-2xl overflow-hidden mt-6">
      <header class="flex items-start gap-3 px-5 py-4 border-b border-base-content/10">
        <div class="shrink-0 size-8 rounded-lg flex items-center justify-center bg-secondary/10">
          <.icon name="hero-arrow-path-rounded-square" class="size-4 text-secondary" />
        </div>
        <div class="min-w-0 flex-1">
          <h2 class="text-heading">{gettext("Props materialization")}</h2>
          <p class="text-caption mt-0.5">
            {gettext(
              "Turn meta.props custom properties into typed graph relations (works_in, has_tier, based_in, written_in, built_with)."
            )}
          </p>
        </div>
      </header>

      <div class="px-5 py-5 space-y-4">
        <p class="text-sm text-base-content/70">
          {gettext(
            "Pages created before props materialization (or with props added after their last augmentation) carry metadata the graph cannot see. Run this to backfill typed relations for every page with non-empty meta.props."
          )}
        </p>

        <div class="flex items-center gap-3">
          <button
            phx-click="run_props_backfill"
            disabled={@props_backfill == :running}
            class={[
              "btn btn-sm gap-2 transition-all duration-150",
              @props_backfill == :running && "btn-ghost opacity-60",
              @props_backfill != :running && "btn-secondary hover:brightness-110"
            ]}
          >
            <.icon
              name={
                if @props_backfill == :running,
                  do: "hero-arrow-path",
                  else: "hero-bolt"
              }
              class={"size-4 #{if @props_backfill == :running, do: "animate-spin", else: ""}"}
            />
            {if @props_backfill == :running,
              do: gettext("Running…"),
              else: gettext("Run backfill")}
          </button>
          <span :if={@props_backfill == :running} class="text-xs text-base-content/50">
            {gettext("Processing pages with props in the background…")}
          </span>
        </div>
      </div>
    </section>
    """
  end

  # ── Jobs panel ──────────────────────────────────────────────────────────────

  attr :jobs, :list, required: true
  attr :running_jobs, :any, required: true

  defp jobs_section(assigns) do
    ~H"""
    <section class="surface-2 rounded-2xl overflow-hidden mt-6">
      <header class="flex items-start gap-3 px-5 py-4 border-b border-base-content/10">
        <div class="shrink-0 size-8 rounded-lg flex items-center justify-center bg-primary/10">
          <.icon name="hero-clock" class="size-4 text-primary" />
        </div>
        <div class="min-w-0 flex-1">
          <h2 class="text-heading">{gettext("Jobs programados")}</h2>
          <p class="text-caption mt-0.5">
            {gettext(
              "Activa o desactiva los jobs recurrentes del cerebro. El toggle afecta solo las corridas programadas — \"Correr ahora\" siempre ejecuta."
            )}
          </p>
        </div>
      </header>

      <div class="overflow-x-auto">
        <table class="table table-sm">
          <thead>
            <tr>
              <th>{gettext("Job")}</th>
              <th>{gettext("Schedule")}</th>
              <th>{gettext("Activo")}</th>
              <th>{gettext("Último run")}</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={job <- @jobs} id={"job-row-#{job.key}"}>
              <td>
                <div class="font-medium">{job.label}</div>
                <div class="text-xs text-base-content/50 max-w-xs">{job.description}</div>
              </td>
              <td>
                <code class="text-xs font-mono text-base-content/60">{job.schedule}</code>
              </td>
              <td>
                <input
                  type="checkbox"
                  id={"job-toggle-#{job.key}"}
                  checked={job.enabled?}
                  phx-click="toggle_job"
                  phx-value-key={job.key}
                  class="toggle toggle-sm toggle-primary"
                />
              </td>
              <td>
                <%= if job.last_run do %>
                  <div class="flex items-center gap-2 flex-wrap">
                    <.job_status_badge status={job.last_run.status} />
                    <.link
                      navigate={
                        PageTypes.page_show_path(%{page_type: "report", slug: job.last_run.slug})
                      }
                      class="link link-hover text-xs text-base-content/70"
                    >
                      {relative_time(job.last_run.at)}
                    </.link>
                    <span class="text-xs text-base-content/50">
                      {format_duration(job.last_run.duration_ms)}
                    </span>
                  </div>
                <% else %>
                  <span class="badge badge-ghost badge-sm">{gettext("Nunca")}</span>
                <% end %>
              </td>
              <td>
                <% running = MapSet.member?(@running_jobs, job.key) %>
                <button
                  type="button"
                  id={"job-run-#{job.key}"}
                  phx-click="run_job"
                  phx-value-key={job.key}
                  disabled={running}
                  class={[
                    "btn btn-xs gap-2 transition-all duration-150",
                    running && "btn-ghost opacity-60",
                    !running && "btn-ghost hover:bg-primary/10"
                  ]}
                >
                  <.icon
                    name={if running, do: "hero-arrow-path", else: "hero-bolt"}
                    class={"size-4 #{if running, do: "animate-spin", else: ""}"}
                  />
                  {if running, do: gettext("Corriendo…"), else: gettext("Correr ahora")}
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
    """
  end

  attr :status, :string, required: true

  defp job_status_badge(assigns) do
    ~H"""
    <span class={[
      "badge badge-sm",
      @status == "ok" && "badge-success",
      @status == "error" && "badge-error",
      @status not in ["ok", "error"] && "badge-ghost"
    ]}>
      {@status}
    </span>
    """
  end

  attr :models_result, :any, required: true
  attr :model_values, :map, required: true
  attr :model_test_status, :map, required: true

  defp models_section(assigns) do
    ~H"""
    <section class="surface-2 rounded-2xl overflow-hidden">
      <header class="flex items-start gap-3 px-5 py-4 border-b border-base-content/10">
        <div class="shrink-0 size-8 rounded-lg flex items-center justify-center bg-primary/10">
          <.icon name="hero-cpu-chip" class="size-4 text-primary" />
        </div>
        <div class="min-w-0 flex-1">
          <h2 class="text-heading">{gettext("Modelos")}</h2>
          <p class="text-caption mt-0.5">
            {gettext("Pick the model used for each purpose from the provider's model list.")}
          </p>
        </div>
      </header>

      <.form
        for={to_form(%{}, as: :models)}
        id="models-form"
        phx-submit="save_models"
        class="px-5 py-5 space-y-5"
      >
        <p :if={match?({:error, _}, @models_result)} class="text-xs text-base-content/60">
          {gettext(
            "API no disponible — los modelos no pueden listarse. Aún puedes escribir un override manual, o revisa DRAN_INFERENCE_API_URL."
          )}
        </p>

        <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
          <%= for {key, label_fn, desc_fn} <- model_purposes() do %>
            <% current = Map.fetch!(@model_values, key) %>
            <% options = model_options(@models_result, current) %>
            <% test_status = Map.get(@model_test_status, key, nil) %>
            <div>
              <div class="flex items-end gap-2">
                <div class="flex-1">
                  <.input
                    id={"models_#{key}"}
                    name={"models[#{key}]"}
                    type="select"
                    label={label_fn.()}
                    options={options}
                    value={current}
                    prompt={gettext("Selecciona un modelo")}
                  />
                </div>
                <button
                  type="button"
                  id={"test_model_#{key}"}
                  phx-hook=".ModelTest"
                  data-model-key={key}
                  data-model-select={"models_#{key}"}
                  disabled={test_status == :testing}
                  class={[
                    "btn btn-xs gap-1.5 mb-1 transition-all duration-150 active:scale-95",
                    test_status == :testing && "btn-ghost opacity-60",
                    test_status != :testing && "btn-ghost hover:bg-primary/10"
                  ]}
                >
                  <.icon
                    name={if test_status == :testing, do: "hero-arrow-path", else: "hero-bolt"}
                    class={"size-3.5 #{if test_status == :testing, do: "animate-spin", else: ""}"}
                  />
                  {if test_status == :testing, do: gettext("Probando..."), else: gettext("Probar")}
                </button>
              </div>
              <p class="text-xs text-base-content/60 mt-1.5">
                {desc_fn.()}
              </p>
              <div
                :if={test_status != nil && test_status != :testing}
                class="mt-1.5 text-xs"
              >
                <span
                  :if={match?({:ok, _}, test_status)}
                  class="inline-flex items-center gap-1 text-success"
                >
                  <.icon name="hero-check-circle" class="size-3.5" />
                  {gettext("OK · %{ms} ms", ms: elem(test_status, 1))}
                </span>
                <span
                  :if={match?({:error, _}, test_status)}
                  class="inline-flex items-center gap-1 text-error"
                >
                  <.icon name="hero-x-circle" class="size-3.5" />
                  {gettext("Error: %{reason}", reason: format_model_error(elem(test_status, 1)))}
                </span>
              </div>
            </div>
          <% end %>
        </div>

        <div class="flex justify-end pt-3 border-t border-base-content/10">
          <button
            type="submit"
            class="btn btn-primary btn-sm transition-colors active:scale-95"
            phx-disable-with={gettext("Saving…")}
          >
            <.icon name="hero-check" class="size-4" />
            {gettext("Save")}
          </button>
        </div>
      </.form>
    </section>
    """
  end

  # Builds the <option> list for a purpose's select.
  # - Starts with the models fetched from the provider's `/v1/models`.
  # - If the current saved value is not in that list, it's appended so the
  #   effective selection is always visible (e.g. provider removed the model).
  defp model_options(models_result, current) do
    fetched =
      case models_result do
        {:ok, ids} -> ids
        _ -> []
      end

    fetched
    |> maybe_prepend(current)
    |> Enum.uniq()
    |> Enum.map(fn id -> {id, id} end)
  end

  defp maybe_prepend(list, nil), do: list
  defp maybe_prepend(list, ""), do: list

  defp maybe_prepend(list, value) do
    if value in list, do: list, else: [value | list]
  end

  attr :active, :boolean, required: true

  defp status_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center gap-1.5 px-2 py-0.5 text-xs font-medium rounded-full",
      @active && "bg-success/15 text-success",
      !@active && "bg-base-200 text-base-content/50"
    ]}>
      <span class={[
        "size-1.5 rounded-full",
        @active && "bg-success",
        !@active && "bg-base-content/30"
      ]} />
      {if @active, do: gettext("Enabled"), else: gettext("Disabled")}
    </span>
    """
  end

  attr :test, :any, default: nil
  attr :configured, :boolean, default: false

  defp inference_status_badge(assigns) do
    ~H"""
    <div class="flex items-center gap-2 flex-wrap">
      <%= cond do %>
        <% @test == :testing -> %>
          <span class="loading loading-dots loading-xs text-info"></span>
          <span class="text-info text-xs font-medium">{gettext("Probando...")}</span>
        <% match?({:ok, _}, @test) -> %>
          <% {:ok, r} = @test %>
          <span class="inline-flex items-center gap-1.5 px-2 py-0.5 text-xs font-medium rounded-full bg-success/15 text-success">
            <.icon name="hero-check-circle" class="size-3" />
            {gettext("Responde")}
          </span>
          <span class="text-xs text-base-content/50">
            {r.latency_ms}ms · {r.models} {gettext("modelos")}
          </span>
        <% match?({:error, _}, @test) -> %>
          <% {:error, reason} = @test %>
          <span class="inline-flex items-center gap-1.5 px-2 py-0.5 text-xs font-medium rounded-full bg-error/15 text-error">
            <.icon name="hero-x-circle" class="size-3" />
            {gettext("Sin conexión")}
          </span>
          <span class="text-xs text-error/70">
            {format_inference_error(reason)}
          </span>
        <% @configured -> %>
          <span class="inline-flex items-center gap-1.5 px-2 py-0.5 text-xs font-medium rounded-full bg-info/15 text-info">
            <.icon name="hero-server" class="size-3" />
            {gettext("Configurada")}
          </span>
        <% true -> %>
          <span class="inline-flex items-center gap-1.5 px-2 py-0.5 text-xs font-medium rounded-full bg-base-200 text-base-content/50">
            <.icon name="hero-x-mark" class="size-3" />
            {gettext("No configurada")}
          </span>
      <% end %>
    </div>
    """
  end

  defp format_inference_error(:not_configured), do: gettext("API no configurada")

  defp format_inference_error(%Req.TransportError{reason: reason}) do
    case reason do
      :econnrefused -> gettext("Connection refused — el servidor no responde")
      :timeout -> gettext("Timeout — el servidor tardó demasiado")
      :nxdomain -> gettext("Dominio no resuelto")
      _ -> "TransportError: #{inspect(reason)}"
    end
  end

  defp format_inference_error({:http_error, status, _body}) do
    gettext("HTTP %{status}", status: status)
  end

  defp format_inference_error(reason), do: inspect(reason)

  defp format_bytes(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 1)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 1)} MB"
      bytes >= 1_024 -> "#{Float.round(bytes / 1_024, 1)} KB"
      true -> "#{bytes} B"
    end
  end

  defp format_bytes(_), do: "—"

  # Compact duration for job run reports: "450 ms" under a second, "1.2 s" above.
  defp format_duration(nil), do: "—"
  defp format_duration(ms) when is_integer(ms) and ms < 1000, do: "#{ms} ms"
  defp format_duration(ms) when is_integer(ms), do: "#{Float.round(ms / 1000, 1)} s"

  # Relative time for the jobs panel ("justo ahora", "hace 3 h"…). Same msgids
  # as ActivityLive so the existing translations are reused.
  defp relative_time(%DateTime{} = dt) do
    now = DateTime.utc_now()
    diff = DateTime.diff(now, dt, :second)
    relative_time_from_seconds(diff)
  end

  defp relative_time(%NaiveDateTime{} = ndt) do
    {:ok, dt} = DateTime.from_naive(ndt, "Etc/UTC")
    relative_time(dt)
  end

  defp relative_time(_), do: ""

  defp relative_time_from_seconds(sec) when sec < 60, do: gettext("just now")

  defp relative_time_from_seconds(sec) when sec < 3600,
    do: gettext("%{n}m ago", n: div(sec, 60))

  defp relative_time_from_seconds(sec) when sec < 86_400,
    do: gettext("%{n}h ago", n: div(sec, 3600))

  defp relative_time_from_seconds(sec) when sec < 604_800,
    do: gettext("%{n}d ago", n: div(sec, 86_400))

  defp relative_time_from_seconds(sec) when sec < 2_592_000,
    do: gettext("%{n}w ago", n: div(sec, 604_800))

  defp relative_time_from_seconds(sec),
    do: gettext("%{n}mo ago", n: div(sec, 2_592_000))

  defp tab_label("users"), do: gettext("Users")
  defp tab_label("contexts"), do: gettext("Contexts")
  defp tab_label("api_keys"), do: gettext("API Keys")
  defp tab_label("brain"), do: gettext("Brain")
  defp tab_label("models"), do: gettext("Models")
  defp tab_label("system"), do: gettext("System")
  defp tab_label("danger"), do: gettext("Danger zone")

  attr :context_slug, :string, required: true

  defp danger_zone_section(assigns) do
    ~H"""
    <section class="surface-2 rounded-2xl overflow-hidden border border-error/20">
      <header class="flex items-start gap-3 px-5 py-4 border-b border-error/20">
        <div class="shrink-0 size-8 rounded-lg flex items-center justify-center bg-error/10">
          <.icon name="hero-exclamation-triangle" class="size-4 text-error" />
        </div>
        <div class="min-w-0 flex-1">
          <h2 class="text-heading text-error">{gettext("Zona de peligro")}</h2>
          <p class="text-caption mt-0.5">
            {gettext("Operaciones destructivas e irreversibles.")}
          </p>
        </div>
      </header>

      <div class="px-5 py-5 space-y-4">
        <div>
          <h3 class="text-sm font-semibold text-base-content/80">
            {gettext("Borrar todo el contenido")}
          </h3>
          <p class="text-xs text-base-content/60 mt-1">
            {gettext(
              "Elimina todas las páginas, relaciones, versiones y registros de actividad del contexto actual. El contexto en sí se conserva. Esta acción no se puede deshacer."
            )}
          </p>
        </div>

        <.form
          for={to_form(%{}, as: :danger)}
          id="reset-context-form"
          phx-submit="reset_context"
          class="space-y-3"
        >
          <div>
            <label class="text-xs text-base-content/60 mb-1 block">
              {gettext("Para confirmar, escribe el slug del contexto:")}
              <code class="ml-1 font-mono text-error">{@context_slug}</code>
            </label>
            <.input
              field={to_form(%{}, as: :danger)[:confirmation]}
              type="text"
              placeholder={@context_slug}
              class="w-full"
            />
          </div>
          <button
            type="submit"
            data-confirm={
              gettext(
                "¿Estás seguro? Esto borrará TODO el contenido del contexto. No se puede deshacer."
              )
            }
            class="btn btn-error btn-sm"
          >
            <.icon name="hero-trash" class="size-4" />
            {gettext("Borrar todo el contenido")}
          </button>
        </.form>
      </div>
    </section>
    """
  end

  # ── API Keys section ──────────────────────────────────────────────────────

  attr :api_keys, :list, required: true
  attr :all_contexts, :list, required: true
  attr :form, :map, required: true
  attr :revealed_api_key, :map, default: nil

  def api_keys_section(assigns) do
    ~H"""
    <div class="space-y-6">
      <div>
        <h2 class="text-heading">{gettext("API Keys")}</h2>
        <p class="text-caption mt-0.5">
          {gettext(
            "Context-scoped keys for integrations and MCP clients. A key grants access to one context only — no user account needed."
          )}
        </p>
      </div>

      <%!-- Newly created / regenerated token — shown ONCE --%>
      <div
        :if={@revealed_api_key}
        class="card bg-success/10 border border-success/40"
        id="revealed-api-key-card"
      >
        <div class="card-body py-4 space-y-3">
          <div class="flex items-center justify-between">
            <h3 class="font-semibold text-success flex items-center gap-2">
              <.icon name="hero-key" class="size-5" />
              {gettext("Copy your new API key now — it won't be shown again")}
            </h3>
            <button
              type="button"
              phx-click="dismiss_revealed_key"
              class="btn btn-ghost btn-xs"
              title={gettext("Dismiss")}
            >
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </div>
          <div class="flex items-center gap-2">
            <code
              id="revealed-api-key-token"
              data-token={@revealed_api_key.token}
              class="flex-1 text-sm font-mono bg-base-100 rounded-md px-3 py-2 border border-success/40 select-all break-all"
            >
              {@revealed_api_key.token}
            </code>
            <button
              type="button"
              id="copy-revealed-key-btn"
              phx-hook=".CopyApiToken"
              class="btn btn-success btn-sm gap-1 transition-all active:scale-95"
            >
              <span data-copy-icon class="flex items-center gap-1">
                <.icon name="hero-clipboard-document" class="size-4" />
                {gettext("Copy")}
              </span>
              <span data-check-icon class="hidden items-center gap-1">
                <.icon name="hero-clipboard-document-check" class="size-4" />
                {gettext("Copied!")}
              </span>
            </button>
          </div>
        </div>
      </div>

      <%!-- Create new key form --%>
      <div class="card bg-base-100 border border-base-300">
        <div class="card-body">
          <h3 class="text-lg font-semibold">{gettext("Create API Key")}</h3>
          <.form for={@form} phx-submit="create_api_key" class="space-y-3" id="create-api-key-form">
            <div class="grid grid-cols-2 gap-3">
              <.input
                field={@form[:name]}
                label={gettext("Name")}
                type="text"
                placeholder={gettext("e.g. Hermes agent, backup script")}
                required
              />
              <div class="form-control">
                <label class="label">
                  <span class="label-text">{gettext("Context")}</span>
                </label>
                <select name="api_key[context_id]" class="select select-bordered w-full" required>
                  <option value="">{gettext("Select a context...")}</option>
                  <option :for={ctx <- @all_contexts} value={ctx.id}>{ctx.name}</option>
                </select>
              </div>
            </div>

            <button type="submit" class="btn btn-primary btn-sm">
              {gettext("Create Key")}
            </button>
          </.form>
        </div>
      </div>

      <%!-- Keys list --%>
      <div class="card bg-base-100 border border-base-300">
        <div class="card-body">
          <h3 class="text-lg font-semibold">{gettext("Existing Keys")}</h3>
          <div class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>{gettext("Name")}</th>
                  <th>{gettext("Context")}</th>
                  <th>{gettext("Token")}</th>
                  <th>{gettext("Status")}</th>
                  <th>{gettext("Created")}</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <tr :for={key <- @api_keys} id={"api-key-#{key.id}"}>
                  <td class="font-medium">{key.name}</td>
                  <td>
                    <span class="badge badge-ghost badge-sm">
                      {if key.context, do: key.context.name, else: "—"}
                    </span>
                  </td>
                  <td>
                    <code class="text-xs">{key.token_prefix}••••••••••••</code>
                  </td>
                  <td>
                    <span :if={key.revoked_at} class="badge badge-error badge-sm">
                      {gettext("Revoked")}
                    </span>
                    <span :if={!key.revoked_at} class="badge badge-success badge-sm">
                      {gettext("Active")}
                    </span>
                  </td>
                  <td class="text-xs text-base-content/60">
                    {Calendar.strftime(key.inserted_at, "%Y-%m-%d")}
                  </td>
                  <td>
                    <div class="flex items-center gap-1">
                      <button
                        :if={!key.revoked_at}
                        type="button"
                        phx-click="revoke_api_key"
                        phx-value-id={key.id}
                        data-confirm={gettext("Revoke this key? It will stop working immediately.")}
                        class="btn btn-ghost btn-xs text-warning"
                        title={gettext("Revoke")}
                      >
                        <.icon name="hero-no-symbol" class="size-4" />
                      </button>
                      <button
                        :if={key.revoked_at}
                        type="button"
                        phx-click="restore_api_key"
                        phx-value-id={key.id}
                        class="btn btn-ghost btn-xs text-success"
                        title={gettext("Restore")}
                      >
                        <.icon name="hero-arrow-uturn-left" class="size-4" />
                      </button>
                      <button
                        type="button"
                        phx-click="regenerate_api_key"
                        phx-value-id={key.id}
                        data-confirm={
                          gettext(
                            "Regenerate this key? The current token stops working immediately and you'll get a new one."
                          )
                        }
                        class="btn btn-ghost btn-xs"
                        title={gettext("Regenerate")}
                      >
                        <.icon name="hero-arrow-path" class="size-4" />
                      </button>
                      <button
                        type="button"
                        phx-click="delete_api_key"
                        phx-value-id={key.id}
                        data-confirm={gettext("Delete this key permanently?")}
                        class="btn btn-ghost btn-xs text-error"
                        title={gettext("Delete")}
                      >
                        <.icon name="hero-trash" class="size-4" />
                      </button>
                    </div>
                  </td>
                </tr>
                <tr :if={@api_keys == []}>
                  <td colspan="6" class="text-center text-base-content/50 py-6">
                    {gettext("No API keys yet — create one above.")}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyApiToken">
        export default {
          mounted() {
            this.el.addEventListener("click", () => {
              const target = document.getElementById("revealed-api-key-token");
              if (!target) return;
              const text = target.dataset.token;
              if (!text) return;
              const copied = () => {
                const icon = this.el.querySelector("[data-copy-icon]");
                const check = this.el.querySelector("[data-check-icon]");
                if (icon && check) {
                  icon.classList.add("hidden");
                  check.classList.remove("hidden");
                  check.classList.add("flex");
                  setTimeout(() => {
                    icon.classList.remove("hidden");
                    check.classList.add("hidden");
                    check.classList.remove("flex");
                  }, 1500);
                }
              };
              if (navigator.clipboard && navigator.clipboard.writeText) {
                navigator.clipboard.writeText(text).then(copied);
              } else {
                const ta = document.createElement("textarea");
                ta.value = text;
                ta.setAttribute("readonly", "");
                ta.style.position = "absolute";
                ta.style.left = "-9999px";
                document.body.appendChild(ta);
                ta.select();
                try { document.execCommand("copy"); } catch (_e) { /* noop */ }
                document.body.removeChild(ta);
                copied();
              }
            });
          }
        }
      </script>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".ModelTest">
        export default {
          mounted() {
            this.el.addEventListener("click", () => {
              const selectId = this.el.dataset.modelSelect;
              const select = document.getElementById(selectId);
              const model = select ? select.value : "";
              this.pushEventTo(this.el, "test_model", {
                key: this.el.dataset.modelKey,
                model: model
              });
            });
          }
        }
      </script>
    </div>
    """
  end

  attr :users, :list, required: true
  attr :all_contexts, :list, required: true
  attr :form, :map, required: true

  def users_section(assigns) do
    ~H"""
    <div class="space-y-6">
      <div>
        <h2 class="text-heading">{gettext("Users")}</h2>
        <p class="text-caption mt-0.5">{gettext("Manage users and their context access.")}</p>
      </div>

      <%!-- Google open signup toggle --%>
      <div
        :if={DranWeb.OAuth.Google.configured?()}
        class="card bg-base-100 border border-base-300 mb-4"
      >
        <div class="card-body p-4 flex-row items-center justify-between gap-4">
          <div>
            <h3 class="text-sm font-semibold flex items-center gap-2">
              <.icon name="hero-globe-alt" class="size-4 text-primary/70" />
              {gettext("Google auto-signup")}
            </h3>
            <p class="text-xs text-base-content/50 mt-1">
              {gettext(
                "Allow anyone with a Google account to sign up and browse wikis. Users are created without context access."
              )}
            </p>
          </div>
          <input
            type="checkbox"
            checked={Map.get(assigns, :wiki_google_open_signup, false)}
            phx-click="toggle_wiki_google_signup"
            class="toggle toggle-sm toggle-primary"
          />
        </div>
      </div>

      <%!-- Add new user form --%>
      <div class="card bg-base-100 border border-base-300">
        <div class="card-body">
          <h3 class="text-lg font-semibold">{gettext("Add User")}</h3>
          <.form for={@form} phx-submit="create_user" class="space-y-3">
            <div class="grid grid-cols-2 gap-3">
              <.input field={@form[:email]} label={gettext("Email")} type="email" required />
              <.input field={@form[:name]} label={gettext("Name")} />
            </div>

            <div>
              <label class="text-sm font-medium">{gettext("Contexts")}</label>
              <div class="flex flex-wrap gap-2 mt-2">
                <label :for={ctx <- @all_contexts} class="flex items-center gap-2">
                  <input
                    type="checkbox"
                    name="user[context_ids][]"
                    value={ctx.id}
                    class="checkbox checkbox-sm"
                  />
                  <span class="text-sm">{ctx.name}</span>
                </label>
              </div>
            </div>

            <button type="submit" class="btn btn-primary btn-sm">{gettext("Create User")}</button>
          </.form>
        </div>
      </div>

      <%!-- Users list --%>
      <div class="card bg-base-100 border border-base-300">
        <div class="card-body">
          <h3 class="text-lg font-semibold">{gettext("Existing Users")}</h3>
          <div class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>{gettext("Email")}</th>
                  <th>{gettext("Name")}</th>
                  <th>{gettext("Admin")}</th>
                  <th>{gettext("Contexts")}</th>
                  <th>{gettext("Default context")}</th>
                  <th>{gettext("API Token")}</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <tr :for={user <- @users}>
                  <td>{user.email}</td>
                  <td>{user.name}</td>
                  <td>
                    <span :if={user.is_admin} class="badge badge-primary badge-sm">Admin</span>
                  </td>
                  <td>
                    <div class="flex flex-wrap gap-1">
                      <span :for={ctx <- user.contexts} class="badge badge-ghost badge-sm">
                        {ctx.name}
                      </span>
                    </div>
                  </td>
                  <td>
                    <form phx-change="set_default_context" id={"default-context-form-#{user.id}"}>
                      <input type="hidden" name="user_id" value={user.id} />
                      <select
                        name="slug"
                        class="select select-bordered select-xs w-full max-w-[12rem]"
                        id={"default-context-select-#{user.id}"}
                      >
                        <option value="" selected={is_nil(user.default_context_slug)}>
                          {gettext("— Global default —")}
                        </option>
                        <option
                          :for={ctx <- @all_contexts}
                          value={ctx.slug}
                          selected={user.default_context_slug == ctx.slug}
                        >
                          {ctx.name}
                        </option>
                      </select>
                    </form>
                  </td>
                  <td>
                    <code class="text-xs">{String.slice(user.api_token, 0, 8)}...</code>
                  </td>
                  <td>
                    <button
                      phx-click="delete_user"
                      phx-value-id={user.id}
                      data-confirm={gettext("Delete this user?")}
                      class="btn btn-ghost btn-xs text-error"
                    >
                      <.icon name="hero-trash" class="size-4" />
                    </button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :contexts, :list, required: true
  attr :users, :list, required: true
  attr :form, :map, required: true
  attr :confirm_delete_context_id, :any, default: nil
  attr :managing_context_id, :any, default: nil
  attr :page_types_context_id, :any, default: nil
  attr :context_slug, :string, default: nil

  def contexts_section(assigns) do
    ~H"""
    <div class="space-y-6">
      <div>
        <h2 class="text-heading">{gettext("Contexts")}</h2>
        <p class="text-caption mt-0.5">
          {gettext("Create contexts and manage context access per user.")}
        </p>
      </div>

      <%!-- Create context form --%>
      <section class="surface-2 rounded-2xl overflow-hidden">
        <header class="flex items-start gap-3 px-5 py-4 border-b border-base-content/10">
          <div class="shrink-0 size-8 rounded-lg flex items-center justify-center bg-primary/10">
            <.icon name="hero-plus" class="size-4 text-primary" />
          </div>
          <div class="min-w-0">
            <h3 class="text-heading">{gettext("New context")}</h3>
            <p class="text-caption mt-0.5">
              {gettext("Create an isolated silo for your knowledge.")}
            </p>
          </div>
        </header>

        <.form
          for={@form}
          id="context-form"
          phx-change="validate_context"
          phx-submit="create_context"
          class="px-5 py-5 space-y-4"
        >
          <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <.input
              field={@form[:name]}
              type="text"
              label={gettext("Name")}
              placeholder={gettext("e.g. Personal")}
              class="w-full"
            />
            <.input
              field={@form[:slug]}
              type="text"
              label={gettext("Slug")}
              placeholder={gettext("e.g. personal")}
              class="w-full font-mono text-sm"
            />
          </div>
          <p class="text-caption">
            {gettext("The slug auto-derives from the name unless you edit it directly.")}
          </p>

          <div class="flex justify-end pt-1">
            <button
              type="submit"
              class="btn btn-primary btn-sm transition-colors active:scale-95"
              phx-disable-with={gettext("Creating…")}
            >
              <.icon name="hero-plus" class="size-4" />
              {gettext("Create")}
            </button>
          </div>
        </.form>
      </section>

      <%!-- Context list with user membership --%>
      <div class="space-y-4">
        <div
          :for={ctx <- @contexts}
          class={[
            "card bg-base-100 border border-base-300",
            @confirm_delete_context_id == ctx.id && "ring-2 ring-error/60 bg-error/5"
          ]}
        >
          <div class="card-body">
            <div class="flex items-start justify-between gap-4">
              <div>
                <h3 class="text-lg font-semibold">
                  {ctx.name}
                  <code class="text-sm text-base-content/60">({ctx.slug})</code>
                  <span :if={@context_slug == ctx.slug} class="text-caption text-primary">
                    · {gettext("current")}
                  </span>
                </h3>
                <p class="text-caption mt-1">
                  {ngettext(
                    "%{count} member",
                    "%{count} members",
                    Enum.count(@users, &Dran.Accounts.user_in_context?(&1, ctx))
                  )}
                </p>
              </div>

              <div class="flex items-center gap-2 shrink-0">
                <button
                  type="button"
                  phx-click="manage_page_types"
                  phx-value-id={ctx.id}
                  class="btn btn-ghost btn-xs"
                >
                  <.icon name="hero-squares-2x2" class="size-3.5" />
                  {gettext("Page types")}
                </button>

                <button
                  type="button"
                  phx-click="manage_context_users"
                  phx-value-id={ctx.id}
                  class="btn btn-ghost btn-xs"
                >
                  <.icon name="hero-users" class="size-3.5" />
                  {gettext("Manage users")}
                </button>

                <%= if @confirm_delete_context_id == ctx.id do %>
                  <span class="text-caption text-error mr-1 hidden sm:inline">
                    {gettext("Delete?")}
                  </span>
                  <button
                    type="button"
                    phx-click="delete_context"
                    phx-value-id={ctx.id}
                    class="btn btn-error btn-xs"
                  >
                    <.icon name="hero-check" class="size-3.5" />
                    {gettext("Confirm")}
                  </button>
                  <button
                    type="button"
                    phx-click="cancel_delete_context"
                    class="btn btn-ghost btn-xs"
                  >
                    {gettext("Cancel")}
                  </button>
                <% else %>
                  <button
                    type="button"
                    phx-click="ask_delete_context"
                    phx-value-id={ctx.id}
                    class="btn btn-ghost btn-xs text-error hover:bg-error/10"
                    title={gettext("Delete context")}
                  >
                    <.icon name="hero-trash" class="size-3.5" />
                  </button>
                <% end %>
              </div>
            </div>
          </div>
        </div>
      </div>

      <%!-- Manage users modal --%>
      <div
        :if={@managing_context_id}
        class="fixed inset-0 z-50 flex items-center justify-center bg-black/50"
        phx-click="close_context_users"
      >
        <div
          class="card bg-base-100 w-full max-w-md shadow-xl border border-base-300"
          phx-click-away="close_context_users"
        >
          <div class="card-body">
            <% managing_ctx = Enum.find(@contexts, &(&1.id == @managing_context_id)) %>
            <div class="flex items-start justify-between">
              <div>
                <h3 class="text-lg font-semibold">
                  {gettext("Manage users")}
                </h3>
                <p class="text-caption mt-0.5">
                  {if managing_ctx, do: managing_ctx.name, else: ""}
                </p>
              </div>
              <button
                type="button"
                phx-click="close_context_users"
                class="btn btn-ghost btn-xs"
              >
                <.icon name="hero-x-mark" class="size-4" />
              </button>
            </div>

            <div class="divide-y divide-base-300 mt-2">
              <label
                :for={user <- @users}
                class="flex items-center justify-between gap-3 py-2.5 cursor-pointer hover:bg-base-200/50 px-2 rounded-lg transition-colors"
              >
                <div class="min-w-0">
                  <p class="text-sm font-medium truncate">{user.email}</p>
                  <p :if={user.name} class="text-caption truncate">{user.name}</p>
                </div>
                <input
                  type="checkbox"
                  checked={managing_ctx && Dran.Accounts.user_in_context?(user, managing_ctx)}
                  phx-click="toggle_context_user"
                  phx-value-context_id={@managing_context_id}
                  phx-value-user_id={user.id}
                  class="checkbox checkbox-sm"
                />
              </label>

              <p :if={@users == []} class="text-caption py-4 text-center">
                {gettext("No users yet — create one in the Users tab.")}
              </p>
            </div>
          </div>
        </div>
      </div>

      <%!-- Page types modal --%>
      <div
        :if={@page_types_context_id}
        class="fixed inset-0 z-50 flex items-center justify-center bg-black/50"
        phx-click="close_page_types"
      >
        <div
          class="card bg-base-100 w-full max-w-md shadow-xl border border-base-300"
          phx-click-away="close_page_types"
        >
          <div class="card-body">
            <% pt_ctx = Enum.find(@contexts, &(&1.id == @page_types_context_id)) %>
            <div class="flex items-start justify-between">
              <div>
                <h3 class="text-lg font-semibold">
                  {gettext("Page types")}
                </h3>
                <p class="text-caption mt-0.5">
                  {if pt_ctx, do: pt_ctx.name, else: ""}
                </p>
              </div>
              <button
                type="button"
                phx-click="close_page_types"
                class="btn btn-ghost btn-xs"
              >
                <.icon name="hero-x-mark" class="size-4" />
              </button>
            </div>

            <p class="text-caption mt-1">
              {gettext(
                "Disabled types are hidden in the web UI and rejected in the MCP API for this context."
              )}
            </p>

            <div class="divide-y divide-base-300 mt-2">
              <label
                :for={page_type <- Dran.Brain.page_types()}
                class="flex items-center justify-between gap-3 py-2.5 cursor-pointer hover:bg-base-200/50 px-2 rounded-lg transition-colors"
              >
                <div class="min-w-0">
                  <p class="text-sm font-medium">{String.capitalize(page_type)}</p>
                  <p
                    :if={pt_ctx && page_type in (pt_ctx.disabled_page_types || [])}
                    class="text-xs text-error"
                  >
                    {gettext("Disabled")}
                  </p>
                  <p class="text-xs text-base-content/40">
                    {page_type_impact(page_type)}
                  </p>
                </div>
                <input
                  type="checkbox"
                  checked={pt_ctx && page_type not in (pt_ctx.disabled_page_types || [])}
                  phx-click="toggle_page_type"
                  phx-value-context_id={@page_types_context_id}
                  phx-value-page_type={page_type}
                  class="toggle toggle-sm toggle-primary"
                />
              </label>
            </div>

            <%!-- Wiki settings --%>
            <div class="border-t border-base-300 mt-4 pt-4 space-y-3">
              <h4 class="text-sm font-semibold">{gettext("Wiki")}</h4>

              <label class="flex items-center justify-between gap-3 cursor-pointer hover:bg-base-200/50 px-2 py-1.5 rounded-lg transition-colors">
                <div>
                  <p class="text-sm font-medium">{gettext("Enable wiki")}</p>
                  <p class="text-xs text-base-content/40">
                    {gettext("Make this context browseable in the wiki")}
                  </p>
                </div>
                <input
                  type="checkbox"
                  checked={pt_ctx && pt_ctx.wiki_enabled}
                  phx-click="toggle_wiki"
                  phx-value-context_id={@page_types_context_id}
                  class="toggle toggle-sm toggle-primary"
                />
              </label>

              <div :if={pt_ctx} class="px-2">
                <label class="text-sm font-medium block mb-1">{gettext("Wiki description")}</label>
                <textarea
                  class="textarea textarea-bordered w-full text-sm"
                  rows="2"
                  placeholder={gettext("Short description shown on the wiki home")}
                  phx-blur="update_wiki_description"
                  phx-value-context_id={@page_types_context_id}
                >{pt_ctx.wiki_description}</textarea>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
