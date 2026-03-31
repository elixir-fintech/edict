defmodule Edict.Schema.UserRoleTest do
  use ExUnit.Case, async: true

  alias Edict.Schema.UserRole

  describe "changeset/2" do
    test "valid changeset with all required fields" do
      attrs = %{
        user_id: "user-123",
        entity_type: "organization",
        entity_id: "org-42",
        role: "admin"
      }

      changeset = UserRole.changeset(%UserRole{}, attrs)
      assert changeset.valid?
    end

    test "invalid changeset missing user_id" do
      attrs = %{entity_type: "organization", entity_id: "org-42", role: "admin"}
      changeset = UserRole.changeset(%UserRole{}, attrs)
      refute changeset.valid?
      assert %{user_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "invalid changeset missing entity_type" do
      attrs = %{user_id: "user-123", entity_id: "org-42", role: "admin"}
      changeset = UserRole.changeset(%UserRole{}, attrs)
      refute changeset.valid?
      assert %{entity_type: ["can't be blank"]} = errors_on(changeset)
    end

    test "invalid changeset missing entity_id" do
      attrs = %{user_id: "user-123", entity_type: "organization", role: "admin"}
      changeset = UserRole.changeset(%UserRole{}, attrs)
      refute changeset.valid?
      assert %{entity_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "invalid changeset missing role" do
      attrs = %{user_id: "user-123", entity_type: "organization", entity_id: "org-42"}
      changeset = UserRole.changeset(%UserRole{}, attrs)
      refute changeset.valid?
      assert %{role: ["can't be blank"]} = errors_on(changeset)
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
