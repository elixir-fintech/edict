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
  @spec assign_role(map(), String.t(), atom(), atom(), String.t()) ::
          {:ok, UserRole.t() | :already_assigned} | {:error, atom()}
  def assign_role(config, user_id, role, entity_type, entity_id) do
    with :ok <- validate_role(config, role),
         :ok <- validate_entity_type(config, entity_type) do
      attrs = %{
        user_id: user_id,
        entity_type: to_string(entity_type),
        entity_id: entity_id,
        role: to_string(role)
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
  end

  @doc "Revokes a specific role from a user on an entity."
  @spec revoke_role(map(), String.t(), atom(), atom(), String.t()) ::
          {:ok, :revoked | :not_found}
  def revoke_role(config, user_id, role, entity_type, entity_id) do
    query =
      from ur in UserRole,
        where:
          ur.user_id == ^user_id and
            ur.entity_type == ^to_string(entity_type) and
            ur.entity_id == ^entity_id and
            ur.role == ^to_string(role)

    case config.repo.delete_all(query) do
      {0, _} ->
        {:ok, :not_found}

      {_count, _} ->
        invalidate_cache(config, user_id)
        {:ok, :revoked}
    end
  end

  @doc "Revokes all roles for a user on a specific entity."
  @spec revoke_all_roles(map(), String.t(), atom(), String.t()) :: {:ok, non_neg_integer()}
  def revoke_all_roles(config, user_id, entity_type, entity_id) do
    query =
      from ur in UserRole,
        where:
          ur.user_id == ^user_id and
            ur.entity_type == ^to_string(entity_type) and
            ur.entity_id == ^entity_id

    {count, _} = config.repo.delete_all(query)

    if count > 0, do: invalidate_cache(config, user_id)

    {:ok, count}
  end

  @doc "Revokes all roles on an entity for all users. Use for cleanup when an entity is deleted."
  @spec revoke_entity(map(), atom(), String.t()) :: {:ok, non_neg_integer()}
  def revoke_entity(config, entity_type, entity_id) do
    entity_type_str = to_string(entity_type)

    {:ok, {count, affected_user_ids}} =
      config.repo.transaction(fn ->
        affected_user_ids =
          config.repo.all(
            from ur in UserRole,
              where: ur.entity_type == ^entity_type_str and ur.entity_id == ^entity_id,
              distinct: true,
              select: ur.user_id
          )

        {count, _} =
          config.repo.delete_all(
            from ur in UserRole,
              where: ur.entity_type == ^entity_type_str and ur.entity_id == ^entity_id
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

  @doc "Assigns a role to a user across multiple entities."
  @spec assign_roles(map(), String.t(), atom(), [{atom(), String.t()}]) ::
          {:ok, [UserRole.t()]} | {:error, atom()}
  def assign_roles(config, user_id, role, entities) do
    with :ok <- validate_role(config, role) do
      invalid =
        Enum.find(entities, fn {entity_type, _} ->
          not config.config_module.valid_entity_type?(entity_type)
        end)

      if invalid do
        {:error, :invalid_entity_type}
      else
        role_str = to_string(role)
        now = DateTime.utc_now()

        entries =
          Enum.map(entities, fn {entity_type, entity_id} ->
            %{
              id: Ecto.UUID.generate(),
              user_id: user_id,
              entity_type: to_string(entity_type),
              entity_id: to_string(entity_id),
              role: role_str,
              inserted_at: now
            }
          end)

        config.repo.insert_all(UserRole, entries,
          on_conflict: :nothing,
          conflict_target: [:user_id, :entity_type, :entity_id, :role]
        )

        invalidate_cache(config, user_id)
        {:ok, entries}
      end
    end
  end

  defp validate_role(config, role) do
    if config.config_module.valid_role?(role), do: :ok, else: {:error, :invalid_role}
  end

  defp validate_entity_type(config, entity_type) do
    if config.config_module.valid_entity_type?(entity_type),
      do: :ok,
      else: {:error, :invalid_entity_type}
  end

  defp invalidate_cache(config, user_id) do
    {:ok, new_version} = Store.bump_version(config.cache, user_id)
    Store.delete_document(config.cache, user_id)

    Phoenix.PubSub.broadcast(
      config.pubsub,
      config.topic,
      {:edict_version_bump, user_id, new_version}
    )
  end
end
