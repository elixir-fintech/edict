defmodule Edict.Cache.Store do
  @moduledoc """
  Cachex wrapper for storing authorization documents and versions.

  Documents are stored under `{:auth_doc, user_id}`.
  Versions are stored under `{:auth_version, user_id}`.

  A version is a unique reference, compared only for equality. Each bump
  sets a fresh one, so a version is never reused: not after its key
  expires, and not across nodes. `0` means no version is set.

  The TTL bounds how long a node that missed a version bump can serve an old
  document. It is configurable via application config:

      config :edict, ttl: :timer.minutes(15)

  Default: 10 minutes.

  Reads return cache errors so callers can fall back to the database. Writes
  always return `:ok`: Cachex only fails a write when the cache process is
  down, and then its table and every document in it are gone, so there is
  nothing stale left to correct.
  """

  @type version :: reference() | 0

  @default_ttl :timer.minutes(10)

  defp ttl, do: Application.get_env(:edict, :ttl, @default_ttl)

  @doc "Stores an authorization document in the cache."
  @spec put_document(atom(), String.t(), Edict.Cache.Document.t()) :: :ok
  def put_document(cache, user_id, document) do
    Cachex.put(cache, {:auth_doc, user_id}, document, expire: ttl())
    :ok
  end

  @doc "Retrieves an authorization document from the cache."
  @spec get_document(atom(), String.t()) ::
          {:ok, Edict.Cache.Document.t()} | :miss | {:error, term()}
  def get_document(cache, user_id) do
    case Cachex.get(cache, {:auth_doc, user_id}) do
      {:ok, nil} -> :miss
      result -> result
    end
  end

  @doc "Sets and returns a new, never reused version for a user."
  @spec bump_version(atom(), String.t()) :: {:ok, version()}
  def bump_version(cache, user_id) do
    version = make_ref()
    :ok = invalidate(cache, user_id, version)
    {:ok, version}
  end

  @doc """
  Sets a new version for a user and drops their cached document.

  Dropping the document means no version, replayed or forged, can make an old
  document current again: the next load rebuilds it from the DB.
  """
  @spec invalidate(atom(), String.t(), version()) :: :ok
  def invalidate(cache, user_id, version) do
    Cachex.del(cache, {:auth_doc, user_id})
    set_version(cache, user_id, version)
  end

  @doc "Returns the current version for a user, `0` if none is set, or the cache error."
  @spec get_version(atom(), String.t()) :: {:ok, version()} | {:error, term()}
  def get_version(cache, user_id) do
    case Cachex.get(cache, {:auth_version, user_id}) do
      {:ok, nil} -> {:ok, 0}
      result -> result
    end
  end

  @doc "Sets a specific version for a user."
  @spec set_version(atom(), String.t(), version()) :: :ok
  def set_version(cache, user_id, version) do
    Cachex.put(cache, {:auth_version, user_id}, version, expire: ttl())
    :ok
  end

  @doc "Deletes both document and version from the cache."
  @spec delete(atom(), String.t()) :: :ok
  def delete(cache, user_id) do
    Cachex.del(cache, {:auth_doc, user_id})
    Cachex.del(cache, {:auth_version, user_id})
    :ok
  end
end
