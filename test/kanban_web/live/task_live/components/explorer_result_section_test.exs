defmodule KanbanWeb.TaskLive.Components.ExplorerResultSectionTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias KanbanWeb.TaskLive.Components.ExplorerResultSection

  @dispatched %{
    "dispatched" => true,
    "summary" => "Explored the three key_files and identified the pattern to mirror.",
    "duration_ms" => 12_500
  }

  # The duration span is the only element carrying this class, so it is a
  # precise probe for "no duration was rendered" — unlike matching on "ms",
  # which also appears inside the "items-baseline" utility class.
  @duration_class "opacity-70"

  @skipped %{
    "dispatched" => false,
    "reason" => "small_task_0_1_key_files",
    "summary" => "Read the single key file directly; no subagent dispatch was warranted."
  }

  defp render_section(explorer_result) do
    render_component(&ExplorerResultSection.explorer_result_section/1,
      explorer_result: explorer_result
    )
  end

  describe "dispatched shape" do
    test "renders the summary and a formatted duration" do
      html = render_section(@dispatched)

      assert html =~ "Explorer Result"
      assert html =~ "Dispatched"
      refute html =~ "Not dispatched"
      assert html =~ "Explored the three key_files"
      assert html =~ "12.5s"
    end

    test "renders sub-second durations in milliseconds" do
      html = render_section(%{@dispatched | "duration_ms" => 640})

      assert html =~ "640 ms"
    end

    test "renders a whole number of seconds without a fractional part" do
      html = render_section(%{@dispatched | "duration_ms" => 12_000})

      assert html =~ "12s"
      refute html =~ "12.0s"
    end

    test "renders durations of a minute or more as minutes and seconds" do
      html = render_section(%{@dispatched | "duration_ms" => 125_000})

      assert html =~ "2m 5s"
    end

    test "renders a duration_ms of 0" do
      html = render_section(%{@dispatched | "duration_ms" => 0})

      assert html =~ "0 ms"
    end

    test "renders a very large duration_ms without raising" do
      html = render_section(%{@dispatched | "duration_ms" => 86_400_000})

      assert html =~ "1440m 0s"
    end
  end

  describe "skip shape" do
    test "renders the summary and a translated skip-reason label" do
      html = render_section(@skipped)

      assert html =~ "Not dispatched"
      assert html =~ "Small task (0-1 key files)"
      assert html =~ "no subagent dispatch was warranted"
      refute html =~ "small_task_0_1_key_files"
    end

    test "renders each of the five skip reasons as a human-readable label" do
      expected = %{
        "no_subagent_support" => "No subagent support",
        "small_task_0_1_key_files" => "Small task (0-1 key files)",
        "trivial_change_docs_only" => "Trivial change (docs only)",
        "self_reported_exploration" => "Self-reported exploration",
        "self_reported_review" => "Self-reported review"
      }

      for {reason, label} <- expected do
        html = render_section(%{@skipped | "reason" => reason})

        assert html =~ label, "expected #{reason} to render as #{label}"
        refute html =~ reason
      end
    end

    test "renders an unrecognized skip reason as its raw value without crashing" do
      html = render_section(%{@skipped | "reason" => "some_future_reason"})

      assert html =~ "some_future_reason"
    end
  end

  describe "malformed and legacy input" do
    # Presence is the CALLER's guard (ReviewReportHelpers.explorer_panel_visible?/1),
    # matching WorkflowStepsSection — the component itself must not gate on it.
    # These two only pin down that a caller mistake degrades rather than crashes.
    test "renders without raising for an empty map" do
      html = render_section(%{})

      assert html =~ "Explorer Result"
      refute html =~ @duration_class
    end

    test "renders without raising for a nil explorer_result" do
      html = render_section(nil)

      assert html =~ "Explorer Result"
      refute html =~ @duration_class
    end

    test "renders without raising when the summary is missing" do
      html = render_section(%{"dispatched" => true, "duration_ms" => 900})

      assert html =~ "Dispatched"
      assert html =~ "900 ms"
    end

    test "renders without raising when the summary is blank" do
      html = render_section(%{@dispatched | "summary" => "   "})

      assert html =~ "Dispatched"
    end

    test "renders without raising when duration_ms is missing" do
      html = render_section(%{"dispatched" => true, "summary" => "Explored the key files."})

      assert html =~ "Explored the key files."
      refute html =~ @duration_class
    end

    test "renders without raising when duration_ms is not an integer" do
      for bad <- ["12450", 12.5, nil, :oops] do
        html = render_section(%{@dispatched | "duration_ms" => bad})

        assert html =~ "Dispatched"
        refute html =~ @duration_class
      end
    end

    test "renders without raising when duration_ms is negative" do
      html = render_section(%{@dispatched | "duration_ms" => -1})

      assert html =~ "Dispatched"
      refute html =~ @duration_class
    end

    test "renders a reason present on a dispatched result" do
      html = render_section(Map.put(@dispatched, "reason", "self_reported_exploration"))

      assert html =~ "Dispatched"
      assert html =~ "Self-reported exploration"
    end

    test "renders a skip result whose reason is absent" do
      html = render_section(%{"dispatched" => false, "summary" => "No exploration was run."})

      assert html =~ "Not dispatched"
      assert html =~ "No exploration was run."
    end

    test "treats a stringified \"false\" dispatched flag as not dispatched" do
      html = render_section(%{@skipped | "dispatched" => "false"})

      assert html =~ "Not dispatched"
      assert html =~ "Small task (0-1 key files)"
    end

    test "renders without raising when reason is not a binary" do
      html = render_section(%{@skipped | "reason" => :small_task_0_1_key_files})

      assert html =~ "Not dispatched"
    end

    test "accepts an atom-keyed explorer_result map" do
      html =
        render_section(%{
          dispatched: false,
          reason: "trivial_change_docs_only",
          summary: "Docs-only change; nothing to explore."
        })

      assert html =~ "Not dispatched"
      assert html =~ "Trivial change (docs only)"
      assert html =~ "Docs-only change"
    end
  end

  describe "escaping and layout" do
    test "renders markup-like characters in the summary as literal text" do
      html = render_section(%{@dispatched | "summary" => "<script>alert('xss')</script>"})

      refute html =~ "<script>alert"
      assert html =~ "&lt;script&gt;"
    end

    test "renders markup-like characters in an unrecognized reason as literal text" do
      html = render_section(%{@skipped | "reason" => "<img onerror=x>"})

      refute html =~ "<img onerror"
      assert html =~ "&lt;img"
    end

    test "wraps a long multi-paragraph summary instead of overflowing" do
      summary = Enum.map_join(1..300, " ", fn n -> "word#{n}" end)

      html = render_section(%{@dispatched | "summary" => summary})

      assert html =~ "whitespace-pre-wrap break-words"
      assert html =~ "word300"
    end
  end

  describe "theming" do
    test "uses the stride orange theme tokens rather than hardcoded colours" do
      html = render_section(@dispatched)

      assert html =~ "var(--stride-orange-soft)"
      assert html =~ "var(--stride-orange)"
      assert html =~ "var(--stride-orange-ink)"
    end

    test "carries no hardcoded gray, white or black utility classes" do
      html = render_section(@dispatched)

      for forbidden <- ["text-gray-", "bg-gray-", "border-gray-", "bg-white", "text-white"] do
        refute html =~ forbidden
      end
    end
  end
end
