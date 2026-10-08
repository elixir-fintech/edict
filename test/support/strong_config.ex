defmodule Edict.Test.StrongConfig do
  # A config with a strong permission on :account, kept apart from
  # Edict.Test.Config so the async, cache-only tests never reach the database.
  # :invoice grants the same permission name from the cache: strength is
  # scoped per entity type.
  use Edict.Config

  strong_permissions do
    on(:account, permissions: [:approve_transfer])
  end

  entity_types do
    entity(:account, struct: Edict.Test.Account)
    entity(:invoice)
  end

  role :treasurer do
    on(:account, permissions: [:read, :approve_transfer])
    on(:invoice, permissions: [:read, :approve_transfer])
  end
end
