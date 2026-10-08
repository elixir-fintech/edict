defmodule Edict.Features.StepDefinitions.StrongPermissionsSteps do
  @moduledoc """
  Step definitions for strong_permissions.feature.

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
  step "{string} is a strong permission on {string}",
       %{args: [permission, entity_type]} = context do
    assert strong_permission?(permission, entity_type)
    context
  end

  step "{string} is not a strong permission on {string}",
       %{args: [permission, entity_type]} = context do
    refute strong_permission?(permission, entity_type)
    context
  end

  step "user {string} has the role {string} on account {string}",
       %{
         args: [user, role, id]
       } = context do
    insert_role!(context, user, role, id, "account")
    context
  end

  step "user {string} has the role {string} on invoice {string}",
       %{
         args: [user, role, id]
       } = context do
    insert_role!(context, user, role, id, "invoice")
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

  step ~r/^(\w+)'s "([^"]+)" role on (account|invoice) "([^"]+)" is revoked without notifying the cache$/,
       %{args: [user, role, entity_type, id]} = context do
    context.repo.delete_all(
      from ur in UserRole,
        where:
          ur.user_id == ^user and ur.role == ^role and ur.entity_type == ^entity_type and
            ur.entity_id == ^id
    )

    context
  end

  step ~r/^(\w+) is given the role "([^"]+)" on account "([^"]+)" without notifying the cache$/,
       %{args: [user, role, id]} = context do
    insert_role!(context, user, role, id, "account")
    context
  end

  step ~r/^(\w+) cannot "([^"]+)" on account "([^"]+)"$/,
       %{args: [user, permission, id]} = context do
    refute authorized?(context, user, permission, "account", id, [])
    context
  end

  step ~r/^(\w+) can "([^"]+)" on account "([^"]+)" with strong: false$/,
       %{args: [user, permission, id]} = context do
    assert authorized?(context, user, permission, "account", id, strong: false)
    context
  end

  step ~r/^(\w+) can "([^"]+)" on account "([^"]+)"$/,
       %{args: [user, permission, id]} = context do
    assert authorized?(context, user, permission, "account", id, [])
    context
  end

  step ~r/^(\w+) can "([^"]+)" on invoice "([^"]+)"$/,
       %{args: [user, permission, id]} = context do
    assert authorized?(context, user, permission, "invoice", id, [])
    context
  end

  defp insert_role!(context, user, role, id, entity_type) do
    context.repo.insert!(%UserRole{
      user_id: user,
      role: role,
      entity_type: entity_type,
      entity_id: id
    })
  end

  defp authorized?(context, user, permission, entity_type, id, opts) do
    Helpers.authorized?(
      context.config,
      context.documents[user],
      String.to_existing_atom(permission),
      String.to_existing_atom(entity_type),
      id,
      opts
    )
  end

  defp strong_permission?(permission, entity_type) do
    Edict.Test.StrongConfig.strong_permission?(
      String.to_existing_atom(permission),
      String.to_existing_atom(entity_type)
    )
  end
end
