defmodule Edict.Config do
  @moduledoc """
  DSL for defining entity types, roles, and scoped permissions.

  ## Usage

      defmodule MyApp.AuthConfig do
        use Edict.Config

        # Optional; the default reads the Phoenix 1.8 scope:
        user_from_assigns fn assigns -> assigns.current_scope.user.id end

        # Optional; these are the shipped defaults:
        permission_aliases [
          index: :read, show: :read,
          new: :write, edit: :write, create: :write, update: :write,
          delete: :delete
        ]

        strong_permissions do
          on :account, permissions: [:delete]
        end

        entity_types do
          entity :organization, struct: MyApp.Organization
          entity :project, struct: MyApp.Project
          entity :account, struct: MyApp.Account
        end

        role :viewer do
          on :project, permissions: [:read]
        end

        role :admin do
          extends :viewer
          on :organization, permissions: [:read, :write, :delete]
          on :project, permissions: [:write, :delete]
          on :account, permissions: [:delete]
        end
      end

  **Note:** Only one module should `use Edict.Config` per application. Two config modules
  naming the same `struct:` would generate duplicate `Edict.Entity` implementations.

  This compiles into fast lookup functions:
  - `permissions_for/2` — permissions a role grants on an entity type, including everything inherited through `extends`
  - `valid_role?/1` — whether a role is defined
  - `valid_entity_type?/1` — whether an entity type is defined
  - `valid_permission?/2` — whether a permission is valid for an entity type
  - `strong_permission?/2` — whether enforcement always checks a (permission, entity type) pair against the database
  - `permission_alias/1` — the permission a Phoenix action name maps to, or `nil`
  - `entity_types/0` — list of valid entity types
  - `user_id_from_assigns/1` — extract user ID from conn/socket assigns
  - `on_unauthorized/0` — the denial handler for Plug and LiveView
  """

  @default_permission_aliases [
    index: :read,
    show: :read,
    new: :write,
    edit: :write,
    create: :write,
    update: :write,
    delete: :delete
  ]

  defmacro __using__(_opts) do
    quote do
      @before_compile Edict.Config

      Module.register_attribute(__MODULE__, :edict_entities, accumulate: true)
      Module.register_attribute(__MODULE__, :edict_roles, accumulate: true)
      Module.register_attribute(__MODULE__, :edict_role_permissions, accumulate: true)
      Module.register_attribute(__MODULE__, :edict_role_extends, accumulate: true)
      Module.register_attribute(__MODULE__, :edict_strong_pairs, accumulate: true)
      Module.register_attribute(__MODULE__, :edict_permission_aliases, accumulate: false)
      Module.register_attribute(__MODULE__, :edict_user_from_assigns, accumulate: false)
      Module.register_attribute(__MODULE__, :edict_on_unauthorized, accumulate: false)
      Module.register_attribute(__MODULE__, :edict_current_role, accumulate: false)
      Module.register_attribute(__MODULE__, :edict_strong_block, accumulate: false)
      Module.register_attribute(__MODULE__, :edict_strong_declared, accumulate: false)

      Module.put_attribute(__MODULE__, :edict_permission_aliases, nil)
      Module.put_attribute(__MODULE__, :edict_user_from_assigns, nil)
      Module.put_attribute(__MODULE__, :edict_on_unauthorized, nil)
      Module.put_attribute(__MODULE__, :edict_current_role, nil)
      Module.put_attribute(__MODULE__, :edict_strong_block, false)
      Module.put_attribute(__MODULE__, :edict_strong_declared, false)

      import Edict.Config,
        only: [
          entity_types: 1,
          entity: 1,
          entity: 2,
          role: 2,
          on: 2,
          extends: 1,
          user_from_assigns: 1,
          on_unauthorized: 1,
          strong_permissions: 1,
          permission_aliases: 1
        ]
    end
  end

  @doc """
  Sets how the user ID is read from conn or socket assigns.

  Default: `fn assigns -> assigns.current_scope.user.id end`, matching the
  `current_scope` that Phoenix 1.8's `mix phx.gen.auth` assigns. It raises when
  `current_scope` is missing or `nil`, so Edict must run after authentication.

  Apps whose authentication assigns `current_user` instead (Phoenix 1.7's
  `phx.gen.auth`, or a hand-written plug) declare:

      user_from_assigns fn assigns -> assigns.current_user.id end
  """
  defmacro user_from_assigns(func) do
    escaped = Macro.escape(func)

    quote do
      Module.put_attribute(__MODULE__, :edict_user_from_assigns, unquote(escaped))
    end
  end

  @doc """
  Sets the denial handler, a `fn conn_or_socket, context -> ... end` where
  `context` is `%{}`.

  Default: a `403` `text/plain` "Forbidden" response for a `Plug.Conn`, and
  `Phoenix.LiveView.redirect(socket, to: "/")` for a LiveView socket. Edict
  halts the conn itself. A LiveView handler must redirect on mount and after
  version bumps (`redirect` or `push_navigate`; `push_patch` keeps the LiveView
  open and raises); for an `authorize` event, a handler that does not redirect
  just drops the event.
  """
  defmacro on_unauthorized(func) do
    escaped = Macro.escape(func)

    quote do
      Module.put_attribute(__MODULE__, :edict_on_unauthorized, unquote(escaped))
    end
  end

  @doc """
  Maps Phoenix action names to Edict permissions.

  An app's declaration merges over the shipped defaults entry by entry: app
  entries win, unmapped names keep their default, and only the entries you
  name change. The defaults are:

      index: :read, show: :read,
      new: :write, edit: :write, create: :write, update: :write,
      delete: :delete

  Aliases are a global naming convention, deliberately not per entity type:
  the resolved permission is validated per entity type where it is used, and
  a name meaning different permissions per entity type is better stated
  explicitly. Generates `permission_alias/1`, which returns the permission
  or `nil` when unmapped.
  """
  defmacro permission_aliases(aliases) do
    unless Keyword.keyword?(aliases) and
             Enum.all?(aliases, fn {_name, permission} -> is_atom(permission) end) do
      raise CompileError,
        description:
          "permission_aliases expects a keyword list of atoms, got: #{Macro.to_string(aliases)}"
    end

    quote do
      Module.put_attribute(
        __MODULE__,
        :edict_permission_aliases,
        Keyword.merge(
          Module.get_attribute(__MODULE__, :edict_permission_aliases) || [],
          unquote(aliases)
        )
      )
    end
  end

  @doc """
  Declares permissions that are always checked against the database.

  Route guards, LiveView mount checks and `authorize` guards always check them
  against the database. Only `Edict.can?` may opt out with `strong: false`,
  for display checks. (`Edict.Enforcement.Helpers.can?/5` reads only a document
  it is given and ignores strong permissions; enforcement does not use it.)

  Strength is a property of the (entity type, permission) pair: the same
  permission name may be strong on one entity type and served from the cache
  on another. The block takes one `on/2` per entity type, each with a literal
  list of permission atoms, and may appear at most once. Every listed
  permission must be granted by some role on that entity type.
  """
  defmacro strong_permissions(do: block) do
    quote do
      if Module.get_attribute(__MODULE__, :edict_strong_declared) do
        raise CompileError, description: "strong_permissions can only be declared once"
      end

      Module.put_attribute(__MODULE__, :edict_strong_declared, true)
      Module.put_attribute(__MODULE__, :edict_strong_block, true)
      unquote(block)
      Module.put_attribute(__MODULE__, :edict_strong_block, false)
    end
  end

  @doc "Groups the `entity/2` declarations."
  defmacro entity_types(do: block) do
    quote do
      unquote(block)
    end
  end

  @doc """
  Declares an entity type.

  Options:
    * `:struct` — a struct module; generates its `Edict.Entity` implementation
    * `:id_field` — the struct field holding the ID (default `:id`)
  """
  defmacro entity(type, opts \\ []) do
    quote do
      Module.put_attribute(__MODULE__, :edict_entities, {
        unquote(type),
        unquote(opts[:struct]),
        unquote(opts[:id_field] || :id)
      })
    end
  end

  @doc "Declares a role; its `on/2` calls list what it grants. A role may be declared once."
  defmacro role(name, do: block) do
    quote do
      if unquote(name) in Enum.map(@edict_roles, & &1) do
        raise CompileError,
          description: "Duplicate role definition: #{inspect(unquote(name))}"
      end

      Module.put_attribute(__MODULE__, :edict_roles, unquote(name))

      @edict_current_role unquote(name)
      unquote(block)
      Module.put_attribute(__MODULE__, :edict_current_role, nil)
    end
  end

  @doc """
  Inside `role/2`: inherits every permission the named role declares, across
  all entity types.

  Takes a role name or a list; multiple extends union. The transitive union
  is resolved when the config compiles, so `permissions_for/2` reports
  effective permissions and no runtime, storage, or cache behavior changes:
  assigning a role still stores a single row. An unknown parent or an
  inheritance cycle fails compilation.
  """
  defmacro extends(parents) do
    quote do
      unless Module.get_attribute(__MODULE__, :edict_current_role) do
        raise CompileError, description: "extends is only valid inside role/2"
      end

      Module.put_attribute(__MODULE__, :edict_role_extends, {
        Module.get_attribute(__MODULE__, :edict_current_role),
        List.wrap(unquote(parents))
      })
    end
  end

  @doc """
  Inside `role/2`: grants `permissions:` on an entity type declared in `entity_types/1`.
  Inside `strong_permissions/1`: marks the listed permissions strong on the entity type.

  Use one `on` per entity type in a role and in `strong_permissions/1`: a
  second declaration for the same entity type fails compilation, so its
  permissions are never silently dropped. Anywhere else it fails compilation
  too.
  """
  defmacro on(entity_type, opts) do
    permissions = opts[:permissions] || []

    quote do
      current_role = Module.get_attribute(__MODULE__, :edict_current_role)
      strong_block? = Module.get_attribute(__MODULE__, :edict_strong_block)

      cond do
        current_role ->
          Module.put_attribute(__MODULE__, :edict_role_permissions, {
            current_role,
            unquote(entity_type),
            unquote(permissions)
          })

        strong_block? ->
          Module.put_attribute(__MODULE__, :edict_strong_pairs, {
            unquote(entity_type),
            unquote(permissions)
          })

        true ->
          raise CompileError,
            description: "on/2 is only valid inside role/2 or strong_permissions/1"
      end
    end
  end

  defmacro __before_compile__(env) do
    entities = Module.get_attribute(env.module, :edict_entities)
    roles = Module.get_attribute(env.module, :edict_roles)
    role_permissions = Module.get_attribute(env.module, :edict_role_permissions)
    role_extends = Module.get_attribute(env.module, :edict_role_extends)
    strong_declarations = Module.get_attribute(env.module, :edict_strong_pairs)
    strong_pairs = strong_pairs(strong_declarations)

    permission_aliases =
      merged_permission_aliases(Module.get_attribute(env.module, :edict_permission_aliases))

    user_fn = user_fn(Module.get_attribute(env.module, :edict_user_from_assigns))
    unauthorized_fn = unauthorized_fn(Module.get_attribute(env.module, :edict_on_unauthorized))

    entity_type_names = Enum.map(entities, fn {name, _, _} -> name end)

    resolved_permissions = resolve_role_permissions!(roles, role_extends, role_permissions)

    validate_entity_types!(role_permissions, entity_type_names)
    validate_duplicate_declarations!(role_permissions, strong_declarations)
    validate_strong_pairs!(strong_pairs, role_permissions, entity_type_names)

    quote do
      @doc "Returns the list of valid entity types."
      @spec entity_types() :: [atom()]
      def entity_types, do: unquote(entity_type_names)

      @doc "Returns `true` if the given entity type is defined."
      @spec valid_entity_type?(term()) :: boolean()
      def valid_entity_type?(type), do: type in unquote(entity_type_names)

      @doc "Returns `true` if the given role is defined."
      @spec valid_role?(term()) :: boolean()
      def valid_role?(role), do: role in unquote(roles)

      @spec permissions_for(atom(), atom()) :: [atom()]
      unquote_splicing(permissions_for_clauses(resolved_permissions))

      @doc """
      Returns the permissions a role grants on an entity type, including
      everything inherited through `extends`. Returns `[]` for undefined combinations.
      """
      def permissions_for(_role, _entity_type), do: []

      @spec valid_permission?(atom(), atom()) :: boolean()
      unquote_splicing(valid_permission_clauses(role_permissions))

      @doc "Returns `true` if the permission is valid for the given entity type."
      def valid_permission?(_permission, _entity_type), do: false

      @doc "Returns `true` if the permission is strong on the entity type: enforcement always checks it against the database."
      @spec strong_permission?(atom(), atom()) :: boolean()
      def strong_permission?(permission, entity_type),
        do: {permission, entity_type} in unquote(Enum.uniq(strong_pairs))

      @doc "Returns the permission the Phoenix action name maps to, or `nil` when unmapped."
      @spec permission_alias(atom()) :: atom() | nil
      def permission_alias(action_name),
        do: Keyword.get(unquote(Macro.escape(permission_aliases)), action_name)

      @doc "Extracts the user ID from conn/socket assigns."
      @spec user_id_from_assigns(map()) :: term()
      def user_id_from_assigns(assigns), do: unquote(user_fn).(assigns)

      @doc "Returns the configured unauthorized handler function."
      @spec on_unauthorized() :: (term(), map() -> term())
      def on_unauthorized, do: unquote(unauthorized_fn)

      unquote_splicing(protocol_impls(entities))
    end
  end

  # The functions below run at compile time, from __before_compile__/1.

  # A second `on` for the same entity type used to be silently ignored while
  # valid_permission?/2 still counted its permissions — the two disagreed.
  # Failing compilation removes the inconsistency.
  defp validate_duplicate_declarations!(role_permissions, strong_declarations) do
    role_duplicates =
      role_permissions
      |> Enum.frequencies_by(fn {role, entity_type, _} -> {role, entity_type} end)
      |> Enum.filter(fn {_key, count} -> count > 1 end)
      |> Enum.map(fn {{role, entity_type}, _} ->
        "#{inspect(role)} on #{inspect(entity_type)}"
      end)

    strong_duplicates =
      strong_declarations
      |> Enum.frequencies_by(&elem(&1, 0))
      |> Enum.filter(fn {_entity_type, count} -> count > 1 end)
      |> Enum.map(fn {entity_type, _} -> "on #{inspect(entity_type)} in strong_permissions" end)

    case role_duplicates ++ strong_duplicates do
      [] ->
        :ok

      duplicates ->
        raise CompileError,
          description:
            "on/2 is declared more than once for: #{Enum.join(duplicates, ", ")}. " <>
              "Combine the permissions into one declaration"
    end
  end

  defp validate_entity_types!(role_permissions, entity_type_names) do
    for {role, entity_type, _permissions} <- role_permissions,
        entity_type not in entity_type_names do
      raise CompileError,
        description:
          "Role #{inspect(role)} references unknown entity type #{inspect(entity_type)}. " <>
            "Valid entity types: #{inspect(entity_type_names)}"
    end

    :ok
  end

  defp permissions_for_clauses(resolved_permissions) do
    for {role, per_entity_type} <- resolved_permissions,
        {entity_type, permissions} <- per_entity_type do
      quote do
        def permissions_for(unquote(role), unquote(entity_type)), do: unquote(permissions)
      end
    end
  end

  # %{role => %{entity_type => [permissions]}} — the transitive union of each
  # role's own and inherited grants, resolved when the config compiles so the
  # runtime stays role-keyed and unchanged.
  defp resolve_role_permissions!(roles, role_extends, role_permissions) do
    extends =
      Enum.reduce(role_extends, %{}, fn {role, parents}, acc ->
        Map.update(acc, role, parents, &Enum.uniq(&1 ++ parents))
      end)

    for {role, parents} <- extends,
        parent <- parents,
        parent not in roles do
      raise CompileError,
        description:
          "Role #{inspect(role)} extends undefined role #{inspect(parent)}. " <>
            "Defined roles: #{inspect(roles)}"
    end

    Map.new(roles, fn role ->
      {role, effective_permissions(role, extends, role_permissions, [])}
    end)
  end

  defp effective_permissions(role, extends, role_permissions, trail) do
    if role in trail do
      raise CompileError,
        description:
          "Inheritance cycle in role definitions: #{inspect(Enum.reverse([role | trail]))}"
    end

    own =
      Enum.reduce(role_permissions, %{}, fn
        {^role, entity_type, permissions}, acc -> Map.put_new(acc, entity_type, permissions)
        _, acc -> acc
      end)

    extends
    |> Map.get(role, [])
    |> Enum.reduce(own, fn parent, acc ->
      inherited = effective_permissions(parent, extends, role_permissions, [role | trail])

      Map.merge(acc, inherited, fn _entity_type, own_permissions, inherited_permissions ->
        Enum.uniq(own_permissions ++ inherited_permissions)
      end)
    end)
  end

  # One valid_permission?/2 clause per permission any role grants on an entity type
  defp valid_permission_clauses(role_permissions) do
    role_permissions
    |> Enum.flat_map(fn {_role, entity_type, permissions} ->
      Enum.map(permissions, &{&1, entity_type})
    end)
    |> Enum.uniq()
    |> Enum.map(fn {permission, entity_type} ->
      quote do
        def valid_permission?(unquote(permission), unquote(entity_type)), do: true
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

  # The strong declarations as (permission, entity type) pairs, the shape
  # strong_permission?/2 answers for.
  defp strong_pairs(declarations) do
    Enum.flat_map(declarations, fn {entity_type, permissions} ->
      Enum.map(permissions, &{&1, entity_type})
    end)
  end

  defp merged_permission_aliases(nil), do: @default_permission_aliases

  defp merged_permission_aliases(aliases),
    do: Keyword.merge(@default_permission_aliases, aliases)

  defp user_fn(nil), do: quote(do: fn assigns -> assigns.current_scope.user.id end)
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

  # Per (entity type, permission) pair: the entity type must be declared and
  # some role must grant the permission on exactly that entity type.
  defp validate_strong_pairs!(strong_pairs, role_permissions, entity_type_names) do
    for {_permission, entity_type} <- strong_pairs, entity_type not in entity_type_names do
      raise CompileError,
        description:
          "strong_permissions references unknown entity type #{inspect(entity_type)}. " <>
            "Valid entity types: #{inspect(entity_type_names)}"
    end

    granted =
      role_permissions
      |> Enum.flat_map(fn {_role, entity_type, permissions} ->
        Enum.map(permissions, &{&1, entity_type})
      end)
      |> MapSet.new()

    case Enum.reject(strong_pairs, &MapSet.member?(granted, &1)) do
      [] ->
        :ok

      unknown ->
        raise CompileError,
          description:
            "strong_permissions lists permissions no role grants on that entity type: " <>
              "#{format_pairs(unknown)}. Granted: #{format_pairs(Enum.sort(MapSet.to_list(granted)))}"
    end
  end

  defp format_pairs(pairs) do
    Enum.map_join(pairs, ", ", fn {permission, entity_type} ->
      "#{inspect(permission)} on #{inspect(entity_type)}"
    end)
  end
end
