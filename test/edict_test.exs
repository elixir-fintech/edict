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

    test "returns error for invalid role on revoke" do
      assert {:error, :invalid_role} =
               Edict.revoke_role("user-1", :superadmin, :organization, "42")
    end

    test "returns error for invalid entity type on revoke" do
      assert {:error, :invalid_entity_type} =
               Edict.revoke_role("user-1", :admin, :galaxy, "42")
    end

    test "returns error for invalid entity type on revoke_all_roles" do
      assert {:error, :invalid_entity_type} =
               Edict.revoke_all_roles("user-1", :galaxy, "42")
    end

    test "returns error for invalid entity type on revoke_entity" do
      assert {:error, :invalid_entity_type} =
               Edict.revoke_entity(:galaxy, "42")
    end
  end

  describe "can?/3 (struct)" do
    test "returns true when user has permission via protocol" do
      {:ok, _} = Edict.assign_role("user-1", :admin, :organization, "42")
      doc = Edict.load_document("user-1")

      org = %Edict.Test.Organization{id: 42, name: "Acme"}
      assert Edict.can?(doc, :billing, org)
    end

    test "returns false when user lacks permission via protocol" do
      {:ok, _} = Edict.assign_role("user-1", :viewer, :organization, "42")
      doc = Edict.load_document("user-1")

      org = %Edict.Test.Organization{id: 42, name: "Acme"}
      refute Edict.can?(doc, :billing, org)
    end
  end

  describe "can?/4 (type + id)" do
    test "returns true when user has permission" do
      {:ok, _} = Edict.assign_role("user-1", :admin, :project, "7")
      doc = Edict.load_document("user-1")

      assert Edict.can?(doc, :manage, :project, "7")
    end

    test "returns false when user lacks permission" do
      {:ok, _} = Edict.assign_role("user-1", :viewer, :project, "7")
      doc = Edict.load_document("user-1")

      refute Edict.can?(doc, :delete, :project, "7")
    end

    test "returns false for entity with no roles" do
      doc = Edict.load_document("user-1")

      refute Edict.can?(doc, :read, :project, "999")
    end
  end

  # Role writes inside a transaction would invalidate the cache before the
  # commit, so they must go through Edict.Multi instead.
  describe "inside a transaction" do
    test "assign_role raises ArgumentError" do
      assert_raise ArgumentError, fn ->
        Edict.Test.Repo.transaction(fn ->
          Edict.assign_role("user-1", :admin, :project, "7")
        end)
      end
    end

    test "assign_roles raises ArgumentError" do
      assert_raise ArgumentError, fn ->
        Edict.Test.Repo.transaction(fn ->
          Edict.assign_roles("user-1", :admin, [{:project, "7"}])
        end)
      end
    end

    test "revoke_role raises ArgumentError" do
      assert_raise ArgumentError, fn ->
        Edict.Test.Repo.transaction(fn ->
          Edict.revoke_role("user-1", :admin, :project, "7")
        end)
      end
    end

    test "revoke_all_roles raises ArgumentError" do
      assert_raise ArgumentError, fn ->
        Edict.Test.Repo.transaction(fn ->
          Edict.revoke_all_roles("user-1", :project, "7")
        end)
      end
    end

    test "revoke_entity raises ArgumentError" do
      assert_raise ArgumentError, fn ->
        Edict.Test.Repo.transaction(fn ->
          Edict.revoke_entity(:project, "7")
        end)
      end
    end
  end

  describe "can? with strong actions" do
    setup do
      Application.put_env(:edict, :config_module, Edict.Test.StrongConfig)
      {:ok, _} = Edict.assign_role("alice", :treasurer, :account, "7")
      doc = Edict.load_document("alice")
      # Revoke without notifying the cache: doc is now stale
      Edict.Test.Repo.delete_all(Edict.Schema.UserRole)

      %{doc: doc, account: %Edict.Test.Account{id: "7"}}
    end

    test "can?/3 checks a strong action against the DB", %{doc: doc, account: account} do
      refute Edict.can?(doc, :approve_transfer, account)
    end

    test "can?/4 with strong: false checks the document", %{doc: doc, account: account} do
      assert Edict.can?(doc, :approve_transfer, account, strong: false)
    end

    test "can?/4 with type and ID checks a strong action against the DB", %{doc: doc} do
      refute Edict.can?(doc, :approve_transfer, :account, "7")
    end

    test "can?/5 with strong: false checks the document", %{doc: doc} do
      assert Edict.can?(doc, :approve_transfer, :account, "7", strong: false)
    end
  end
end
