defmodule KanbanWeb.DurationTest do
  use ExUnit.Case, async: true

  alias KanbanWeb.Duration

  describe "format_minutes/2 with defaults (archive strip and archive row variant)" do
    for {minutes, expected} <- [
          {0, "0m"},
          {5, "5m"},
          {59, "59m"},
          {60, "1h"},
          {65, "1h 5m"},
          {120, "2h"},
          {125, "2h 5m"},
          {161, "2h 41m"}
        ] do
      test "#{minutes} minutes renders #{expected}" do
        assert Duration.format_minutes(unquote(minutes)) == unquote(expected)
      end
    end

    test "nil renders the em dash" do
      assert Duration.format_minutes(nil) == "—"
    end

    test "non-integer input renders the em dash" do
      assert Duration.format_minutes(:oops) == "—"
      assert Duration.format_minutes(12.5) == "—"
    end
  end

  describe "format_minutes/2 with zero_label (goal sidebar variant)" do
    test "zero renders the em dash" do
      assert Duration.format_minutes(0, zero_label: "—") == "—"
    end

    test "non-zero values are unaffected by zero_label" do
      assert Duration.format_minutes(95, zero_label: "—") == "1h 35m"
      assert Duration.format_minutes(45, zero_label: "—") == "45m"
      assert Duration.format_minutes(120, zero_label: "—") == "2h"
    end

    test "nil still renders the nil label" do
      assert Duration.format_minutes(nil, zero_label: "—") == "—"
    end
  end

  describe "format_minutes/2 with pad_remainder (metrics KPI strip variant)" do
    for {minutes, expected} <- [
          {0, "0m"},
          {47, "47m"},
          {65, "1h 05m"},
          {107, "1h 47m"},
          {120, "2h"},
          {125, "2h 05m"}
        ] do
      test "#{minutes} minutes renders #{expected}" do
        assert Duration.format_minutes(unquote(minutes), pad_remainder: true) ==
                 unquote(expected)
      end
    end

    test "a clean hour never renders a padded zero remainder" do
      refute Duration.format_minutes(120, pad_remainder: true) =~ "00m"
    end
  end

  describe "format_minutes/2 option independence" do
    test "custom nil_label applies to nil and non-integers" do
      assert Duration.format_minutes(nil, nil_label: "n/a") == "n/a"
      assert Duration.format_minutes(:bad, nil_label: "n/a") == "n/a"
    end

    test "options combine without interfering" do
      assert Duration.format_minutes(65, zero_label: "—", pad_remainder: true) == "1h 05m"
      assert Duration.format_minutes(0, zero_label: "zero", pad_remainder: true) == "zero"
    end
  end
end
