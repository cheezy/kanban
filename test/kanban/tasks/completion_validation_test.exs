defmodule Kanban.Tasks.CompletionValidationTest do
  use ExUnit.Case, async: true

  alias Kanban.Tasks.CompletionValidation

  @valid_summary "A substantive summary explaining what was explored in detail."

  describe "skip_reasons/0" do
    test "returns the five allowed atoms" do
      reasons = CompletionValidation.skip_reasons()

      assert length(reasons) == 5
      assert :no_subagent_support in reasons
      assert :small_task_0_1_key_files in reasons
      assert :trivial_change_docs_only in reasons
      assert :self_reported_exploration in reasons
      assert :self_reported_review in reasons
    end
  end

  describe "validate_explorer_result/1 — happy paths" do
    test "accepts dispatched=true with summary and duration_ms" do
      payload = %{"dispatched" => true, "summary" => @valid_summary, "duration_ms" => 12_000}
      assert {:ok, ^payload} = CompletionValidation.validate_explorer_result(payload)
    end

    test "accepts each allowed skip reason as string" do
      for reason <- CompletionValidation.skip_reasons() do
        payload = %{
          "dispatched" => false,
          "reason" => to_string(reason),
          "summary" => @valid_summary
        }

        assert {:ok, _} = CompletionValidation.validate_explorer_result(payload),
               "expected #{reason} to be accepted"
      end
    end

    test "accepts reason as atom" do
      payload = %{
        "dispatched" => false,
        "reason" => :no_subagent_support,
        "summary" => @valid_summary
      }

      assert {:ok, _} = CompletionValidation.validate_explorer_result(payload)
    end

    test "accepts summary at exactly 40 non-whitespace characters (boundary: minimum)" do
      exact = String.duplicate("x", 40)
      payload = %{"dispatched" => true, "summary" => exact, "duration_ms" => 100}
      assert {:ok, _} = CompletionValidation.validate_explorer_result(payload)
    end

    test "accepts summary at 41 non-whitespace characters (boundary: minimum+1)" do
      one_over = String.duplicate("x", 41)
      payload = %{"dispatched" => true, "summary" => one_over, "duration_ms" => 100}
      assert {:ok, _} = CompletionValidation.validate_explorer_result(payload)
    end

    test "counts non-whitespace characters only" do
      padded = "x " |> String.duplicate(40) |> String.trim()
      payload = %{"dispatched" => true, "summary" => padded, "duration_ms" => 100}
      assert {:ok, _} = CompletionValidation.validate_explorer_result(payload)
    end
  end

  describe "validate_explorer_result/1 — rejections" do
    test "rejects summary under 40 non-whitespace characters" do
      short = String.duplicate("x", 39)
      payload = %{"dispatched" => true, "summary" => short, "duration_ms" => 100}
      assert {:error, errors} = CompletionValidation.validate_explorer_result(payload)
      assert error_for(errors, :summary)
    end

    test "rejects whitespace-only summary" do
      payload = %{"dispatched" => true, "summary" => "   \n\t  ", "duration_ms" => 100}
      assert {:error, errors} = CompletionValidation.validate_explorer_result(payload)
      assert error_for(errors, :summary)
    end

    test "rejects unknown skip reason" do
      payload = %{
        "dispatched" => false,
        "reason" => "because_i_said_so",
        "summary" => @valid_summary
      }

      assert {:error, errors} = CompletionValidation.validate_explorer_result(payload)
      assert error_for(errors, :reason)
    end

    test "rejects integer reason" do
      payload = %{"dispatched" => false, "reason" => 42, "summary" => @valid_summary}
      assert {:error, errors} = CompletionValidation.validate_explorer_result(payload)
      assert error_for(errors, :reason)
    end

    test "rejects dispatched=false without reason" do
      payload = %{"dispatched" => false, "summary" => @valid_summary}
      assert {:error, errors} = CompletionValidation.validate_explorer_result(payload)
      assert error_for(errors, :reason)
    end

    test "rejects atom that exists but is not in skip_reasons" do
      payload = %{
        "dispatched" => false,
        "reason" => :__some_other_atom__,
        "summary" => @valid_summary
      }

      assert {:error, errors} = CompletionValidation.validate_explorer_result(payload)
      assert error_for(errors, :reason)
    end

    test "rejects missing dispatched" do
      payload = %{"summary" => @valid_summary, "duration_ms" => 100}
      assert {:error, errors} = CompletionValidation.validate_explorer_result(payload)
      assert error_for(errors, :dispatched)
    end

    test "rejects non-boolean dispatched" do
      payload = %{"dispatched" => "yes", "summary" => @valid_summary, "duration_ms" => 100}
      assert {:error, errors} = CompletionValidation.validate_explorer_result(payload)
      assert error_for(errors, :dispatched)
    end

    test "rejects dispatched=true without duration_ms" do
      payload = %{"dispatched" => true, "summary" => @valid_summary}
      assert {:error, errors} = CompletionValidation.validate_explorer_result(payload)
      assert error_for(errors, :duration_ms)
    end

    test "rejects negative duration_ms" do
      payload = %{"dispatched" => true, "summary" => @valid_summary, "duration_ms" => -1}
      assert {:error, errors} = CompletionValidation.validate_explorer_result(payload)
      assert error_for(errors, :duration_ms)
    end

    test "rejects non-integer duration_ms" do
      payload = %{"dispatched" => true, "summary" => @valid_summary, "duration_ms" => "100"}
      assert {:error, errors} = CompletionValidation.validate_explorer_result(payload)
      assert error_for(errors, :duration_ms)
    end

    test "rejects nil input" do
      assert {:error, [{:result, _}]} = CompletionValidation.validate_explorer_result(nil)
    end

    test "rejects non-map input" do
      assert {:error, [{:result, _}]} = CompletionValidation.validate_explorer_result("oops")
    end

    test "empty map produces errors for dispatched and summary" do
      assert {:error, errors} = CompletionValidation.validate_explorer_result(%{})
      fields = Enum.map(errors, &elem(&1, 0))
      assert :dispatched in fields
      assert :summary in fields
    end
  end

  describe "validate_reviewer_result/1" do
    test "accepts dispatched=true with full reviewer fields" do
      payload = %{
        "dispatched" => true,
        "summary" => @valid_summary,
        "duration_ms" => 8_000,
        "acceptance_criteria_checked" => 5,
        "issues_found" => 0
      }

      assert {:ok, _} = CompletionValidation.validate_reviewer_result(payload)
    end

    test "rejects dispatched=true missing acceptance_criteria_checked" do
      payload = %{
        "dispatched" => true,
        "summary" => @valid_summary,
        "duration_ms" => 8_000,
        "issues_found" => 0
      }

      assert {:error, errors} = CompletionValidation.validate_reviewer_result(payload)
      assert error_for(errors, :acceptance_criteria_checked)
    end

    test "rejects dispatched=true missing issues_found" do
      payload = %{
        "dispatched" => true,
        "summary" => @valid_summary,
        "duration_ms" => 8_000,
        "acceptance_criteria_checked" => 5
      }

      assert {:error, errors} = CompletionValidation.validate_reviewer_result(payload)
      assert error_for(errors, :issues_found)
    end

    test "rejects negative acceptance_criteria_checked" do
      payload = %{
        "dispatched" => true,
        "summary" => @valid_summary,
        "duration_ms" => 8_000,
        "acceptance_criteria_checked" => -1,
        "issues_found" => 0
      }

      assert {:error, errors} = CompletionValidation.validate_reviewer_result(payload)
      assert error_for(errors, :acceptance_criteria_checked)
    end

    test "accepts self_reported_review skip with substantive summary" do
      payload = %{
        "dispatched" => false,
        "reason" => "self_reported_review",
        "summary" => @valid_summary
      }

      assert {:ok, _} = CompletionValidation.validate_reviewer_result(payload)
    end

    test "dispatched=false does not require reviewer counts" do
      payload = %{
        "dispatched" => false,
        "reason" => "no_subagent_support",
        "summary" => @valid_summary
      }

      assert {:ok, _} = CompletionValidation.validate_reviewer_result(payload)
    end
  end

  describe "validate_reviewer_result/1 — structured issues and acceptance_criteria" do
    test "accepts well-formed structured payload" do
      payload = %{
        "dispatched" => true,
        "summary" => @valid_summary,
        "duration_ms" => 8_000,
        "acceptance_criteria_checked" => 2,
        "issues_found" => 2,
        "issues" => [
          %{
            "severity" => "critical",
            "category" => "pitfall",
            "description" => "Bypassed CSRF check"
          },
          %{"severity" => "minor", "category" => "code_quality"}
        ],
        "acceptance_criteria" => [
          %{"criterion" => "Validator accepts arrays", "status" => "met"},
          %{"criterion" => "Status enum enforced", "status" => "not_met"}
        ]
      }

      assert {:ok, _} = CompletionValidation.validate_reviewer_result(payload)
    end

    test "accepts severity and category as atoms" do
      payload =
        base_reviewer_payload()
        |> Map.put("issues", [%{"severity" => :important, "category" => :testing}])

      assert {:ok, _} = CompletionValidation.validate_reviewer_result(payload)
    end

    test "accepts empty issues array" do
      payload = Map.put(base_reviewer_payload(), "issues", [])
      assert {:ok, _} = CompletionValidation.validate_reviewer_result(payload)
    end

    test "accepts empty acceptance_criteria array" do
      payload = Map.put(base_reviewer_payload(), "acceptance_criteria", [])
      assert {:ok, _} = CompletionValidation.validate_reviewer_result(payload)
    end

    test "tolerates unknown fields inside an issue entry" do
      payload =
        Map.put(base_reviewer_payload(), "issues", [
          %{
            "severity" => "minor",
            "category" => "pattern",
            "file" => "lib/foo.ex",
            "line" => 42,
            "future_field" => %{"nested" => true}
          }
        ])

      assert {:ok, _} = CompletionValidation.validate_reviewer_result(payload)
    end

    test "rejects malformed severity enum" do
      payload =
        Map.put(base_reviewer_payload(), "issues", [
          %{"severity" => "blocker", "category" => "pitfall"}
        ])

      assert {:error, errors} = CompletionValidation.validate_reviewer_result(payload)
      assert {_field, msg} = error_for(errors, :issue_severity)
      assert msg =~ "issues[0]"
      assert msg =~ "critical, important, minor"
    end

    test "rejects malformed category enum" do
      payload =
        Map.put(base_reviewer_payload(), "issues", [
          %{"severity" => "minor", "category" => "performance"}
        ])

      assert {:error, errors} = CompletionValidation.validate_reviewer_result(payload)
      assert {_field, msg} = error_for(errors, :issue_category)
      assert msg =~ "issues[0]"
    end

    test "rejects issue entry missing severity" do
      payload = Map.put(base_reviewer_payload(), "issues", [%{"category" => "pitfall"}])

      assert {:error, errors} = CompletionValidation.validate_reviewer_result(payload)
      assert {_field, msg} = error_for(errors, :issue_severity)
      assert msg =~ "missing severity"
    end

    test "rejects non-map issue entry" do
      payload = Map.put(base_reviewer_payload(), "issues", ["not a map"])
      assert {:error, errors} = CompletionValidation.validate_reviewer_result(payload)
      assert {_field, msg} = error_for(errors, :issue_entry)
      assert msg =~ "issues[0]"
    end

    test "rejects non-list issues field" do
      payload = Map.put(base_reviewer_payload(), "issues", "not a list")
      assert {:error, errors} = CompletionValidation.validate_reviewer_result(payload)
      assert error_for(errors, :issues)
    end

    test "rejects malformed acceptance_criterion status with space form" do
      payload =
        Map.put(base_reviewer_payload(), "acceptance_criteria", [
          %{"criterion" => "Status enum", "status" => "not met"}
        ])

      assert {:error, errors} = CompletionValidation.validate_reviewer_result(payload)
      assert {_field, msg} = error_for(errors, :criterion_status)
      assert msg =~ "acceptance_criteria[0]"
      assert msg =~ "met, not_met"
    end

    test "rejects acceptance_criterion missing status" do
      payload =
        Map.put(base_reviewer_payload(), "acceptance_criteria", [
          %{"criterion" => "Status enum"}
        ])

      assert {:error, errors} = CompletionValidation.validate_reviewer_result(payload)
      assert {_field, msg} = error_for(errors, :criterion_status)
      assert msg =~ "missing status"
    end

    test "rejects non-list acceptance_criteria field" do
      payload = Map.put(base_reviewer_payload(), "acceptance_criteria", %{"oops" => true})
      assert {:error, errors} = CompletionValidation.validate_reviewer_result(payload)
      assert error_for(errors, :acceptance_criteria)
    end

    test "collects errors from second entry when first is well-formed" do
      payload =
        Map.put(base_reviewer_payload(), "issues", [
          %{"severity" => "critical", "category" => "pitfall"},
          %{"severity" => "wrong", "category" => "pattern"}
        ])

      assert {:error, errors} = CompletionValidation.validate_reviewer_result(payload)
      severity_errors = Enum.filter(errors, fn {f, _} -> f == :issue_severity end)
      assert length(severity_errors) == 1
      assert {_field, msg} = hd(severity_errors)
      assert msg =~ "issues[1]"
    end
  end

  describe "validate_reviewer_result/1 — section verdicts and schema_version" do
    test "accepts well-formed testing_strategy verdict with notes" do
      payload =
        Map.put(base_reviewer_payload(), "testing_strategy", %{
          "status" => "passed",
          "notes" => "All five required test cases present."
        })

      assert {:ok, _} = CompletionValidation.validate_reviewer_result(payload)
    end

    test "accepts patterns and pitfalls verdicts together" do
      payload =
        base_reviewer_payload()
        |> Map.put("patterns", %{"status" => "passed"})
        |> Map.put("pitfalls", %{"status" => "failed", "notes" => "Two pitfalls violated"})

      assert {:ok, _} = CompletionValidation.validate_reviewer_result(payload)
    end

    test "accepts not_assessed status" do
      payload =
        Map.put(base_reviewer_payload(), "patterns", %{"status" => "not_assessed"})

      assert {:ok, _} = CompletionValidation.validate_reviewer_result(payload)
    end

    test "accepts empty notes string" do
      payload =
        Map.put(base_reviewer_payload(), "testing_strategy", %{
          "status" => "passed",
          "notes" => ""
        })

      assert {:ok, _} = CompletionValidation.validate_reviewer_result(payload)
    end

    test "rejects malformed status in testing_strategy" do
      payload =
        Map.put(base_reviewer_payload(), "testing_strategy", %{"status" => "ok"})

      assert {:error, errors} = CompletionValidation.validate_reviewer_result(payload)
      assert {_field, msg} = error_for(errors, :testing_strategy_status)
      assert msg =~ "testing_strategy"
      assert msg =~ "passed, failed, not_assessed"
    end

    test "rejects malformed status in patterns" do
      payload = Map.put(base_reviewer_payload(), "patterns", %{"status" => "great"})
      assert {:error, errors} = CompletionValidation.validate_reviewer_result(payload)
      assert error_for(errors, :patterns_status)
    end

    test "rejects malformed status in pitfalls" do
      payload = Map.put(base_reviewer_payload(), "pitfalls", %{"status" => "broken"})
      assert {:error, errors} = CompletionValidation.validate_reviewer_result(payload)
      assert error_for(errors, :pitfalls_status)
    end

    test "accepts well-formed security_considerations verdict with notes" do
      payload =
        Map.put(base_reviewer_payload(), "security_considerations", %{
          "status" => "passed",
          "notes" => "Move query scoped to the current user's board; no new input surface."
        })

      assert {:ok, _} = CompletionValidation.validate_reviewer_result(payload)
    end

    test "accepts not_assessed status for security_considerations" do
      payload =
        Map.put(base_reviewer_payload(), "security_considerations", %{"status" => "not_assessed"})

      assert {:ok, _} = CompletionValidation.validate_reviewer_result(payload)
    end

    test "rejects malformed status in security_considerations" do
      payload =
        Map.put(base_reviewer_payload(), "security_considerations", %{"status" => "ok"})

      assert {:error, errors} = CompletionValidation.validate_reviewer_result(payload)
      assert {_field, msg} = error_for(errors, :security_considerations_status)
      assert msg =~ "security_considerations"
      assert msg =~ "passed, failed, not_assessed"
    end

    test "rejects security_considerations verdict that is not a map" do
      payload =
        Map.put(base_reviewer_payload(), "security_considerations", "all good")

      assert {:error, errors} = CompletionValidation.validate_reviewer_result(payload)
      assert {_field, msg} = error_for(errors, :security_considerations_entry)
      assert msg =~ "must be a map"
    end

    test "rejects security_considerations verdict missing status" do
      payload =
        Map.put(base_reviewer_payload(), "security_considerations", %{"notes" => "ok"})

      assert {:error, errors} = CompletionValidation.validate_reviewer_result(payload)
      assert {_field, msg} = error_for(errors, :security_considerations_status)
      assert msg =~ "missing status"
    end

    test "rejects non-string notes for security_considerations" do
      payload =
        Map.put(base_reviewer_payload(), "security_considerations", %{
          "status" => "passed",
          "notes" => 42
        })

      assert {:error, errors} = CompletionValidation.validate_reviewer_result(payload)
      assert {_field, msg} = error_for(errors, :notes)
      assert msg =~ "security_considerations.notes"
    end

    test "absent security_considerations verdict still validates (optional)" do
      assert {:ok, _} = CompletionValidation.validate_reviewer_result(base_reviewer_payload())
    end

    test "rejects section verdict that is not a map" do
      payload = Map.put(base_reviewer_payload(), "testing_strategy", "all good")
      assert {:error, errors} = CompletionValidation.validate_reviewer_result(payload)
      assert {_field, msg} = error_for(errors, :testing_strategy_entry)
      assert msg =~ "must be a map"
    end

    test "rejects section verdict missing status" do
      payload = Map.put(base_reviewer_payload(), "patterns", %{"notes" => "ok"})
      assert {:error, errors} = CompletionValidation.validate_reviewer_result(payload)
      assert {_field, msg} = error_for(errors, :patterns_status)
      assert msg =~ "missing status"
    end

    test "rejects non-string notes" do
      payload =
        Map.put(base_reviewer_payload(), "pitfalls", %{"status" => "passed", "notes" => 42})

      assert {:error, errors} = CompletionValidation.validate_reviewer_result(payload)
      assert {_field, msg} = error_for(errors, :notes)
      assert msg =~ "pitfalls.notes"
    end

    test "accepts schema_version as MAJOR.MINOR" do
      payload = Map.put(base_reviewer_payload(), "schema_version", "1.0")
      assert {:ok, _} = CompletionValidation.validate_reviewer_result(payload)
    end

    test "accepts schema_version as MAJOR.MINOR.PATCH" do
      payload = Map.put(base_reviewer_payload(), "schema_version", "2.3.4")
      assert {:ok, _} = CompletionValidation.validate_reviewer_result(payload)
    end

    test "accepts schema_version with pre-release suffix" do
      payload = Map.put(base_reviewer_payload(), "schema_version", "1.0.0-beta.1")
      assert {:ok, _} = CompletionValidation.validate_reviewer_result(payload)
    end

    test "rejects malformed schema_version" do
      payload = Map.put(base_reviewer_payload(), "schema_version", "v1")
      assert {:error, errors} = CompletionValidation.validate_reviewer_result(payload)
      assert {_field, msg} = error_for(errors, :schema_version)
      assert msg =~ "semver"
    end

    test "rejects non-string schema_version" do
      payload = Map.put(base_reviewer_payload(), "schema_version", 1)
      assert {:error, errors} = CompletionValidation.validate_reviewer_result(payload)
      assert error_for(errors, :schema_version)
    end

    test "accepts payload with all new fields together" do
      payload =
        base_reviewer_payload()
        |> Map.put("schema_version", "1.0")
        |> Map.put("testing_strategy", %{"status" => "passed", "notes" => "5 cases"})
        |> Map.put("patterns", %{"status" => "passed"})
        |> Map.put("pitfalls", %{"status" => "passed", "notes" => "none violated"})
        |> Map.put("security_considerations", %{
          "status" => "passed",
          "notes" => "no new attack surface"
        })
        |> Map.put("issues", [%{"severity" => "minor", "category" => "code_quality"}])
        |> Map.put("acceptance_criteria", [%{"criterion" => "X", "status" => "met"}])

      assert {:ok, _} = CompletionValidation.validate_reviewer_result(payload)
    end

    test "legacy payload (no section verdicts, no schema_version) still validates" do
      assert {:ok, _} = CompletionValidation.validate_reviewer_result(base_reviewer_payload())
    end
  end

  describe "validate_reviewer_result/2 — require_structured_block (D55)" do
    test "accepts a dispatched payload carrying the full structured block" do
      assert {:ok, _} =
               CompletionValidation.validate_reviewer_result(full_structured_payload(),
                 require_structured_block: true
               )
    end

    test "empty issues[] with an approved status is valid, not missing" do
      payload =
        full_structured_payload()
        |> Map.put("issues", [])
        |> Map.put("status", "approved")

      assert {:ok, _} =
               CompletionValidation.validate_reviewer_result(payload,
                 require_structured_block: true
               )
    end

    test "rejects a dispatched legacy-only payload naming every missing field" do
      assert {:error, errors} =
               CompletionValidation.validate_reviewer_result(base_reviewer_payload(),
                 require_structured_block: true
               )

      assert error_for(errors, :issues)
      assert error_for(errors, :acceptance_criteria)
      assert error_for(errors, :status)
      assert error_for(errors, :schema_version)
    end

    test "missing issues[] is reported by name" do
      payload = Map.delete(full_structured_payload(), "issues")

      assert {:error, errors} =
               CompletionValidation.validate_reviewer_result(payload,
                 require_structured_block: true
               )

      assert {_field, msg} = error_for(errors, :issues)
      assert msg =~ "issues"
      refute error_for(errors, :acceptance_criteria)
    end

    test "missing acceptance_criteria[] is reported by name" do
      payload = Map.delete(full_structured_payload(), "acceptance_criteria")

      assert {:error, errors} =
               CompletionValidation.validate_reviewer_result(payload,
                 require_structured_block: true
               )

      assert error_for(errors, :acceptance_criteria)
    end

    test "issue_counts satisfies the status-or-issue_counts requirement" do
      payload =
        full_structured_payload()
        |> Map.delete("status")
        |> Map.put("issue_counts", %{"critical" => 0, "important" => 0, "minor" => 0})

      assert {:ok, _} =
               CompletionValidation.validate_reviewer_result(payload,
                 require_structured_block: true
               )
    end

    test "missing both status and issue_counts is reported" do
      payload =
        full_structured_payload()
        |> Map.delete("status")
        |> Map.delete("issue_counts")

      assert {:error, errors} =
               CompletionValidation.validate_reviewer_result(payload,
                 require_structured_block: true
               )

      assert error_for(errors, :status)
    end

    test "missing schema_version is reported by name" do
      payload = Map.delete(full_structured_payload(), "schema_version")

      assert {:error, errors} =
               CompletionValidation.validate_reviewer_result(payload,
                 require_structured_block: true
               )

      assert error_for(errors, :schema_version)
    end

    test "a dispatched=false skip is unaffected by the structured-block rule" do
      payload = %{
        "dispatched" => false,
        "reason" => "self_reported_review",
        "summary" => @valid_summary
      }

      assert {:ok, _} =
               CompletionValidation.validate_reviewer_result(payload,
                 require_structured_block: true
               )
    end

    test "a present-but-malformed structured field yields one error, not a duplicate presence error" do
      payload = Map.put(full_structured_payload(), "issues", "not a list")

      assert {:error, errors} =
               CompletionValidation.validate_reviewer_result(payload,
                 require_structured_block: true
               )

      issues_errors = Enum.filter(errors, fn {f, _} -> f == :issues end)
      assert length(issues_errors) == 1
      assert {:issues, msg} = hd(issues_errors)
      assert msg =~ "must be a list"
    end

    test "default (require_structured_block: false) leaves legacy-only payloads valid" do
      assert {:ok, _} = CompletionValidation.validate_reviewer_result(base_reviewer_payload())

      assert {:ok, _} =
               CompletionValidation.validate_reviewer_result(base_reviewer_payload(),
                 require_structured_block: false
               )
    end
  end

  describe "validate_changed_files/1" do
    test "rejects nil (D36: never silently NULL the column)" do
      assert {:error, [{:changed_files, message}]} =
               CompletionValidation.validate_changed_files(nil)

      assert message == "must be present (send [] to clear)"
    end

    test "accepts an empty list" do
      assert {:ok, []} = CompletionValidation.validate_changed_files([])
    end

    test "accepts a well-formed entry with diff" do
      entry = %{"path" => "lib/foo.ex", "diff" => sample_diff(3)}
      assert {:ok, [^entry]} = CompletionValidation.validate_changed_files([entry])
    end

    test "accepts an entry without a diff field (legacy per-file entry)" do
      entry = %{"path" => "lib/foo.ex"}
      assert {:ok, [^entry]} = CompletionValidation.validate_changed_files([entry])
    end

    test "accepts the binary-file placeholder string verbatim" do
      entry = %{"path" => "assets/logo.png", "diff" => "[binary file — no diff captured]"}
      assert {:ok, _} = CompletionValidation.validate_changed_files([entry])
    end

    test "accepts an empty-string diff value (edge case — no content captured)" do
      entry = %{"path" => "lib/foo.ex", "diff" => ""}
      assert {:ok, _} = CompletionValidation.validate_changed_files([entry])
    end

    test "accepts a diff at exactly 500 lines (boundary: maximum)" do
      entry = %{"path" => "lib/big.ex", "diff" => sample_diff(500)}
      assert {:ok, _} = CompletionValidation.validate_changed_files([entry])
    end

    test "accepts mixed entries — one with diff, one without" do
      entries = [
        %{"path" => "lib/foo.ex", "diff" => sample_diff(3)},
        %{"path" => "lib/bar.ex"}
      ]

      assert {:ok, ^entries} = CompletionValidation.validate_changed_files(entries)
    end

    test "rejects a non-list value" do
      assert {:error, errors} = CompletionValidation.validate_changed_files(%{"not" => "a list"})
      assert error_for(errors, :changed_files)
    end

    test "rejects a string value" do
      assert {:error, errors} = CompletionValidation.validate_changed_files("lib/foo.ex")
      assert error_for(errors, :changed_files)
    end

    test "rejects an entry that is not a map" do
      assert {:error, errors} = CompletionValidation.validate_changed_files(["lib/foo.ex"])
      assert {_, msg} = error_for(errors, :changed_file_entry)
      assert msg =~ "changed_files[0]"
      assert msg =~ "must be a map"
    end

    test "rejects an entry missing the path field" do
      assert {:error, errors} =
               CompletionValidation.validate_changed_files([%{"diff" => sample_diff(2)}])

      assert {_, msg} = error_for(errors, :changed_file_path)
      assert msg =~ "changed_files[0]"
      assert msg =~ "path"
    end

    test "rejects an entry with a non-string path" do
      assert {:error, errors} = CompletionValidation.validate_changed_files([%{"path" => 42}])
      assert {_, msg} = error_for(errors, :changed_file_path)
      assert msg =~ "changed_files[0]"
    end

    test "rejects an entry with an empty-string path" do
      assert {:error, errors} = CompletionValidation.validate_changed_files([%{"path" => ""}])
      assert {_, msg} = error_for(errors, :changed_file_path)
      assert msg =~ "changed_files[0]"
    end

    test "rejects a non-string diff value" do
      assert {:error, errors} =
               CompletionValidation.validate_changed_files([
                 %{"path" => "lib/foo.ex", "diff" => 1}
               ])

      assert {_, msg} = error_for(errors, :changed_file_diff)
      assert msg =~ "changed_files[0]"
      assert msg =~ "must be a string"
    end

    test "rejects a diff exceeding 500 lines (defensive backstop)" do
      entry = %{"path" => "lib/huge.ex", "diff" => sample_diff(501)}
      assert {:error, errors} = CompletionValidation.validate_changed_files([entry])
      assert {_, msg} = error_for(errors, :changed_file_diff)
      assert msg =~ "changed_files[0]"
      assert msg =~ "500"
    end

    test "reports errors from multiple malformed entries (no short-circuit)" do
      entries = [
        %{"path" => "lib/ok.ex", "diff" => sample_diff(2)},
        %{"path" => 42},
        "not a map",
        %{"path" => "lib/huge.ex", "diff" => sample_diff(501)}
      ]

      assert {:error, errors} = CompletionValidation.validate_changed_files(entries)
      assert error_for(errors, :changed_file_path)
      assert error_for(errors, :changed_file_entry)
      assert error_for(errors, :changed_file_diff)
    end

    test "error messages embed the entry index, not a runtime atom" do
      entries = [
        %{"path" => "lib/ok.ex"},
        %{"path" => 42},
        %{"path" => 99}
      ]

      assert {:error, errors} = CompletionValidation.validate_changed_files(entries)
      messages = Enum.map(errors, fn {_field, msg} -> msg end)
      assert Enum.any?(messages, &(&1 =~ "changed_files[1]"))
      assert Enum.any?(messages, &(&1 =~ "changed_files[2]"))
    end
  end

  defp sample_diff(lines) when lines >= 1 do
    Enum.map_join(1..lines, "\n", fn idx -> "+ line #{idx}" end)
  end

  defp error_for(errors, field) do
    Enum.find(errors, fn {f, _msg} -> f == field end)
  end

  defp base_reviewer_payload do
    %{
      "dispatched" => true,
      "summary" => @valid_summary,
      "duration_ms" => 8_000,
      "acceptance_criteria_checked" => 0,
      "issues_found" => 0
    }
  end

  defp full_structured_payload do
    base_reviewer_payload()
    |> Map.put("status", "approved")
    |> Map.put("issue_counts", %{"critical" => 0, "important" => 0, "minor" => 0})
    |> Map.put("issues", [%{"severity" => "minor", "category" => "code_quality"}])
    |> Map.put("acceptance_criteria", [%{"criterion" => "X", "status" => "met"}])
    |> Map.put("schema_version", "1.0")
  end
end
