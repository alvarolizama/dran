---
name: dran-dev-auth-surface
description: "Use when auditing Dran REST authorization layers."
---

# dran-dev-auth-surface — Authorization map and audit method

Dran has THREE authorization layers that are easy to conflate; knowing
which one a route actually uses is the whole task when auditing or adding
endpoints. This skill holds the map and the audit procedure that found
real IDORs with it.

## The map

| Surface | Authn | Authz | Failure shape |
|---|---|---|---|
| REST read (`scope "/api"` + `:api_read_access`) | `require_api_token` (Bearer → 3 identity shapes) | `require_read_access` → `ResourceAuthorization.authorize(user, :read, ws_id)` per request, fail-closed when no resolvable workspace | 403 JSON |
| REST write (`:api_write_access`) | idem | `require_write_access` → `authorize(user, :write, ws_id)` for ALL identity shapes (API keys via `:access_levels`, per-user tokens via membership) | 403 JSON |
| Agent tools (Hermes plugin → REST) | key's actor + per-workspace `access_levels` | `resource_authorization.ex: authorize/3` per route; write routes behind `:require_write_access` | `403` |
| Browser LiveViews | session | `:auth` / `:workspace_access` / `:admin` pipelines, role checks in LiveViews | redirect |

Identity shapes from `require_api_token`: legacy admin token
(`%{is_owner: true}`, `workspaces: :all`), per-user token
(`%Accounts.User{}`), context API key (synthetic map with `:workspaces`,
`:access_levels`, `:actor`). `ResourceAuthorization.do_authorize/3` has a
clause per shape — a plug that only handles ONE shape silently passes the
others through (that is how the write bypass existed).

Who each shape IS as an identity (actor name, key creator, and why
"who owns this agent" is the wrong frame): skill `dran-actor-model`.

`get_requested_workspace_id/1` resolves the workspace from
`params["workspace_id"] || params["workspace"] || params["slug"] ||
query_params["workspace"]` — controllers read DIFFERENT keys, so the plug
must check them all or a route family escapes authorization.

## Audit procedure (row-level)

1. Read the ROUTER first, not the controllers: list every `scope`/`pipe_through`
   and classify each route read/write. The pipeline names promise more than
   they deliver — verify by reading the plug body, not its name.
2. For each read route, trace the controller's workspace resolution
   (`with_context` resolves by slug and executes — it authorizes NOTHING)
   and confirm a plug upstream authorizes against the acting identity.
3. Endpoint families that need EXEMPTION from a read plug (they list or
   self-describe across workspaces): scope them to their own pipeline and
   scope their payload by identity IN the controller — `GET /api/workspaces`
   must list only reachable workspaces, `GET /api/agent/config` returns
   only the key's own matrix. An exemption without in-controller scoping is
   the same leak one layer down.
4. Hunt fallback-to-global paths: `resolve_workspace_id(nil) -> nil` + a
   list/search function that does NOT filter on nil workspace = every
   workspace's data. Search controllers for `|| conn.query_params[...]`
   chains and or-else-nil resolution.
5. For write plugs, feed each IDENTITY SHAPE through mentally — a plug that
   checks `Map.has_key?(user, :access_levels)` only guards API keys.
6. Verify a reported finding against the code before fixing: subagent
   auditors over-report. Confirm the exact line chain (plug → helper →
   controller) — a "tool args not validated" finding may already be covered
   by `validate_tool_context_access`, and a blanket fix would have
   dead-ended.

## Fix shape

- New row-level gate = small plug calling `ResourceAuthorization.authorize/3`
  + a pipeline mounting it, NEVER per-controller checks (a new route forgets
  them). Fail closed on nil workspace.
- Secret comparisons use `Plug.Crypto.secure_compare/2` (admin token, OAuth
  state). Guard the unset case: `secure_compare(token, Auth.api_token() || "")`.
- Unknown-email login burns a dummy hash (`Bcrypt.no_user_verify/0`) before
  returning `:unauthorized` — timing otherwise enumerates users.
- Key-creation validators: a `nil` creator cannot be membership-validated,
  so require every referenced workspace to EXIST instead of blanket-allowing
  arbitrary ids — a full fail-closed here breaks system/test key creation.

## Pitfalls

- **A read plug exemption keyed on `conn.path_info` must match the EXACT
  path shape** — `path_info == ["api", "index"]` never matches anything
  real. Pattern-match the list (`["api", section] -> section in exempt_list`)
  and test the exemption against a live route, not by reading it.
- **Fixing a security finding can break the legitimate path in tests first**:
  run the API-key/E2E test files immediately after an auth change — they
  exercise `create_api_key` and per-key access flows the unit suite does
  not, and an over-tight validator shows up as a MatchError cascade there.
