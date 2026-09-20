defmodule Dran.Auth do
  @moduledoc """
  Instance-level auth and default-workspace helpers. Everything lives in the
  database — there are no environment variables behind any of it.

    * Admin API token — Settings key `"api_token"`. Legacy bearer token for
      API/agent access (full owner, no user row). Unset = disabled.
    * Instance — the ONE workspace row that carries the instance's settings
      (page types, features, tuning). `Dran.Auth.instance_workspace/0`; there is
      no default flag and no per-user landing workspace any more (W6).
    * No other control exists: no env var, no settings override.

  Web login is handled entirely by `Dran.Accounts` (email + bcrypt password)
  and the first-run `/setup` flow — there are no env-var login credentials.
  """

  @fallback_workspace_slug "personal"

  @doc """
  Bearer token for API/agent access (legacy admin token).

  Stored in the `settings` table; unset means the legacy admin token is
  DISABLED (fail closed on DB errors too). Generate or rotate it from
  /admin/system.
  """
  def api_token do
    Dran.Settings.get("api_token")
  rescue
    _ -> nil
  end

  @doc "Generates a random URL-safe token for the legacy admin bearer."
  def generate_token do
    :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
  end

  @doc """
  The instance: the ONE workspace row that carries the instance's settings
  (page types, features, tuning). Everything instance-scoped reads through here.

  W6 (contract-instance-visibility-20260919): there is no "flagged default" and
  no "sole workspace" rule any more — after the fold there is a single row, and
  the flag that used to choose among several columns (`is_default`) is gone.
  `nil` only on an empty database (fresh install before seeding).
  """
  def instance_workspace do
    the_instance()
  end

  @doc """
  The slug of the instance — where a session lands.

  The name still says "default": renaming it belongs to the vocabulary wave, and
  it is still true in the sense that the instance IS the default (and only)
  container. What it no longer does is CHOOSE: the `is_default` flag died with
  the multi-workspace model, so this resolves the single row's slug.
  """
  def default_workspace_slug do
    case the_instance() do
      %{slug: slug} when is_binary(slug) and slug != "" -> slug
      _ -> @fallback_workspace_slug
    end
  end

  @doc """
  The instance's display name (what the shell shows as the brain's name), else
  the slug-derived default.
  """
  def default_workspace_name do
    case the_instance() do
      %{name: name} when is_binary(name) and name != "" -> name
      _ -> String.capitalize(@fallback_workspace_slug)
    end
  end

  # The instance row lives in the DB: a missing or unavailable repo must never
  # break resolution — the fallbacks still answer.
  defp the_instance do
    Dran.Knowledge.the_instance()
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  @doc """
  Checks a bearer token against the configured legacy API token (admin).
  """
  def valid_token?(token) when is_binary(token), do: token == api_token()
  def valid_token?(_), do: false

  # ── Owner / created_by resolution ──

  # The synthetic user map built by the API auth pipelines carries the KEY as
  # the agent identity (W3): `:key_name` is `api_keys.name`, and `:agent_name`
  # is the X-Hermes-Agent header — resolved in ONE place
  # (`DranWeb.Router.require_api_token/2`), never re-derived here.
  # Legacy admin token maps to "system" for owner and "admin" for created_by.
  defp key_name(user), do: Map.get(user, :key_name)

  @doc """
  Resolve the owner identity for a page being created.

  Prefers the API key name; otherwise falls back to the authenticated user's
  email (the literal `"admin"` email maps to `"system"`), then `"system"` when
  no identity is available. Not client-settable.
  """
  def resolve_owner(user) when is_map(user) do
    key_name(user) ||
      case Map.get(user, :email) do
        "admin" -> "system"
        email when is_binary(email) -> email
        _ -> "system"
      end
  end

  def resolve_owner(_), do: "system"

  @doc """
  Resolve the created_by identity for a page being created.

  For API key auth: the `X-Hermes-Agent` header when it came, otherwise the
  key `name` (M7). For user auth, the user email. Falls back to `"system"`
  when no identity is available.
  """
  def resolve_created_by(user) when is_map(user) do
    Map.get(user, :agent_name) ||
      key_name(user) ||
      case Map.get(user, :email) do
        "admin" -> "admin"
        email when is_binary(email) -> email
        _ -> "system"
      end
  end

  def resolve_created_by(_), do: "system"

  @doc """
  Resolve the OWNER user id for content being written — the user that owns the
  agent behind the request. Injected server-side, never client-settable.

  * API key identity — `api_keys.created_by_user_id` (the user that created
    the key), or `nil` for keys with no creator (historical / system-created
    keys). The actor is no longer part of this chain (W3).
  * user identity (`%Dran.Accounts.User{}`) — that user.
  * legacy admin token / `nil` — `nil`: historical producer content is
    workspace-wide (see `Dran.ContentVisibility`).
  """
  def resolve_owner_user_id(%Dran.Accounts.User{id: id}), do: id

  def resolve_owner_user_id(user) when is_map(user) do
    Map.get(user, :created_by_user_id)
  end

  def resolve_owner_user_id(_), do: nil

  @doc """
  Extract the Hermes profile name from the request headers
  (`X-Hermes-Agent`), or `nil` when absent. Plug lowercases header names.

  It is attribution, not authorization: the value is persisted as
  `agent_name` on the written content and never widens access.
  """
  def agent_name_from_headers(headers) when is_list(headers) do
    Enum.find_value(headers, fn
      {"x-hermes-agent", value} when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> String.slice(trimmed, 0, 120)
        end

      _ ->
        nil
    end)
  end

  def agent_name_from_headers(_), do: nil
end
