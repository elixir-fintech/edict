defmodule Edict.Enforcement.Authorize do
  @moduledoc """
  Macro that generates authorization guards for LiveView `handle_event/3`.

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

        def handle_event("ping", _params, socket) do
          {:noreply, assign(socket, :pinged, true)}
        end
      end

  `:action`, `:entity_from_assigns` and `:entity_type` are required; a missing
  one fails compilation. Strong actions (see `Edict.Config.strong_actions/1`)
  are always checked against the database; a `:strong` option fails
  compilation, since only `Edict.can?` may opt out.

  Each `authorize` declaration generates a `handle_event/3` clause that checks
  permission before delegating to the original handler via `super/3`.
  """

  defmacro __using__(_opts) do
    quote do
      Module.register_attribute(__MODULE__, :edict_authorizations, accumulate: true)
      @before_compile Edict.Enforcement.Authorize
      import Edict.Enforcement.Authorize, only: [authorize: 2]
    end
  end

  @required_options [:action, :entity_from_assigns, :entity_type]

  defmacro authorize(event_name, opts) do
    [action, assigns_key, entity_type] = Enum.map(@required_options, &fetch_option!(opts, &1))
    Edict.Enforcement.Helpers.reject_strong!(opts)

    quote do
      Module.put_attribute(__MODULE__, :edict_authorizations, {
        unquote(event_name),
        unquote(action),
        unquote(assigns_key),
        unquote(entity_type)
      })
    end
  end

  # A security declaration must be explicit: a default could silently guard
  # the wrong action or resource.
  defp fetch_option!(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> value
      :error -> raise ArgumentError, "authorize requires the #{inspect(key)} option"
    end
  end

  defmacro __before_compile__(env) do
    authorizations = Module.get_attribute(env.module, :edict_authorizations)

    guard_clauses =
      Enum.map(authorizations, fn {event_name, action, assigns_key, entity_type} ->
        quote do
          def handle_event(unquote(event_name), params, socket) do
            entity_id = socket.assigns[unquote(assigns_key)]
            document = socket.assigns[:current_user_roles]
            edict_config = socket.assigns[:edict_config] || Edict.config()
            config_module = edict_config.config_module

            if Edict.Enforcement.Helpers.authorized?(
                 edict_config,
                 document,
                 unquote(action),
                 unquote(entity_type),
                 entity_id,
                 []
               ) do
              super(unquote(event_name), params, socket)
            else
              {:noreply, config_module.on_unauthorized().(socket, %{})}
            end
          end
        end
      end)

    quote do
      defoverridable handle_event: 3
      unquote_splicing(guard_clauses)

      def handle_event(event, params, socket) do
        super(event, params, socket)
      end
    end
  end
end
