defmodule Edict.Test.StrongConfig do
  # A config with a strong action, kept apart from Edict.Test.Config so the
  # async, cache-only tests never reach the database.
  use Edict.Config

  strong_actions([:approve_transfer])

  entity_types do
    entity(:account, struct: Edict.Test.Account)
  end

  role :treasurer do
    on(:account, actions: [:read, :approve_transfer])
  end
end
