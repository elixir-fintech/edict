defmodule Edict.Features.StepDefinitions.MultiSteps do
  @moduledoc """
  Step definitions for multi_atomicity.feature.
  """

  use Cucumber.StepDefinition
  import Ecto.Query
  import ExUnit.Assertions

  alias Edict.Cache.Store
  alias Edict.Test.Checks
  alias Edict.Schema.UserRole
  alias Edict.Test.Project

  step "a project {string} exists", %{args: [id]} = context do
    Map.put(context, :project, %Project{id: id, name: "Project #{id}"})
  end

  step "{word} is assigned {string} on project {string} inside a Multi transaction",
       %{args: [user, role, _id]} = context do
    result =
      Ecto.Multi.new()
      |> Edict.Multi.assign_role(:role, {user, String.to_existing_atom(role), context.project})
      |> Edict.Multi.transaction()

    assert match?({:ok, _}, result)
    context
  end

  step "a Multi transaction assigning {word} {string} on project {string} is paused before commit",
       %{args: [user, role, _id]} = context do
    {:ok, before} = Store.get_version(context.cache, user)
    parent = self()

    result =
      Ecto.Multi.new()
      |> Edict.Multi.assign_role(:role, {user, String.to_existing_atom(role), context.project})
      |> Ecto.Multi.run(:observe, fn _repo, _changes ->
        {:ok, during} = Store.get_version(context.cache, user)
        send(parent, {:during, during})
        {:ok, :observed}
      end)
      |> Edict.Multi.transaction()

    assert match?({:ok, _}, result)

    during =
      receive do
        {:during, version} -> version
      after
        1_000 -> flunk("observe step never ran")
      end

    Map.put(context, :versions, %{before: before, during: during})
  end

  step "a Multi transaction assigns {word} an unknown role on project {string}",
       %{args: [user, _id]} = context do
    result =
      Ecto.Multi.new()
      |> Edict.Multi.assign_role(:role, {user, :superadmin, context.project})
      |> Edict.Multi.transaction()

    assert match?({:error, :role, :invalid_role, _}, result)
    Map.put(context, :failed, true)
  end

  step "an Edict step runs inside a plain Repo transaction", context do
    multi =
      Ecto.Multi.new()
      |> Edict.Multi.assign_role(:role, {"alice", :admin, context.project})

    assert match?({:error, :role, :not_run_by_edict, _}, context.repo.transaction(multi))
    context
  end

  step "a Multi transaction starts inside another transaction", context do
    multi =
      Ecto.Multi.new()
      |> Edict.Multi.assign_role(:role, {"alice", :admin, context.project})

    outcome =
      try do
        context.repo.transaction(fn -> Edict.Multi.transaction(multi) end)
      rescue
        e in ArgumentError -> {:raised, e}
      end

    Map.put(context, :outcome, outcome)
  end

  step ~r/^(\w+)'s "([^"]+)" on project "([^"]+)" is revoked inside a Multi transaction$/,
       %{args: [user, role, _id]} = context do
    result =
      Ecto.Multi.new()
      |> Edict.Multi.revoke_role(:role, {user, String.to_existing_atom(role), context.project})
      |> Edict.Multi.transaction()

    assert match?({:ok, _}, result)
    context
  end

  step "the transaction commits and {word} can {string} on project {string}",
       %{args: [user, action, id]} = context do
    assert Checks.authorized?(context, user, action, id)
    context
  end

  step "the transaction commits and {word} cannot {string} on project {string}",
       %{args: [user, action, id]} = context do
    refute Checks.authorized?(context, user, action, id)
    context
  end

  step ~r/^(\w+)'s cached version is still the pre-transaction one$/, %{args: [user]} = context do
    assert context.versions.during == context.versions.before
    {:ok, after_commit} = Store.get_version(context.cache, user)
    assert after_commit != context.versions.before
    context
  end

  step "the transaction fails and {word} has no roles and no version bump",
       %{args: [user]} = context do
    assert context.failed
    assert context.repo.all(from ur in UserRole, where: ur.user_id == ^user) == []
    {:ok, version} = Store.get_version(context.cache, user)
    assert version == 0
    context
  end

  step "the transaction rolls back and {word} has no roles", %{args: [user]} = context do
    assert context.repo.all(from ur in UserRole, where: ur.user_id == ^user) == []
    context
  end

  step "it raises ArgumentError", context do
    assert match?({:raised, %ArgumentError{}}, context.outcome)
    context
  end
end
