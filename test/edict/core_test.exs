defmodule Edict.CoreTest do
  use ExUnit.Case

  alias Edict.Core
  alias Edict.Cache.Store
  alias Edict.Schema.UserRole

  setup do
    cache_name = :"edict_cache_#{:erlang.unique_integer([:positive])}"
    pubsub_name = :"edict_pubsub_#{:erlang.unique_integer([:positive])}"

    {:ok, _} = Cachex.start_link(cache_name)
    start_supervised!({Phoenix.PubSub, name: pubsub_name})

    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Edict.Test.Repo)

    config = %{
      repo: Edict.Test.Repo,
      cache: cache_name,
      pubsub: pubsub_name,
      topic: "edict:versions",
      config_module: Edict.Test.Config
    }

    %{config: config, cache: cache_name, pubsub: pubsub_name}
  end

  describe "assign_role/5" do
    test "inserts a role assignment into the database", %{config: config} do
      assert {:ok, _role} = Core.assign_role(config, "user-1", :admin, :organization, "42")

      roles = Edict.Test.Repo.all(UserRole)
      assert length(roles) == 1

      role = hd(roles)
      assert role.user_id == "user-1"
      assert role.entity_type == "organization"
      assert role.entity_id == "42"
      assert role.role == "admin"
    end

    test "is idempotent — assigning the same role twice is a no-op", %{config: config} do
      assert {:ok, _} = Core.assign_role(config, "user-1", :admin, :organization, "42")
      assert {:ok, _} = Core.assign_role(config, "user-1", :admin, :organization, "42")

      roles = Edict.Test.Repo.all(UserRole)
      assert length(roles) == 1
    end

    test "bumps the cache version", %{config: config, cache: cache} do
      Core.assign_role(config, "user-1", :admin, :organization, "42")

      assert {:ok, version} = Store.get_version(cache, "user-1")
      assert version > 0
    end

    test "broadcasts version bump via PubSub", %{config: config, pubsub: pubsub} do
      Phoenix.PubSub.subscribe(pubsub, "edict:versions")

      Core.assign_role(config, "user-1", :admin, :organization, "42")

      assert_receive {:edict_version_bump, "user-1", _version}, 1000
    end

    test "returns error for invalid role", %{config: config} do
      assert {:error, :invalid_role} =
               Core.assign_role(config, "user-1", :superadmin, :organization, "42")
    end

    test "returns error for invalid entity type", %{config: config} do
      assert {:error, :invalid_entity_type} =
               Core.assign_role(config, "user-1", :admin, :galaxy, "42")
    end
  end

  describe "revoke_role/5" do
    test "removes a role assignment from the database", %{config: config} do
      {:ok, _} = Core.assign_role(config, "user-1", :admin, :organization, "42")
      assert {:ok, :revoked} = Core.revoke_role(config, "user-1", :admin, :organization, "42")

      roles = Edict.Test.Repo.all(UserRole)
      assert length(roles) == 0
    end

    test "returns ok even if role doesn't exist", %{config: config} do
      assert {:ok, :not_found} =
               Core.revoke_role(config, "user-1", :admin, :organization, "42")
    end

    test "bumps cache version after revoking", %{config: config, cache: cache} do
      {:ok, _} = Core.assign_role(config, "user-1", :admin, :organization, "42")
      {:ok, v1} = Store.get_version(cache, "user-1")

      Core.revoke_role(config, "user-1", :admin, :organization, "42")
      {:ok, v2} = Store.get_version(cache, "user-1")

      assert v2 > v1
    end
  end
end
