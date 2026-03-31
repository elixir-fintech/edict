defmodule Edict.Cache.DocumentTest do
  use ExUnit.Case, async: true

  alias Edict.Cache.Document

  describe "new/3" do
    test "creates a document from a list of user_role rows" do
      roles = [
        %{entity_type: "organization", entity_id: "42", role: "admin"},
        %{entity_type: "organization", entity_id: "42", role: "billing_manager"},
        %{entity_type: "project", entity_id: "7", role: "editor"}
      ]

      doc = Document.new("user-123", roles, 1)

      assert doc.user_id == "user-123"
      assert doc.version == 1
      assert doc.roles[{:organization, "42"}] == [:admin, :billing_manager]
      assert doc.roles[{:project, "7"}] == [:editor]
    end

    test "creates an empty document when user has no roles" do
      doc = Document.new("user-456", [], 1)

      assert doc.user_id == "user-456"
      assert doc.version == 1
      assert doc.roles == %{}
    end
  end

  describe "roles_for/3" do
    test "returns roles for a specific entity" do
      doc = %Document{
        user_id: "user-123",
        version: 1,
        roles: %{
          {:organization, "42"} => [:admin, :billing_manager],
          {:project, "7"} => [:editor]
        }
      }

      assert Document.roles_for(doc, :organization, "42") == [:admin, :billing_manager]
      assert Document.roles_for(doc, :project, "7") == [:editor]
    end

    test "returns empty list for entity with no roles" do
      doc = %Document{user_id: "user-123", version: 1, roles: %{}}

      assert Document.roles_for(doc, :organization, "99") == []
    end
  end
end
