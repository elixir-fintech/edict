defmodule Edict.Invalidator do
  @moduledoc """
  Invalidates a user's cached authorization document after a role change.

  Bumps the user's version in the local cache and broadcasts it on the global
  topic (for `Edict.Cache.PubSubListener` on every node) and on the user's own
  topic (for mounted LiveViews).
  """

  require Logger

  alias Edict.Cache.Store

  @doc """
  Invalidates a user's cached document: bumps the version and broadcasts it
  to other nodes and the user's LiveViews.

  Always returns `:ok`: the DB change has already committed, so a failed
  broadcast is reported, not returned. Each failure emits
  `[:edict, :invalidation, :broadcast_failed]` and logs an error.
  """
  @spec invalidate(map(), String.t()) :: :ok
  def invalidate(config, user_id) do
    {:ok, new_version} = Store.bump_version(config.cache, user_id)
    message = {:edict_version_bump, user_id, new_version}

    # Global topic for PubSubListener (cross-node cache invalidation) and the
    # per-user topic for LiveView hooks. Both are always attempted; the DB change
    # has already committed, so a failure is reported, not rolled back.
    Enum.each(
      [config.topic, "edict:user:#{user_id}"],
      &broadcast(config.pubsub, &1, user_id, message)
    )
  end

  defp broadcast(pubsub, topic, user_id, message) do
    with {:error, reason} <- Phoenix.PubSub.broadcast(pubsub, topic, message) do
      :telemetry.execute([:edict, :invalidation, :broadcast_failed], %{count: 1}, %{
        user_id: user_id,
        topic: topic,
        reason: reason
      })

      Logger.error(
        "Edict invalidation broadcast failed on #{topic} (#{inspect(reason)}); " <>
          "other nodes may serve user #{user_id}'s old roles until the TTL expires"
      )
    end
  end
end
