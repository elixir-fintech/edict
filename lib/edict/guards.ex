defmodule Edict.Guards do
  @moduledoc """
  Shared guards for Edict's compile-time validations.

  `nil` is an atom in Elixir, so a bare `is_atom/1` accepts it as a
  permission, an entity type or an assign key — every validation site needs
  the exclusion, and it belongs in one place.
  """

  @doc "True for an atom that is not `nil`."
  defguard is_atom_present(value) when is_atom(value) and value != nil
end
