# Edict

Cached authorization for Phoenix applications.

Edict maintains a per-user authorization document in an ETS-backed cache (Cachex).
Instead of loading authorization context on every request, permission checks read
from the cached document with sub-microsecond latency. Documents are automatically
invalidated when roles change, with cross-node support via Phoenix.PubSub.

## Core concepts

- **Roles** are explicitly assigned per user per entity (no implicit inheritance)
- **Entities** are typed resources (organization, team, project) identified by a string ID
- **Actions** are scoped per entity type per role — `admin` on an organization may differ from `admin` on a project
- **A user can hold multiple roles** on the same entity — actions are the union of all roles
- **The cache stores roles**, not resolved actions — action resolution happens at check time, so config changes don't require cache invalidation

## Installation

Add `edict` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:edict, "~> 0.1"}
  ]
end
```

Generate the migration and run it:

```bash
mix edict.install
mix ecto.migrate
```

The migration adds `CHECK` constraints that reject blank identity columns. If you generated
the migration with an earlier Edict version, add them in a new migration:

```elixir
for column <- [:user_id, :entity_type, :entity_id, :role] do
  create constraint(:user_roles, :"user_roles_#{column}_not_blank", check: "#{column} <> ''")
end
```

## Configuration

```elixir
# config/config.exs
config :edict,
  config_module: MyApp.AuthConfig,
  repo: MyApp.Repo,
  pubsub: MyApp.PubSub

# Optional settings with defaults:
# cache: :edict_cache,
# topic: "edict:versions",
# ttl: :timer.minutes(10)  # upper bound on staleness, see "Consistency guarantees"
```

Add the supervisor to your application:

```elixir
# lib/my_app/application.ex
children = [
  MyApp.Repo,
  {Phoenix.PubSub, name: MyApp.PubSub},
  Edict.Supervisor,
  MyAppWeb.Endpoint
]
```

## Defining roles

Create a config module using the `Edict.Config` DSL:

```elixir
defmodule MyApp.AuthConfig do
  use Edict.Config

  # Optional: customize how user ID is extracted from assigns
  # Default: fn assigns -> assigns.current_user.id end
  user_from_assigns fn assigns -> assigns.current_user.id end

  # Optional: customize unauthorized behavior for Plug and LiveView.
  # Edict halts the conn after this runs, so it only builds the response.
  on_unauthorized fn
    %Plug.Conn{} = conn, _context ->
      conn
      |> Phoenix.Controller.put_flash(:error, "Not authorized")
      |> Phoenix.Controller.redirect(to: "/")

    %Phoenix.LiveView.Socket{} = socket, _context ->
      socket
      |> Phoenix.LiveView.put_flash(:error, "Not authorized")
      |> Phoenix.LiveView.redirect(to: "/")
  end

  entity_types do
    entity :organization, struct: MyApp.Organization
    entity :team, struct: MyApp.Team
    entity :project, struct: MyApp.Project
    entity :resource, struct: MyApp.Resource, id_field: :uuid
  end

  role :admin do
    on :organization, actions: [:read, :write, :delete, :manage, :billing]
    on :team, actions: [:read, :write, :delete, :manage]
    on :project, actions: [:read, :write, :delete, :manage]
    on :resource, actions: [:read, :write, :delete]
  end

  role :editor do
    on :organization, actions: [:read, :write]
    on :project, actions: [:read, :write]
  end

  role :viewer do
    on :organization, actions: [:read]
    on :project, actions: [:read]
  end

  role :billing_manager do
    on :organization, actions: [:read, :billing]
  end
end
```

The `struct:` option auto-generates `Edict.Entity` protocol implementations at compile time. Omit it to implement the protocol manually for custom ID extraction.

## Managing roles

```elixir
# Assign a role (idempotent)
{:ok, _} = Edict.assign_role(user_id, :admin, :organization, "42")

# Bulk assign
{:ok, _} = Edict.assign_roles(user_id, :admin, [
  {:organization, "42"},
  {:team, "10"},
  {:project, "7"}
])

