# Edict

Cached authorization for Phoenix applications.

Edict maintains a per-user authorization document in an ETS-backed cache (Cachex).
Instead of loading authorization context on every request, permission checks read
from the cached document without a database query (strong permissions excepted). Documents are automatically
invalidated when roles change, with cross-node support via Phoenix.PubSub.

## Core concepts

- **Roles** are explicitly assigned per user per entity (no implicit inheritance)
- **Entities** are typed resources (organization, team, project) identified by a string ID
- **Permissions** are granted per entity type per role — `admin` on an organization may grant different permissions from `admin` on a project
- **A user can hold multiple roles** on the same entity — permissions are the union of all roles
- **The cache stores roles**, not resolved permissions — permission resolution happens at check time, so config changes don't require cache invalidation

## Installation

Add `edict` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:edict, "~> 0.1"}
  ]
end
```

Configure at least `config :edict, repo: MyApp.Repo` first (see [Configuration](#configuration)):
the install task reads it. Then generate the migration and run it:

```bash
mix edict.install
mix ecto.migrate
```

The task writes the migration to `priv/repo/migrations`.

The migration adds `CHECK` constraints that reject empty identity columns. If you generated
the migration with an earlier Edict version, add them in a new migration:

```elixir
for column <- [:user_id, :entity_type, :entity_id, :role] do
  create constraint(:edict_user_roles, :"edict_user_roles_#{column}_not_blank", check: "#{column} <> ''")
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
# ttl: :timer.minutes(10)  # how long a cached document lives, see "Consistency guarantees"
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

`Edict.Supervisor` takes no options and validates the config module when it starts
(`Edict.validate_config!/1`), so a module missing a required function fails at boot.

## Default-on enforcement

Edict is strict by default at the router: every route is guarded unless it explicitly opts out.

```elixir
defmodule MyAppWeb.Router do
  use MyAppWeb, :router
  use Edict.Router

  scope "/", MyAppWeb do
    pipe_through [:browser]

    edict :project, param: "project_id" do
      get    "/projects/:project_id", ProjectController, :show    # → :read
      put    "/projects/:project_id", ProjectController, :update  # → :write
      delete "/projects/:project_id", ProjectController, :delete  # → :delete
      get    "/projects/:project_id/billing", ProjectController, :billing, permission: :billing
    end

    edict :project, param: "project_id", permission: :read do
      live "/projects/:project_id", ProjectShowLive
    end

    # The explicit opt-out, for genuinely public routes:
    unguarded do
      live "/dev/dashboard", Phoenix.LiveDashboard
      get "/health", HealthController, :check
    end
  end
end
```

`use Edict.Router` must come after `use Phoenix.Router` (usually via
`use MyAppWeb, :router`). It re-imports Phoenix's route macros in wrapped form,
so any route outside an `edict` or `unguarded` block fails compilation naming
the route and both remedies — an unguarded route is a build failure, not a
runtime hole. Routers that never `use Edict.Router` compile untouched.

### edict blocks

