defmodule Edict.Enforcement.Authorize do
  @moduledoc """
  Authorization guards for LiveView events.

  ## Usage

      defmodule MyAppWeb.ProjectLive do
        use Phoenix.LiveView
        use Edict.Enforcement.Authorize

        authorize "delete", action: :delete, entity_from_assigns: :project_id, entity_type: :project
        authorize "update", action: :write, entity_from_assigns: :project_id, entity_type: :project

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

  `:action`, `:entity_from_assigns` and `:entity_type` are required; a missing
  one fails compilation, and so does declaring an event twice. Strong actions
  (see `Edict.Config.strong_actions/1`) are always checked against the
  database; a `:strong` option fails compilation, since only `Edict.can?` may
  opt out. An action the entity type does not define raises `ArgumentError`
  when the event arrives.
  """

  alias Edict.Enforcement.Helpers

  @required_options [:action, :entity_from_assigns, :entity_type]

  defmacro __using__(_opts) do
    quote do
      unless Module.has_attribute?(__MODULE__, :phoenix_live_mount) do
        raise CompileError,
          description: "use Edict.Enforcement.Authorize must come after use Phoenix.LiveView"
      end

      Module.register_attribute(__MODULE__, :edict_authorizations, accumulate: true)
      @before_compile Edict.Enforcement.Authorize
      import Edict.Enforcement.Authorize, only: [authorize: 2]

      require Phoenix.LiveView
      Phoenix.LiveView.on_mount({Edict.Enforcement.Authorize, __MODULE__})
    end
  end

  @doc "Declares that `event_name` requires `action` on the entity in assigns."
  defmacro authorize(event_name, opts) do
    Helpers.require_options!(opts, @required_options, "authorize")
    Helpers.reject_strong!(opts)
    [action, assigns_key, entity_type] = Enum.map(@required_options, &Keyword.fetch!(opts, &1))

    quote do
      Module.put_attribute(__MODULE__, :edict_authorizations, {
        unquote(event_name),
        {unquote(action), unquote(assigns_key), unquote(entity_type)}
      })
    end
  end

  defmacro __before_compile__(env) do
    authorizations = Module.get_attribute(env.module, :edict_authorizations)
    validate_unique_events!(authorizations)

    quote do
      @doc false
      def __edict_authorizations__, do: unquote(Macro.escape(Map.new(authorizations)))
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

  defp guard({:ok, {action, assigns_key, entity_type}}, socket) do
    edict_config = socket.assigns[:edict_config] || Edict.config()
    config_module = edict_config.config_module
    Helpers.validate_action!(config_module, action, entity_type)

    if Helpers.authorized?(
         edict_config,
         socket.assigns[:current_user_roles],
         action,
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
