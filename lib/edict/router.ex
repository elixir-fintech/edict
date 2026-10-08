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
      inherits it. It also guards controller routes whose action has no
      alias (a route's own `permission:` always wins); when it contradicts
      an action's alias, compilation fails asking for an explicit route
      `permission:`
    * `:on_mount` — hooks (a module, `{module, arg}`, or a list) that run in
      the block's live session before Edict's mount hook; typically the app's
      authentication, which the hook needs on the socket to resolve the user

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

  import Edict.Guards

  @verbs [:get, :post, :put, :patch, :delete, :head, :options]
  @block_opts [:param, :entity_from, :permission, :on_mount]

  # The shadowed Phoenix macros, built once: the verb arities plus the
  # pass-through macros. Both import lists below come from these, so the
  # wrapped names exist in exactly one place.
  @phoenix_except for(verb <- @verbs, arity <- [3, 4], do: {verb, arity}) ++
                    [match: 4, match: 5, resources: 2, resources: 3, resources: 4] ++
                    for(arity <- [2, 3, 4], do: {:forward, arity})

  @edict_only [edict: 2, edict: 3, unguarded: 1] ++
                for(arity <- [2, 3, 4], do: {:live, arity}) ++ @phoenix_except

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

      # Drop `live` from any app-level Phoenix.LiveView.Router import so the
      # wrapper is unambiguous; `live_session` stays importable.
      import Phoenix.Router, except: unquote(@phoenix_except)
      import Phoenix.LiveView.Router, except: [live: 2, live: 3, live: 4]

      Module.register_attribute(__MODULE__, :edict_route_context, accumulate: false)
      Module.put_attribute(__MODULE__, :edict_route_context, nil)
      Module.register_attribute(__MODULE__, :edict_routes, accumulate: true)
      @before_compile Edict.Router

      import Edict.Router, only: unquote(@edict_only)
    end
  end

  @doc """
  Declares the entity type every route inside the block is checked against.

  See the module documentation for the options. Blocks may not nest.
  """
  defmacro edict(entity_type, opts \\ [], do: block) do
    on_mount = expand_on_mount(opts[:on_mount], __CALLER__)
    validate_edict_opts!(entity_type, opts, on_mount)

    permission = opts[:permission]

    body =
      if is_atom_present(permission) do
        # The app's own hooks (typically authentication) run before Edict's:
        # the mount hook resolves the user from socket assigns they set.
        on_mount_hooks =
          List.wrap(on_mount) ++ [{Edict.LiveView, guard_opts(entity_type, permission, opts)}]

        session = :"edict_#{entity_type}_#{permission}_#{System.unique_integer([:positive])}"

        quote do
          Phoenix.LiveView.Router.live_session unquote(session),
            on_mount: unquote(on_mount_hooks) do
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

  @doc """
  Wraps `Phoenix.Router.match/5`: allowed inside `unguarded` (a declared,
  unguarded route), but never inside an `edict` block — use the verb macros,
  which derive the permission from the action name.
  """
  defmacro match(verb, path, plug, action, opts \\ []) do
    quote do
      case Edict.Router.__route_context!(__MODULE__, unquote(verb), unquote(path)) do
        :unguarded ->
          Edict.Router.__record__(__MODULE__, %{
            verb: unquote(verb),
            path: unquote(path),
            kind: :unguarded
          })

          Phoenix.Router.match(
            unquote(verb),
            unquote(path),
            unquote(plug),
            unquote(action),
            unquote(opts)
          )

        {:edict, _, _} ->
          raise CompileError,
            description:
              "match is not supported inside edict blocks: use the verb macros " <>
                "(get, post, put, patch, delete, head, options), which derive " <>
                "the permission from the action name"
      end
    end
  end

  @doc """
  Wraps `Phoenix.Router.resources/4`: allowed inside `unguarded`, but never
  inside an `edict` block — `resources` generates `index`, `new` and
  `create` routes with no entity ID in their paths, and no member guard can
  check them. Declare those routes individually.
  """
  defmacro resources(path, controller, opts \\ [], rest \\ nil) do
    # The do-block form arrives as `rest`; forward the exact arity Phoenix
    # expects for each shape.
    phoenix_call =
      if rest == nil do
        quote do
          Phoenix.Router.resources(unquote(path), unquote(controller), unquote(opts))
        end
      else
        quote do
          Phoenix.Router.resources(
            unquote(path),
            unquote(controller),
            unquote(opts),
            unquote(rest)
          )
        end
      end

    quote do
      case Edict.Router.__route_context!(__MODULE__, :resources, unquote(path)) do
        :unguarded ->
          Edict.Router.__record__(__MODULE__, %{
            verb: :resources,
            path: unquote(path),
            kind: :unguarded
          })

          unquote(phoenix_call)

        {:edict, _, _} ->
          raise CompileError,
            description:
              "resources #{inspect(unquote(path))} inside an edict block would generate " <>
                "index, new and create routes without an entity ID, which no member " <>
                "guard can check. Declare those routes individually, or move the " <>
                "resources call to an unguarded block"
      end
    end
  end

  @doc """
  Wraps `Phoenix.Router.forward/4`: a delegation is a whole sub-tree, so it
  must sit inside `unguarded` — the sub-router enforces its own routes when
  it uses `Edict.Router`.
  """
  defmacro forward(path, plug, plug_opts \\ [], router_opts \\ []) do
    quote do
      case Edict.Router.__route_context!(__MODULE__, :forward, unquote(path)) do
        :unguarded ->
          Edict.Router.__record__(__MODULE__, %{
            verb: :forward,
            path: unquote(path),
            kind: :unguarded
          })

          Phoenix.Router.forward(
            unquote(path),
            unquote(plug),
            unquote(plug_opts),
            unquote(router_opts)
          )

        {:edict, _, _} ->
          raise CompileError,
            description:
              "forward inside an edict block would delegate a whole sub-tree that " <>
                "Edict.Plug cannot guard. Wrap it in unguarded; the sub-router " <>
                "enforces its own routes when it uses Edict.Router"
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
    permission =
      resolve_permission!(
        entity_type,
        action,
        route_permission,
        block_opts[:permission],
        config_module
      )

    guard_opts(entity_type, permission, block_opts)
  end

  @doc false
  def __live_mount_opts__({:edict, entity_type, block_opts}, path, config_module) do
    permission = block_opts[:permission]

    unless is_atom_present(permission) do
      raise CompileError,
        description:
          "live route #{inspect(path)} requires the edict block's permission: " <>
            "a live route has no action name to derive from, so state the " <>
            "permission on the block; every live route inside inherits it"
    end

    validate_pair!(config_module, entity_type, permission)

    guard_opts(entity_type, permission, block_opts)
  end

  # What Edict.Plug and the mount hook are called with, from the block.
  defp guard_opts(entity_type, permission, block_opts),
    do:
      [permission: permission, entity_type: entity_type] ++
        Keyword.take(block_opts, [:param, :entity_from])

  # Resolution: the route's own permission: option; otherwise, for actions
  # with no alias, the block's permission; otherwise the alias. A block
  # permission that contradicts the alias fails compilation — silently
  # guarding a mutating action with a reading permission is the failure this
  # prevents.
  defp resolve_permission!(
         entity_type,
         _action,
         route_permission,
         _block_permission,
         config_module
       )
       when is_atom_present(route_permission) do
    validate_pair!(config_module, entity_type, route_permission)
    route_permission
  end

  # Without a config module the conflict between the block permission and
  # the action's alias cannot be checked — and silently guarding every
  # route with the block permission would downgrade mutating routes. Fail
  # instead, asking for an explicit route permission:.
  defp resolve_permission!(
         _entity_type,
         action,
         _route_permission,
         block_permission,
         nil
       )
       when is_atom_present(block_permission) do
    raise CompileError,
      description:
        "cannot reconcile the edict block's #{inspect(block_permission)} with action " <>
          "#{inspect(action)}: config :edict, config_module is not available at compile " <>
          "time, so the conflict check cannot run. Pass permission: on the route, or " <>
          "make the config module available when the router compiles"
  end

  # No config module at compile time and no permissions declared on the
  # route or block: the raw action name stands in for the permission, and
  # the runtime validate_permission!/3 is the backstop.
  defp resolve_permission!(_entity_type, action, _route_permission, _block_permission, nil),
    do: action

  defp resolve_permission!(
         entity_type,
         action,
         _route_permission,
         block_permission,
         config_module
       )
       when is_atom_present(block_permission) do
    case config_module.permission_alias(action) do
      nil ->
        validate_pair!(config_module, entity_type, block_permission)
        block_permission

      ^block_permission ->
        validate_pair!(config_module, entity_type, block_permission)
        block_permission

      alias_permission ->
        raise CompileError,
          description:
            "action #{inspect(action)} on #{inspect(entity_type)} derives " <>
              "#{inspect(alias_permission)} from permission_aliases, but the edict " <>
              "block declares #{inspect(block_permission)}. Pass permission: on the " <>
              "route to choose one explicitly"
    end
  end

  defp resolve_permission!(
         entity_type,
         action,
         _route_permission,
         _block_permission,
         config_module
       ) do
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
          "fall back to the raw action name, entity types and permissions are " <>
          "not checked, and a block permission: on controller routes without " <>
          "their own permission: fails to compile. " <>
          "Edict.Enforcement.Helpers.validate_permission!/3 remains the runtime " <>
          "backstop",
        caller
      )
    end
  end

  defp validate_edict_opts!(entity_type, opts, on_mount) do
    unless is_atom_present(entity_type) do
      raise CompileError,
        description: "edict expects an entity type atom, got: #{Macro.to_string(entity_type)}"
    end

    unless Keyword.keyword?(opts) do
      raise CompileError,
        description: "edict expects a keyword list of options, got: #{Macro.to_string(opts)}"
    end

    unless opts[:permission] == nil or
             is_atom_present(opts[:permission]) do
      raise CompileError,
        description:
          "edict permission: must be a permission atom, got: #{inspect(opts[:permission])}"
    end

    unless opts[:param] == nil or is_binary(opts[:param]) do
      raise CompileError,
        description: "edict param: must be a string, got: #{inspect(opts[:param])}"
    end

    unless on_mount_hook?(on_mount) do
      raise CompileError,
        description:
          "edict on_mount: must be a module, {module, arg} or a list of them, " <>
            "got: #{inspect(on_mount)}"
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

  # nil (absent), a module, {module, arg}, or a list of those.
  defp on_mount_hook?(hooks) when is_nil(hooks) or hooks == [], do: true

  defp on_mount_hook?(hooks) when is_list(hooks) and hooks != [],
    do: Enum.all?(hooks, &on_mount_hook?/1)

  defp on_mount_hook?(module) when is_atom_present(module), do: true
  defp on_mount_hook?({module, _arg}) when is_atom(module), do: true
  defp on_mount_hook?(_), do: false

  # Alias ASTs must be resolved against the caller's scope before they reach
  # the live_session options.
  defp expand_on_mount(nil, _caller), do: []

  defp expand_on_mount(hooks, caller) when is_list(hooks),
    do: Enum.map(hooks, &expand_on_mount(&1, caller))

  defp expand_on_mount({{:__aliases__, _, _} = alias, arg}, caller),
    do: {Macro.expand(alias, caller), arg}

  defp expand_on_mount({module, arg}, _caller) when is_atom(module), do: {module, arg}

  defp expand_on_mount({:__aliases__, _, _} = alias, caller), do: Macro.expand(alias, caller)

  defp expand_on_mount(module, _caller) when is_atom(module), do: module
end
