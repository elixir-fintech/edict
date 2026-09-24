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
# ttl: :timer.minutes(10)
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

  # Optional: customize unauthorized behavior for Plug and LiveView
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

## How caching works

Each user has a cached authorization document containing their roles grouped by entity. The document is stored in Cachex (ETS-backed) with a version number.

**On role change:**

1. DB write
2. Version bump in local Cachex
3. PubSub broadcast to all nodes (global topic) and the user's LiveViews (per-user topic)
4. Other nodes bump their local version via `PubSubListener`

**On permission check:**

1. Load document from Cachex
2. Compare `document.version` against current version
3. Match: use document (sub-microsecond)
4. Mismatch or miss: rebuild from DB (~1-5ms), cache result

A configurable TTL (default: 10 minutes) acts as a safety net if PubSub messages are lost.

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
