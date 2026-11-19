defmodule Kanban.Reviews.DiffCacheTest do
  use ExUnit.Case, async: true

  alias Kanban.Reviews.DiffCache

  defp key(diff \\ "d"), do: [:positive] |> System.unique_integer() |> DiffCache.key(0, diff)

  test "key/3 hashes the diff" do
    assert {7, 2, hash} = DiffCache.key(7, 2, "diff")
    assert hash == :crypto.hash(:sha256, "diff")
    refute DiffCache.key(7, 2, "diff") == DiffCache.key(7, 2, "diff2")
  end

  test "a stored value is returned without computing again" do
    key = key()

    assert DiffCache.fetch_or_compute(key, fn -> :first end) == :first
    assert DiffCache.fetch_or_compute(key, fn -> flunk("computed twice") end) == :first
  end

  test "an expired entry is not returned and a sweep deletes it" do
    key = key()

    assert DiffCache.fetch_or_compute(key, fn -> :stale end, ttl: -1) == :stale
    assert DiffCache.fetch_or_compute(key, fn -> :fresh end, ttl: -1) == :fresh

    assert DiffCache.sweep() >= 1
    assert :ets.lookup(DiffCache, key) == []
  end

  test "room?/3 refuses at 1,000 entries or past 64 MB" do
    max = 64 * 1024 * 1024

    assert DiffCache.room?(999, 0, 0)
    refute DiffCache.room?(1_000, 0, 0)
    assert DiffCache.room?(0, max - 10, 10)
    refute DiffCache.room?(0, max - 10, 11)
  end

  test "an entry too heavy for the byte limit is returned but not stored" do
    key = key()

    assert DiffCache.fetch_or_compute(key, fn -> :heavy end, weight: 64 * 1024 * 1024) == :heavy
    assert :ets.lookup(DiffCache, key) == []
    assert DiffCache.fetch_or_compute(key, fn -> :light end, weight: 10) == :light
    assert [{^key, :light, _expires_at, 10}] = :ets.lookup(DiffCache, key)
  end

  test "a sweep message keeps the process running" do
    pid = Process.whereis(DiffCache)
    send(pid, :sweep)
    send(pid, :unexpected)

    assert :sys.get_state(pid) == :timer.minutes(10)
    assert Process.alive?(pid)
  end
end
