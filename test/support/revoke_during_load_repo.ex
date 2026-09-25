defmodule Edict.Test.RevokeDuringLoadRepo do
  # Simulates a revocation landing while a LiveView mounts: every read first
  # broadcasts a version bump for user-1 on :edict_revoke_pubsub, as
  # Core.invalidate/2 would from another process.

  alias Edict.Test.Repo

  def all(queryable, opts \\ []) do
    Phoenix.PubSub.broadcast(
      :edict_revoke_pubsub,
      "edict:user:user-1",
      {:edict_version_bump, "user-1", make_ref()}
    )

    Repo.all(queryable, opts)
  end
end
