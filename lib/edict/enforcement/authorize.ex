defmodule Edict.Enforcement.Authorize do
  @moduledoc """
  Macro that generates authorization guards for LiveView `handle_event/3`.

  ## Usage

      defmodule MyAppWeb.ProjectLive do
        use Phoenix.LiveView
        use Edict.Enforcement.Authorize

        authorize "delete", action: :delete, entity_from_assigns: :project_id
        authorize "update", action: :write, entity_from_assigns: :project_id

        def handle_event("delete", _params, socket) do
          # Only reached if authorized
          {:noreply, assign(socket, :deleted, true)}
        end

        def handle_event("ping", _params, socket) do
          {:noreply, assign(socket, :pinged, true)}
        end
      end

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

  defmacro authorize(event_name, opts) do
    quote do
      Module.put_attribute(__MODULE__, :edict_authorizations, {
        unquote(event_name),
        unquote(opts[:action] || :read),
        unquote(opts[:entity_from_assigns] || :entity_id),
        unquote(opts[:entity_type] || :project)
      })
    end
  end

  defmacro __before_compile__(env) do
    authorizations = Module.get_attribute(env.module, :edict_authorizations)

    guard_clauses =
      Enum.map(authorizations, fn {event_name, action, assigns_key, entity_type} ->
        quote do
          def handle_event(unquote(event_name), params, socket) do
            entity_id = socket.assigns[unquote(assigns_key)]
            document = socket.assigns[:edict_document]
            config_module = socket.assigns[:edict_config].config_module

            if Edict.Enforcement.Helpers.can?(
                 document,
                 unquote(action),
                 unquote(entity_type),
                 to_string(entity_id),
                 config_module
               ) do
              super(unquote(event_name), params, socket)
            else
              {:noreply, socket}
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
