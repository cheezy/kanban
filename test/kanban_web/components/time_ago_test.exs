defmodule KanbanWeb.TimeAgoTest do
  use ExUnit.Case, async: true

  alias KanbanWeb.TimeAgo

  defp fine(seconds_ago) do
    seconds_ago
    |> ago()
    |> TimeAgo.format_age(:fine)
  end

  defp coarse(seconds_ago) do
    seconds_ago
    |> ago()
    |> TimeAgo.format_age(:coarse)
  end

  defp ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds, :second)

  describe "format_age/2 with :fine granularity" do
    test "renders just now under 5 seconds" do
      assert fine(3) == "just now"
    end

    test "renders seconds between 5 and 59 seconds" do
      assert fine(30) =~ ~r/^3\ds ago$/
      assert fine(58) =~ ~r/^(58|59)s ago$/
    end

    test "exactly 5 seconds is the first age rendered with second precision" do
      # Drift can only push 5 to 6 during the test run; both render as seconds.
      assert fine(5) =~ ~r/^[56]s ago$/
    end

    test "renders minutes between one minute and one hour" do
      assert fine(61) == "1m ago"
      assert fine(59 * 60) == "59m ago"
    end

    test "renders hours between one hour and one day" do
      assert fine(3 * 3600) == "3h ago"
    end

    test "renders days at one day and beyond" do
      assert fine(25 * 3600) == "1d ago"
      assert fine(3 * 86_400) == "3d ago"
    end
  end

  describe "format_age/2 with :coarse granularity" do
    test "renders just now for anything under a minute" do
      assert coarse(3) == "just now"
      assert coarse(30) == "just now"
    end

    test "renders minutes, hours, and days identically to fine" do
      assert coarse(61) == "1m ago"
      assert coarse(3 * 3600) == "3h ago"
      assert coarse(3 * 86_400) == "3d ago"
    end
  end

  describe "format_age/2 divergence and edge cases" do
    test "the two granularities intentionally disagree under a minute" do
      assert coarse(30) == "just now"
      assert fine(30) =~ ~r/s ago$/
    end

    test "nil renders an empty string in both granularities" do
      assert TimeAgo.format_age(nil, :fine) == ""
      assert TimeAgo.format_age(nil, :coarse) == ""
    end

    test "just past 60 seconds rolls over to minutes in both granularities" do
      # 61s instead of boundary-exact 60s to absorb a second of test-runtime
      # drift; the guard is seconds < 60 so 61 is firmly in minutes.
      assert fine(61) == "1m ago"
      assert coarse(61) == "1m ago"
    end
  end
end
