defmodule Edict.Config do
  @moduledoc """
  DSL for defining entity types, roles, and scoped actions.

  ## Usage

      defmodule MyApp.AuthConfig do
        use Edict.Config

        user_from_assigns fn assigns -> assigns.current_user.id end

        strong_actions [:delete]

        entity_types do
          entity :organization, struct: MyApp.Organization
          entity :project, struct: MyApp.Project
        end

        role :admin do
          on :organization, actions: [:read, :write, :delete]
          on :project, actions: [:read, :write]
        end
      end

  **Note:** Only one module should `use Edict.Config` per application. Multiple config modules
  will cause duplicate protocol implementations and compilation errors.

  This compiles into fast lookup functions:
  - `actions_for/2` — actions for a role on an entity type
  - `valid_role?/1` — whether a role is defined
  - `valid_entity_type?/1` — whether an entity type is defined
  - `valid_action?/2` — whether an action is valid for an entity type
  - `strong_action?/1` — whether enforcement always checks an action against the database
  - `entity_types/0` — list of valid entity types
  - `user_id_from_assigns/1` — extract user ID from conn/socket assigns
  """

  defmacro __using__(_opts) do
    quote do
      @before_compile Edict.Config

      Module.register_attribute(__MODULE__, :edict_entities, accumulate: true)
      Module.register_attribute(__MODULE__, :edict_roles, accumulate: true)
      Module.register_attribute(__MODULE__, :edict_role_actions, accumulate: true)
      Module.register_attribute(__MODULE__, :edict_user_from_assigns, accumulate: false)
      Module.register_attribute(__MODULE__, :edict_on_unauthorized, accumulate: false)
      Module.register_attribute(__MODULE__, :edict_strong_actions, accumulate: false)

      Module.put_attribute(__MODULE__, :edict_user_from_assigns, nil)
      Module.put_attribute(__MODULE__, :edict_on_unauthorized, nil)
      Module.put_attribute(__MODULE__, :edict_strong_actions, nil)

      import Edict.Config,
        only: [
          entity_types: 1,
          entity: 1,
          entity: 2,
          role: 2,
          on: 2,
          user_from_assigns: 1,
          on_unauthorized: 1,
          strong_actions: 1
        ]
    end
  end

  defmacro user_from_assigns(func) do
    escaped = Macro.escape(func)

    quote do
      Module.put_attribute(__MODULE__, :edict_user_from_assigns, unquote(escaped))
    end
  end

  defmacro on_unauthorized(func) do
    escaped = Macro.escape(func)

    quote do
      Module.put_attribute(__MODULE__, :edict_on_unauthorized, unquote(escaped))
    end
  end

  @doc """
  Declares actions that are always checked against the database.

  `Edict.Plug`, `Edict.LiveView` and `authorize` guards always check them
  against the database. Only `Edict.can?` may opt out with `strong: false`,
  for display checks.

  Takes a literal list of atoms and may appear at most once. Every listed
  action must be granted by some role.
  """
  defmacro strong_actions(actions) do
    unless is_list(actions) and Enum.all?(actions, &is_atom/1) do
      raise CompileError,
        description:
          "strong_actions expects a literal list of atoms, got: #{Macro.to_string(actions)}"
    end

    quote do
      if Module.get_attribute(__MODULE__, :edict_strong_actions) do
        raise CompileError, description: "strong_actions can only be declared once"
      end

      Module.put_attribute(__MODULE__, :edict_strong_actions, unquote(actions))
    end
  end

  defmacro entity_types(do: block) do
    quote do
      unquote(block)
    end
  end

  defmacro entity(type, opts \\ []) do
    quote do
      Module.put_attribute(__MODULE__, :edict_entities, {
        unquote(type),
        unquote(opts[:struct]),
        unquote(opts[:id_field] || :id)
      })
    end
  end

  defmacro role(name, do: block) do
    quote do
      if unquote(name) in Enum.map(@edict_roles, & &1) do
        raise CompileError,
          description: "Duplicate role definition: #{inspect(unquote(name))}"
      end

      Module.put_attribute(__MODULE__, :edict_roles, unquote(name))

      @edict_current_role unquote(name)
      unquote(block)
      Module.delete_attribute(__MODULE__, :edict_current_role)
    end
  end

  defmacro on(entity_type, opts) do
    actions = opts[:actions] || []

    quote do
      Module.put_attribute(__MODULE__, :edict_role_actions, {
        @edict_current_role,
        unquote(entity_type),
        unquote(actions)
      })
    end
  end

  defmacro __before_compile__(env) do
    entities = Module.get_attribute(env.module, :edict_entities)
    roles = Module.get_attribute(env.module, :edict_roles)
    role_actions = Module.get_attribute(env.module, :edict_role_actions)

    strong_actions =
      strong_actions_or_none(Module.get_attribute(env.module, :edict_strong_actions))

    user_fn = user_fn(Module.get_attribute(env.module, :edict_user_from_assigns))
    unauthorized_fn = unauthorized_fn(Module.get_attribute(env.module, :edict_on_unauthorized))

    entity_type_names = Enum.map(entities, fn {name, _, _} -> name end)

    validate_entity_types!(role_actions, entity_type_names)
    validate_strong_actions!(strong_actions, role_actions)

    quote do
      @doc "Returns the list of valid entity types."
      def entity_types, do: unquote(entity_type_names)

      @doc "Returns `true` if the given entity type is defined."
      def valid_entity_type?(type), do: type in unquote(entity_type_names)

      @doc "Returns `true` if the given role is defined."
      def valid_role?(role), do: role in unquote(roles)

      unquote_splicing(actions_for_clauses(role_actions))

      @doc "Returns the actions a role grants on an entity type. Returns `[]` for undefined combinations."
      def actions_for(_role, _entity_type), do: []

      unquote_splicing(valid_action_clauses(role_actions))

      @doc "Returns `true` if the action is valid for the given entity type."
      def valid_action?(_action, _entity_type), do: false

      @doc "Returns `true` if the action is strong: enforcement always checks it against the database."
      def strong_action?(action), do: action in unquote(strong_actions)

      @doc "Extracts the user ID from conn/socket assigns."
      def user_id_from_assigns(assigns), do: unquote(user_fn).(assigns)

      @doc "Returns the configured unauthorized handler function."
      def on_unauthorized, do: unquote(unauthorized_fn)

      unquote_splicing(protocol_impls(entities))
    end
  end

  # The functions below run at compile time, from __before_compile__/1.

  defp validate_entity_types!(role_actions, entity_type_names) do
    for {role, entity_type, _actions} <- role_actions, entity_type not in entity_type_names do
      raise CompileError,
        description:
          "Role #{inspect(role)} references unknown entity type #{inspect(entity_type)}. " <>
            "Valid entity types: #{inspect(entity_type_names)}"
    end

    :ok
  end

  defp actions_for_clauses(role_actions) do
    Enum.map(role_actions, fn {role, entity_type, actions} ->
      quote do
        def actions_for(unquote(role), unquote(entity_type)), do: unquote(actions)
      end
    end)
  end

  # One valid_action?/2 clause per action any role grants on an entity type
  defp valid_action_clauses(role_actions) do
    role_actions
    |> Enum.flat_map(fn {_role, entity_type, actions} ->
      Enum.map(actions, &{&1, entity_type})
    end)
    |> Enum.uniq()
    |> Enum.map(fn {action, entity_type} ->
      quote do
        def valid_action?(unquote(action), unquote(entity_type)), do: true
      end
    end)
  end

  defp protocol_impls(entities) do
    for {name, struct_mod, id_field} <- entities, struct_mod != nil do
      quote do
        defimpl Edict.Entity, for: unquote(struct_mod) do
          def entity_id(entity), do: to_string(Map.get(entity, unquote(id_field)))
          def entity_type(_entity), do: unquote(name)
        end
      end
    end
  end

  defp strong_actions_or_none(nil), do: []
  defp strong_actions_or_none(strong_actions), do: strong_actions

  defp user_fn(nil), do: quote(do: fn assigns -> assigns.current_user.id end)
  defp user_fn(user_from_assigns), do: user_from_assigns

  # Default on_unauthorized: 403 for Plug.Conn, redirect for LiveView.Socket
  defp unauthorized_fn(nil) do
    quote do
      fn
        %Plug.Conn{} = conn, _context ->
          conn
          |> Plug.Conn.put_resp_content_type("text/plain")
          |> Plug.Conn.send_resp(403, "Forbidden")
          |> Plug.Conn.halt()

        %Phoenix.LiveView.Socket{} = socket, _context ->
          Phoenix.LiveView.redirect(socket, to: "/")
      end
    end
  end

  defp unauthorized_fn(on_unauthorized), do: on_unauthorized

  defp validate_strong_actions!(strong_actions, role_actions) do
    granted = Enum.flat_map(role_actions, fn {_role, _entity_type, actions} -> actions end)

    case Enum.reject(strong_actions, &(&1 in granted)) do
      [] ->
        :ok

      unknown ->
        raise CompileError,
          description:
            "strong_actions lists actions no role grants: #{inspect(unknown)}. " <>
              "Granted actions: #{inspect(Enum.uniq(granted))}"
    end
  end
end
