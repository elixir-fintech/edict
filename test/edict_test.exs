defmodule EdictTest do
  use ExUnit.Case

  setup do
    cache_name = :"edict_cache_#{:erlang.unique_integer([:positive])}"
    pubsub_name = :"edict_pubsub_#{:erlang.unique_integer([:positive])}"

    {:ok, _} = Cachex.start_link(cache_name)
    start_supervised!({Phoenix.PubSub, name: pubsub_name})
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Edict.Test.Repo)

    Application.put_env(:edict, :repo, Edict.Test.Repo)
    Application.put_env(:edict, :config_module, Edict.Test.Config)
    Application.put_env(:edict, :cache, cache_name)
    Application.put_env(:edict, :pubsub, pubsub_name)

    on_exit(fn ->
      Application.delete_env(:edict, :repo)
      Application.delete_env(:edict, :config_module)
      Application.delete_env(:edict, :cache)
      Application.delete_env(:edict, :pubsub)
    end)

    %{cache: cache_name}
  end

  describe "full lifecycle" do
    test "assign, check, revoke flow" do
      assert {:ok, _} = Edict.assign_role("user-1", :admin, :organization, "42")

      doc = Edict.load_document("user-1")
      assert Edict.can?(doc, :read, :organization, "42")
      assert Edict.can?(doc, :billing, :organization, "42")
      refute Edict.can?(doc, :read, :project, "7")

      {:ok, _} = Edict.assign_role("user-1", :editor, :project, "7")
      doc = Edict.load_document("user-1")
      assert Edict.can?(doc, :read, :project, "7")
      assert Edict.can?(doc, :write, :project, "7")
      refute Edict.can?(doc, :delete, :project, "7")

      {:ok, :revoked} = Edict.revoke_role("user-1", :editor, :project, "7")
      doc = Edict.load_document("user-1")
      refute Edict.can?(doc, :read, :project, "7")

      roles = Edict.list_roles("user-1")
      assert length(roles) == 1
    end

    test "protocol-based can? with entity struct" do
      {:ok, _} = Edict.assign_role("user-1", :admin, :organization, "42")
      doc = Edict.load_document("user-1")

      org = %Edict.Test.Organization{id: 42, name: "Acme"}
      assert Edict.can?(doc, :billing, org)
    end

    test "bulk assign roles" do
      entities = [{:organization, "42"}, {:team, "10"}, {:project, "7"}]
      assert {:ok, _} = Edict.assign_roles("user-1", :admin, entities)

      roles = Edict.list_roles("user-1")
      assert length(roles) == 3
    end
  end

  describe "validation" do
    test "returns error for invalid role" do
      assert {:error, :invalid_role} =
               Edict.assign_role("user-1", :superadmin, :organization, "42")
    end

    test "returns error for invalid entity type" do
      assert {:error, :invalid_entity_type} =
               Edict.assign_role("user-1", :admin, :galaxy, "42")
    end

    test "returns error for invalid role in bulk assign" do
      assert {:error, :invalid_role} =
               Edict.assign_roles("user-1", :superadmin, [{:organization, "42"}])
    end

    test "returns error for invalid entity type in bulk assign" do
      assert {:error, :invalid_entity_type} =
               Edict.assign_roles("user-1", :admin, [{:galaxy, "42"}])
    end
  end
end
