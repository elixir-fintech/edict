defmodule Edict.Features.StepDefinitions.ProjectRolesSteps do
  @moduledoc """
  Shared role setup on the project entity for feature tests.
  """

  use Cucumber.StepDefinition
  import Ecto.Query
  import ExUnit.Assertions

  alias Edict.Schema.UserRole

  step "user {string} has the role {string} on project {string}",
       %{
         args: [user, role, id]
       } = context do
    {:ok, _} = Edict.assign_role(user, String.to_existing_atom(role), :project, id)
    context
  end

  step "user {string} has no roles", %{args: [user]} = context do
    assert context.repo.all(from ur in UserRole, where: ur.user_id == ^user) == []
    context
  end
end