# Revoke
{:ok, :revoked} = Edict.revoke_role(user_id, :admin, :organization, "42")

# Revoke all roles for a user on an entity
{:ok, count} = Edict.revoke_all_roles(user_id, :organization, "42")

# Cleanup when an entity is deleted
{:ok, count} = Edict.revoke_entity(:organization, "42")

# List roles (reads from DB)
roles = Edict.list_roles(user_id)
```

All write functions validate roles and entity types against the config module.

### Atomic role changes

Write functions invalidate the cache as soon as they run, so they raise `ArgumentError`
inside a transaction: the invalidation would happen before the commit, letting other
processes cache the old roles under the new version. To change roles together with
other writes, use `Edict.Multi`:

```elixir
Ecto.Multi.new()
|> Ecto.Multi.insert(:org, Organization.changeset(%Organization{}, attrs))
|> Edict.Multi.assign_role(:admin, fn %{org: org} -> {user.id, :admin, org} end)
|> Edict.Multi.transaction()
```

Steps take a `{user_id, role, entity}` tuple, or a function of the changes so far that
returns one; the entity struct's type and ID come from `Edict.Entity`. `Edict.Multi.transaction/1`
invalidates affected users only after the commit. Edict steps fail with `:not_run_by_edict`
under a plain `Repo.transaction/1`, and `Edict.Multi.transaction/1` raises inside another
transaction.

## Checking permissions

### In controllers (Plug)

```elixir
# In router
pipeline :require_project_read do
  plug Edict.Plug,
    action: :read,
    entity_type: :project,
    param: "project_id"
end

scope "/projects/:project_id" do
  pipe_through [:browser, :require_auth, :require_project_read]
  # routes...
end
```

On success, the authorization document is stored in `conn.assigns.current_user_roles`.
On denial, Edict calls `on_unauthorized` and then halts the connection itself. A missing
param or blank entity ID is always denied.

`param:` names the request param holding the entity ID. When the ID needs custom extraction,
pass `entity_from:` instead. Plug and `on_mount` options are stored at compile time, so it must
be a remote capture such as `&MyAppWeb.ProjectIds.from_conn/1`; anonymous functions do not compile.

### In LiveView (on_mount)

```elixir
defmodule MyAppWeb.ProjectLive.Show do
  use MyAppWeb, :live_view

  on_mount {Edict.LiveView,
    action: :read,
    entity_type: :project,
    param: "project_id"}

  # ...
end
```

On mount, the hook loads the document into `socket.assigns.current_user_roles` and subscribes to PubSub for real-time role change notifications.

On each role change for the user, the hook reloads the document and re-runs the mount check. If the user lost access, `on_unauthorized` is called and must redirect the socket, which stops the LiveView. If it does not redirect, the LiveView raises, and the client's remount is denied.

### Per-event authorization (LiveView)

```elixir
defmodule MyAppWeb.ProjectLive.Show do
  use MyAppWeb, :live_view
  use Edict.Enforcement.Authorize

  on_mount {Edict.LiveView,
    action: :read,
    entity_type: :project,
    param: "project_id"}

  authorize "delete", action: :delete, entity_from_assigns: :project_id, entity_type: :project
  authorize "update", action: :write, entity_from_assigns: :project_id, entity_type: :project

  def handle_event("delete", _params, socket) do
    # Only reached if authorized
  end
end
```

`action:`, `entity_from_assigns:` and `entity_type:` are all required; leaving one out fails compilation.

### In templates

```elixir
<%= if Edict.can?(@current_user_roles, :delete, @project) do %>
  <button phx-click="delete">Delete project</button>
<% end %>

<%# Or with raw type + id %>
<%= if Edict.can?(@current_user_roles, :delete, :project, "7") do %>
  <button phx-click="delete">Delete project</button>
