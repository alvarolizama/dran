---
name: dran-dev-slug-management
description: "Use when touching Dran slug creation or updates."
---

# Dran slug management

All slug-bearing resources (pages, goals, workflows, steps, collections,
workspaces) share ONE auto-management policy in `lib/dran/slug.ex`. Route
every create/update through it; never call `Slug.slugify/1` inline at a
call site to build a slug.

## Policy (Dran.Slug.inject_create / inject_update)

- An explicit non-blank `slug` in attrs ALWAYS wins (API/seeds contract).
- Create without slug → base slugified from the title (or `:name` for
  workspaces), fallback to the resource type (`"goal"`, `"workspace"`, …).
- Collision → retry with `-<6 hex>` random suffix until free (`ensure_unique`).
- Update → slug regenerates ONLY when the title/name changed AND no explicit
  slug arrived; `"sync_slug" => false` in attrs opts out (page editor
  keystroke autosave uses this to avoid slug churn).
- Scope: uniqueness is per-workspace (or per-workflow for steps) — pass a
  `taken?` (create) or `lookup` (update) predicate that closes over the scope
  and excludes the record itself by id.

## Wiring a new resource

1. Context function (e.g. `lib/dran/knowledge.ex`, `lib/dran/goals.ex`):

   ```elixir
   def create_x(attrs) do
     attrs
     |> Slug.inject_create(field: "name", fallback: "x",
       taken?: &get_x_by_slug(&1, workspace_id))
     |> then(&(%X{} |> X.changeset(&1) |> Repo.insert()))
   end

   def update_x(%X{} = x, attrs) do
     attrs
     |> Slug.inject_update(x, field: "name", fallback: "x",
       lookup: &get_x_by_slug(&1, x.workspace_id))
     |> then(&(x |> X.changeset(&1) |> Repo.update()))
   end
   ```

2. LiveView forms: if the form auto-suggests a slug from the name as the
   user types, track `slug_touched` (set when `_target` hits the slug field)
   and DROP the untouched suggested slug before calling the context — a
   pre-filled slug is an "explicit" slug to the policy and will raise the
   unique_constraint instead of getting a random suffix.
3. Remove any leftover `Map.put(params, "slug", Slug.slugify(name))` in the
   LiveView save handler once the context owns the policy.

## Pitfalls

- Workspaces have a unique index on `name` INDEPENDENT of `slug` — a test
  colliding slugs must use a different name that slugifies to the same base
  (e.g. "Personal!"), or it fails on the name constraint, not the slug path.
- The API update endpoint drops the URL `slug` param before calling the
  context, so an API rename regenerates the slug internally — keep that
  drop when touching controllers.
- `inject_update` compares against the record's CURRENT title; a no-change
  name (or update of unrelated fields like visibility) leaves the slug
  untouched. Don't add manual slug-preservation logic on top.
