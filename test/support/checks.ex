defmodule Edict.Test.Checks do
  @moduledoc """
  Shared permission-check helper for feature steps.

  A fresh check of `permission` on project `id` for `user`: loads the document
  from the cache (rebuilding when stale) and checks a non-strong permission
  against it, exactly as the Plug and LiveView enforcement do.
  """

  alias Edict.Enforcement.Helpers

  @doc """
  Returns whether `user` may perform `permission` (given as a string) on
  project `id`, using the scenario's `:project_config`.
  """
  @spec authorized?(map(), String.t(), String.t(), String.t()) :: boolean()
  def authorized?(context, user, permission, id) do
    Helpers.authorized?(
      context.project_config,
      Helpers.load_document(context.project_config, user),
      String.to_existing_atom(permission),
      :project,
      id,
      []
    )
  end
end
