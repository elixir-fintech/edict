defmodule Edict.Features.StepDefinitions.RoleWriteSteps do
  @moduledoc """
  Step definitions for role_writes.feature.
  """

  use Cucumber.StepDefinition
  import Ecto.Query
  import ExUnit.Assertions

  alias Edict.Schema.UserRole

  step "{string} is assigned the unknown role {string} on project {string}",
       %{args: [user, role, id]} = context do
    # The unknown names must not exist as atoms, so String.to_atom/1 is deliberate.
    Map.put(context, :write, Edict.assign_role(user, String.to_atom(role), :project, id))
  end

  step "{string} is assigned {string} on unknown entity {string} {string}",
       %{args: [user, role, entity, id]} = context do
    Map.put(
      context,
      :write,
      Edict.assign_role(user, String.to_existing_atom(role), String.to_atom(entity), id)
    )
  end

  step "{string} is assigned {string} on project {string}", %{args: [user, role, id]} = context do
    Map.put(context, :write, Edict.assign_role(user, String.to_existing_atom(role), :project, id))
  end

  step "a blank user is assigned {string} on project {string}", %{args: [role, id]} = context do
    Map.put(context, :write, Edict.assign_role("", String.to_existing_atom(role), :project, id))
  end

  step ~r/^(\w+)'s missing "([^"]+)" role on project "([^"]+)" is revoked$/,
       %{args: [user, role, id]} = context do
    Map.put(context, :write, Edict.revoke_role(user, String.to_existing_atom(role), :project, id))
  end

  step "{string} is assigned {string} on project {string} again",
       %{args: [user, role, id]} = context do
    Map.put(context, :write, Edict.assign_role(user, String.to_existing_atom(role), :project, id))
  end

  step "{string} is assigned {string} on projects {string} and {string}",
       %{args: [user, role, first, second]} = context do
    result =
      Edict.assign_roles(user, String.to_existing_atom(role), [project(first), project(second)])

    Map.put(context, :write, result)
  end

  step "{string} is bulk-assigned {string} on project {string} and unknown entity {string} {string}",
       %{args: [user, role, id, entity, other_id]} = context do
    result =
      Edict.assign_roles(user, String.to_existing_atom(role), [
        {:project, id},
        {String.to_atom(entity), other_id}
      ])

    Map.put(context, :write, result)
  end

  step "project {string} is deleted and its roles are revoked", %{args: [id]} = context do
    {:ok, _} = Edict.revoke_entity(:project, id)
    context
  end

  step "the write fails with invalid_role and stores nothing", context do
    assert context.write == {:error, :invalid_role}
    assert stored_roles(context) == []
    context
  end

  step "the write fails with invalid_entity_type and stores nothing", context do
    assert context.write == {:error, :invalid_entity_type}
    assert stored_roles(context) == []
    context
  end

  step "the write fails with a changeset error and stores nothing", context do
    assert match?({:error, %Ecto.Changeset{}}, context.write)
    assert stored_roles(context) == []
    context
  end

  step "the write reports already_assigned", context do
    assert context.write == {:ok, :already_assigned}
    context
  end

  step "the write reports not_found", context do
    assert context.write == {:ok, :not_found}
    context
  end

  step "only the project {string} assignment is returned", %{args: [id]} = context do
    assert match?({:ok, [_]}, context.write)
    {:ok, [role]} = context.write
    assert role.entity_id == id
    context
  end

  step "{word} and {word} hold no roles on project {string}",
       %{args: [first, second, id]} = context do
    for user <- [first, second] do
      assert context.repo.all(
               from ur in UserRole,
                 where:
                   ur.user_id == ^user and ur.entity_type == "project" and ur.entity_id == ^id
             ) == []
    end

    context
  end

  defp project(id), do: {:project, id}

  defp stored_roles(context) do
    context.repo.all(from(ur in UserRole))
  end
end
