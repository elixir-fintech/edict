defmodule Edict.Features.StepDefinitions.StrongActionsSteps do
  @moduledoc """
  Step definitions for strong_actions.feature.

  State lives in the scenario context: `:config` is the per-scenario Edict
  config (see `Edict.Features.Support.Sandbox`), `:documents` maps user names
  to their cached authorization documents.
  """

  use Cucumber.StepDefinition
  import Ecto.Query
  import ExUnit.Assertions

  alias Edict.Enforcement.Helpers
  alias Edict.Schema.UserRole

  # Cucumber expressions for simple patterns...
  step "{string} is a strong action", %{args: [action]} = context do
    assert strong_action?(String.to_existing_atom(action))
    context
  end

  step "user {string} has the role {string} on account {string}",
       %{
         args: [user, role, id]
       } = context do
    insert_role!(context, user, role, id)
    context
  end

  # "user {string} has no roles" is shared by every feature; defined once in
  # project_roles_steps.exs.

  # ...and regexes for possessives: {word} eats "alice's" whole and the
  # expression parser cannot backtrack to leave the 's literal behind.
  step ~r/^(\w+)'s authorization document is cached$/, %{args: [user]} = context do
    document = Helpers.load_document(context.config, user)
    Map.put(context, :documents, Map.put(context.documents, user, document))
  end

  step ~r/^(\w+)'s "([^"]+)" role on account "([^"]+)" is revoked without notifying the cache$/,
       %{args: [user, role, id]} = context do
    context.repo.delete_all(
      from ur in UserRole,
        where:
          ur.user_id == ^user and ur.role == ^role and ur.entity_type == "account" and
            ur.entity_id == ^id
    )

    context
  end

  step ~r/^(\w+) is given the role "([^"]+)" on account "([^"]+)" without notifying the cache$/,
       %{args: [user, role, id]} = context do
    insert_role!(context, user, role, id)
    context
  end

  step ~r/^(\w+) cannot "([^"]+)" on account "([^"]+)"$/,
       %{args: [user, permission, id]} = context do
    refute authorized?(context, user, permission, id, [])
    context
  end

  step ~r/^(\w+) can "([^"]+)" on account "([^"]+)" with strong: false$/,
       %{args: [user, permission, id]} = context do
    assert authorized?(context, user, permission, id, strong: false)
    context
  end

  step ~r/^(\w+) can "([^"]+)" on account "([^"]+)"$/,
       %{args: [user, permission, id]} = context do
    assert authorized?(context, user, permission, id, [])
    context
  end

  defp insert_role!(context, user, role, id) do
    context.repo.insert!(%UserRole{
      user_id: user,
      role: role,
      entity_type: "account",
      entity_id: id
    })
  end

  defp authorized?(context, user, permission, id, opts) do
    Helpers.authorized?(
      context.config,
      context.documents[user],
      String.to_existing_atom(permission),
      :account,
      id,
      opts
    )
  end

  defp strong_action?(action) do
    Edict.Test.StrongConfig.strong_action?(action)
  end
end
