defmodule Kanban.Reviews.DiffCacheTest do
  use ExUnit.Case, async: true

  alias Kanban.Reviews.DiffCache

  defp key(diff \\ "d"), do: [:positive] |> System.unique_integer() |> DiffCache.key(0, diff)

  # A private cache, so a test can fill it to its limits without touching the
  # shared table other tests highlight into. The tests of a module run one at
  # a time and start_supervised!/2 stops the cache when a test ends, so a
  # fixed name is free in each test.
  defp private_cache(opts \\ [], table \\ :diff_cache_test_private) do
    start_supervised!({DiffCache, Keyword.merge([table: table], opts)}, id: table)
    table
  end

  defp stored?(table, key), do: :ets.lookup(table, key) != []

  # An empty table's own memory (its locks, mostly), which the byte limit
  # also counts, so a limit can be set that far above it.
  defp empty_table_bytes do
    table = private_cache([], :diff_cache_test_empty)
    bytes = DiffCache.used_bytes(table)
    stop_supervised!(table)
    bytes
  end

  test "key/3 hashes the diff" do
    assert {7, 2, hash, nil} = DiffCache.key(7, 2, "diff")
    assert hash == :crypto.hash(:sha256, "diff")
    refute DiffCache.key(7, 2, "diff") == DiffCache.key(7, 2, "diff2")
  end

  test "a stored value is returned without computing again" do
    key = key()

    assert DiffCache.fetch_or_compute(key, fn -> :first end) == :first
    assert DiffCache.fetch_or_compute(key, fn -> flunk("computed twice") end) == :first
  end

  test "a stored value comes back equal, however it was built" do
    table = private_cache()
    parent = String.duplicate("x", 10_000)
    value = [%{text: binary_part(parent, 0, 100), spans: [{:keyword, "def"}]}]

    assert DiffCache.fetch_or_compute(key(), fn -> value end, table: table) == value

    [{key, _blob, _expires_at, _size}] =
      table |> :ets.tab2list() |> Enum.filter(&(tuple_size(&1) == 4))

    assert DiffCache.fetch_or_compute(key, fn -> flunk("computed twice") end, table: table) ==
             value
  end

  test "an expired entry is not returned and a sweep deletes it" do
    key = key()

    assert DiffCache.fetch_or_compute(key, fn -> :stale end, ttl: -1) == :stale
    assert DiffCache.fetch_or_compute(key, fn -> :fresh end, ttl: -1) == :fresh

    assert DiffCache.sweep() >= 1
    assert :ets.lookup(DiffCache, key) == []
  end

  test "room?/4 refuses at 1,000 entries or past 64 MB" do
    max = 64 * 1024 * 1024

    assert DiffCache.room?(999, 0, 0)
    refute DiffCache.room?(1_000, 0, 0)
    assert DiffCache.room?(0, max - 10, 10)
    refute DiffCache.room?(0, max - 10, 11)
  end

  test "the 1,001st entry is computed and returned but not stored" do
    table = private_cache()
    keys = for _ <- 1..1_000, do: key()

    for k <- keys, do: DiffCache.fetch_or_compute(k, fn -> :ok end, table: table)
    assert Enum.all?(keys, &stored?(table, &1))

    extra = key()
    assert DiffCache.fetch_or_compute(extra, fn -> :extra end, table: table) == :extra
    refute stored?(table, extra)
  end

  test "the byte limit counts each value's encoded bytes, off-heap binaries included" do
    # Each value is one 40 KB binary: off-heap, so ETS memory alone would not
    # see it, but its encoded size is counted.
    table = private_cache(max_bytes: empty_table_bytes() + 90_000)
    big = fn -> :crypto.strong_rand_bytes(40_000) end
    first = key()
    second = key()
    third = key()

    DiffCache.fetch_or_compute(first, big, table: table)
    DiffCache.fetch_or_compute(second, big, table: table)
    assert stored?(table, first) and stored?(table, second)
    assert DiffCache.used_bytes(table) > empty_table_bytes() + 80_000

    value = DiffCache.fetch_or_compute(third, big, table: table)
    assert byte_size(value) == 40_000
    refute stored?(table, third)
  end

  test "an expired entry's bytes are released when it is swept" do
    table = private_cache(max_bytes: empty_table_bytes() + 60_000)
    old = key()
    new = key()

    DiffCache.fetch_or_compute(old, fn -> :crypto.strong_rand_bytes(40_000) end,
      table: table,
      ttl: -1
    )

    assert stored?(table, old)
    assert DiffCache.sweep(table) == 1
    assert DiffCache.used_bytes(table) < empty_table_bytes() + 20_000

    DiffCache.fetch_or_compute(new, fn -> :crypto.strong_rand_bytes(40_000) end, table: table)
    assert stored?(table, new)
  end

  test "with no table every call computes and nothing raises" do
    table = :diff_cache_test_missing_table
    key = key()

    assert DiffCache.fetch_or_compute(key, fn -> :one end, table: table) == :one
    assert DiffCache.fetch_or_compute(key, fn -> :two end, table: table) == :two
    assert DiffCache.sweep(table) == 0
    assert DiffCache.used_bytes(table) == 0
  end

  test "a sweep message keeps the process running" do
    pid = Process.whereis(DiffCache)
    send(pid, :sweep)
    send(pid, :unexpected)

    assert %{interval: interval} = :sys.get_state(pid)
    assert interval == :timer.minutes(10)
    assert Process.alive?(pid)
  end
end
