defmodule KanbanWeb.TaskTokensTest do
  @moduledoc """
  Exhaustive clause coverage for the shared design-token resolvers used
  across the task-detail surface.
  """
  use KanbanWeb.ConnCase, async: true

  alias KanbanWeb.TaskTokens

  describe "status_label/1" do
    for {status, label} <- [
          {:open, "Open"},
          {:ready, "Ready"},
          {:in_progress, "Doing"},
          {:review, "Review"},
          {:completed, "Done"},
          {:blocked, "Blocked"}
        ] do
      test "#{status} → #{label}" do
        assert TaskTokens.status_label(unquote(status)) == unquote(label)
      end
    end

    test "unknown status falls back to Open" do
      assert TaskTokens.status_label(:totally_unknown) == "Open"
    end
  end

  describe "status_soft/1" do
    for {status, token} <- [
          {:open, "var(--st-backlog-soft)"},
          {:ready, "var(--st-ready-soft)"},
          {:in_progress, "var(--st-doing-soft)"},
          {:review, "var(--st-review-soft)"},
          {:completed, "var(--st-done-soft)"},
          {:blocked, "var(--st-blocked-soft)"}
        ] do
      test "#{status} → #{token}" do
        assert TaskTokens.status_soft(unquote(status)) == unquote(token)
      end
    end

    test "unknown status falls back to backlog-soft" do
      assert TaskTokens.status_soft(:wat) == "var(--st-backlog-soft)"
    end
  end

  describe "status_ink/1" do
    for {status, token} <- [
          {:open, "var(--st-backlog)"},
          {:ready, "var(--st-ready)"},
          {:in_progress, "var(--st-doing)"},
          {:review, "var(--st-review)"},
          {:completed, "var(--st-done)"},
          {:blocked, "var(--st-blocked)"}
        ] do
      test "#{status} → #{token}" do
        assert TaskTokens.status_ink(unquote(status)) == unquote(token)
      end
    end

    test "unknown status falls back to backlog" do
      assert TaskTokens.status_ink(:wat) == "var(--st-backlog)"
    end
  end

  describe "priority_color/1" do
    for {level, token} <- [
          {:critical, "var(--pri-critical)"},
          {:high, "var(--pri-high)"},
          {:medium, "var(--pri-medium)"},
          {:low, "var(--pri-low)"}
        ] do
      test "#{level} → #{token}" do
        assert TaskTokens.priority_color(unquote(level)) == unquote(token)
      end
    end

    test "unknown priority falls back to ink-4" do
      assert TaskTokens.priority_color(:wat) == "var(--ink-4)"
    end
  end

  describe "priority_word/1" do
    for {level, word} <- [
          {:critical, "Critical"},
          {:high, "High"},
          {:medium, "Medium"},
          {:low, "Low"}
        ] do
      test "#{level} → #{word}" do
        assert TaskTokens.priority_word(unquote(level)) == unquote(word)
      end
    end

    test "unknown priority returns empty string" do
      assert TaskTokens.priority_word(:wat) == ""
    end
  end

  describe "complexity_word/1" do
    for {tier, word} <- [
          {:small, "Small"},
          {:medium, "Medium"},
          {:large, "Large"}
        ] do
      test "#{tier} → #{word}" do
        assert TaskTokens.complexity_word(unquote(tier)) == unquote(word)
      end
    end

    test "unknown complexity returns empty string" do
      assert TaskTokens.complexity_word(:wat) == ""
    end
  end

  describe "archive_reason_label/1" do
    for {reason, label} <- [
          {:completed, "Completed"},
          {:cancelled, "Cancelled"},
          {:wontdo, "Won't do"},
          {:duplicate, "Duplicate"},
          {:deferred, "Deferred"}
        ] do
      test "#{reason} → #{label}" do
        assert TaskTokens.archive_reason_label(unquote(reason)) == unquote(label)
      end
    end

    test "nil falls back to Completed (legacy archived rows)" do
      assert TaskTokens.archive_reason_label(nil) == "Completed"
    end

    test "unknown reason falls back to Completed" do
      assert TaskTokens.archive_reason_label(:nonsense) == "Completed"
    end
  end

  describe "archive_reason_soft/1" do
    for {reason, token} <- [
          {:completed, "var(--st-done-soft)"},
          {:cancelled, "var(--st-blocked-soft)"},
          {:wontdo, "var(--surface-sunken)"},
          {:duplicate, "var(--surface-sunken)"},
          {:deferred, "var(--st-review-soft)"}
        ] do
      test "#{reason} → #{token}" do
        assert TaskTokens.archive_reason_soft(unquote(reason)) == unquote(token)
      end
    end

    test "nil falls back to st-done-soft" do
      assert TaskTokens.archive_reason_soft(nil) == "var(--st-done-soft)"
    end
  end

  describe "archive_reason_ink/1" do
    for {reason, token} <- [
          {:completed, "var(--st-done)"},
          {:cancelled, "var(--st-blocked)"},
          {:wontdo, "var(--ink-3)"},
          {:duplicate, "var(--ink-3)"},
          {:deferred, "var(--st-review)"}
        ] do
      test "#{reason} → #{token}" do
        assert TaskTokens.archive_reason_ink(unquote(reason)) == unquote(token)
      end
    end

    test "nil falls back to st-done" do
      assert TaskTokens.archive_reason_ink(nil) == "var(--st-done)"
    end
  end
end
