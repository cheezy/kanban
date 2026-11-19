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
  module, so only one cache runs per VM; `Kanban.Application` starts it.

  Two callers that miss on the same key at once both compute. Highlighting is
  deterministic, so both get equal results, and only the first insert is
  kept: "compute once or return equal results".

  ## Limits

  The table holds at most 1,000 entries and at most 64 MB. The byte figure
  is the table's own memory, as `:ets.info/2` reports it, plus each entry's
  `:weight`. The weight is there because ETS memory leaves out binaries over
  64 bytes, which live off-heap and may be shared with the text they were cut
  from, so the caller states how many off-heap bytes an entry can hold alive.
  When an entry would pass either limit it is computed and returned but not
  stored, until a sweep frees room. Two concurrent stores may each see room,
  so the limits can be overshot by at most one entry per concurrent caller.
  If the table is not running at all, every call computes.

  ## Options

    * `:interval` - milliseconds between sweeps. Defaults to 10 minutes.
    * `:name` - the name to register under.
  """

  use GenServer

  @table __MODULE__
  # The running total of the weights of the stored entries.
  @weight_key :__weight_bytes__
  @ttl :timer.hours(1)
  @default_interval :timer.minutes(10)
  @max_entries 1_000
  @max_bytes 64 * 1024 * 1024

  @typedoc "A cache key: task id, file index and the diff's SHA-256 hash."
  @type key :: {term(), non_neg_integer(), binary()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    opts = Keyword.validate!(opts, [:name, interval: @default_interval])

    GenServer.start_link(__MODULE__, opts[:interval], Keyword.take(opts, [:name]))
  end

  @doc "The cache key for one file's diff in one task."
  @spec key(term(), non_neg_integer(), String.t()) :: key()
  def key(task_id, file_index, diff) when is_binary(diff) do
    {task_id, file_index, :crypto.hash(:sha256, diff)}
  end

  @doc """
  Returns the cached value for `key`, or calls `fun`, stores its result and
  returns it.

    * `:ttl` - the entry's lifetime in milliseconds. Defaults to one hour.
    * `:weight` - the off-heap bytes the value can hold alive, counted
      against the 64 MB limit. Defaults to 0.
  """
  @spec fetch_or_compute(key(), (-> value), keyword()) :: value when value: term()
  def fetch_or_compute(key, fun, opts \\ []) when is_function(fun, 0) do
    now = now()

    case lookup(key, now) do
      {:ok, value} ->
        value

      :miss ->
        value = fun.()
        weight = Keyword.get(opts, :weight, 0)
        store({key, value, now + Keyword.get(opts, :ttl, @ttl), weight})
        value
    end
  end

  @doc "Deletes every expired entry and returns how many it deleted."
  @spec sweep() :: non_neg_integer()
  def sweep do
    @table
    |> :ets.select([{{:"$1", :_, :"$2", :_}, [{:"=<", :"$2", now()}], [:"$1"]}])
    |> Enum.map(&evict/1)
    |> Enum.sum()
  rescue
    ArgumentError -> 0
  end

  @doc false
  # Whether an entry of `weight` bytes fits beside `entries` entries holding
  # `bytes` bytes. Public only so its limits can be tested.
  @spec room?(non_neg_integer(), non_neg_integer(), non_neg_integer()) :: boolean()
  def room?(entries, bytes, weight), do: entries < @max_entries and bytes + weight <= @max_bytes

  @impl true
  def init(interval) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    :ets.insert(@table, {@weight_key, 0})
    schedule(interval)
    {:ok, interval}
  end

  @impl true
  def handle_info(:sweep, interval) do
    sweep()
    schedule(interval)
    {:noreply, interval}
  end

  def handle_info(_other, interval), do: {:noreply, interval}

  defp lookup(key, now) do
    case :ets.lookup(@table, key) do
      [{^key, value, expires_at, _weight}] when expires_at > now -> {:ok, value}
      _ -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  # An expired entry still under this key is removed first, so it never
  # blocks the insert and its weight is released.
  defp store({key, _value, _expires_at, weight} = entry) do
    evict(key)

    if room?(:ets.info(@table, :size) - 1, used_bytes(), weight) and
         :ets.insert_new(@table, entry) do
      :ets.update_counter(@table, @weight_key, weight)
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  defp evict(key) do
    case :ets.take(@table, key) do
      [{^key, _value, _expires_at, weight}] ->
        :ets.update_counter(@table, @weight_key, -weight)
        1

      _ ->
        0
    end
  end

  defp used_bytes do
    :ets.info(@table, :memory) * :erlang.system_info(:wordsize) +
      :ets.lookup_element(@table, @weight_key, 2)
  end

  defp schedule(interval), do: Process.send_after(self(), :sweep, interval)

  defp now, do: System.monotonic_time(:millisecond)
end
