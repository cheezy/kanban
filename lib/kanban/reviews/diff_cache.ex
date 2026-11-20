defmodule Kanban.Reviews.DiffCache do
  @moduledoc """
  An ETS cache of highlighted review diffs, for
  `Kanban.Reviews.DiffHighlighter` (docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md
  §7.6).

  An entry is keyed by task id, file index and a SHA-256 hash of the diff
  text (`key/3`), so a resubmitted diff misses and is highlighted afresh. An
  entry lives one hour. Expired entries are never returned, and this process
  deletes them on a timer.

  This process only owns the table. Callers read and write it directly, so a
  slow highlight never queues behind another. The table is named after this
  module by default, so one shared cache runs per VM; `Kanban.Application`
  starts it.

  Two callers that miss on the same key at once both compute. Highlighting is
  deterministic, so both get equal results, and only the first insert is
  kept: "compute once or return equal results".

  ## Limits

  The table holds at most 1,000 entries and at most 64 MB. Each value is
  stored as its external term format (`:erlang.term_to_binary/1`), one binary
  of known size, and a counter row keeps the running total of those sizes, so
  the byte figure is the stored bytes themselves plus the table's own memory
  (`:ets.info/2`). ETS memory alone leaves out binaries over 64 bytes, which
  live off-heap, and a value's span texts could otherwise keep a larger
  parent binary alive; a stored blob refers to nothing else, so what is
  counted is what is held. A hit decodes the blob again.

  When an entry would pass either limit it is computed and returned but not
  stored, until a sweep frees room. Two concurrent stores may each see room,
  so the limits can be overshot by at most one entry per concurrent caller.
  If the table is not running at all, every call computes and nothing is
  stored.

  ## Options

    * `:interval` - milliseconds between sweeps. Defaults to 10 minutes.
    * `:name` - the name to register under.
    * `:table` - the ETS table's name. Defaults to this module; a test runs a
      private cache under another name and passes the same `:table` to
      `fetch_or_compute/3`, `sweep/1` and `used_bytes/1`.
    * `:max_entries` and `:max_bytes` - the limits, 1,000 and 64 MB by
      default.
  """

  use GenServer

  @table __MODULE__
  # The running total of the encoded sizes of the stored values, and the
  # table's limits: {@bytes_key, bytes, {max_entries, max_bytes}}.
  @bytes_key :__stored_bytes__
  @ttl :timer.hours(1)
  @default_interval :timer.minutes(10)
  @max_entries 1_000
  @max_bytes 64 * 1024 * 1024

  @typedoc "A cache key: task id, file index and the diff's SHA-256 hash."
  @type key :: {term(), non_neg_integer(), binary(), String.t() | nil}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    opts =
      Keyword.validate!(opts, [
        :name,
        interval: @default_interval,
        table: @table,
        max_entries: @max_entries,
        max_bytes: @max_bytes
      ])

    GenServer.start_link(
      __MODULE__,
      Keyword.take(opts, [:interval, :table, :max_entries, :max_bytes]),
      Keyword.take(opts, [:name])
    )
  end

  @doc """
  The cache key for one file's diff in one task. `path` is part of it, so a
  file renamed with the same diff text at the same index, which may need
  another lexer, is never served the old path's lines.
  """
  @spec key(term(), non_neg_integer(), String.t(), String.t() | nil) :: key()
  def key(task_id, file_index, diff, path \\ nil) when is_binary(diff) do
    {task_id, file_index, :crypto.hash(:sha256, diff), path}
  end

  @doc """
  Returns the cached value for `key`, or calls `fun`, stores its result and
  returns it.

    * `:ttl` - the entry's lifetime in milliseconds. Defaults to one hour.
    * `:table` - the cache's table; this module's by default.
  """
  @spec fetch_or_compute(key(), (-> value), keyword()) :: value when value: term()
  def fetch_or_compute(key, fun, opts \\ []) when is_function(fun, 0) do
    table = Keyword.get(opts, :table, @table)
    now = now()

    case lookup(table, key, now) do
      {:ok, value} ->
        value

      :miss ->
        value = fun.()
        store(table, key, value, now + Keyword.get(opts, :ttl, @ttl))
        value
    end
  end

  @doc """
  The bytes the stored entries hold, as the byte limit counts them: the
  table's own memory plus every stored value's encoded size. `0` when the
  table is not running.
  """
  @spec used_bytes(atom()) :: non_neg_integer()
  def used_bytes(table \\ @table) do
    case :ets.info(table, :memory) do
      :undefined -> 0
      _words -> used_bytes!(table)
    end
  rescue
    ArgumentError -> 0
  end

  @doc "Deletes every expired entry and returns how many it deleted."
  @spec sweep(atom()) :: non_neg_integer()
  def sweep(table \\ @table) do
    table
    |> :ets.select([{{:"$1", :_, :"$2", :_}, [{:"=<", :"$2", now()}], [:"$1"]}])
    |> Enum.map(&evict(table, &1))
    |> Enum.sum()
  rescue
    ArgumentError -> 0
  end

  @doc false
  # Whether an entry of `size` bytes fits beside `entries` entries holding
  # `bytes` bytes, under `limits` (the defaults unless given). Public only so
  # its limits can be tested.
  @spec room?(non_neg_integer(), non_neg_integer(), non_neg_integer(), tuple()) :: boolean()
  def room?(entries, bytes, size, limits \\ {@max_entries, @max_bytes})

  def room?(entries, bytes, size, {max_entries, max_bytes}),
    do: entries < max_entries and bytes + size <= max_bytes

  @impl true
  def init(opts) do
    table = opts[:table]

    :ets.new(table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    :ets.insert(table, {@bytes_key, 0, {opts[:max_entries], opts[:max_bytes]}})
    state = %{interval: opts[:interval], table: table}
    schedule(state.interval)
    {:ok, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep(state.table)
    schedule(state.interval)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # Trusted input: only store/4 writes blobs, from values this VM built.
  defp lookup(table, key, now) do
    case :ets.lookup(table, key) do
      [{^key, blob, expires_at, _size}] when expires_at > now ->
        {:ok, Plug.Crypto.non_executable_binary_to_term(blob)}

      _ ->
        :miss
    end
  rescue
    ArgumentError -> :miss
  end

  # An expired entry still under this key is removed first, so it never
  # blocks the insert and its bytes are released. The blob's size is what
  # the counter adds, so the limit counts exactly the bytes stored.
  defp store(table, key, value, expires_at) do
    blob = :erlang.term_to_binary(value)
    size = byte_size(blob)
    evict(table, key)
    limits = :ets.lookup_element(table, @bytes_key, 3)

    if room?(:ets.info(table, :size) - 1, used_bytes!(table), size, limits) and
         :ets.insert_new(table, {key, blob, expires_at, size}) do
      :ets.update_counter(table, @bytes_key, {2, size})
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  defp evict(table, key) do
    case :ets.take(table, key) do
      [{^key, _blob, _expires_at, size}] ->
        :ets.update_counter(table, @bytes_key, {2, -size})
        1

      _ ->
        0
    end
  end

  defp used_bytes!(table) do
    :ets.info(table, :memory) * :erlang.system_info(:wordsize) +
      :ets.lookup_element(table, @bytes_key, 2)
  end

  defp schedule(interval), do: Process.send_after(self(), :sweep, interval)

  defp now, do: System.monotonic_time(:millisecond)
end
