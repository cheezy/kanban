defmodule KanbanWeb.ReviewQueueSubtitleTest do
  use ExUnit.Case, async: true

  alias KanbanWeb.ReviewQueueSubtitle

  defp stats(count, agents, oldest),
    do: %{count: count, distinct_agents: agents, oldest_age_minutes: oldest}

  describe "text/1" do
    test "an empty queue says no tasks wait" do
      assert ReviewQueueSubtitle.text(%{count: 0}) == "0 tasks waiting on you."
    end

    test "counts tasks and agents in the singular and the plural" do
      assert stats(1, 1, nil) |> ReviewQueueSubtitle.text() ==
               "1 task from 1 agent waiting on you"

      assert stats(3, 2, nil) |> ReviewQueueSubtitle.text() ==
               "3 tasks from 2 agents waiting on you"
    end

    test "adds the oldest task's age in minutes, hours or days" do
      assert stats(1, 1, 0) |> ReviewQueueSubtitle.text() =~ ~r/ · oldest just now$/
      assert stats(1, 1, 59) |> ReviewQueueSubtitle.text() =~ ~r/ · oldest 59m ago$/
      assert stats(1, 1, 60) |> ReviewQueueSubtitle.text() =~ ~r/ · oldest 1h ago$/
      assert stats(1, 1, 1439) |> ReviewQueueSubtitle.text() =~ ~r/ · oldest 23h ago$/
      assert stats(1, 1, 1440) |> ReviewQueueSubtitle.text() =~ ~r/ · oldest 1d ago$/
    end
  end
end
