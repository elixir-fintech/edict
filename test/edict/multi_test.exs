defmodule Edict.MultiTest do
  use ExUnit.Case

  alias Ecto.Multi
  alias Edict.Cache.Store
  alias Edict.Schema.UserRole
  alias Edict.Test.{Project, Repo}

  setup do
    cache_name = :"multi_cache_#{:erlang.unique_integer([:positive])}"
    pubsub_name = :"multi_pubsub_#{:erlang.unique_integer([:positive])}"

    {:ok, _} = Cachex.start_link(cache_name)
    start_supervised!({Phoenix.PubSub, name: pubsub_name})
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    Application.put_env(:edict, :repo, Repo)
    Application.put_env(:edict, :config_module, Edict.Test.Config)
    Application.put_env(:edict, :cache, cache_name)
    Application.put_env(:edict, :pubsub, pubsub_name)

    on_exit(fn ->
      Application.delete_env(:edict, :repo)
      Application.delete_env(:edict, :config_module)
      Application.delete_env(:edict, :cache)
      Application.delete_env(:edict, :pubsub)
    end)

    %{cache: cache_name, pubsub: pubsub_name, project: %Project{id: "7", name: "Apollo"}}
  end

  describe "writing roles" do
    test "assign_role step with a tuple stores the role", %{project: project} do
      {:ok, %{role: %UserRole{}}} =
        Multi.new()
        |> Edict.Multi.assign_role(:role, {"user-1", :admin, project})
        |> Edict.Multi.transaction()

      assert [%UserRole{role: "admin", entity_type: "project", entity_id: "7"}] =
               Edict.list_roles("user-1")
    end

    test "assign_role step with a function uses an earlier change", %{project: project} do
      {:ok, _changes} =
        Multi.new()
        |> Multi.put(:project, project)
        |> Edict.Multi.assign_role(:role, fn %{project: project} ->
          {"user-1", :admin, project}
        end)
        |> Edict.Multi.transaction()

      assert [%UserRole{role: "admin", entity_id: "7"}] = Edict.list_roles("user-1")
    end

    test "revoke_role step removes the role", %{project: project} do
      {:ok, _} = Edict.assign_role("user-1", :admin, :project, "7")

      {:ok, %{revoke: :revoked}} =
        Multi.new()
        |> Edict.Multi.revoke_role(:revoke, {"user-1", :admin, project})
        |> Edict.Multi.transaction()

      assert [] == Edict.list_roles("user-1")
    end

    test "invalid role fails the step and stores nothing", %{project: project} do
      result =
        Multi.new()
        |> Edict.Multi.assign_role(:role, {"user-1", :superuser, project})
        |> Edict.Multi.transaction()

      assert {:error, :role, :invalid_role, %{}} == result
      assert [] == Edict.list_roles("user-1")
    end
  end

  describe "invalidation after commit" do
    test "version is not bumped before the commit", %{cache: cache, project: project} do
      {:ok, %{version_during: version_during}} =
        Multi.new()
        |> Edict.Multi.assign_role(:role, {"user-1", :admin, project})
        |> Multi.run(:version_during, fn _repo, _changes ->
          Store.get_version(cache, "user-1")
        end)
        |> Edict.Multi.transaction()

      assert 0 == version_during
    end

    test "version changes once the transaction returns", %{cache: cache, project: project} do
      {:ok, _} =
        Multi.new()
        |> Edict.Multi.assign_role(:role, {"user-1", :admin, project})
        |> Edict.Multi.transaction()

      {:ok, version} = Store.get_version(cache, "user-1")
      assert version != 0
    end

    test "bump is broadcast on the per-user topic", %{pubsub: pubsub, project: project} do
      Phoenix.PubSub.subscribe(pubsub, "edict:user:user-1")

      {:ok, _} =
        Multi.new()
        |> Edict.Multi.assign_role(:role, {"user-1", :admin, project})
        |> Edict.Multi.transaction()

      assert_receive {:edict_version_bump, "user-1", _version}
    end

    test "document cached before the transaction includes the new role", %{project: project} do
      Edict.load_document("user-1")

      {:ok, _} =
        Multi.new()
        |> Edict.Multi.assign_role(:role, {"user-1", :admin, project})
        |> Edict.Multi.transaction()

      assert Edict.can?(Edict.load_document("user-1"), :read, project)
    end

    test "two steps for the same user broadcast once", %{pubsub: pubsub, project: project} do
      Phoenix.PubSub.subscribe(pubsub, "edict:user:user-1")

      {:ok, _} =
        Multi.new()
        |> Edict.Multi.assign_role(:admin, {"user-1", :admin, project})
        |> Edict.Multi.assign_role(:editor, {"user-1", :editor, project})
        |> Edict.Multi.transaction()

      assert_receive {:edict_version_bump, "user-1", _version}
      refute_receive {:edict_version_bump, "user-1", _version}
    end

    test "steps for two users bump both versions", %{cache: cache, project: project} do
      {:ok, _} =
        Multi.new()
        |> Edict.Multi.assign_role(:first, {"user-1", :admin, project})
        |> Edict.Multi.assign_role(:second, {"user-2", :viewer, project})
        |> Edict.Multi.transaction()

      {:ok, user_1_version} = Store.get_version(cache, "user-1")
      {:ok, user_2_version} = Store.get_version(cache, "user-2")
      assert user_1_version != 0
      assert user_2_version != 0
    end
  end

  describe "nothing changed, nothing invalidated" do
    test "already assigned role leaves the version unchanged", %{cache: cache, project: project} do
      {:ok, _} = Edict.assign_role("user-1", :admin, :project, "7")
      {:ok, version_before} = Store.get_version(cache, "user-1")

      {:ok, %{role: :already_assigned}} =
        Multi.new()
        |> Edict.Multi.assign_role(:role, {"user-1", :admin, project})
        |> Edict.Multi.transaction()

      assert {:ok, version_before} == Store.get_version(cache, "user-1")
    end

    test "revoking a missing role leaves the version unchanged", %{cache: cache, project: project} do
      {:ok, %{revoke: :not_found}} =
        Multi.new()
        |> Edict.Multi.revoke_role(:revoke, {"user-1", :admin, project})
        |> Edict.Multi.transaction()

      assert {:ok, 0} == Store.get_version(cache, "user-1")
    end

    test "failing later step rolls back and invalidates nothing",
         %{cache: cache, pubsub: pubsub, project: project} do
      Phoenix.PubSub.subscribe(pubsub, "edict:user:user-1")

      result =
        Multi.new()
        |> Edict.Multi.assign_role(:role, {"user-1", :admin, project})
        |> Multi.run(:fail, fn _repo, _changes -> {:error, :boom} end)
        |> Edict.Multi.transaction()

      assert {:error, :fail, :boom, _changes} = result
      assert [] == Edict.list_roles("user-1")
      assert {:ok, 0} == Store.get_version(cache, "user-1")
      refute_receive {:edict_version_bump, "user-1", _version}
    end
  end

  describe "enforcement and return shape" do
    test "changes contain only caller step names", %{project: project} do
      {:ok, changes} =
        Multi.new()
        |> Edict.Multi.assign_role(:role, {"user-1", :admin, project})
        |> Edict.Multi.transaction()

      assert [:role] == Map.keys(changes)
    end

    test "Edict step run by a plain Repo.transaction fails and stores nothing",
         %{project: project} do
      result =
        Multi.new()
        |> Edict.Multi.assign_role(:role, {"user-1", :admin, project})
        |> Repo.transaction()

      assert {:error, :role, :not_run_by_edict, _changes} = result
      assert [] == Edict.list_roles("user-1")
    end

    test "transaction inside Repo.transaction raises ArgumentError", %{project: project} do
      multi = Edict.Multi.assign_role(Multi.new(), :role, {"user-1", :admin, project})

      assert_raise ArgumentError, fn ->
        Repo.transaction(fn -> Edict.Multi.transaction(multi) end)
      end
    end
  end
end
