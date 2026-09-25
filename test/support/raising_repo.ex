defmodule Edict.Test.RaisingRepo do
  # Fails any query, to prove a code path never reaches the database.
  def all(_queryable, _opts \\ []), do: raise("unexpected database query")
end
