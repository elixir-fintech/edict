defmodule Edict.TestHelpers do
  @moduledoc """
  Test helpers for Edict authorization.

  ## Usage

      Edict.TestHelpers.grant_role("user-1", :admin, org)
      Edict.TestHelpers.assert_can("user-1", :read, org)
      Edict.TestHelpers.refute_can("user-1", :billing, org)
  """

  @doc "Assigns a role to a user on an entity. Uses the Edict.Entity protocol."
  @spec grant_role(String.t(), atom(), struct()) :: :ok
  def grant_role(user_id, role, entity) do
    entity_type = Edict.Entity.entity_type(entity)
    entity_id = Edict.Entity.entity_id(entity)

    {:ok, _} = Edict.assign_role(user_id, role, entity_type, entity_id)
    :ok
  end

  @doc "Asserts that a user has the given permission on an entity."
  @spec assert_can(String.t(), atom(), struct()) :: :ok
  def assert_can(user_id, action, entity) do
    doc = Edict.load_document(user_id)

    unless Edict.can?(doc, action, entity) do
      entity_type = Edict.Entity.entity_type(entity)
      entity_id = Edict.Entity.entity_id(entity)

      raise ExUnit.AssertionError,
        message:
          "Expected user #{inspect(user_id)} to have #{inspect(action)} " <>
            "on #{inspect(entity_type)} #{inspect(entity_id)}, but they don't. " <>
            "Roles: #{inspect(Edict.Cache.Document.roles_for(doc, entity_type, entity_id))}"
    end

    :ok
  end

  @doc "Asserts that a user does NOT have the given permission on an entity."
  @spec refute_can(String.t(), atom(), struct()) :: :ok
  def refute_can(user_id, action, entity) do
    doc = Edict.load_document(user_id)

    if Edict.can?(doc, action, entity) do
      entity_type = Edict.Entity.entity_type(entity)
      entity_id = Edict.Entity.entity_id(entity)

      raise ExUnit.AssertionError,
        message:
          "Expected user #{inspect(user_id)} NOT to have #{inspect(action)} " <>
            "on #{inspect(entity_type)} #{inspect(entity_id)}, but they do. " <>
            "Roles: #{inspect(Edict.Cache.Document.roles_for(doc, entity_type, entity_id))}"
    end

    :ok
  end
end
