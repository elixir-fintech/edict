defmodule Edict.ConfigTest do
  use ExUnit.Case, async: true

  describe "entity_types/0" do
    test "returns the list of valid entity types" do
      assert :organization in Edict.Test.Config.entity_types()
      assert :team in Edict.Test.Config.entity_types()
      assert :project in Edict.Test.Config.entity_types()
      assert :resource in Edict.Test.Config.entity_types()
    end
  end

  describe "valid_entity_type?/1" do
    test "returns true for valid entity types" do
      assert Edict.Test.Config.valid_entity_type?(:organization)
      assert Edict.Test.Config.valid_entity_type?(:project)
    end

    test "returns false for invalid entity types" do
      refute Edict.Test.Config.valid_entity_type?(:nonexistent)
    end
  end

  describe "valid_role?/1" do
    test "returns true for defined roles" do
      assert Edict.Test.Config.valid_role?(:admin)
      assert Edict.Test.Config.valid_role?(:editor)
      assert Edict.Test.Config.valid_role?(:viewer)
      assert Edict.Test.Config.valid_role?(:billing_manager)
    end

    test "returns false for undefined roles" do
      refute Edict.Test.Config.valid_role?(:superadmin)
    end
  end

  describe "permissions_for/2" do
    test "returns permissions for a role on an entity type" do
      permissions = Edict.Test.Config.permissions_for(:admin, :organization)
      assert :read in permissions
      assert :write in permissions
      assert :delete in permissions
      assert :manage in permissions
      assert :billing in permissions
    end

    test "returns empty list for a role with no definition on an entity type" do
      assert Edict.Test.Config.permissions_for(:billing_manager, :project) == []
    end

    test "returns scoped permissions per entity type" do
      org_permissions = Edict.Test.Config.permissions_for(:admin, :organization)
      project_permissions = Edict.Test.Config.permissions_for(:admin, :project)

      assert :billing in org_permissions
      refute :billing in project_permissions
    end
  end

  describe "user_id_from_assigns/1" do
    test "extracts user ID using the configured function" do
      assigns = %{current_user: %{id: "user-123"}}
      assert Edict.Test.Config.user_id_from_assigns(assigns) == "user-123"
    end
  end

  describe "on_unauthorized/0" do
    test "returns the configured on_unauthorized function" do
      assert is_function(Edict.Test.Config.on_unauthorized())
    end
  end

  describe "valid_permission?/2" do
    test "returns true for permissions defined on an entity type" do
      assert Edict.Test.Config.valid_permission?(:read, :organization)
      assert Edict.Test.Config.valid_permission?(:billing, :organization)
      assert Edict.Test.Config.valid_permission?(:manage, :project)
    end

    test "returns false for permissions not defined on an entity type" do
      refute Edict.Test.Config.valid_permission?(:billing, :project)
      refute Edict.Test.Config.valid_permission?(:manage, :resource)
    end

    test "returns false for completely unknown permissions" do
      refute Edict.Test.Config.valid_permission?(:fly, :organization)
    end
  end

  describe "validate_config!/1" do
    test "returns :ok for a valid config module" do
      assert :ok = Edict.validate_config!(Edict.Test.Config)
    end

    test "raises for a module missing required functions" do
      assert_raise ArgumentError, ~r/missing required functions/, fn ->
        Edict.validate_config!(String)
      end
    end
  end

  describe "strong_permission?/2" do
    test "is true for a listed permission on its entity type" do
      assert Edict.Test.StrongConfig.strong_permission?(:approve_transfer, :account)
    end

    test "is false for the same permission on another entity type" do
      refute Edict.Test.StrongConfig.strong_permission?(:approve_transfer, :invoice)
    end

    test "is false for an unlisted permission" do
      refute Edict.Test.StrongConfig.strong_permission?(:read, :account)
    end

    test "is false for every permission without strong_permissions" do
      refute Edict.Test.Config.strong_permission?(:delete, :project)
    end
  end

  describe "strong_permissions/1" do
    test "rejects a permission no role grants on that entity type" do
      assert_raise CompileError, ~r/:approve_transfr/, fn ->
        compile_config("""
        strong_permissions do
          on(:account, permissions: [:approve_transfr])
        end
        """)
      end
    end

    test "rejects a permission granted only on another entity type" do
      assert_raise CompileError, ~r/no role grants on that entity type/, fn ->
        compile_config("""
        strong_permissions do
          on(:account, permissions: [:write])
        end

        entity(:team)

        role :editor do
          on(:team, permissions: [:write])
        end
        """)
      end
    end

    test "rejects an unknown entity type" do
      assert_raise CompileError, ~r/unknown entity type/, fn ->
        compile_config("""
        strong_permissions do
          on(:galaxy, permissions: [:read])
        end
        """)
      end
    end

    test "rejects a second declaration" do
      assert_raise CompileError, ~r/once/, fn ->
        compile_config("""
        strong_permissions do
          on(:account, permissions: [:read])
        end

        strong_permissions do
          on(:account, permissions: [:read])
        end
        """)
      end
    end

    test "rejects on/2 outside a role or strong_permissions block" do
      assert_raise CompileError, ~r/only valid inside/, fn ->
        compile_config("on(:account, permissions: [:read])")
      end
    end
  end

  describe "on/2 duplicates" do
    test "a second on for the same entity type in a role fails compilation" do
      assert_raise CompileError, ~r/more than once/, fn ->
        compile_config("""
        role :editor do
          on(:account, permissions: [:write])
          on(:account, permissions: [:delete])
        end
        """)
      end
    end

    test "a second on for the same entity type in strong_permissions fails compilation" do
      assert_raise CompileError, ~r/more than once/, fn ->
        compile_config("""
        strong_permissions do
          on(:account, permissions: [:read])
          on(:account, permissions: [:write])
        end
        """)
      end
    end
  end

  describe "permission_alias/1" do
    test "maps the shipped default action names" do
      assert Edict.Test.Config.permission_alias(:index) == :read
      assert Edict.Test.Config.permission_alias(:show) == :read
      assert Edict.Test.Config.permission_alias(:new) == :write
      assert Edict.Test.Config.permission_alias(:edit) == :write
      assert Edict.Test.Config.permission_alias(:create) == :write
      assert Edict.Test.Config.permission_alias(:update) == :write
      assert Edict.Test.Config.permission_alias(:delete) == :delete
    end

    test "returns nil for an unmapped name" do
      assert is_nil(Edict.Test.Config.permission_alias(:billing))
    end

    test "an app declaration merges over the defaults entry by entry" do
      module =
        compile_config("""
        permission_aliases(show: :view, archive: :delete)

        entity(:team)

        role :curator do
          on(:team, permissions: [:view, :delete])
        end
        """)

      assert module.permission_alias(:show) == :view
      assert module.permission_alias(:index) == :read
      assert module.permission_alias(:archive) == :delete
      assert is_nil(module.permission_alias(:billing))
    end

    test "rejects a value that is not a keyword list of atoms" do
      assert_raise CompileError, ~r/keyword list of atoms/, fn ->
        compile_config("permission_aliases(show: \"read\")")
      end
    end
  end

  describe "extends (role seniority)" do
    test "unions the parent's permissions into the extending role" do
      permissions = Edict.Test.Config.permissions_for(:editor, :project)
      assert :read in permissions
      assert :write in permissions
    end

    test "composes transitively" do
      permissions = Edict.Test.Config.permissions_for(:admin, :project)
      assert :read in permissions
      assert :write in permissions
      assert :delete in permissions
    end

    test "inherits across every entity type the parent declares" do
      assert Enum.sort(Edict.Test.Config.permissions_for(:editor, :resource)) == [:read, :write]
    end

    test "multiple extends is a union" do
      module =
        compile_config("""
        entity(:team)

        role :reader do
          on(:team, permissions: [:read])
        end

        role :writer do
          on(:team, permissions: [:write])
        end

        role :manager do
          extends [:reader, :writer]
          on(:team, permissions: [:manage])
        end
        """)

      assert Enum.sort(module.permissions_for(:manager, :team)) == [:manage, :read, :write]
    end

    test "an unknown parent fails compilation" do
      assert_raise CompileError, ~r/ghost/, fn ->
        compile_config("""
        role :manager do
          extends :ghost
          on(:account, permissions: [:write])
        end
        """)
      end
    end

    test "an inheritance cycle fails compilation" do
      assert_raise CompileError, ~r/cycle/, fn ->
        compile_config("""
        role :a do
          extends :b
          on(:account, permissions: [:read])
        end

        role :b do
          extends :a
          on(:account, permissions: [:write])
        end
        """)
      end
    end

    test "extends outside a role fails compilation" do
      assert_raise CompileError, ~r/only valid inside role/, fn ->
        compile_config("extends :viewer")
      end
    end
  end

  defp compile_config(declaration) do
    module = "Edict.ConfigTest.Compiled#{System.unique_integer([:positive])}"

    [{compiled, _binary}] =
      Code.compile_string("""
      defmodule #{module} do
        use Edict.Config
        #{declaration}

        entity_types do
          entity(:account)
        end

        role :viewer do
          on(:account, permissions: [:read])
        end
      end
      """)

    compiled
  end
end
