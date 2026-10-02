defmodule Edict.Multi do
  @moduledoc """
  Atomic role changes as `Ecto.Multi` steps.

  Use this when a role change must commit together with other writes, such as
  creating an organization and making its creator an admin:

      Ecto.Multi.new()
      |> Ecto.Multi.insert(:org, Organization.changeset(%Organization{}, attrs))
      |> Edict.Multi.assign_role(:creator_role, fn %{org: org} -> {user.id, :admin, org} end)
      |> Edict.Multi.transaction()

  Steps write roles without touching the cache. `transaction/1` runs the Multi
  and invalidates each affected user only after the commit, so no other process
  can cache roles from before the commit under the new version.

  Edict steps only run through `transaction/1`: under a plain `Repo.transaction/1`
  they fail with `:not_run_by_edict` and the transaction rolls back. Plain role
  writes such as `Edict.assign_role/4` raise inside a transaction.

  A step fails, rolling the transaction back, with `:invalid_role` or
  `:invalid_entity_type` for a role or entity type the config does not define,
  with an `Ecto.Changeset` for an invalid assignment, or with `:not_run_by_edict`.
  An entity struct without an `Edict.Entity` implementation, or a `change` of
  another shape, raises instead, which also rolls the transaction back.
  """

  alias Ecto.Multi
  alias Edict.Core
  alias Edict.Invalidator

  @marker {__MODULE__, :run_by_edict}

  @typedoc "A user, role and entity struct (resolved via `Edict.Entity`)."
  @type role_change :: {Edict.id(), atom(), struct()}

  @doc """
  Adds a step assigning a role. Its result is `%Edict.Schema.UserRole{}` or
  `:already_assigned`.

  `change` is a `{user_id, role, entity}` tuple, or a function receiving the
  changes so far and returning one.
  """
  @spec assign_role(Multi.t(), Multi.name(), role_change() | (map() -> role_change())) ::
          Multi.t()
  def assign_role(multi, name, change), do: add_step(multi, name, change, &Core.insert_role/5)

  @doc """
  Adds a step revoking a role. Its result is `:revoked` or `:not_found`.

  `change` is a `{user_id, role, entity}` tuple, or a function receiving the
  changes so far and returning one.
  """
  @spec revoke_role(Multi.t(), Multi.name(), role_change() | (map() -> role_change())) ::
          Multi.t()
  def revoke_role(multi, name, change), do: add_step(multi, name, change, &Core.delete_role/5)

  @doc """
  Runs the Multi in a transaction, then invalidates every user whose roles
  changed. Returns the same shape as `c:Ecto.Repo.transaction/2`.

  Raises `ArgumentError` inside another transaction, since that one would
  commit only after the invalidation.
  """
  @spec transaction(Multi.t()) ::
          {:ok, map()} | {:error, Multi.name(), term(), map()}
  def transaction(multi) do
    config = Edict.config()

    if config.repo.in_transaction?() do
      raise ArgumentError,
            "Edict.Multi.transaction/1 cannot run inside another transaction, " <>
              "which would commit only after the cache is invalidated."
    end

    multi
    |> Multi.prepend(Multi.put(Multi.new(), @marker, true))
    |> config.repo.transaction()
    |> case do
      {:ok, changes} ->
        changes |> changed_user_ids() |> Enum.each(&Invalidator.invalidate(config, &1))
        {:ok, unwrap(changes)}

      {:error, name, value, changes} ->
        {:error, name, value, unwrap(changes)}
    end
  end

  # A step's value is tagged with the user it changed (nil if none) until
  # transaction/1 unwraps it back to the plain result.
  defp add_step(multi, name, change, write) do
    Multi.run(multi, name, fn _repo, changes ->
      config = Edict.config()

      with :ok <- check_run_by_edict(changes),
           {user_id, role, entity} = resolve(change, changes),
           entity_type = Edict.Entity.entity_type(entity),
           :ok <- Edict.validate(config, role, entity_type),
           user_id = to_string(user_id),
           {:ok, value} = result <-
             write.(
               config,
               user_id,
               to_string(role),
               to_string(entity_type),
               to_string(Edict.Entity.entity_id(entity))
             ) do
        {:ok, {__MODULE__, changed_user_id(user_id, result), value}}
      end
    end)
  end

  defp check_run_by_edict(changes) do
    if Map.has_key?(changes, @marker), do: :ok, else: {:error, :not_run_by_edict}
  end

  defp resolve(change, changes) when is_function(change, 1), do: change.(changes)
  defp resolve({_user_id, _role, _entity} = change, _changes), do: change

  defp changed_user_id(user_id, result), do: if(Core.changed?(result), do: user_id)

  defp changed_user_ids(changes) do
    for {_name, {__MODULE__, user_id, _value}} <- changes, user_id != nil, uniq: true, do: user_id
  end

  defp unwrap(changes) do
    changes
    |> Map.delete(@marker)
    |> Map.new(fn
      {name, {__MODULE__, _user_id, value}} -> {name, value}
      change -> change
    end)
  end
end
