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
  - `strong_action?/1` — whether an action is always checked against the database
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
    user_from_assigns = Module.get_attribute(env.module, :edict_user_from_assigns)
    on_unauthorized_fn = Module.get_attribute(env.module, :edict_on_unauthorized)
    strong_actions = Module.get_attribute(env.module, :edict_strong_actions) || []

    entity_type_names = Enum.map(entities, fn {name, _, _} -> name end)

    # Validate that role actions reference valid entity types
    for {role, entity_type, _actions} <- role_actions do
      unless entity_type in entity_type_names do
        raise CompileError,
          description:
            "Role #{inspect(role)} references unknown entity type #{inspect(entity_type)}. " <>
              "Valid entity types: #{inspect(entity_type_names)}"
      end
    end

    validate_strong_actions!(strong_actions, role_actions)

    # Generate actions_for/2 clauses
    actions_for_clauses =
      Enum.map(role_actions, fn {role, entity_type, actions} ->
        quote do
          def actions_for(unquote(role), unquote(entity_type)), do: unquote(actions)
        end
      end)

    # Collect all valid actions per entity type
    actions_by_entity_type =
      role_actions
      |> Enum.reduce(%{}, fn {_role, entity_type, actions}, acc ->
        Map.update(acc, entity_type, MapSet.new(actions), &MapSet.union(&1, MapSet.new(actions)))
      end)
      |> Map.new(fn {et, actions} -> {et, MapSet.to_list(actions)} end)

    valid_action_clauses =
      Enum.flat_map(actions_by_entity_type, fn {entity_type, actions} ->
        Enum.map(actions, fn action ->
          quote do
            def valid_action?(unquote(action), unquote(entity_type)), do: true
          end
        end)
      end)

    # Generate protocol implementations
    protocol_impls =
      entities
      |> Enum.filter(fn {_name, struct_mod, _id_field} -> struct_mod != nil end)
      |> Enum.map(fn {name, struct_mod, id_field} ->
        quote do
          defimpl Edict.Entity, for: unquote(struct_mod) do
            def entity_id(entity), do: to_string(Map.get(entity, unquote(id_field)))
            def entity_type(_entity), do: unquote(name)
          end
        end
      end)

    # Default user_from_assigns
    user_fn =
      if user_from_assigns do
        user_from_assigns
      else
        quote(do: fn assigns -> assigns.current_user.id end)
      end

    # Default on_unauthorized — 403 for Plug.Conn, redirect for LiveView.Socket
    unauthorized_fn =
      if on_unauthorized_fn do
        on_unauthorized_fn
      else
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

    quote do
      @doc "Returns the list of valid entity types."
      def entity_types, do: unquote(entity_type_names)

      @doc "Returns `true` if the given entity type is defined."
      def valid_entity_type?(type), do: type in unquote(entity_type_names)

      @doc "Returns `true` if the given role is defined."
      def valid_role?(role), do: role in unquote(roles)

      unquote_splicing(actions_for_clauses)

      @doc "Returns the actions a role grants on an entity type. Returns `[]` for undefined combinations."
      def actions_for(_role, _entity_type), do: []

      unquote_splicing(valid_action_clauses)

      @doc "Returns `true` if the action is valid for the given entity type."
      def valid_action?(_action, _entity_type), do: false

      @doc "Returns `true` if the action is strong: always checked against the database."
      def strong_action?(action), do: action in unquote(strong_actions)

      @doc "Extracts the user ID from conn/socket assigns."
      def user_id_from_assigns(assigns), do: unquote(user_fn).(assigns)

      @doc "Returns the configured unauthorized handler function."
      def on_unauthorized, do: unquote(unauthorized_fn)

      # Protocol implementations
      unquote_splicing(protocol_impls)
    end
  end

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
