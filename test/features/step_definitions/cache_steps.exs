defmodule Edict.Features.StepDefinitions.CacheSteps do
  @moduledoc """
  Step definitions for cache_invalidation.feature.
  """

  use Cucumber.StepDefinition
  import Ecto.Query
  import ExUnit.Assertions

  alias Edict.Cache.Store
  alias Edict.Enforcement.Helpers
  alias Edict.Test.Checks
  alias Edict.Schema.UserRole

  step ~r/^(\w+)'s project document is cached$/, %{args: [user]} = context do
    document = Helpers.load_document(context.project_config, user)

    context
    |> Map.put(:documents, Map.put(context.documents, user, document))
    |> Map.put(:cached_version, version(context, user))
  end

  step ~r/^(\w+) is assigned "([^"]+)" on project "([^"]+)"$/,
       %{args: [user, role, id]} = context do
    {:ok, _} = Edict.assign_role(user, String.to_existing_atom(role), :project, id)
    context
  end

  step ~r/^(\w+) is assigned "([^"]+)" on project "([^"]+)" again$/,
       %{args: [user, role, id]} = context do
    {:ok, _} = Edict.assign_role(user, String.to_existing_atom(role), :project, id)
    context
  end

  step ~r/^(\w+)'s "([^"]+)" role on project "([^"]+)" is revoked$/,
       %{args: [user, role, id]} = context do
    {:ok, _} = Edict.revoke_role(user, String.to_existing_atom(role), :project, id)
    context
  end

  # "missing role revoked" is shared with role_writes.feature; defined once in
  # role_write_steps.exs (it stores the result, which the cache scenario ignores).

  step ~r/^(\w+)'s roles change in the database without a version bump$/,
       %{args: [user]} = context do
    context.repo.delete_all(from ur in UserRole, where: ur.user_id == ^user)
    context
  end

  step "the version bump for {word} arrives late", %{args: [user]} = context do
    {:ok, _} = Store.bump_version(context.cache, user)
    context
  end

  step "{word} can {string} on project {string}", %{args: [user, action, id]} = context do
    assert Checks.authorized?(context, user, action, id)
    context
  end

  step "{word} cannot {string} on project {string}", %{args: [user, action, id]} = context do
    refute Checks.authorized?(context, user, action, id)
    context
  end

  step ~r/^(\w+) can still "([^"]+)" on project "([^"]+)" from the stale cache$/,
       %{args: [user, action, id]} = context do
    assert Checks.authorized?(context, user, action, id)
    context
  end

  step ~r/^(\w+)'s cached version is unchanged$/, %{args: [user]} = context do
    assert version(context, user) == context.cached_version
    context
  end

  step "the cache is down and {word} checks {string} on project {string}",
       %{args: [user, action, id]} = context do
    down_config = %{
      context.project_config
      | cache: :"down_cache_#{System.unique_integer([:positive])}"
    }

    allowed =
      ExUnit.CaptureLog.capture_log(fn ->
        send(
          self(),
          {:down_check,
           Checks.authorized?(%{context | project_config: down_config}, user, action, id)}
        )
      end)

    assert allowed =~ "Edict cache unavailable"

    receive do
      {:down_check, result} -> Map.put(context, :down_result, result)
    after
      0 -> flunk("down-cache check produced no result")
    end
  end

  step "the check reads the database and allows it", context do
    assert context.down_result
    context
  end

  defp version(context, user) do
    {:ok, version} = Store.get_version(context.cache, user)
    version
  end
end
