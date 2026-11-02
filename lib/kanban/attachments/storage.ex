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

  The facade holds every adapter to that contract. An adapter call that
  raises, exits or throws (the S3 adapter's HTTP pool raises when no
  connection frees up in time, for example), or that returns anything else,
  is logged with the operation and a reason code only, never the message,
  which can hold a URL, and becomes `{:error, :storage_unavailable}`. So a
  caller can rely on the documented results alone, and a storage outage
  reaches it as a refusal rather than a crash.
  """

  alias Kanban.Attachments.Storage.Local

  require Logger

  @typedoc "A validated storage key such as `boards/12/0b9c...`."
  @type key :: String.t()

  @typedoc "The bytes to store: a file on disk or data already in memory."
  @type source :: {:file, Path.t()} | {:binary, iodata()}

  @type reason :: :invalid_key | :not_found | :storage_unavailable

  @doc "Stores `source` under `key`, replacing any object already there."
  @callback put(key(), source(), keyword()) :: :ok | {:error, reason()}

  @doc """
  Returns the bytes stored under `key` as an enumerable of binaries.

  A missing or unreadable object must be an error here, before the
  enumerable is returned: callers send a 200 as soon as they hold it.
  """
  @callback stream(key()) :: {:ok, Enumerable.t()} | {:error, reason()}

  @doc "Removes the object stored under `key`. A missing object is not an error."
  @callback delete(key()) :: :ok | {:error, reason()}

  @doc "Reports whether an object is stored under `key`."
  @callback exists(key()) :: {:ok, boolean()} | {:error, reason()}

  @doc """
  Removes leftovers of writes that never finished, such as a temp file a
  killed process left behind, once they are older than `older_than_seconds`.
  Optional: an adapter that leaves nothing behind need not implement it.
  Returns `{:error, :storage_unavailable}` when it could not sweep or could
  not remove a leftover; the facade logs nothing more and the next call
  tries again.
  """
  @callback sweep(older_than_seconds :: pos_integer()) :: :ok | {:error, :storage_unavailable}

  @optional_callbacks sweep: 1

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
    do: with_valid_key(key, :put, fn -> adapter().put(key, source, opts) end)

  def put(key, {:binary, data} = source, opts)
      when (is_binary(data) or is_list(data)) and is_list(opts),
      do: with_valid_key(key, :put, fn -> adapter().put(key, source, opts) end)

  @doc "Returns `{:ok, enumerable}` of the bytes stored under `key`."
  @spec stream(term()) :: {:ok, Enumerable.t()} | {:error, reason()}
  def stream(key), do: with_valid_key(key, :stream, fn -> adapter().stream(key) end)

  @doc "Removes the object under `key`; `:ok` when it is already gone."
  @spec delete(term()) :: :ok | {:error, reason()}
  def delete(key), do: with_valid_key(key, :delete, fn -> adapter().delete(key) end)

  @doc "Returns `{:ok, true}` when an object is stored under `key`."
  @spec exists(term()) :: {:ok, boolean()} | {:error, reason()}
  def exists(key), do: with_valid_key(key, :exists, fn -> adapter().exists(key) end)

  @doc """
  Asks the adapter to remove leftovers of unfinished writes older than
  `older_than_seconds` (see the optional `c:sweep/1` callback). Always `:ok`:
  an adapter without the callback has nothing to sweep, and a failure is
  logged and retried on the next call.
  """
  @spec sweep(pos_integer()) :: :ok
  def sweep(older_than_seconds) when is_integer(older_than_seconds) and older_than_seconds > 0 do
    adapter = adapter()

    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :sweep, 1) do
      _ = contain(:sweep, fn -> adapter.sweep(older_than_seconds) end)
    end

    :ok
  end

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

  defp with_valid_key(key, operation, fun) do
    if valid_key?(key), do: contain(operation, fun), else: {:error, :invalid_key}
  end

  # Runs one adapter call and holds its result to the contract above.
  defp contain(operation, fun) do
    operation |> conform(fun.()) |> report(operation)
  rescue
    _exception -> report({:violation, :exception}, operation)
  catch
    :exit, _reason -> report({:violation, :exit}, operation)
    :throw, _value -> report({:violation, :throw}, operation)
  end

  defp conform(:put, :ok), do: :ok
  defp conform(:delete, :ok), do: :ok
  defp conform(:sweep, :ok), do: :ok
  defp conform(:stream, {:ok, _enumerable} = ok), do: ok
  defp conform(:exists, {:ok, exists} = ok) when is_boolean(exists), do: ok

  defp conform(_operation, {:error, reason} = error)
       when reason in [:invalid_key, :not_found, :storage_unavailable],
       do: error

  defp conform(_operation, {:error, _other}), do: {:violation, :unexpected_reason}
  defp conform(_operation, _other), do: {:violation, :unexpected_result}

  defp report({:violation, code}, operation) do
    Logger.warning("attachment storage #{operation} failed: #{inspect(code)}")
    {:error, :storage_unavailable}
  end

  defp report(result, _operation), do: result
end
