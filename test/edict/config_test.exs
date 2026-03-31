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
end