<% end %>
```

`can?/3` uses the `Edict.Entity` protocol to extract type and ID from the struct. `can?/4` takes them directly.

## Strong actions

Cached checks can be stale for up to the TTL on a node that missed a role change
(see [Consistency guarantees](#consistency-guarantees)). For high-risk actions, declare
them strong: every check of a strong action reads the user's current roles on that
entity from the DB, never from the cache.

```elixir
defmodule MyApp.AuthConfig do
  use Edict.Config

  strong_actions [:approve_transfer, :delete]
  # ...
end
```

This applies to `Edict.Plug`, `Edict.LiveView` (on mount), `authorize` event guards, and
`Edict.can?`. Each strong check costs one indexed query. If the DB is unavailable, the check
raises: a strong check never falls back to the cache.

A strong check protects the moment it runs: a request, a mount, or an event. A LiveView that
is already open re-checks its mount permission only when the node receives the role change,
and a node that missed it keeps the LiveView running. **Guard every event that performs a
strong action with `authorize`**, not only the mount.

`Edict.can?` accepts `strong: false` for display checks, where a stale answer is acceptable:

```heex
<%= if Edict.can?(@current_user_roles, :approve_transfer, @account, strong: false) do %>
  <button phx-click="approve">Approve</button>
<% end %>
```

Pair it with a strong check on the event itself:

```elixir
authorize "approve", action: :approve_transfer, entity_from_assigns: :account_id, entity_type: :account
```

`strong: false` is the only accepted value, and only `Edict.can?` accepts it. `Edict.Plug`,
`Edict.LiveView` and `authorize` raise on a `:strong` option, so enforcement always follows the
config.

## How caching works

Each user has a cached authorization document containing their roles grouped by entity. The document is stored in Cachex (ETS-backed) with a version: a unique reference that each role change replaces, so a version is never reused.

**On role change:**

1. DB write
2. Version bump in local Cachex
3. PubSub broadcast to all nodes (global topic) and the user's LiveViews (per-user topic)
4. Other nodes copy the new version via `PubSubListener`

**On permission check:**

1. Load document from Cachex
2. Compare `document.version` against current version
3. Match: use document (sub-microsecond)
4. Mismatch or miss: rebuild from DB (~1-5ms), cache result

Cached documents and versions expire after the TTL (default: 10 minutes), which repairs a node
that missed a PubSub message.

### Consistency guarantees

Role changes are written to the DB first, then announced over PubSub. Caches are therefore
eventually consistent:

- **Normally, a revocation takes effect immediately** on every node: the next permission check
  rebuilds from the DB, and mounted LiveViews re-check their mount permission.
- **A node that misses the PubSub message** (network partition, node reconnecting) keeps
  granting the old roles **until the TTL expires**. With the default TTL, that is up to 10 minutes.
- **A check already in progress** when the role changes may still use the previous document.
  Requests that passed the Plug before a revocation run to completion.
- **Strong checks are not affected**: every check of a strong action reads the DB (see
  [Strong actions](#strong-actions)). An open LiveView is not re-checked until the node receives
  the role change, so guard strong events with `authorize`.

A shorter TTL narrows the window at the cost of more DB reads:

```elixir
config :edict, ttl: :timer.minutes(1)
```

**If the cache is unavailable** (for example while Cachex restarts), permission checks build the
document from the DB and skip caching it. Each fallback logs an error and emits a telemetry event:

| Event | Measurements | Metadata |
|---|---|---|
| `[:edict, :cache, :unavailable]` | `%{count: 1}` | `%{user_id: String.t(), reason: term()}` |

## Testing

Edict provides test helpers for convenient permission setup and assertions:

```elixir
# In your test
Edict.TestHelpers.grant_role("user-1", :admin, org_struct)
Edict.TestHelpers.assert_can("user-1", :delete, org_struct)
Edict.TestHelpers.refute_can("user-1", :billing, project_struct)
```

Validate your config module at startup:

```elixir
Edict.validate_config!(MyApp.AuthConfig)
```

## License

MIT
