defmodule KanbanWeb.ReviewReportHelpersTest do
  use ExUnit.Case, async: true

  alias KanbanWeb.ReviewReportHelpers

  describe "structured-field source" do
    test "testing_strategy_value prefers reviewer_result.testing_strategy.status" do
      task = %{
        reviewer_result: %{"testing_strategy" => %{"status" => "passed"}},
        review_report: nil
      }

      assert ReviewReportHelpers.testing_strategy_value(task) == "passed"
    end

    test "testing_strategy_passed reflects structured status" do
      assert ReviewReportHelpers.testing_strategy_passed(%{
               reviewer_result: %{"testing_strategy" => %{"status" => "passed"}}
             }) == true

      assert ReviewReportHelpers.testing_strategy_passed(%{
               reviewer_result: %{"testing_strategy" => %{"status" => "failed"}}
             }) == false

      assert ReviewReportHelpers.testing_strategy_passed(%{
               reviewer_result: %{"testing_strategy" => %{"status" => "not_assessed"}}
             }) == nil
    end

    test "patterns_value prefers structured status over regex" do
      task = %{
        reviewer_result: %{"patterns" => %{"status" => "failed"}},
        review_report: "### Patterns followed\n\nUsed existing pattern."
      }

      assert ReviewReportHelpers.patterns_value(task) == "failed"
      assert ReviewReportHelpers.patterns_passed(task) == false
    end

    test "pitfalls_value prefers structured status over regex" do
      task = %{
        reviewer_result: %{"pitfalls" => %{"status" => "passed"}},
        review_report: "### Pitfalls\n\nNone violated."
      }

      assert ReviewReportHelpers.pitfalls_value(task) == "passed"
      assert ReviewReportHelpers.pitfalls_passed(task) == true
    end

    test "security_considerations_value prefers reviewer_result.security_considerations.status" do
      task = %{
        reviewer_result: %{"security_considerations" => %{"status" => "passed"}},
        review_report: nil
      }

      assert ReviewReportHelpers.security_considerations_value(task) == "passed"
    end

    test "security_considerations_passed reflects structured status" do
      assert ReviewReportHelpers.security_considerations_passed(%{
               reviewer_result: %{"security_considerations" => %{"status" => "passed"}}
             }) == true

      assert ReviewReportHelpers.security_considerations_passed(%{
               reviewer_result: %{"security_considerations" => %{"status" => "failed"}}
             }) == false

      assert ReviewReportHelpers.security_considerations_passed(%{
               reviewer_result: %{"security_considerations" => %{"status" => "not_assessed"}}
             }) == nil
    end
  end

  describe "regex fallback when no structured field" do
    test "testing_strategy_value falls back to regex when reviewer_result lacks the field" do
      task = %{
        reviewer_result: nil,
        review_report: """
        ### Required test cases (all present)

        - Handles login
        - Handles logout
        """
      }

      assert ReviewReportHelpers.testing_strategy_value(task) =~ "cases · all present"
      assert ReviewReportHelpers.testing_strategy_passed(task) == true
    end

    test "patterns_value falls back to 'followed' regex" do
      task = %{
        reviewer_result: nil,
        review_report: "### Patterns followed\n\nUsed standard pattern."
      }

      assert ReviewReportHelpers.patterns_value(task) == "followed"
      assert ReviewReportHelpers.patterns_passed(task) == true
    end

    test "pitfalls_value falls back to regex" do
      task_clean = %{
        reviewer_result: nil,
        review_report: "### Pitfalls\n\nNone violated."
      }

      task_dirty = %{
        reviewer_result: nil,
        review_report: "### Pitfalls\n\nTwo pitfalls violated."
      }

      assert ReviewReportHelpers.pitfalls_value(task_clean) == "none violated"
      assert ReviewReportHelpers.pitfalls_passed(task_clean) == true
      assert ReviewReportHelpers.pitfalls_value(task_dirty) == "violated"
      assert ReviewReportHelpers.pitfalls_passed(task_dirty) == false
    end

    test "all helpers return nil when neither source is present" do
      task = %{reviewer_result: nil, review_report: nil}

      assert ReviewReportHelpers.testing_strategy_value(task) == nil
      assert ReviewReportHelpers.testing_strategy_passed(task) == nil
      assert ReviewReportHelpers.patterns_value(task) == nil
      assert ReviewReportHelpers.patterns_passed(task) == nil
      assert ReviewReportHelpers.pitfalls_value(task) == nil
      assert ReviewReportHelpers.pitfalls_passed(task) == nil
      assert ReviewReportHelpers.security_considerations_value(task) == nil
      assert ReviewReportHelpers.security_considerations_passed(task) == nil
    end
  end

  describe "report_section/2" do
    test "extracts the section body when present" do
      task = %{review_report: "## Title\n\nbody text"}

      assert ReviewReportHelpers.report_section(task, ~r/title/i) == "body text"
    end

    test "returns nil when section is absent" do
      task = %{review_report: "## Other\n\nbody"}

      assert ReviewReportHelpers.report_section(task, ~r/title/i) == nil
    end

    test "returns nil when review_report is nil" do
      assert ReviewReportHelpers.report_section(%{review_report: nil}, ~r/title/i) == nil
    end

    test "returns nil when the heading is the last line with no body" do
      task = %{review_report: "## Title\n"}

      assert ReviewReportHelpers.report_section(task, ~r/title/i) == nil
    end

    test "accepts string-keyed review_report" do
      task = %{"review_report" => "## Title\n\nbody"}

      assert ReviewReportHelpers.report_section(task, ~r/title/i) == "body"
    end

    test "returns nil for a non-map task" do
      assert ReviewReportHelpers.report_section(nil, ~r/title/i) == nil
    end
  end

  describe "structured-status fallback labels" do
    test "structured_status_label returns localized failed/not_assessed" do
      assert ReviewReportHelpers.testing_strategy_value(%{
               reviewer_result: %{"testing_strategy" => %{"status" => "failed"}}
             }) == "failed"

      assert ReviewReportHelpers.testing_strategy_value(%{
               reviewer_result: %{"testing_strategy" => %{"status" => "not_assessed"}}
             }) == "not assessed"
    end

    test "structured status returns nil for unrecognized values" do
      assert ReviewReportHelpers.testing_strategy_value(%{
               reviewer_result: %{"testing_strategy" => %{"status" => "weird"}}
             }) == nil

      assert ReviewReportHelpers.testing_strategy_passed(%{
               reviewer_result: %{"testing_strategy" => %{"status" => "weird"}}
             }) == nil
    end

    test "accepts a string-keyed reviewer_result" do
      task = %{"reviewer_result" => %{"testing_strategy" => %{"status" => "passed"}}}

      assert ReviewReportHelpers.testing_strategy_value(task) == "passed"
      assert ReviewReportHelpers.testing_strategy_passed(task) == true
    end

    test "ignores reviewer_result entries that are not %{status: binary}" do
      assert ReviewReportHelpers.testing_strategy_value(%{
               reviewer_result: %{"testing_strategy" => "yep"}
             }) == nil

      assert ReviewReportHelpers.testing_strategy_value(%{
               reviewer_result: %{"testing_strategy" => %{"status" => 42}}
             }) == nil
    end
  end

  describe "regex testing-strategy counts" do
    test "returns 'n cases' (without all-present) when no 'all present' marker" do
      task = %{
        reviewer_result: nil,
        review_report: """
        ### Required test cases

        - Login works
        * Logout works
        1. Refresh works
        """
      }

      value = ReviewReportHelpers.testing_strategy_value(task)
      assert value =~ "3 cases"
      refute value =~ "all present"
      assert ReviewReportHelpers.testing_strategy_passed(task) == true
    end

    test "returns the 'reviewed' label when the section has body but no list items" do
      task = %{
        reviewer_result: nil,
        review_report: """
        ### Testing strategy

        Manually exercised the upload form.
        """
      }

      assert ReviewReportHelpers.testing_strategy_value(task) == "reviewed"
      assert ReviewReportHelpers.testing_strategy_passed(task) == true
    end
  end

  describe "pitfalls regex" do
    test "detects 'violations' (plural) as a violation" do
      task = %{
        reviewer_result: nil,
        review_report: "### Pitfalls\n\nFound several violations."
      }

      assert ReviewReportHelpers.pitfalls_value(task) == "violated"
      assert ReviewReportHelpers.pitfalls_passed(task) == false
    end

    test "treats a benign section without any violation language as clean" do
      task = %{
        reviewer_result: nil,
        review_report: "### Pitfalls\n\nNothing of note here."
      }

      assert ReviewReportHelpers.pitfalls_value(task) == "none violated"
      assert ReviewReportHelpers.pitfalls_passed(task) == true
    end
  end

  describe "all_present_heading? with string-keyed review_report" do
    test "still recognizes the 'all present' marker" do
      task = %{
        "reviewer_result" => nil,
        "review_report" => "### Required test cases (all covered)\n\n- One\n- Two"
      }

      assert ReviewReportHelpers.testing_strategy_value(task) =~ "all present"
      assert ReviewReportHelpers.testing_strategy_passed(task) == true
    end
  end

  describe "issues[]-category derivation (between structured and regex) (D59)" do
    test "testing_strategy_passed is false when issues[] has a testing-category issue" do
      task = %{
        reviewer_result: %{
          "issues" => [%{"category" => "testing", "severity" => "important"}]
        },
        review_report: nil,
        testing_strategy: %{"unit_tests" => ["Test login"]}
      }

      assert ReviewReportHelpers.testing_strategy_passed(task) == false
      assert ReviewReportHelpers.testing_strategy_value(task) == "failed"
    end

    test "testing_strategy_passed is true when issues[] has no testing issue and metadata is present" do
      task = %{
        reviewer_result: %{"issues" => [%{"category" => "pitfall"}]},
        review_report: nil,
        testing_strategy: %{"unit_tests" => ["Test login"]}
      }

      assert ReviewReportHelpers.testing_strategy_passed(task) == true
      assert ReviewReportHelpers.testing_strategy_value(task) == "passed"
    end

    test "testing_strategy_passed is nil (not_assessed) when issues[] present but metadata absent" do
      task = %{
        reviewer_result: %{"issues" => []},
        review_report: nil,
        testing_strategy: %{}
      }

      assert ReviewReportHelpers.testing_strategy_passed(task) == nil
      assert ReviewReportHelpers.testing_strategy_value(task) == "not assessed"
    end

    test "patterns derivation uses the 'pattern' category and patterns_to_follow metadata" do
      failed = %{
        reviewer_result: %{"issues" => [%{"category" => "pattern"}]},
        review_report: nil,
        patterns_to_follow: "Follow the context pattern"
      }

      passed = %{
        reviewer_result: %{"issues" => []},
        review_report: nil,
        patterns_to_follow: "Follow the context pattern"
      }

      not_assessed = %{
        reviewer_result: %{"issues" => []},
        review_report: nil,
        patterns_to_follow: ""
      }

      assert ReviewReportHelpers.patterns_passed(failed) == false
      assert ReviewReportHelpers.patterns_passed(passed) == true
      assert ReviewReportHelpers.patterns_passed(not_assessed) == nil
    end

    test "pitfalls derivation uses the 'pitfall' category and pitfalls metadata" do
      failed = %{
        reviewer_result: %{"issues" => [%{"category" => "pitfall"}]},
        review_report: nil,
        pitfalls: ["Don't query in the LiveView"]
      }

      passed = %{
        reviewer_result: %{"issues" => []},
        review_report: nil,
        pitfalls: ["Don't query in the LiveView"]
      }

      not_assessed = %{reviewer_result: %{"issues" => []}, review_report: nil, pitfalls: []}

      assert ReviewReportHelpers.pitfalls_passed(failed) == false
      assert ReviewReportHelpers.pitfalls_passed(passed) == true
      assert ReviewReportHelpers.pitfalls_passed(not_assessed) == nil
    end

    test "security_considerations derivation uses the 'security' category and security_considerations metadata" do
      failed = %{
        reviewer_result: %{"issues" => [%{"category" => "security"}]},
        review_report: nil,
        security_considerations: ["Scope queries to current user"]
      }

      passed = %{
        reviewer_result: %{"issues" => []},
        review_report: nil,
        security_considerations: ["Scope queries to current user"]
      }

      not_assessed = %{
        reviewer_result: %{"issues" => []},
        review_report: nil,
        security_considerations: []
      }

      assert ReviewReportHelpers.security_considerations_passed(failed) == false
      assert ReviewReportHelpers.security_considerations_value(failed) == "failed"
      assert ReviewReportHelpers.security_considerations_passed(passed) == true
      assert ReviewReportHelpers.security_considerations_value(passed) == "passed"
      assert ReviewReportHelpers.security_considerations_passed(not_assessed) == nil
      assert ReviewReportHelpers.security_considerations_value(not_assessed) == "not assessed"
    end

    test "structured per-section status still wins over the issues[] derivation" do
      task = %{
        reviewer_result: %{
          "testing_strategy" => %{"status" => "passed"},
          "issues" => [%{"category" => "testing"}]
        },
        review_report: nil,
        testing_strategy: %{"unit_tests" => ["x"]}
      }

      # Explicit section status takes precedence over the derived failure.
      assert ReviewReportHelpers.testing_strategy_passed(task) == true
    end

    test "does not fall through to regex when reviewer_result carries an issues[] list" do
      task = %{
        reviewer_result: %{"issues" => []},
        review_report: "### Required test cases\n\n- Login",
        testing_strategy: %{}
      }

      # issues[] present + no testing issue + no metadata → not_assessed,
      # never the regex-derived "reviewed"/"all present".
      assert ReviewReportHelpers.testing_strategy_passed(task) == nil
    end

    test "string-keyed metadata fields are recognized for presence" do
      task = %{
        "reviewer_result" => %{"issues" => []},
        "review_report" => nil,
        "pitfalls" => ["Avoid N+1"]
      }

      assert ReviewReportHelpers.pitfalls_passed(task) == true
    end
  end

  describe "section_incomplete?/2 and project_checks_gap/1 (W1071)" do
    test "flags a section the task supplied but the review left unassessed" do
      task = %{
        security_considerations: ["Keep board scoping intact"],
        reviewer_result: %{"security_considerations" => %{"status" => "not_assessed"}}
      }

      assert ReviewReportHelpers.section_incomplete?(task, :security_considerations)
    end

    test "flags a section the task supplied but the review left out entirely" do
      task = %{
        security_considerations: ["Keep board scoping intact"],
        reviewer_result: %{"status" => "approved"}
      }

      assert ReviewReportHelpers.section_incomplete?(task, :security_considerations)
    end

    test "does not flag a section the task did not supply" do
      task = %{
        security_considerations: [],
        reviewer_result: %{"security_considerations" => %{"status" => "not_assessed"}}
      }

      refute ReviewReportHelpers.section_incomplete?(task, :security_considerations)
    end

    test "does not flag a section the review actually assessed" do
      task = %{
        security_considerations: ["x"],
        reviewer_result: %{"security_considerations" => %{"status" => "passed"}}
      }

      refute ReviewReportHelpers.section_incomplete?(task, :security_considerations)
    end

    test "incomplete_sections lists only supplied-but-unassessed sections" do
      task = %{
        security_considerations: ["x"],
        testing_strategy: %{"unit_tests" => ["t"]},
        reviewer_result: %{
          "security_considerations" => %{"status" => "not_assessed"},
          "testing_strategy" => %{"status" => "passed"}
        }
      }

      assert ReviewReportHelpers.incomplete_sections(task) == [:security_considerations]
    end

    test "project_checks_gap returns {supplied, expected} for a short dispatched review" do
      expected = Kanban.Tasks.CompletionValidation.project_checklist_count()
      task = %{reviewer_result: %{"dispatched" => true, "project_checks" => [%{"check" => "a"}]}}

      assert {1, ^expected} = ReviewReportHelpers.project_checks_gap(task)
    end

    test "project_checks_gap returns nil for a full dispatched review" do
      expected = Kanban.Tasks.CompletionValidation.project_checklist_count()
      checks = for i <- 1..expected, do: %{"check" => "c#{i}"}
      task = %{reviewer_result: %{"dispatched" => true, "project_checks" => checks}}

      assert ReviewReportHelpers.project_checks_gap(task) == nil
    end

    test "project_checks_gap returns nil for a skip-form (non-dispatched) review" do
      task = %{reviewer_result: %{"dispatched" => false, "reason" => "small_task_0_1_key_files"}}

      assert ReviewReportHelpers.project_checks_gap(task) == nil
    end
  end

  describe "review panel visibility predicates (W1085)" do
    test "visible with a non-empty reviewer_result map" do
      task = %{reviewer_result: %{"dispatched" => true}, review_report: nil}

      assert ReviewReportHelpers.review_panel_visible?(task)
      assert ReviewReportHelpers.has_reviewer_result?(task)
      refute ReviewReportHelpers.has_review_report?(task)
    end

    test "visible with a non-empty review_report string" do
      task = %{reviewer_result: nil, review_report: "## Approved"}

      assert ReviewReportHelpers.review_panel_visible?(task)
      refute ReviewReportHelpers.has_reviewer_result?(task)
      assert ReviewReportHelpers.has_review_report?(task)
    end

    test "visible with both present" do
      task = %{reviewer_result: %{"status" => "approved"}, review_report: "report"}

      assert ReviewReportHelpers.review_panel_visible?(task)
    end

    test "hidden with neither present" do
      refute ReviewReportHelpers.review_panel_visible?(%{
               reviewer_result: nil,
               review_report: nil
             })

      refute ReviewReportHelpers.review_panel_visible?(%{})
    end

    test "an empty-map reviewer_result does not make the panel visible" do
      task = %{reviewer_result: %{}, review_report: nil}

      refute ReviewReportHelpers.has_reviewer_result?(task)
      refute ReviewReportHelpers.review_panel_visible?(task)
    end

    test "an empty review_report string does not make the panel visible" do
      refute ReviewReportHelpers.has_review_report?(%{review_report: ""})
    end

    test "a whitespace-only review_report counts as content, matching the original predicate" do
      task = %{review_report: "   "}

      assert ReviewReportHelpers.has_review_report?(task)
      assert ReviewReportHelpers.review_panel_visible?(task)
    end
  end

  describe "section_note/2 (W1091)" do
    test "returns the note for each of the four section atoms" do
      task = %{
        reviewer_result: %{
          "testing_strategy" => %{"status" => "passed", "note" => "Covered by unit tests."},
          "patterns" => %{"status" => "passed", "note" => "Mirrors the reorder pattern."},
          "pitfalls" => %{"status" => "passed", "note" => "None of the pitfalls violated."},
          "security_considerations" => %{"status" => "passed", "note" => "Scoped to the board."}
        }
      }

      assert ReviewReportHelpers.section_note(task, :testing_strategy) ==
               "Covered by unit tests."

      assert ReviewReportHelpers.section_note(task, :patterns) ==
               "Mirrors the reorder pattern."

      assert ReviewReportHelpers.section_note(task, :pitfalls) ==
               "None of the pitfalls violated."

      assert ReviewReportHelpers.section_note(task, :security_considerations) ==
               "Scoped to the board."
    end

    test "trims surrounding whitespace from the note" do
      task = %{reviewer_result: %{"patterns" => %{"note" => "  trimmed note  \n"}}}

      assert ReviewReportHelpers.section_note(task, :patterns) == "trimmed note"
    end

    test "works on a string-keyed task map" do
      task = %{"reviewer_result" => %{"pitfalls" => %{"note" => "String-keyed task."}}}

      assert ReviewReportHelpers.section_note(task, :pitfalls) == "String-keyed task."
    end

    test "returns nil when reviewer_result is nil or missing" do
      assert ReviewReportHelpers.section_note(%{reviewer_result: nil}, :patterns) == nil
      assert ReviewReportHelpers.section_note(%{}, :patterns) == nil
    end

    test "returns nil when the section map is absent" do
      task = %{reviewer_result: %{"testing_strategy" => %{"note" => "present"}}}

      assert ReviewReportHelpers.section_note(task, :patterns) == nil
    end

    test "returns nil when the note key is missing" do
      task = %{reviewer_result: %{"patterns" => %{"status" => "passed"}}}

      assert ReviewReportHelpers.section_note(task, :patterns) == nil
    end

    test "returns nil for an empty or whitespace-only note" do
      assert ReviewReportHelpers.section_note(
               %{reviewer_result: %{"patterns" => %{"note" => ""}}},
               :patterns
             ) == nil

      assert ReviewReportHelpers.section_note(
               %{reviewer_result: %{"patterns" => %{"note" => "   \n\t"}}},
               :patterns
             ) == nil
    end

    test "returns nil for a non-binary note instead of raising" do
      assert ReviewReportHelpers.section_note(
               %{reviewer_result: %{"patterns" => %{"note" => ["a", "list"]}}},
               :patterns
             ) == nil

      assert ReviewReportHelpers.section_note(
               %{reviewer_result: %{"patterns" => %{"note" => %{"nested" => "map"}}}},
               :patterns
             ) == nil
    end

    test "returns nil for an atom outside the four-section domain" do
      task = %{reviewer_result: %{"patterns" => %{"note" => "present"}}}

      assert ReviewReportHelpers.section_note(task, :acceptance_criteria) == nil
    end
  end

  describe "testing_strategy_breakdown/1" do
    @full_strategy %{
      "unit_tests" => ["case one", "case two", "case three"],
      "integration_tests" => ["end to end flow"],
      "manual_tests" => ["check it in the browser"],
      "edge_cases" => ["empty board"],
      "coverage_target" => "all new functions covered"
    }

    test "returns one entry per category in fixed order with the items" do
      task = %{
        testing_strategy: @full_strategy,
        reviewer_result: %{"testing_strategy" => %{"status" => "passed"}}
      }

      breakdown = ReviewReportHelpers.testing_strategy_breakdown(task)

      assert Enum.map(breakdown, & &1.key) == [
               "unit_tests",
               "integration_tests",
               "manual_tests",
               "edge_cases",
               "coverage_target"
             ]

      unit = hd(breakdown)
      assert unit.items == ["case one", "case two", "case three"]
      assert unit.label == "Unit tests"
    end

    test "categories inherit the section-level verdict when no per-category status exists" do
      task = %{
        testing_strategy: @full_strategy,
        reviewer_result: %{"testing_strategy" => %{"status" => "passed"}}
      }

      assert ReviewReportHelpers.testing_strategy_breakdown(task)
             |> Enum.all?(&(&1.passed == true))
    end

    test "a per-category reviewer status overrides the section-level verdict" do
      task = %{
        testing_strategy: @full_strategy,
        reviewer_result: %{
          "testing_strategy" => %{
            "status" => "passed",
            "categories" => %{"edge_cases" => %{"status" => "failed"}}
          }
        }
      }

      breakdown = ReviewReportHelpers.testing_strategy_breakdown(task)
      edge = Enum.find(breakdown, &(&1.key == "edge_cases"))
      unit = Enum.find(breakdown, &(&1.key == "unit_tests"))

      assert edge.passed == false
      assert unit.passed == true
    end

    test "coverage_target string becomes a one-item list" do
      task = %{testing_strategy: %{"coverage_target" => "everything"}, reviewer_result: nil}

      assert [%{key: "coverage_target", items: ["everything"]}] =
               ReviewReportHelpers.testing_strategy_breakdown(task)
    end

    test "empty categories and blank entries are skipped" do
      task = %{
        testing_strategy: %{
          "unit_tests" => ["real case", "", "  "],
          "integration_tests" => [],
          "manual_tests" => nil,
          "coverage_target" => "   "
        },
        reviewer_result: nil
      }

      assert [%{key: "unit_tests", items: ["real case"]}] =
               ReviewReportHelpers.testing_strategy_breakdown(task)
    end

    test "returns [] when the task has no testing strategy" do
      assert ReviewReportHelpers.testing_strategy_breakdown(%{
               testing_strategy: nil,
               reviewer_result: nil
             }) == []

      assert ReviewReportHelpers.testing_strategy_breakdown(%{
               testing_strategy: %{},
               reviewer_result: nil
             }) == []
    end

    test "passed is nil when no reviewer verdict exists at any level" do
      task = %{testing_strategy: %{"unit_tests" => ["a case"]}, reviewer_result: nil}

      assert [%{passed: nil}] = ReviewReportHelpers.testing_strategy_breakdown(task)
    end

    test "tolerates string-keyed task maps" do
      task = %{
        "testing_strategy" => %{"unit_tests" => ["a case"]},
        "reviewer_result" => %{"testing_strategy" => %{"status" => "passed"}}
      }

      assert [%{key: "unit_tests", passed: true}] =
               ReviewReportHelpers.testing_strategy_breakdown(task)
    end
  end

  describe "review_status_pill/1 (moved from ReviewLive, W1441)" do
    test "approved status renders the approved pill" do
      pill = ReviewReportHelpers.review_status_pill(%{reviewer_result: %{"status" => "approved"}})
      assert pill.status == "approved"
      assert pill.icon == "hero-check-circle"
      assert pill.style =~ "--st-done"
    end

    test "changes_requested status renders the changes-requested pill" do
      pill =
        ReviewReportHelpers.review_status_pill(%{
          reviewer_result: %{"status" => "changes_requested"}
        })

      assert pill.status == "changes_requested"
      assert pill.icon == "hero-arrow-uturn-left"
      assert pill.style =~ "--st-blocked"
    end

    test "dispatched-but-no-status renders the neutral unavailable pill (D56)" do
      pill = ReviewReportHelpers.review_status_pill(%{reviewer_result: %{"dispatched" => true}})
      assert pill.status == "unavailable"
      assert pill.icon == "hero-question-mark-circle"
    end

    test "returns nil when the reviewer was skipped/never ran" do
      assert ReviewReportHelpers.review_status_pill(%{reviewer_result: %{}}) == nil
      assert ReviewReportHelpers.review_status_pill(%{}) == nil
    end
  end

  describe "verdict_tone_style/1 and verdict_icon/2 (moved from ReviewLive, W1441)" do
    test "tone style is green for true, red for false, neutral otherwise" do
      assert ReviewReportHelpers.verdict_tone_style(true) =~ "--st-done"
      assert ReviewReportHelpers.verdict_tone_style(false) =~ "--st-blocked"
      assert ReviewReportHelpers.verdict_tone_style(nil) =~ "--surface-2"
    end

    test "security section keeps shield iconography" do
      assert ReviewReportHelpers.verdict_icon(:security_considerations, false) ==
               "hero-shield-exclamation"

      assert ReviewReportHelpers.verdict_icon(:security_considerations, true) ==
               "hero-shield-check"
    end

    test "generic sections use pass/fail/unknown circles" do
      assert ReviewReportHelpers.verdict_icon(:testing_strategy, true) == "hero-check-circle"
      assert ReviewReportHelpers.verdict_icon(:patterns, false) == "hero-x-circle"
      assert ReviewReportHelpers.verdict_icon(:pitfalls, nil) == "hero-question-mark-circle"
    end
  end

  describe "category_status_key/1 and category_verdict_label/1 (moved from ReviewLive, W1441)" do
    test "status key maps the boolean verdict" do
      assert ReviewReportHelpers.category_status_key(true) == "passed"
      assert ReviewReportHelpers.category_status_key(false) == "failed"
      assert ReviewReportHelpers.category_status_key(nil) == "not_assessed"
    end

    test "verdict label maps the boolean verdict" do
      assert ReviewReportHelpers.category_verdict_label(true) == "passed"
      assert ReviewReportHelpers.category_verdict_label(false) == "failed"
      assert ReviewReportHelpers.category_verdict_label(nil) == "not assessed"
    end
  end

  describe "section_status_key/1 and review_check_rows/1 (moved from ReviewLive, W1441)" do
    test "section_status_key reflects the section verdict" do
      passed = %{
        reviewer_result: %{"testing_strategy" => %{"status" => "passed"}},
        review_report: nil
      }

      failed = %{
        reviewer_result: %{"testing_strategy" => %{"status" => "failed"}},
        review_report: nil
      }

      absent = %{reviewer_result: %{}, review_report: nil}

      assert ReviewReportHelpers.section_status_key(passed, :testing_strategy) == "passed"
      assert ReviewReportHelpers.section_status_key(failed, :testing_strategy) == "failed"
      assert ReviewReportHelpers.section_status_key(absent, :testing_strategy) == "not_assessed"
    end

    test "review_check_rows returns rows for sections with a value and none for a legacy task" do
      task = %{
        reviewer_result: %{
          "testing_strategy" => %{"status" => "passed"},
          "patterns" => %{"status" => "passed"}
        },
        review_report: nil
      }

      rows = ReviewReportHelpers.review_check_rows(task)
      assert Enum.any?(rows, &(&1.section == :testing_strategy and &1.status == "passed"))

      empty = %{reviewer_result: %{}, review_report: nil}
      assert ReviewReportHelpers.review_check_rows(empty) == []
    end
  end

  describe "security_considerations_note/1 (moved from ReviewLive, W1441)" do
    test "returns the reviewer's security note when present" do
      task = %{
        reviewer_result: %{"security_considerations" => %{"note" => "Scoped to the board."}},
        review_report: nil
      }

      assert ReviewReportHelpers.security_considerations_note(task) == "Scoped to the board."
    end

    test "returns nil when absent or blank" do
      assert ReviewReportHelpers.security_considerations_note(%{
               reviewer_result: %{},
               review_report: nil
             }) ==
               nil
    end
  end

  describe "security_considerations_breakdown/1 (W1867)" do
    test "returns one normalized entry per well-formed consideration" do
      task = %{
        reviewer_result: %{
          "security_considerations" => %{
            "status" => "failed",
            "considerations" => [
              %{"consideration" => "Untrusted status never atom-ized", "status" => "mitigated"},
              %{
                "consideration" => "Diff text unbounded",
                "status" => "partial",
                "evidence" => "capped at 500 lines"
              }
            ]
          }
        }
      }

      assert ReviewReportHelpers.security_considerations_breakdown(task) == [
               %{
                 consideration: "Untrusted status never atom-ized",
                 status: "mitigated",
                 detail: nil
               },
               %{
                 consideration: "Diff text unbounded",
                 status: "partial",
                 detail: "capped at 500 lines"
               }
             ]
    end

    test "accepts a string-keyed reviewer_result" do
      task = %{
        "reviewer_result" => %{
          "security_considerations" => %{
            "considerations" => [%{"consideration" => "a", "status" => "unmitigated"}]
          }
        }
      }

      assert [%{consideration: "a", status: "unmitigated"}] =
               ReviewReportHelpers.security_considerations_breakdown(task)
    end

    test "prefers evidence over note for the detail line" do
      task = %{
        reviewer_result: %{
          "security_considerations" => %{
            "considerations" => [
              %{
                "consideration" => "a",
                "status" => "mitigated",
                "evidence" => "ev",
                "note" => "nt"
              }
            ]
          }
        }
      }

      assert [%{detail: "ev"}] = ReviewReportHelpers.security_considerations_breakdown(task)
    end

    test "falls back to note when evidence is absent" do
      task = %{
        reviewer_result: %{
          "security_considerations" => %{
            "considerations" => [%{"consideration" => "a", "status" => "partial", "note" => "nt"}]
          }
        }
      }

      assert [%{detail: "nt"}] = ReviewReportHelpers.security_considerations_breakdown(task)
    end

    test "drops entries whose consideration string is blank or missing" do
      task = %{
        reviewer_result: %{
          "security_considerations" => %{
            "considerations" => [
              %{"consideration" => "   ", "status" => "mitigated"},
              %{"status" => "partial"},
              %{"consideration" => "kept", "status" => "unmitigated"}
            ]
          }
        }
      }

      assert [%{consideration: "kept"}] =
               ReviewReportHelpers.security_considerations_breakdown(task)
    end

    test "carries a nil status through rather than crashing" do
      task = %{
        reviewer_result: %{
          "security_considerations" => %{
            "considerations" => [%{"consideration" => "a"}]
          }
        }
      }

      assert [%{consideration: "a", status: nil}] =
               ReviewReportHelpers.security_considerations_breakdown(task)
    end

    test "returns [] when the breakdown is absent" do
      task = %{reviewer_result: %{"security_considerations" => %{"status" => "passed"}}}
      assert ReviewReportHelpers.security_considerations_breakdown(task) == []
    end

    test "returns [] when considerations is not a list" do
      task = %{
        reviewer_result: %{"security_considerations" => %{"considerations" => "nope"}}
      }

      assert ReviewReportHelpers.security_considerations_breakdown(task) == []
    end

    test "returns [] when security_considerations is absent" do
      task = %{reviewer_result: %{"issues" => []}}
      assert ReviewReportHelpers.security_considerations_breakdown(task) == []
    end

    test "returns [] when reviewer_result is nil" do
      assert ReviewReportHelpers.security_considerations_breakdown(%{reviewer_result: nil}) == []
    end
  end
end
