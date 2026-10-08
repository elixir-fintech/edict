defmodule Edict.Router.Declaration do
  @moduledoc """
  Stamps `conn.private[:edict]` with the router's declaration.

  Emitted by `Edict.Router` around live routes — whose check happens in
  `on_mount`, on the socket, not in a plug — and around `unguarded` blocks.
  A declaration is not a decision: when `Edict.Plug` runs it overwrites the
  stamp with its decision, and a present stamp simply marks the request as
  declared. Options are a keyword list, since plug options in `pipe_through`
  must survive `Macro.escape/1`.
  """

  @behaviour Plug

  @impl true
  def init(declaration), do: declaration

  @impl true
  def call(conn, declaration), do: Plug.Conn.put_private(conn, :edict, declaration)
end

defmodule Edict.Router do
  @moduledoc """
  Default-on route enforcement: routes live in `edict` or `unguarded` blocks.

  ## Usage

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

          # The explicit opt-out, for genuinely public routes:
          unguarded do
            get "/health", HealthController, :check
          end
        end
      end

  `use Edict.Router` must come after `use Phoenix.Router` (usually via
  `use MyAppWeb, :router`). It re-imports Phoenix's route macros in wrapped
  form: a route outside every block fails compilation naming the route and
  both remedies — declare it inside an `edict` block, or wrap it in
  `unguarded`. Routers that never `use Edict.Router` compile untouched, so
  Edict composes with dashboards and other libraries' routers.

  ## edict blocks

  `edict entity_type, opts do ... end` guards every route inside. Options:

    * `:param` / `:entity_from` — where the entity ID comes from; one of them
      is required, and `Edict.Plug` rejects the route without it
    * `:permission` — required when the block declares `live` routes, which
      have no action name to derive from; every live route in the block
      inherits it

  Controller routes derive their permission from the Phoenix action name via
  the config's `permission_alias/1`, or declare their own with a per-route
  `permission:` option, which wins over the alias. Each gets `Edict.Plug`
  with the resolved options.

  Live routes are wrapped in a `live_session` whose `on_mount` is
  `{Edict.LiveView, block options}` — the existing mount hook, so strong
  permissions, version-bump re-checks and `current_user_roles` behave exactly
  as today. The block *is* the live session: one block, one permission, one
  session; do not nest `live_session` inside it. A block-level declaration
  plug stamps the conn (see `Edict.Router.Declaration`) so a response-time
  sentinel can tell declared live routes from undeclared requests.

  ## Compile-time validation

  When the router compiles, the entity type and every resolved permission
  are validated against the config module
  (`Application.compile_env(:edict, :config_module)`): an undeclared entity
  type, a permission no role grants on it, or an action name with neither an
  alias nor a `permission:` option fails compilation — drift is a build
  failure, not a first-request error. When the config module is not yet
  available, validation is skipped **with a compile-time warning — never
  silently** — and the runtime `validate_permission!/3` remains the backstop.

  The resolved guards are introspectable via `__edict_routes__/0`.
  """

  @verbs [:get, :post, :put, :patch, :delete, :head, :options]
  @block_opts [:param, :entity_from, :permission]

  defmacro __using__(_opts) do
    quote do
      unless Module.has_attribute?(__MODULE__, :phoenix_routes) do
        raise CompileError,
          description:
            "use Edict.Router must come after use Phoenix.Router " <>
              "(usually via use MyAppWeb, :router)"
      end

      # The wrapped macros call Phoenix's originals fully qualified.
      require Phoenix.Router
      require Phoenix.LiveView.Router

      # Shadow Phoenix's verb macros with the wrapped ones, and clear any
      # app-level import of Phoenix.LiveView.Router that would make `live`
      # ambiguous with the wrapper. Both lists must be literals.
      import Phoenix.Router,
        except: [
          get: 3,
          get: 4,
          post: 3,
          post: 4,
          put: 3,
          put: 4,
          patch: 3,
          patch: 4,
          delete: 3,
          delete: 4,
          head: 3,
          head: 4,
          options: 3,
          options: 4
        ]

      import Phoenix.LiveView.Router, only: []

      Module.register_attribute(__MODULE__, :edict_route_context, accumulate: false)
      Module.put_attribute(__MODULE__, :edict_route_context, nil)
      Module.register_attribute(__MODULE__, :edict_routes, accumulate: true)
      @before_compile Edict.Router

      import Edict.Router,
        only: [
          edict: 2,
          edict: 3,
          unguarded: 1,
          live: 2,
          live: 3,
          live: 4,
          get: 3,
          get: 4,
          post: 3,
          post: 4,
          put: 3,
          put: 4,
          patch: 3,
          patch: 4,
          delete: 3,
          delete: 4,
          head: 3,
          head: 4,
          options: 3,
          options: 4
        ]
    end
  end

  @doc """
  Declares the entity type every route inside the block is checked against.

  See the module documentation for the options. Blocks may not nest.
  """
  defmacro edict(entity_type, opts \\ [], do: block) do
    validate_edict_opts!(entity_type, opts)

    permission = opts[:permission]

    body =
      if is_atom(permission) and not is_nil(permission) do
        mount_opts =
          [permission: permission, entity_type: entity_type] ++
            Keyword.take(opts, [:param, :entity_from])

        session = :"edict_#{entity_type}_#{permission}_#{System.unique_integer([:positive])}"

        quote do
          Phoenix.LiveView.Router.live_session unquote(session),
            on_mount: {Edict.LiveView, unquote(mount_opts)} do
            scope [] do
              pipe_through([{Edict.Router.Declaration, [declaration: :edict]}])
              unquote(block)
            end
          end
        end
      else
        block
      end

    quote do
      if Module.get_attribute(__MODULE__, :edict_route_context) do
        raise CompileError, description: "edict blocks cannot be nested"
      end

      Module.put_attribute(__MODULE__, :edict_route_context, {
        :edict,
        unquote(entity_type),
        unquote(opts)
      })

      unquote(body)

      Module.put_attribute(__MODULE__, :edict_route_context, nil)
    end
  end

  @doc "The explicit opt-out: routes inside are declared without an Edict guard."
  defmacro unguarded(do: block) do
    quote do
      if Module.get_attribute(__MODULE__, :edict_route_context) do
        raise CompileError, description: "unguarded blocks cannot be nested"
      end

      Module.put_attribute(__MODULE__, :edict_route_context, :unguarded)

      scope [] do
        pipe_through([{Edict.Router.Declaration, [declaration: :unguarded]}])
        unquote(block)
      end

      Module.put_attribute(__MODULE__, :edict_route_context, nil)
    end
  end

  for verb <- @verbs do
    @doc """
    Wraps `Phoenix.Router.#{verb}/4`: the route must sit inside an `edict`
    or `unguarded` block, and an `edict` route derives or declares its
    permission.
    """
    defmacro unquote(verb)(path, plug, action, opts \\ []) do
      verb = unquote(verb)
      {route_permission, phoenix_opts} = Keyword.split(opts, [:permission])
      permission_ast = route_permission[:permission]
      warn_without_config(__CALLER__)

      quote do
        # Read where it lands in the router's module body, so the router is
        # recompiled when the config module changes.
        config_module = Application.compile_env(:edict, :config_module)
        context = Edict.Router.__route_context!(__MODULE__, unquote(verb), unquote(path))

        case context do
          :unguarded ->
            Edict.Router.__record__(__MODULE__, %{
              verb: unquote(verb),
              path: unquote(path),
              kind: :unguarded
            })

            Phoenix.Router.unquote(verb)(
              unquote(path),
              unquote(plug),
              unquote(action),
              unquote(phoenix_opts)
            )

          {:edict, _, _} = context ->
            guard_opts =
              Edict.Router.__controller_guard_opts__(
                context,
                unquote(action),
                unquote(permission_ast),
                config_module
              )

            Edict.Router.__record__(__MODULE__, %{
              verb: unquote(verb),
              path: unquote(path),
              kind: :controller,
              permission: guard_opts[:permission],
              entity_type: guard_opts[:entity_type],
              guard: guard_opts
            })

            scope [] do
              pipe_through([{Edict.Plug, guard_opts}])

              Phoenix.Router.unquote(verb)(
                unquote(path),
                unquote(plug),
                unquote(action),
                unquote(phoenix_opts)
              )
            end
        end
      end
    end
  end

  @doc """
  Wraps `Phoenix.LiveView.Router.live/4`: the route must sit inside an
  `edict` or `unguarded` block, and an `edict` block carrying live routes
  must declare the block's `permission:`.
  """
  defmacro live(path, live_view, action \\ nil, opts \\ []) do
    warn_without_config(__CALLER__)

    quote do
      config_module = Application.compile_env(:edict, :config_module)
      context = Edict.Router.__route_context!(__MODULE__, :live, unquote(path))

      case context do
        :unguarded ->
          Edict.Router.__record__(__MODULE__, %{
            verb: :live,
            path: unquote(path),
            kind: :unguarded
          })

          Phoenix.LiveView.Router.live(
            unquote(path),
            unquote(live_view),
            unquote(action),
            unquote(opts)
          )

        {:edict, entity_type, _block_opts} = context ->
          mount_opts = Edict.Router.__live_mount_opts__(context, unquote(path), config_module)

          Edict.Router.__record__(__MODULE__, %{
            verb: :live,
            path: unquote(path),
            kind: :live,
            entity_type: entity_type,
            permission: mount_opts[:permission],
            on_mount: mount_opts
          })

          Phoenix.LiveView.Router.live(
            unquote(path),
            unquote(live_view),
            unquote(action),
            unquote(opts)
          )
      end
    end
  end

  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(:edict_routes) |> Enum.reverse()

    quote do
      @doc false
      def __edict_routes__, do: unquote(Macro.escape(routes))
    end
  end

  # The functions below run at the router's compile time, from the wrapped
  # macros' expansion. They record each guard and raise on violations.

  @doc false
  def __route_context!(module, verb, path) do
    case Module.get_attribute(module, :edict_route_context) do
      nil ->
        raise CompileError,
          description:
            "#{describe(verb)} #{inspect(path)} is outside every edict block. " <>
              "Declare it inside an edict block, or wrap it in unguarded"

      context ->
        context
    end
  end

  @doc false
  def __record__(module, entry), do: Module.put_attribute(module, :edict_routes, entry)

  @doc false
  def __controller_guard_opts__(
        {:edict, entity_type, block_opts},
        action,
        route_permission,
        config_module
      ) do
    permission = resolve_permission!(entity_type, action, route_permission, config_module)

    [permission: permission, entity_type: entity_type] ++
      Keyword.take(block_opts, [:param, :entity_from])
  end

  @doc false
  def __live_mount_opts__({:edict, entity_type, block_opts}, path, config_module) do
    permission = block_opts[:permission]

    unless is_atom(permission) and not is_nil(permission) do
      raise CompileError,
        description:
          "live route #{inspect(path)} requires the edict block's permission: " <>
            "a live route has no action name to derive from, so state the " <>
            "permission on the block; every live route inside inherits it"
    end

    validate_pair!(config_module, entity_type, permission)

    [permission: permission, entity_type: entity_type] ++
      Keyword.take(block_opts, [:param, :entity_from])
  end

  # Resolution order: the route's own permission: option, then the alias map.
  defp resolve_permission!(entity_type, _action, route_permission, config_module)
       when is_atom(route_permission) and not is_nil(route_permission) do
    validate_pair!(config_module, entity_type, route_permission)
    route_permission
  end

  defp resolve_permission!(_entity_type, action, _route_permission, nil), do: action

  defp resolve_permission!(entity_type, action, _route_permission, config_module) do
    case config_module.permission_alias(action) do
      nil ->
        raise CompileError,
          description:
            "cannot derive a permission for action #{inspect(action)} on " <>
              "#{inspect(entity_type)}: the name has no alias. Pass " <>
              "permission: on the route, or add an alias with permission_aliases"

      permission ->
        validate_pair!(config_module, entity_type, permission)
        permission
    end
  end

  defp validate_pair!(nil, _entity_type, _permission), do: :ok

  defp validate_pair!(config_module, entity_type, permission) do
    unless config_module.valid_entity_type?(entity_type) do
      raise CompileError,
        description:
          "the edict block for #{inspect(entity_type)} cannot check " <>
            "#{inspect(permission)}: the entity type is not declared. " <>
            "Valid entity types: #{inspect(config_module.entity_types())}"
    end

    unless config_module.valid_permission?(permission, entity_type) do
      raise CompileError,
        description:
          "no role grants #{inspect(permission)} on #{inspect(entity_type)}. " <>
            "Grant it to a role, or declare a permission the entity type grants"
    end

    :ok
  end

  defp describe(:live), do: "live route"

  defp describe(verb), do: "#{verb |> Atom.to_string() |> String.upcase()} route"

  # Emitted where the route is declared, so the warning names the router file.
  defp warn_without_config(%Macro.Env{} = caller) do
    if Application.get_env(:edict, :config_module) == nil do
      IO.warn(
        "Edict router validation skipped: config :edict, config_module is not " <>
          "available at compile time, so permissions derived from action names " <>
          "fall back to the raw action name and entity types and permissions " <>
          "are not checked. Edict.Enforcement.Helpers.validate_permission!/3 " <>
          "remains the runtime backstop",
        caller
      )
    end
  end

  defp validate_edict_opts!(entity_type, opts) do
    unless is_atom(entity_type) and not is_nil(entity_type) do
      raise CompileError,
        description: "edict expects an entity type atom, got: #{Macro.to_string(entity_type)}"
    end

    unless Keyword.keyword?(opts) do
      raise CompileError,
        description: "edict expects a keyword list of options, got: #{Macro.to_string(opts)}"
    end

    unless opts[:permission] == nil or
             (is_atom(opts[:permission]) and not is_nil(opts[:permission])) do
      raise CompileError,
        description:
          "edict permission: must be a permission atom, got: #{inspect(opts[:permission])}"
    end

    unless opts[:param] == nil or is_binary(opts[:param]) do
      raise CompileError,
        description: "edict param: must be a string, got: #{inspect(opts[:param])}"
    end

    case Keyword.split(opts, @block_opts) do
      {_known, []} ->
        :ok

      {_known, unknown} ->
        raise CompileError,
          description:
            "edict got unknown options #{inspect(unknown)}. Valid options: #{inspect(@block_opts)}"
    end
  end
end
