defmodule Edict.Core do
  @moduledoc """
  Core operations for managing role assignments.

  All functions take a config map with:
  - `:repo` — the Ecto repo
  - `:cache` — the Cachex instance name
  - `:pubsub` — the Phoenix.PubSub instance name
  - `:topic` — the PubSub topic for version bumps
  - `:config_module` — the module using `Edict.Config`
  """

  import Ecto.Query

  alias Edict.Cache.Store
  alias Edict.Schema.UserRole

  @doc "Assigns a role to a user on an entity. Idempotent — assigning the same role twice is a no-op."
  @spec assign_role(map(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, UserRole.t() | :already_assigned} | {:error, Ecto.Changeset.t()}
  def assign_role(config, user_id, role, entity_type, entity_id) do
    attrs = %{
      user_id: user_id,
      entity_type: entity_type,
      entity_id: entity_id,
      role: role
    }

    result =
      config.repo.insert(
        UserRole.changeset(%UserRole{}, attrs),
        on_conflict: :nothing,
        conflict_target: [:user_id, :entity_type, :entity_id, :role],
        returning: true
      )

    case result do
      {:ok, %UserRole{id: nil}} ->
        {:ok, :already_assigned}

      {:ok, user_role} ->
        invalidate_cache(config, user_id)
        {:ok, user_role}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc "Revokes a specific role from a user on an entity."
  @spec revoke_role(map(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, :revoked | :not_found}
  def revoke_role(config, user_id, role, entity_type, entity_id) do
    query =
      from ur in UserRole,
        where:
          ur.user_id == ^user_id and
            ur.entity_type == ^entity_type and
            ur.entity_id == ^entity_id and
            ur.role == ^role

    case config.repo.delete_all(query) do
      {0, _} ->
        {:ok, :not_found}

      {_count, _} ->
        invalidate_cache(config, user_id)
        {:ok, :revoked}
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

    if count > 0, do: invalidate_cache(config, user_id)

    {:ok, count}
  end

  @doc "Revokes all roles on an entity for all users. Use for cleanup when an entity is deleted."
  @spec revoke_entity(map(), String.t(), String.t()) :: {:ok, non_neg_integer()}
  def revoke_entity(config, entity_type, entity_id) do
    {:ok, {count, affected_user_ids}} =
      config.repo.transaction(fn ->
        affected_user_ids =
          config.repo.all(
            from ur in UserRole,
              where: ur.entity_type == ^entity_type and ur.entity_id == ^entity_id,
              distinct: true,
              select: ur.user_id
          )

        {count, _} =
          config.repo.delete_all(
            from ur in UserRole,
              where: ur.entity_type == ^entity_type and ur.entity_id == ^entity_id
          )

        {count, affected_user_ids}
      end)

    Enum.each(affected_user_ids, fn uid ->
      invalidate_cache(config, uid)
    end)

    {:ok, count}
  end

  @doc "Lists all role assignments for a user. Reads from DB, not cache."
  @spec list_roles(map(), String.t()) :: [UserRole.t()]
  def list_roles(config, user_id) do
    from(ur in UserRole, where: ur.user_id == ^user_id)
    |> config.repo.all()
  end

  @doc "Assigns a role to a user across multiple entities. Expects pre-validated, string arguments."
  @spec assign_roles(map(), String.t(), String.t(), [{String.t(), String.t()}]) ::
          {:ok, [UserRole.t()]}
  def assign_roles(config, user_id, role, entities) do
    now = DateTime.utc_now()

    entries =
      Enum.map(entities, fn {entity_type, entity_id} ->
        %{
          id: Ecto.UUID.generate(),
          user_id: user_id,
          entity_type: entity_type,
          entity_id: entity_id,
          role: role,
          inserted_at: now
        }
      end)

    {_count, user_roles} =
      config.repo.insert_all(UserRole, entries,
        on_conflict: :nothing,
        conflict_target: [:user_id, :entity_type, :entity_id, :role],
        returning: true
      )

    invalidate_cache(config, user_id)
    {:ok, user_roles}
  end

  defp invalidate_cache(config, user_id) do
    {:ok, new_version} = Store.bump_version(config.cache, user_id)
    message = {:edict_version_bump, user_id, new_version}

    # Global topic for PubSubListener (cross-node cache invalidation)
    Phoenix.PubSub.broadcast(config.pubsub, config.topic, message)
    # Per-user topic for LiveView hooks (targeted delivery)
    Phoenix.PubSub.broadcast(config.pubsub, "edict:user:#{user_id}", message)
  end
end
