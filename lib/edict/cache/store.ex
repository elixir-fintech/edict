defmodule Edict.Cache.Store do
  @moduledoc """
  Cachex wrapper for storing authorization documents and version numbers.

  Documents are stored under `{:auth_doc, user_id}`.
  Versions are stored under `{:auth_version, user_id}`.

  TTL is configurable via application config:

      config :edict, ttl: :timer.minutes(15)

  Default: 10 minutes.
  """

  @default_ttl :timer.minutes(10)

  defp ttl, do: Application.get_env(:edict, :ttl, @default_ttl)

  @doc "Stores an authorization document in the cache."
  @spec put_document(atom(), String.t(), Edict.Cache.Document.t()) :: :ok
  def put_document(cache, user_id, document) do
    Cachex.put(cache, {:auth_doc, user_id}, document, ttl: ttl())
    :ok
  end

  @doc "Retrieves an authorization document from the cache."
  @spec get_document(atom(), String.t()) :: {:ok, Edict.Cache.Document.t()} | :miss
  def get_document(cache, user_id) do
    case Cachex.get(cache, {:auth_doc, user_id}) do
      {:ok, nil} -> :miss
      {:ok, doc} -> {:ok, doc}
    end
  end

  @doc "Deletes only the document (not the version) from the cache."
  @spec delete_document(atom(), String.t()) :: :ok
  def delete_document(cache, user_id) do
    Cachex.del(cache, {:auth_doc, user_id})
    :ok
  end

  @doc "Increments and returns the new version number for a user."
  @spec bump_version(atom(), String.t()) :: {:ok, non_neg_integer()}
  def bump_version(cache, user_id) do
    key = {:auth_version, user_id}

    new_version =
      case Cachex.incr(cache, key, 1) do
        {:ok, val} ->
          val

        {:error, :missing} ->
          Cachex.put(cache, key, 1, ttl: ttl())
          1
      end

    {:ok, new_version}
  end

  @doc "Returns the current version number for a user."
  @spec get_version(atom(), String.t()) :: {:ok, non_neg_integer()}
  def get_version(cache, user_id) do
    case Cachex.get(cache, {:auth_version, user_id}) do
      {:ok, nil} -> {:ok, 0}
      {:ok, version} -> {:ok, version}
    end
  end

  @doc "Sets a specific version number for a user."
  @spec set_version(atom(), String.t(), non_neg_integer()) :: :ok
  def set_version(cache, user_id, version) do
    Cachex.put(cache, {:auth_version, user_id}, version, ttl: ttl())
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
