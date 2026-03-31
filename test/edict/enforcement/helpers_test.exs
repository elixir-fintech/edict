defmodule Edict.Enforcement.HelpersTest do
  use ExUnit.Case, async: true

  alias Edict.Cache.Document
  alias Edict.Enforcement.Helpers

  @config_module Edict.Test.Config

  setup do
    doc = %Document{
      user_id: "user-1",
      version: 1,
      roles: %{
        {:organization, "42"} => [:admin, :billing_manager],
        {:project, "7"} => [:editor]
      }
    }

    %{doc: doc}
  end

  describe "can?/5 (with entity_type and entity_id)" do
    test "returns true when user has a role granting the action", %{doc: doc} do
      assert Helpers.can?(doc, :read, :organization, "42", @config_module)
      assert Helpers.can?(doc, :billing, :organization, "42", @config_module)
    end

    test "returns false when user lacks the action", %{doc: doc} do
      refute Helpers.can?(doc, :billing, :project, "7", @config_module)
    end

    test "returns false when user has no roles on the entity", %{doc: doc} do
      refute Helpers.can?(doc, :read, :team, "99", @config_module)
    end

    test "unions actions across multiple roles", %{doc: doc} do
      assert Helpers.can?(doc, :manage, :organization, "42", @config_module)
      assert Helpers.can?(doc, :billing, :organization, "42", @config_module)
    end
  end

  describe "can?/4 (with entity struct via protocol)" do
    test "returns true when authorized via protocol", %{doc: doc} do
      org = %Edict.Test.Organization{id: 42, name: "Acme"}
      assert Helpers.can?(doc, :read, org, @config_module)
    end

    test "returns false when not authorized via protocol", %{doc: doc} do
      project = %Edict.Test.Project{id: 99, name: "Unknown"}
      refute Helpers.can?(doc, :read, project, @config_module)
    end
  end
end
