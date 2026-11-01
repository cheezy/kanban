defmodule Kanban.Attachments.Storage do
  @moduledoc """
  Where attachment bytes live: a behaviour plus a facade that dispatches to
  the configured adapter.

  Two adapters ship with Stride:

    * `Kanban.Attachments.Storage.Local` writes under a directory on the
      machine's own disk. It is the default, and suits dev, test and a
      single-machine self-hosted instance.
    * `Kanban.Attachments.Storage.S3` talks to any S3-compatible object store
      (Tigris on Fly, AWS S3, MinIO).

  The adapter is chosen by config, never by the caller:

      config :kanban, Kanban.Attachments.Storage, adapter: Kanban.Attachments.Storage.S3

  `config/runtime.exs` sets it from `ATTACHMENTS_STORAGE`; see
  `docs/attachments.md`.

  Every function here validates the key before any adapter sees it, so an
  adapter can join a key onto a directory or a bucket URL without checking it
  again. A valid key is made of lowercase letters, digits, `_` and `-`
  separated by single slashes, at most 512 characters, with no leading or
  trailing slash and no empty segment. Dots are not allowed, so `..` can never
  climb out of the storage root.

  This module knows nothing about tasks, boards or the database. Key layout
  is decided by its caller, `Kanban.Attachments`.

  Results:

    * `put/3` returns `:ok`.
    * `stream/1` returns `{:ok, enumerable}` of binaries. Enumerate it once,
      in the process that called `stream/1`: the S3 adapter's stream is
      single-pass and its bytes arrive as messages to that process.
    * `delete/1` returns `:ok`, also when the object is already gone.
    * `exists/1` returns `{:ok, boolean}`.
    * Any failure is `{:error, reason}`, with `reason` one of `:invalid_key`,
      `:not_found` or `:storage_unavailable`.
  """

  alias Kanban.Attachments.Storage.Local

  @typedoc "A validated storage key such as `boards/12/0b9c...`."
  @type key :: String.t()

  @typedoc "The bytes to store: a file on disk or data already in memory."
  @type source :: {:file, Path.t()} | {:binary, iodata()}

  @type reason :: :invalid_key | :not_found | :storage_unavailable

  @doc "Stores `source` under `key`, replacing any object already there."
  @callback put(key(), source(), keyword()) :: :ok | {:error, reason()}

  @doc "Returns the bytes stored under `key` as an enumerable of binaries."
  @callback stream(key()) :: {:ok, Enumerable.t()} | {:error, reason()}

  @doc "Removes the object stored under `key`. A missing object is not an error."
  @callback delete(key()) :: :ok | {:error, reason()}

  @doc "Reports whether an object is stored under `key`."
  @callback exists(key()) :: {:ok, boolean()} | {:error, reason()}

  @max_key_length 512
  @key_format ~r/\A[a-z0-9_-]+(?:\/[a-z0-9_-]+)*\z/

  @doc "The longest key accepted, in characters."
  @spec max_key_length() :: pos_integer()
  def max_key_length, do: @max_key_length

  @doc """
  Stores `source` under `key`. `opts` may carry `content_type:`, which an
  adapter that records one (S3) sends with the object. A source that is not
  a `{:file, path}` or `{:binary, iodata}` tuple is a programming error and
  raises `FunctionClauseError`.
  """
  @spec put(term(), source(), keyword()) :: :ok | {:error, reason()}
  def put(key, source, opts \\ [])

  def put(key, {:file, path} = source, opts) when is_binary(path) and is_list(opts),
    do: with_valid_key(key, fn -> adapter().put(key, source, opts) end)

  def put(key, {:binary, data} = source, opts)
      when (is_binary(data) or is_list(data)) and is_list(opts),
      do: with_valid_key(key, fn -> adapter().put(key, source, opts) end)

  @doc "Returns `{:ok, enumerable}` of the bytes stored under `key`."
  @spec stream(term()) :: {:ok, Enumerable.t()} | {:error, reason()}
  def stream(key), do: with_valid_key(key, fn -> adapter().stream(key) end)

  @doc "Removes the object under `key`; `:ok` when it is already gone."
  @spec delete(term()) :: :ok | {:error, reason()}
  def delete(key), do: with_valid_key(key, fn -> adapter().delete(key) end)

  @doc "Returns `{:ok, true}` when an object is stored under `key`."
  @spec exists(term()) :: {:ok, boolean()} | {:error, reason()}
  def exists(key), do: with_valid_key(key, fn -> adapter().exists(key) end)

  @doc """
  True when `key` is a valid storage key: lowercase letters, digits, `_` and
  `-` in segments separated by single slashes, no leading or trailing slash,
  and at most `max_key_length/0` characters.
  """
  @spec valid_key?(term()) :: boolean()
  def valid_key?(key) when is_binary(key) and byte_size(key) in 1..@max_key_length,
    do: Regex.match?(@key_format, key)

  def valid_key?(_key), do: false

  @doc """
  The configured adapter module: `config :kanban, Kanban.Attachments.Storage,
  adapter:`, or `Kanban.Attachments.Storage.Local` when unset.
  """
  @spec adapter() :: module()
  def adapter do
    :kanban
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:adapter, Local)
  end

  defp with_valid_key(key, fun) do
    if valid_key?(key), do: fun.(), else: {:error, :invalid_key}
  end
end