Each route inside an `edict` block gets `Edict.Plug` with the block's entity
type and ID source (`param:` or `entity_from:`). Controller routes derive
their permission from the Phoenix action name via
[permission aliases](#permission-aliases); an unmapped name fails compilation.
A per-route `permission:` option wins over the alias.

Live routes have no action name to derive from, so a block carrying them must
declare `permission:` — missing it fails compilation. The block becomes a
`live_session` whose `on_mount` is `{Edict.LiveView, block options}`, so every
live route inside mounts guarded, inheriting the block's permission. One block
is one permission: split views needing different mount permissions into
separate blocks.

### unguarded

`unguarded` is the explicit opt-out for genuinely public routes — dashboards,
health checks. It is the only one; there is no controller-level skip.

### Sentinel as defense in depth

```elixir
pipeline :browser do
  ...
  plug Edict.Sentinel
end
```

The sentinel denies, at response time, any request that never passed an Edict
decision. For apps wiring `Edict.Plug` by hand it blocks only the response,
not the handler's side effects — acceptable only as the second line behind the
router compiler.

### Auditing LiveView events in CI

LiveView events are guarded per view with `authorize` (see
[Per-event authorization](#per-event-authorization-liveview)). `mix edict.audit`
diffs `handle_event` clauses against those declarations and exits non-zero on
gaps:

```bash
mix edict.audit
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
    on :organization, permissions: [:read, :write, :delete, :manage, :billing]
    on :team, permissions: [:read, :write, :delete, :manage]
    on :project, permissions: [:read, :write, :delete, :manage]
    on :resource, permissions: [:read, :write, :delete]
  end

  role :editor do
    extends :viewer
    on :organization, permissions: [:write]
    on :project, permissions: [:write]
  end

  role :viewer do
    on :organization, permissions: [:read]
    on :project, permissions: [:read]
  end

  role :billing_manager do
    on :organization, permissions: [:read, :billing]
  end
end
```

The `struct:` option auto-generates `Edict.Entity` protocol implementations at compile time. Omit it to implement the protocol manually for custom ID extraction.

### Role seniority

`extends` makes a role inherit every permission its parent declares, across
all entity types; multiple parents union. The transitive union is resolved
when the config compiles, so nothing changes at runtime: assigning a role
still stores a single row, and `permissions_for/2` reports effective
permissions. An unknown parent and an inheritance cycle fail compilation.

In the config above, `:editor` extends `:viewer` and therefore grants `:read`
and `:write` — declaring `:read` twice would be the drift `extends` prevents.

### Permission aliases

`permission_aliases` maps Phoenix action names to permissions. The shipped
defaults apply when you declare nothing:

```elixir
permission_aliases [
  index: :read, show: :read,
  new: :write, edit: :write, create: :write, update: :write,
  delete: :delete
]
```

An app's entries merge over the defaults entry by entry. Aliases are a
compile-time naming convention used by route derivation; the resolved
permission is validated per entity type where it is used.

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

# Revoke ({:ok, :not_found} if the user did not have the role)
{:ok, :revoked} = Edict.revoke_role(user_id, :admin, :organization, "42")

# Revoke all roles for a user on an entity
{:ok, count} = Edict.revoke_all_roles(user_id, :organization, "42")

# Cleanup when an entity is deleted
{:ok, count} = Edict.revoke_entity(:organization, "42")

# List roles (reads from DB)
roles = Edict.list_roles(user_id)
```

All write functions validate roles and entity types against the config module and return
`{:error, :invalid_role}` or `{:error, :invalid_entity_type}` otherwise. `assign_role/4` and
`assign_roles/3` also return `{:error, %Ecto.Changeset{}}` for an empty (or `nil`) or over-long
user or entity ID; the revoke functions just match nothing. `assign_roles/3` returns only the
newly inserted assignments, skipping entities the user already has the role on.

### Atomic role changes

Write functions invalidate the cache as soon as they run, so they raise `ArgumentError`
inside a transaction: the invalidation would happen before the commit, letting other
processes cache the old roles under the new version. To change roles together with
other writes, use `Edict.Multi`:

```elixir
Ecto.Multi.new()
|> Ecto.Multi.insert(:org, Organization.changeset(%Organization{}, attrs))
|> Edict.Multi.assign_role(:creator_role, fn %{org: org} -> {user.id, :admin, org} end)
|> Edict.Multi.transaction()
```

`Edict.Multi.assign_role/3` and `Edict.Multi.revoke_role/3` take a step name (here
`:creator_role`) and a `{user_id, role, entity}` tuple, or a function of the changes so far that
returns one; the entity struct's type and ID come from `Edict.Entity`. `Edict.Multi.transaction/1`
invalidates affected users only after the commit. Edict steps fail with `:not_run_by_edict`
under a plain `Repo.transaction/1`, and `Edict.Multi.transaction/1` raises inside another
transaction.

## Checking permissions

With `Edict.Router`, the router is the primary wiring point; this section shows
the underlying plug and LiveView wiring the router generates (see
[Default-on enforcement](#default-on-enforcement)).

### In controllers (Plug)

```elixir
# In router
pipeline :require_project_read do
  plug Edict.Plug,
    permission: :read,
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
param, an empty entity ID, or a non-scalar one such as an array param (`?project_id[]=7`) is
always denied.
A permission the config does not define for the entity type (a typo such as `:aprove`) raises
`ArgumentError` instead of silently denying every request.

`param:` names the request param holding the entity ID. When the ID needs custom extraction,
pass `entity_from:` instead. Plug and `on_mount` options are stored at compile time, so it must
be a remote capture such as `&MyAppWeb.ProjectIds.from_conn/1`; anonymous functions do not compile.
The Plug calls it with the conn; `Edict.LiveView` calls it with the route params.

By default a denied request gets a `403` "Forbidden" text response, and a denied LiveView
is redirected to `/` (see `on_unauthorized` above). The default `user_from_assigns` reads
`assigns.current_user.id`, so Edict must run after authentication.

### In LiveView (on_mount)

```elixir
defmodule MyAppWeb.ProjectLive.Show do
  use MyAppWeb, :live_view

  on_mount {Edict.LiveView,
    permission: :read,
    entity_type: :project,
    param: "project_id"}

  # ...
end
```

On mount, the hook subscribes to the user's role change notifications (when the socket is connected), then loads the document into `socket.assigns.current_user_roles`. `authorize` guards and `Edict.can?` in templates read it from there.

A denied mount calls `on_unauthorized`, which must redirect: LiveView raises on a halted mount without one.

On each role change for the user, the hook reloads the document from the DB and re-runs the mount check. If the user lost access, `on_unauthorized` is called and must redirect the socket (`redirect` or `push_navigate`), which stops the LiveView. If it does not redirect, or only uses `push_patch`, which keeps the LiveView open, the LiveView raises, and the client's remount is denied. Role-change messages are handled by Edict and never reach your `handle_info/2`.

### Per-event authorization (LiveView)

```elixir
defmodule MyAppWeb.ProjectLive.Show do
  use MyAppWeb, :live_view
  use Edict.Enforcement.Authorize

  on_mount {Edict.LiveView,
    permission: :read,
    entity_type: :project,
    param: "project_id"}

  # The module default: entity type and the assign holding its ID, once per view
  edict_entity :project, from: :project_id

  authorize "delete", :delete                  # permission atom: rest comes from edict_entity
  authorize ["save", "publish"], :write         # a list declares one guard per event
  authorize "export", permission: :billing, entity_from_assigns: :project_id, entity_type: :project

  def mount(%{"project_id" => project_id}, _session, socket) do
    # The guards read the entity ID from this assign
    {:ok, assign(socket, :project_id, project_id)}
  end

  def handle_event("delete", _params, socket) do
    # Only reached if authorized
    {:noreply, socket}
  end
end
```

The guards need `on_mount {Edict.LiveView, ...}`, which assigns `current_user_roles`, and the LiveView must assign the key named by `entity_from_assigns:` itself. Without `current_user_roles`, a declared event fails closed: it raises, or is denied through
`on_unauthorized` when the assigned entity ID is missing or empty. A missing entity assign on its
own also means denial.

With `edict_entity/2` declared, `authorize/2` accepts a permission atom, and
its first argument accepts a single event name or a list — every sugar form
expands to exactly the same runtime declaration as the keyword form, and the
forms mix freely.

`permission:`, `entity_from_assigns:` and `entity_type:` are all required in the keyword form; leaving one out, declaring an event twice, or naming it with anything but a string fails compilation, and so does `use Edict.Enforcement.Authorize` before `use Phoenix.LiveView` or in a LiveComponent. A denied event whose `on_unauthorized` does not redirect is dropped. `use Edict.Enforcement.Authorize` must come after `use Phoenix.LiveView` (here via `use MyAppWeb, :live_view`): it attaches a `handle_event` hook that checks each declared event before your handler runs.

**Earlier hooks run first:** `handle_event` hooks attached before Edict's, for example by `live_session` `on_mount` callbacks, see declared events before they are authorized. Such hooks must never perform or authorize protected operations; keep protected work in `handle_event/3`, which always runs after every hook.

### In templates

```heex
<%= if Edict.can?(@current_user_roles, :delete, @project) do %>
  <button phx-click="delete">Delete project</button>
<% end %>

<%!-- Or with raw type + id --%>
<%= if Edict.can?(@current_user_roles, :delete, :project, "7") do %>
  <button phx-click="delete">Delete project</button>
<% end %>
```

`can?/3` uses the `Edict.Entity` protocol to extract type and ID from the struct. `can?/4` takes
them directly (`can?(doc, permission, :project, "7")`), or a struct plus options; `can?/5` takes type,
ID and options. Unlike the Plug and LiveView, `can?` does not validate the permission: a permission the
entity type does not define returns `false`.

## Strong permissions

Cached checks can be stale on a node that missed a role change
(see [Consistency guarantees](#consistency-guarantees)). For high-risk permissions, declare
them strong: every check of a strong permission reads the user's current roles on that
entity from the DB, never from the cache. Strength is scoped per entity type — the same
permission name can be strong on one entity type and served from the cache on another.

```elixir
defmodule MyApp.AuthConfig do
  use Edict.Config

  strong_permissions do
    on :account, permissions: [:approve_transfer]
  end

  entity_types do
    entity :account, struct: MyApp.Account
    # ...
  end

  role :treasurer do
    on :account, permissions: [:read, :approve_transfer]
  end

  # ... the roles granting every other strong permission
end
```

`strong_permissions` is a block of `on/2` declarations — an entity type and its
`permissions:` list of atoms. It may appear once, the entity type must be declared,
and every listed permission must be granted by some role on that entity type,
otherwise the config fails to compile.

This applies to `Edict.Plug`, `Edict.LiveView` (on mount), `authorize` event guards, and
`Edict.can?`. Each strong check costs one indexed query. If the DB is unavailable, the check
raises: a strong check never falls back to the cache.

A strong check is current at the moment it queries the DB, not atomic with what your code does
next: a role revoked between the check and your write does not stop that write. For operations
that must be atomic with authorization, such as moving money, check the user's role inside the
same DB transaction as the write.

A strong check protects the moment it runs: a request, a mount, or an event. A LiveView that
is already open re-checks its mount permission only when the node receives the role change,
and a node that missed it keeps the LiveView running. **Guard every event that performs a
strong permission with `authorize`**, not only the mount.

`Edict.can?` accepts `strong: false` for display checks, where a stale answer is acceptable:

```heex
<%= if Edict.can?(@current_user_roles, :approve_transfer, @account, strong: false) do %>
  <button phx-click="approve">Approve</button>
<% end %>
```

Pair it with a strong check on the event itself:

```elixir
authorize "approve", permission: :approve_transfer, entity_from_assigns: :account_id, entity_type: :account
```

`strong: false` is the only accepted value, and only `Edict.can?` accepts it. `Edict.Plug`,
`Edict.LiveView` and `authorize` raise on a `:strong` option, so enforcement always follows the
config.

## How caching works

Each user has a cached authorization document containing their roles grouped by entity. The document is stored in Cachex (ETS-backed) with a version: a unique reference that each role change replaces, so a version is never reused.

**On role change:**

1. DB write
2. Version bump in local Cachex, which drops the user's cached document
3. PubSub broadcast to all nodes (global topic) and the user's LiveViews (per-user topic)
4. Other nodes set the new version and drop the document via `PubSubListener`

**On permission check:**

1. Load document from Cachex
2. Compare `document.version` against current version
3. Match: use document (no DB query)
4. Mismatch or miss: rebuild from DB, cache result

Cached documents and versions expire after the TTL (default: 10 minutes), which repairs a node
that missed a PubSub message.

**PubSub is a trust boundary.** Edict trusts every message on its topics. A bump can never
restore an old document, because each one drops the cached document, but anyone who can
broadcast on the PubSub can force DB rebuilds. Use a PubSub server that only your app
broadcasts on; don't share it, or Edict's topics, with other apps or an external broker
that other systems can publish to.

### Consistency guarantees

Role changes are written to the DB first, then announced over PubSub. Caches are therefore
eventually consistent:

- **Normally, a revocation takes effect immediately** on every node: the next permission check
  rebuilds from the DB, and mounted LiveViews re-check their mount permission.
- **A node that misses the PubSub message** (network partition, node reconnecting) keeps
  granting the old roles from its cache **until the TTL expires**. With the default TTL, that is
  up to 10 minutes.
- **An open LiveView on such a node can stay stale for as long as it is open**, not just for
  the TTL: its roles live in socket assigns, and they are refreshed only by a role change the
  node does receive. That covers its mount permission (even for a strong permission, which is
  re-checked only on a received role change), non-strong `authorize` events and non-strong
  `Edict.can?` calls in its templates. Strong `authorize` events and strong `can?` calls still
  read the DB.
- **A check already in progress** when the role changes may still use the previous document.
  Requests that passed the Plug before a revocation run to completion.
- **Strong checks read the DB every time they run** (see
  [Strong permissions](#strong-permissions)). An open LiveView is not re-checked until the node receives
  the role change, so guard strong events with `authorize`.

A shorter TTL narrows the cache window at the cost of more DB reads (it does not refresh open
LiveViews):

```elixir
config :edict, ttl: :timer.minutes(1)
```

**If the cache is unavailable** (for example while Cachex restarts), permission checks build the
document from the DB and skip caching it. Each fallback logs an error and emits a telemetry event:

| Event | Measurements | Metadata |
|---|---|---|
| `[:edict, :cache, :unavailable]` | `%{count: 1}` | `%{user_id: String.t(), reason: term()}` |

**If a role change can't be broadcast** (for example a PubSub adapter that lost its connection),
the DB change stays committed. If the global broadcast fails, other nodes may keep the old roles
until the TTL expires; if the per-user broadcast fails, the user's open LiveViews, on any node,
keep their roles while open. Each failed broadcast logs an error and emits:

| Event | Measurements | Metadata |
|---|---|---|
| `[:edict, :invalidation, :broadcast_failed]` | `%{count: 1}` | `%{user_id: String.t(), topic: String.t(), reason: term()}` |

## Testing

Edict provides test helpers for convenient permission setup and assertions:

```elixir
# In your test
Edict.TestHelpers.grant_role("user-1", :admin, org_struct)
Edict.TestHelpers.assert_can("user-1", :delete, org_struct)
Edict.TestHelpers.refute_can("user-1", :billing, project_struct)
```

Acceptance criteria live as Gherkin features in `test/features/`, executed by
the [`cucumber`](https://hex.pm/packages/cucumber) hex package (test-only
dependency). Step definitions go in `test/features/step_definitions/`, and
scenario setup — SQL sandbox checkout and a per-scenario cache — in
`test/features/support/sandbox.exs`. Run them with the rest of the suite
(`mix test`) or alone:

```bash
mix test --only cucumber
```

Note that cucumber requires Elixir 1.18+ to run the test suite; the library
itself still supports `~> 1.15`.

## License

MIT
