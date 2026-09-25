defmodule Edict.Enforcement.AuthorizedTest do
  use ExUnit.Case

  alias Edict.Cache.Document
  alias Edict.Enforcement.Helpers
  alias Edict.Schema.UserRole
  alias Edict.Test.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    config = %{repo: Repo, config_module: Edict.Test.StrongConfig}

    # Grants treasurer on account 7, but the database has no rows: a stale cache.
    stale_doc = %Document{
      user_id: "alice",
      version: make_ref(),
      roles: %{{:account, "7"} => [:treasurer]}
    }

    empty_doc = %Document{user_id: "alice", version: make_ref(), roles: %{}}

    %{config: config, stale_doc: stale_doc, empty_doc: empty_doc}
  end

  defp insert_role!(role, entity_id) do
    Repo.insert!(%UserRole{
      user_id: "alice",
      role: role,
      entity_type: "account",
      entity_id: entity_id
    })
  end

  test "denies a strong action revoked in the DB despite a stale document", %{
    config: config,
    stale_doc: stale_doc
  } do
    refute Helpers.authorized?(config, stale_doc, :approve_transfer, :account, "7", [])
  end

  test "allows a strong action granted in the DB but missing from the document", %{
    config: config,
    empty_doc: empty_doc
  } do
    insert_role!("treasurer", "7")

    assert Helpers.authorized?(config, empty_doc, :approve_transfer, :account, "7", [])
  end

  test "answers a strong action from the document with strong: false", %{
    config: config,
    stale_doc: stale_doc
  } do
    assert Helpers.authorized?(config, stale_doc, :approve_transfer, :account, "7", strong: false)
  end

  test "answers a non-strong action from the document", %{config: config, stale_doc: stale_doc} do
    assert Helpers.authorized?(config, stale_doc, :read, :account, "7", [])
  end

  test "accepts an integer entity ID on a strong action", %{
    config: config,
    empty_doc: empty_doc
  } do
    insert_role!("treasurer", "7")

    assert Helpers.authorized?(config, empty_doc, :approve_transfer, :account, 7, [])
  end

  test "denies a strong action for a role the config no longer defines", %{
    config: config,
    empty_doc: empty_doc
  } do
    insert_role!("ghost", "7")

    refute Helpers.authorized?(config, empty_doc, :approve_transfer, :account, "7", [])
  end

  test "denies a strong action with a missing entity ID", %{config: config, stale_doc: stale_doc} do
    refute Helpers.authorized?(config, stale_doc, :approve_transfer, :account, nil, [])
  end

  test "rejects strong: true", %{config: config, stale_doc: stale_doc} do
    assert_raise ArgumentError, ~r/:strong/, fn ->
      Helpers.authorized?(config, stale_doc, :approve_transfer, :account, "7", strong: true)
    end
  end

  test "rejects a non-boolean strong value", %{config: config, stale_doc: stale_doc} do
    assert_raise ArgumentError, ~r/:strong/, fn ->
      Helpers.authorized?(config, stale_doc, :approve_transfer, :account, "7", strong: :yes)
    end
  end
end
