defmodule KanbanWeb.ReviewReportHelpers.MarkdownReportTest do
  use ExUnit.Case, async: true

  alias KanbanWeb.ReviewReportHelpers.MarkdownReport

  # all_present_heading?/2, count_list_items/1 and pitfalls_violated?/1 were
  # private before the W2004 split and had only indirect coverage through the
  # parent's regex fallbacks. Going public raises the bar, so they get direct
  # tests here.
  describe "all_present_heading?/2 (W2004 — newly public)" do
    @heading ~r/testing/i

    test "true when a matching heading also declares everything present" do
      assert MarkdownReport.all_present_heading?(
               %{review_report: "## Testing strategy — all present"},
               @heading
             )
    end

    test "accepts the covered and met phrasings" do
      for phrase <- ["all covered", "all met"] do
        assert MarkdownReport.all_present_heading?(
                 %{review_report: "## Testing #{phrase}"},
                 @heading
               )
      end
    end

    test "false when the heading matches but claims nothing about coverage" do
      refute MarkdownReport.all_present_heading?(
               %{review_report: "## Testing strategy"},
               @heading
             )
    end

    test "false when the all-present marker is not on a heading line" do
      refute MarkdownReport.all_present_heading?(
               %{review_report: "## Testing\nall present"},
               @heading
             )
    end

    test "accepts a string-keyed report and rejects a missing or blank one" do
      assert MarkdownReport.all_present_heading?(
               %{"review_report" => "## Testing all present"},
               @heading
             )

      refute MarkdownReport.all_present_heading?(%{review_report: ""}, @heading)
      refute MarkdownReport.all_present_heading?(%{}, @heading)
      refute MarkdownReport.all_present_heading?(nil, @heading)
    end
  end

  describe "count_list_items/1 (W2004 — newly public)" do
    test "counts dash, star and ordered bullets" do
      assert MarkdownReport.count_list_items("- one\n* two\n3. three") == 3
    end

    test "counts indented bullets and ignores prose" do
      assert MarkdownReport.count_list_items("  - one\nprose\n    * two") == 2
    end

    test "returns 0 for an empty body and for a non-binary" do
      assert MarkdownReport.count_list_items("") == 0
      assert MarkdownReport.count_list_items(nil) == 0
      assert MarkdownReport.count_list_items(42) == 0
    end
  end

  describe "pitfalls_violated?/1 (W2004 — newly public)" do
    test "true when the body reports a violation" do
      assert MarkdownReport.pitfalls_violated?("One pitfall was violated.")
      assert MarkdownReport.pitfalls_violated?("2 violations found")
    end

    test "an explicit none-violated marker wins over the bare word" do
      for body <- ["none violated", "No violations", "all honored", "all honoured"] do
        refute MarkdownReport.pitfalls_violated?(body),
               "expected #{inspect(body)} to read as no violation"
      end
    end

    test "false for an unrelated body and for a non-binary" do
      refute MarkdownReport.pitfalls_violated?("All pitfalls respected.")
      refute MarkdownReport.pitfalls_violated?(nil)
    end
  end

  describe "report_section/2" do
    test "extracts the section body when present" do
      task = %{review_report: "## Title\n\nbody text"}

      assert MarkdownReport.report_section(task, ~r/title/i) == "body text"
    end

    test "returns nil when section is absent" do
      task = %{review_report: "## Other\n\nbody"}

      assert MarkdownReport.report_section(task, ~r/title/i) == nil
    end

    test "returns nil when review_report is nil" do
      assert MarkdownReport.report_section(%{review_report: nil}, ~r/title/i) == nil
    end

    test "returns nil when the heading is the last line with no body" do
      task = %{review_report: "## Title\n"}

      assert MarkdownReport.report_section(task, ~r/title/i) == nil
    end

    test "accepts string-keyed review_report" do
      task = %{"review_report" => "## Title\n\nbody"}

      assert MarkdownReport.report_section(task, ~r/title/i) == "body"
    end

    test "returns nil for a non-map task" do
      assert MarkdownReport.report_section(nil, ~r/title/i) == nil
    end
  end
end
