defmodule Edict.Core do
  @moduledoc """
  Core operations for managing role assignments.

  Writes roles to the DB; every change is followed by `Edict.Invalidator.invalidate/2`.

  All functions take a config map with:
  - `:repo` — the Ecto repo
  - `:cache` — the Cachex instance name
  - `:pubsub` — the Phoenix.PubSub instance name
  - `:topic` — the PubSub topic for version bumps
  - `:config_module` — the module using `Edict.Config`
  """

  import Ecto.Query

  alias Edict.Invalidator
  alias Edict.Schema.UserRole

  @insert_ignoring_duplicates [
    on_conflict: :nothing,
    conflict_target: [:user_id, :entity_type, :entity_id, :role],
    returning: true
  ]

  @doc "Assigns a role to a user on an entity. Idempotent — assigning the same role twice is a no-op."
  @spec assign_role(map(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, UserRole.t() | :already_assigned} | {:error, Ecto.Changeset.t()}
  def assign_role(config, user_id, role, entity_type, entity_id) do
    config
    |> insert_role(user_id, role, entity_type, entity_id)
    |> tap(&invalidate_if_changed(config, user_id, &1))
  end

  @doc """
  Inserts a role assignment without invalidating the cache.

  For use inside a transaction, where invalidation must wait for the commit.
  """
  @spec insert_role(map(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, UserRole.t() | :already_assigned} | {:error, Ecto.Changeset.t()}
  def insert_role(config, user_id, role, entity_type, entity_id) do
    # insert_all reports the rows actually inserted. Repo.insert can't detect
    # the conflict: the binary_id is generated client-side, so the returned
    # struct carries an id even when no row was written.
    with {:ok, entry} <- build_entry(user_id, role, {entity_type, entity_id}, DateTime.utc_now()) do
      case config.repo.insert_all(UserRole, [entry], @insert_ignoring_duplicates) do
        {0, []} -> {:ok, :already_assigned}
        {1, [user_role]} -> {:ok, user_role}
      end
    end
  end

  @doc "Revokes a specific role from a user on an entity."
  @spec revoke_role(map(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, :revoked | :not_found}
  def revoke_role(config, user_id, role, entity_type, entity_id) do
    config
    |> delete_role(user_id, role, entity_type, entity_id)
    |> tap(&invalidate_if_changed(config, user_id, &1))
  end

  @doc """
  Deletes a role assignment without invalidating the cache.

  For use inside a transaction, where invalidation must wait for the commit.
  """
  @spec delete_role(map(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, :revoked | :not_found}
  def delete_role(config, user_id, role, entity_type, entity_id) do
    query =
      from ur in UserRole,
        where:
          ur.user_id == ^user_id and
            ur.entity_type == ^entity_type and
            ur.entity_id == ^entity_id and
            ur.role == ^role

    case config.repo.delete_all(query) do
      {0, _} -> {:ok, :not_found}
      {_count, _} -> {:ok, :revoked}
    end
  end

  @doc "Revokes all roles for a user on a specific entity."
  @spec revoke_all_roles(map(), String.t(), String.t(), String.t()) :: {:ok, non_neg_integer()}
  def revoke_all_roles(config, user_id, entity_type, entity_id) do
    query =
      from ur in UserRole,
        where:
          ur.user_id == ^user_id and
            ur.entity_type == ^entity_type and
            ur.entity_id == ^entity_id

    {count, _} = config.repo.delete_all(query)

    if count > 0, do: Invalidator.invalidate(config, user_id)

    {:ok, count}
  end

  @doc "Revokes all roles on an entity for all users. Use for cleanup when an entity is deleted."
  @spec revoke_entity(map(), String.t(), String.t()) :: {:ok, non_neg_integer()}
  def revoke_entity(config, entity_type, entity_id) do
    # One DELETE ... RETURNING: invalidations come from the rows actually
    # deleted, including any assigned while the revocation was running.
    {count, user_ids} =
      config.repo.delete_all(
        from ur in UserRole,
          where: ur.entity_type == ^entity_type and ur.entity_id == ^entity_id,
          select: ur.user_id
      )

    user_ids
    |> Enum.uniq()
    |> Enum.each(&Invalidator.invalidate(config, &1))

    {:ok, count}
  end

  @doc "Lists all role assignments for a user. Reads from DB, not cache."
  @spec list_roles(map(), String.t()) :: [UserRole.t()]
  def list_roles(config, user_id) do
    from(ur in UserRole, where: ur.user_id == ^user_id)
    |> config.repo.all()
  end

  @doc "Lists a user's role assignments on one entity. Reads from DB, not cache."
  @spec list_entity_roles(map(), String.t(), String.t(), String.t()) :: [UserRole.t()]
  def list_entity_roles(config, user_id, entity_type, entity_id) do
    from(ur in UserRole,
      where:
        ur.user_id == ^user_id and ur.entity_type == ^entity_type and
          ur.entity_id == ^entity_id
    )
    |> config.repo.all()
  end

  @doc """
  Assigns a role to a user across multiple entities.

  Every entry is validated like a single assignment. If any is invalid,
  nothing is inserted and its changeset is returned.
  """
  @spec assign_roles(map(), String.t(), String.t(), [{String.t(), String.t()}]) ::
          {:ok, [UserRole.t()]} | {:error, Ecto.Changeset.t()}
  def assign_roles(config, user_id, role, entities) do
    with {:ok, entries} <- build_entries(user_id, role, entities, DateTime.utc_now()) do
      {count, user_roles} =
        config.repo.insert_all(UserRole, entries, @insert_ignoring_duplicates)

      if count > 0, do: Invalidator.invalidate(config, user_id)
      {:ok, user_roles}
    end
  end

  defp build_entries(user_id, role, entities, now) do
    entities
    |> Enum.reduce_while({:ok, []}, fn entity, {:ok, entries} ->
      case build_entry(user_id, role, entity, now) do
        {:ok, entry} -> {:cont, {:ok, [entry | entries]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end

  # Every write goes through the changeset, so single and bulk inserts
  # share one invariant.
  defp build_entry(user_id, role, {entity_type, entity_id}, now) do
    attrs = %{user_id: user_id, entity_type: entity_type, entity_id: entity_id, role: role}

    with {:ok, _user_role} <-
           %UserRole{} |> UserRole.changeset(attrs) |> Ecto.Changeset.apply_action(:insert) do
      {:ok, Map.merge(attrs, %{id: Ecto.UUID.generate(), inserted_at: now})}
    end
  end

  @doc "Returns whether the result of `insert_role/5` or `delete_role/5` changed a role."
  @spec changed?({:ok, term()} | {:error, term()}) :: boolean()
  def changed?({:ok, result}) when result in [:already_assigned, :not_found], do: false
  def changed?({:ok, _result}), do: true
  def changed?({:error, _reason}), do: false

  defp invalidate_if_changed(config, user_id, result) do
    if changed?(result), do: Invalidator.invalidate(config, user_id)
  end
end
