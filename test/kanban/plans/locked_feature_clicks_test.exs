defmodule Kanban.Plans.LockedFeatureClicksTest do
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures

  alias Kanban.Plans.LockedFeatureClick
  alias Kanban.Plans.LockedFeatureClicks

  @now ~U[2026-10-19 12:00:00.000000Z]

  defp days_after(days), do: DateTime.add(@now, days, :day)

  describe "count_click/3" do
    test "counts a user's first click on a feature and stores when" do
      user = user_fixture()

      assert LockedFeatureClicks.count_click(user, :mcp, @now) == :counted

      query = from c in LockedFeatureClick, where: c.user_id == ^user.id
      assert [%LockedFeatureClick{feature: :mcp, counted_at: @now}] = Repo.all(query)
    end

    test "does not count the same user and feature again within 7 days" do
      user = user_fixture()
      :counted = LockedFeatureClicks.count_click(user, :mcp, @now)

      assert LockedFeatureClicks.count_click(user, :mcp, @now) == :already_counted

      assert LockedFeatureClicks.count_click(user, :mcp, DateTime.add(days_after(7), -1)) ==
               :already_counted

      assert Repo.get_by!(LockedFeatureClick, user_id: user.id).counted_at == @now
    end

    test "counts again from exactly 7 days later, and restarts the week from then" do
      user = user_fixture()
      :counted = LockedFeatureClicks.count_click(user, :mcp, @now)

      assert LockedFeatureClicks.count_click(user, :mcp, days_after(7)) == :counted
      assert Repo.get_by!(LockedFeatureClick, user_id: user.id).counted_at == days_after(7)

      assert LockedFeatureClicks.count_click(user, :mcp, days_after(10)) == :already_counted
      assert LockedFeatureClicks.count_click(user, :mcp, days_after(14)) == :counted
    end

    test "keeps one record per user and feature" do
      user = user_fixture()
      other = user_fixture()

      assert LockedFeatureClicks.count_click(user, :mcp, @now) == :counted
      assert LockedFeatureClicks.count_click(user, :telemetry, @now) == :counted
      assert LockedFeatureClicks.count_click(other, :mcp, @now) == :counted

      for _ <- 1..3, do: LockedFeatureClicks.count_click(user, :mcp, @now)

      assert Repo.aggregate(LockedFeatureClick, :count) == 3
    end

    test "simultaneous clicks count once" do
      user = user_fixture()

      results =
        1..8
        |> Task.async_stream(fn _ -> LockedFeatureClicks.count_click(user, :sso, @now) end)
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.count(results, &(&1 == :counted)) == 1
      assert Enum.count(results, &(&1 == :already_counted)) == 7
    end

    test "a user's records go when the user is deleted" do
      user = user_fixture()
      :counted = LockedFeatureClicks.count_click(user, :mcp, @now)

      Repo.delete!(user)

      assert Repo.aggregate(LockedFeatureClick, :count) == 0
    end
  end
end
