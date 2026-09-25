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

  describe "actions_for/2" do
    test "returns actions for a role on an entity type" do
      actions = Edict.Test.Config.actions_for(:admin, :organization)
      assert :read in actions
      assert :write in actions
      assert :delete in actions
      assert :manage in actions
      assert :billing in actions
    end

    test "returns empty list for a role with no definition on an entity type" do
      assert Edict.Test.Config.actions_for(:billing_manager, :project) == []
    end

    test "returns scoped actions per entity type" do
      org_actions = Edict.Test.Config.actions_for(:admin, :organization)
      project_actions = Edict.Test.Config.actions_for(:admin, :project)

      assert :billing in org_actions
      refute :billing in project_actions
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

  describe "valid_action?/2" do
    test "returns true for actions defined on an entity type" do
      assert Edict.Test.Config.valid_action?(:read, :organization)
      assert Edict.Test.Config.valid_action?(:billing, :organization)
      assert Edict.Test.Config.valid_action?(:manage, :project)
    end

    test "returns false for actions not defined on an entity type" do
      refute Edict.Test.Config.valid_action?(:billing, :project)
      refute Edict.Test.Config.valid_action?(:manage, :resource)
    end

    test "returns false for completely unknown actions" do
      refute Edict.Test.Config.valid_action?(:fly, :organization)
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

  describe "strong_action?/1" do
    test "is true for a listed action" do
      assert Edict.Test.StrongConfig.strong_action?(:approve_transfer)
    end

    test "is false for an unlisted action" do
      refute Edict.Test.StrongConfig.strong_action?(:read)
    end

    test "is false for every action without strong_actions" do
      refute Edict.Test.Config.strong_action?(:delete)
    end
  end

  describe "strong_actions/1" do
    test "rejects an action no role grants" do
      assert_raise CompileError, ~r/:approve_transfr/, fn ->
        compile_config("strong_actions([:approve_transfr])")
      end
    end

    test "rejects a second declaration" do
      assert_raise CompileError, ~r/once/, fn ->
        compile_config("strong_actions([:read])\nstrong_actions([:read])")
      end
    end

    test "rejects a value that is not a list of atoms" do
      assert_raise CompileError, ~r/list of atoms/, fn ->
        compile_config("strong_actions(:read)")
      end
    end
  end

  defp compile_config(declaration) do
    module = "Edict.ConfigTest.Compiled#{System.unique_integer([:positive])}"

    Code.compile_string("""
    defmodule #{module} do
      use Edict.Config
      #{declaration}

      entity_types do
        entity(:account)
      end

      role :viewer do
        on(:account, actions: [:read])
      end
    end
    """)
  end
end
