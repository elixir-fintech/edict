defmodule Edict.Enforcement.Authorize do
  @moduledoc """
  Authorization guards for LiveView events.

  ## Usage

  The LiveView is routed inside an `edict` block, whose mount check assigns
  `current_user_roles` (see `Edict.Router`):

      edict :project, param: "project_id", permission: :read do
        live "/projects/:project_id", MyAppWeb.ProjectLive
      end

  The view declares its event guards:

      defmodule MyAppWeb.ProjectLive do
        use Phoenix.LiveView
        use Edict.Enforcement.Authorize

        # The module default: entity type and the assign holding its ID, once per view
        edict_entity :project, from: :project_id

        def mount(%{"project_id" => project_id}, _session, socket) do
          # The guards read the entity ID from this assign
          {:ok, assign(socket, :project_id, project_id)}
        end

        authorize "delete", :delete
        authorize ["save", "publish"], :write
        authorize "export", permission: :billing, entity_from_assigns: :project_id, entity_type: :project

        def handle_event("delete", _params, socket) do
          # Only reached if authorized
          {:noreply, assign(socket, :deleted, true)}
        end
      end

  `use Edict.Enforcement.Authorize` must come after `use Phoenix.LiveView`. It
  registers an `on_mount` hook that attaches a `:handle_event` hook: for every
  declared event, the permission is checked against `current_user_roles`
  before your `handle_event/3` runs. A denied event calls `on_unauthorized` and
  never reaches it; undeclared events pass through. LiveComponents are not
  supported.

  The guards need two assigns: `current_user_roles`, set by the mount check
  of the `edict` block routing the LiveView, and the key named by
  `:entity_from_assigns` (for example `:project_id`), which the LiveView
  assigns itself. A LiveView that is not routed in an `edict` block has no
  `current_user_roles`. Without
  `current_user_roles` a declared event fails closed: it raises, or is denied
  through `on_unauthorized` when the assigned key holds no valid entity ID. The config
  comes from `socket.assigns[:edict_config]`, falling back to `Edict.config/0`.

  > #### Earlier hooks run first {: .warning}
  >
  > LiveView runs `handle_event` hooks in the order they were attached, and
  > this one is attached by the LiveView's own `on_mount`. Hooks attached
  > before it, for example by `live_session` `on_mount` callbacks, see declared
  > events first and can act on them or halt them. They must never perform or
  > authorize protected operations: keep protected work in the LiveView's
  > `handle_event/3`, which always runs after every hook.

  `:permission`, `:entity_from_assigns` and `:entity_type` are required in the
  keyword form; a missing one fails compilation, and so does declaring an
  event twice or naming it with anything but a string. With `edict_entity/2`
  declared, `authorize/2` also accepts sugar that expands to exactly the same
  runtime declarations:

      edict_entity :project, from: :project_id  # once per view
      authorize "delete", :delete               # permission atom: type and assign come from edict_entity
      authorize ["save", "publish"], :write     # a list declares one guard per event, sharing the options

  Both sugar forms combine freely with the keyword form. Strong permissions
  (see `Edict.Config.strong_permissions/1`) are always checked against the
  database; a `:strong` option fails compilation, since only `Edict.can?` may
  opt out. A permission the entity type does not define raises `ArgumentError`
  when the event arrives.
  """

  alias Edict.Enforcement.Helpers
  import Edict.Guards

  @required_options [:permission, :entity_from_assigns, :entity_type]

  defmacro __using__(_opts) do
    quote do
      unless Phoenix.LiveView in Module.get_attribute(__MODULE__, :behaviour, []) do
        raise CompileError,
          description:
            "use Edict.Enforcement.Authorize must come after use Phoenix.LiveView " <>
              "(LiveComponents are not supported)"
      end

      Module.register_attribute(__MODULE__, :edict_authorizations, accumulate: true)
      Module.register_attribute(__MODULE__, :edict_entity, accumulate: false)
      Module.put_attribute(__MODULE__, :edict_entity, nil)
      @before_compile Edict.Enforcement.Authorize
      import Edict.Enforcement.Authorize, only: [authorize: 2, edict_entity: 1, edict_entity: 2]

      require Phoenix.LiveView
      Phoenix.LiveView.on_mount({Edict.Enforcement.Authorize, __MODULE__})
    end
  end

  @doc """
  Declares the module's entity type and the assign holding its ID, once per
  view. The `authorize/2` sugar forms read both from it.
  """
  defmacro edict_entity(entity_type, opts \\ []) do
    from = opts[:from]

    unless is_atom_present(from) do
      raise CompileError,
        description: "edict_entity requires the :from option: the assign holding the entity ID"
    end

    quote do
      if Module.get_attribute(__MODULE__, :edict_entity) do
        raise CompileError, description: "edict_entity can only be declared once"
      end

      Module.put_attribute(__MODULE__, :edict_entity, {unquote(entity_type), unquote(from)})
    end
  end

  @doc """
  Declares that `event_name` requires `permission` on the entity in assigns.

  The first argument accepts a single event name or a list — a list declares
  one guard per event, sharing the options. The second argument accepts the
  full keyword form, or a permission atom when `edict_entity/2` is declared.
  """
  defmacro authorize(event_names, permission) when is_list(event_names) and is_atom(permission) do
    quote do
      (unquote_splicing(Enum.map(event_names, &authorization_quote(&1, permission))))
    end
  end

  defmacro authorize(event_names, opts) when is_list(event_names) do
    quote do
      (unquote_splicing(Enum.map(event_names, &keyword_authorization(&1, opts))))
    end
  end

  defmacro authorize(event_name, permission) when is_atom(permission) do
    authorization_quote(event_name, permission)
  end

  defmacro authorize(event_name, opts) do
    keyword_authorization(event_name, opts)
  end

  # The keyword form: every option is stated on the declaration itself.
  # A non-literal second argument (a module attribute, a function call) is an
  # AST node rather than a keyword list, so it is caught here with a message
  # naming both accepted forms.
  defp keyword_authorization(event_name, opts) do
    unless Keyword.keyword?(opts) do
      raise CompileError,
        description:
          "authorize expects a permission atom or keyword options, " <>
            "got: #{Macro.to_string(opts)}"
    end

    Helpers.require_options!(opts, @required_options, "authorize")
    Helpers.reject_strong!(opts)

    [permission, assigns_key, entity_type] =
      Enum.map(@required_options, &Keyword.fetch!(opts, &1))

    quote do
      Module.put_attribute(__MODULE__, :edict_authorizations, {
        unquote(event_name),
        {unquote(permission), unquote(assigns_key), unquote(entity_type)}
      })
    end
  end

  # The sugar form: the entity type and assign come from edict_entity, read
  # where the declaration sits so a missing default fails compilation there.
  defp authorization_quote(event_name, permission) do
    quote do
      edict = Module.get_attribute(__MODULE__, :edict_entity)

      unless edict do
        raise CompileError,
          description:
            "authorize with a permission atom requires edict_entity: " <>
              "declare the entity type and its assign once per view"
      end

      {entity_type, from} = edict

      Module.put_attribute(__MODULE__, :edict_authorizations, {
        unquote(event_name),
        {unquote(permission), from, entity_type}
      })
    end
  end

  defmacro __before_compile__(env) do
    authorizations = Module.get_attribute(env.module, :edict_authorizations)
    validate_event_names!(authorizations)
    validate_unique_events!(authorizations)

    quote do
      @doc false
      def __edict_authorizations__, do: unquote(Macro.escape(Map.new(authorizations)))
    end
  end

  # LiveView sends event names as strings, so any other name would never match
  # and its event would go unguarded.
  defp validate_event_names!(authorizations) do
    invalid = for {event, _policy} <- authorizations, not is_binary(event), do: event

    unless invalid == [] do
      raise CompileError,
        description: "authorize event names must be strings, got: #{inspect(invalid)}"
    end
  end

  defp validate_unique_events!(authorizations) do
    duplicates =
      for {event, count} <- Enum.frequencies_by(authorizations, &elem(&1, 0)),
          count > 1,
          do: event

    unless duplicates == [] do
      raise CompileError,
        description: "authorize is declared more than once for: #{inspect(duplicates)}"
    end
  end

  @doc false
  def on_mount(module, _params, _session, socket) do
    authorizations = module.__edict_authorizations__()

    {:cont,
     Phoenix.LiveView.attach_hook(socket, :edict_authorize, :handle_event, fn event,
                                                                              _params,
                                                                              socket ->
       guard(Map.fetch(authorizations, event), socket)
     end)}
  end

  defp guard(:error, socket), do: {:cont, socket}

  defp guard({:ok, {permission, assigns_key, entity_type}}, socket) do
    edict_config = socket.assigns[:edict_config] || Edict.config()
    config_module = edict_config.config_module
    Helpers.validate_permission!(config_module, permission, entity_type)

    if Helpers.authorized?(
         edict_config,
         socket.assigns[:current_user_roles],
         permission,
         entity_type,
         socket.assigns[assigns_key],
         []
       ) do
      {:cont, socket}
    else
      {:halt, config_module.on_unauthorized().(socket, %{})}
    end
  end
end
