defmodule Edict.EntityTest do
  use ExUnit.Case, async: true

  alias Edict.Entity

  describe "entity_id/1" do
    test "returns the entity ID as a string" do
      org = %Edict.Test.Organization{id: 42, name: "Acme"}
      assert Entity.entity_id(org) == "42"
    end

    test "returns string IDs unchanged" do
      org = %Edict.Test.Organization{id: "uuid-123", name: "Acme"}
      assert Entity.entity_id(org) == "uuid-123"
    end
  end

  describe "entity_type/1" do
    test "returns the entity type atom" do
      org = %Edict.Test.Organization{id: 1, name: "Acme"}
      assert Entity.entity_type(org) == :organization
    end
  end
end
