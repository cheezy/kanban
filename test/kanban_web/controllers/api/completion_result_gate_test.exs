defmodule KanbanWeb.API.CompletionResultGateTest do
  use ExUnit.Case, async: false

  alias KanbanWeb.API.CompletionResultGate

  # Several tests intentionally drive the gate down its reject/grace paths,
  # which emit "stride.completion.validation_failed" warnings by design.
  # Capture them so passing runs stay quiet; ExUnit still prints captured
  # logs when a test fails.
  @moduletag :capture_log

  @summary "A substantive summary explaining what was checked in detail."

  # CompletionResultGate.strict?/0 reads the `:strict_completion_validation`
  # Application env key. This is the same key flipped by the
  # `STRIDE_STRICT_COMPLETION_VALIDATION=true` env-var branch in
  # `config/runtime.exs`. Asserting that the two ends of that wire agree
  # is the only practical way to catch the class of bug where the runtime
  # toggle sets the wrong value (which is exactly what motivated this
  # test — the prior block hard-coded `false` on the truthy branch).
  describe "strict?/0" do
    setup do
      previous = Application.get_env(:kanban, :strict_completion_validation, false)
      on_exit(fn -> Application.put_env(:kanban, :strict_completion_validation, previous) end)
      :ok
    end

    test "returns false when the application env is false (grace mode)" do
      Application.put_env(:kanban, :strict_completion_validation, false)
      refute CompletionResultGate.strict?()
    end

    test "returns true when the application env is true (strict mode)" do
      Application.put_env(:kanban, :strict_completion_validation, true)
      assert CompletionResultGate.strict?()
    end

    test "defaults to false when the key is absent" do
      Application.delete_env(:kanban, :strict_completion_validation)
      refute CompletionResultGate.strict?()
    end
  end

  # W1070: the fully-populated + consistent review contract rejects UNCONDITIONALLY
  # (independent of the grace flag); only legacy shape nits follow the grace path.
  describe "gate/2 — unconditional review contract (W1070)" do
    test "a completeness failure rejects with grace mode OFF" do
      request = build_request(thin_reviewer())
      assert {:reject, body} = CompletionResultGate.gate(request, strict: false)
      fields = reviewer_failure_fields(body)
      assert "project_checks" in fields
    end

    test "a completeness failure rejects with strict mode ON" do
      request = build_request(thin_reviewer())
      assert {:reject, body} = CompletionResultGate.gate(request, strict: true)
      fields = reviewer_failure_fields(body)
      assert "project_checks" in fields
    end

    test "a short project_checks does NOT reject — the caller's checklist may be short" do
      # Regression guard for the cross-tenant defect: a caller whose
      # CODE-REVIEW.md has one bullet is complete, not truncated.
      request =
        full_reviewer()
        |> Map.put("project_checks", [%{"check" => "x", "status" => "met"}])
        |> build_request()

      assert :ok = CompletionResultGate.gate(request, strict: true)
    end

    test "an empty project_checks does NOT reject — the caller has no CODE-REVIEW.md" do
      request =
        full_reviewer()
        |> Map.put("project_checks", [])
        |> build_request()

      assert :ok = CompletionResultGate.gate(request, strict: true)
    end

    test "a purely legacy-shape difference still follows the grace path (warn, not reject)" do
      # A complete review (contract satisfied) with only a bad schema_version FORMAT
      # is a shape nit — grace warns, strict rejects.
      shape_nit = Map.put(full_reviewer(), "schema_version", "not-a-semver")
      request = build_request(shape_nit)

      assert {:warn, _failures} = CompletionResultGate.gate(request, strict: false)
      assert {:reject, _body} = CompletionResultGate.gate(request, strict: true)
    end

    test "a valid fully-populated report passes in both modes" do
      request = build_request(full_reviewer())
      assert :ok = CompletionResultGate.gate(request, strict: false)
      assert :ok = CompletionResultGate.gate(request, strict: true)
    end
  end

  # W1102: the acceptance-criteria count consistency check is grace-GATED — it
  # warns in grace mode and rejects only in strict mode (unlike the W1070
  # contract above, which rejects unconditionally).
  describe "gate/2 — acceptance-criteria count consistency (W1102)" do
    test "an over-count warns in grace mode (does not reject)" do
      request = build_request(over_count_reviewer())

      assert {:warn, failures} =
               CompletionResultGate.gate(request, strict: false, task: task_with_one_criterion())

      assert "reviewer_result" in Enum.map(failures, & &1.field)
    end

    test "an over-count rejects with strict mode ON" do
      request = build_request(over_count_reviewer())

      assert {:reject, body} =
               CompletionResultGate.gate(request, strict: true, task: task_with_one_criterion())

      assert "acceptance_criteria" in reviewer_failure_fields(body) or
               "acceptance_criteria_checked" in reviewer_failure_fields(body)
    end

    test "a count-consistent review passes in both modes" do
      request = build_request(full_reviewer())
      task = %{acceptance_criteria: "X"}

      assert :ok = CompletionResultGate.gate(request, strict: false, task: task)
      assert :ok = CompletionResultGate.gate(request, strict: true, task: task)
    end

    test "with no task supplied, the count check is skipped" do
      request = build_request(over_count_reviewer())
      assert :ok = CompletionResultGate.gate(request, strict: false)
    end
  end

  # W1866: the nested security_considerations.considerations[] consistency check
  # is grace-GATED — a partial/unmitigated item with a non-failed verdict warns in
  # grace mode and rejects only in strict mode.
  describe "gate/2 — considerations[] consistency (W1866)" do
    test "an inconsistent breakdown warns in grace mode (does not reject)" do
      request = build_request(inconsistent_considerations_reviewer())

      assert {:warn, failures} = CompletionResultGate.gate(request, strict: false)
      assert "reviewer_result" in Enum.map(failures, & &1.field)
    end

    test "an inconsistent breakdown rejects with strict mode ON" do
      request = build_request(inconsistent_considerations_reviewer())

      assert {:reject, body} = CompletionResultGate.gate(request, strict: true)
      assert "security_considerations" in reviewer_failure_fields(body)
    end

    test "a consistent breakdown (partial item with a failed verdict) passes in both modes" do
      request = build_request(consistent_considerations_reviewer())

      assert :ok = CompletionResultGate.gate(request, strict: false)
      assert :ok = CompletionResultGate.gate(request, strict: true)
    end

    test "a fully-mitigated breakdown passes in both modes" do
      reviewer =
        Map.put(full_reviewer(), "security_considerations", %{
          "status" => "passed",
          "considerations" => [%{"consideration" => "scoped to board", "status" => "mitigated"}]
        })

      request = build_request(reviewer)

      assert :ok = CompletionResultGate.gate(request, strict: false)
      assert :ok = CompletionResultGate.gate(request, strict: true)
    end
  end

  # (D231) End to end through the gate, not just the validator. Unlike the two
  # grace-gated checks above, this one is part of the unconditional contract:
  # a stubbed note is malformed output, not a consistency warning, so it must
  # reject in grace mode too — a payload that only rejects under strict mode
  # would let the stub through on every deployment that has not enabled it.
  describe "gate/2 — failed section verdicts must carry a substantive note (D231)" do
    test "a stubbed note on a failed verdict is refused in both modes" do
      request = build_request(stubbed_note_reviewer())

      assert {:reject, body} = CompletionResultGate.gate(request, strict: false)
      assert "pitfalls" in reviewer_failure_fields(body)

      assert {:reject, _} = CompletionResultGate.gate(request, strict: true)
    end

    test "the refusal names the offending section" do
      request = build_request(stubbed_note_reviewer())

      assert {:reject, body} = CompletionResultGate.gate(request, strict: false)

      message =
        body.failures
        |> Enum.find(&(&1.field == "reviewer_result"))
        |> Map.fetch!(:errors)
        |> Enum.find(&(&1.field == "pitfalls"))
        |> Map.fetch!(:message)

      assert message =~ "pitfalls.note"
    end

    test "a substantive note on the same failed verdict passes both modes" do
      reviewer =
        Map.put(full_reviewer(), "pitfalls", %{
          "status" => "failed",
          "note" => "A direct Ecto query was introduced in the LiveView, which pitfall 1 forbids."
        })

      request = build_request(reviewer)

      assert :ok = CompletionResultGate.gate(request, strict: false)
      assert :ok = CompletionResultGate.gate(request, strict: true)
    end

    test "an all-passed review with no notes at all is untouched" do
      request = build_request(full_reviewer())

      assert :ok = CompletionResultGate.gate(request, strict: false)
      assert :ok = CompletionResultGate.gate(request, strict: true)
    end
  end

  defp stubbed_note_reviewer do
    Map.put(full_reviewer(), "pitfalls", %{
      "status" => "failed",
      "note" => "placeholder placeholder placeholder"
    })
  end

  defp inconsistent_considerations_reviewer do
    Map.put(full_reviewer(), "security_considerations", %{
      "status" => "passed",
      "considerations" => [%{"consideration" => "input not sanitized", "status" => "unmitigated"}]
    })
  end

  defp consistent_considerations_reviewer do
    Map.put(full_reviewer(), "security_considerations", %{
      "status" => "failed",
      # (D231) A failed verdict now owes a substantive note. This fixture is
      # about considerations[] consistency, so the note is incidental here —
      # but it has to be real, which is the point of the rule.
      "note" =>
        "The first listed consideration is only partially mitigated: input is not sanitized.",
      "considerations" => [%{"consideration" => "input not sanitized", "status" => "partial"}]
    })
  end

  defp task_with_one_criterion, do: %{acceptance_criteria: "Only one criterion"}

  defp over_count_reviewer do
    full_reviewer()
    |> Map.put("acceptance_criteria", [
      %{"criterion" => "X", "status" => "met"},
      %{"criterion" => "Y", "status" => "met"}
    ])
    |> Map.put("acceptance_criteria_checked", 2)
  end

  defp build_request(reviewer) do
    %{"explorer_result" => valid_explorer(), "reviewer_result" => reviewer}
  end

  defp valid_explorer, do: %{"dispatched" => true, "summary" => @summary, "duration_ms" => 12_000}

  defp thin_reviewer do
    %{
      "dispatched" => true,
      "summary" => @summary,
      "duration_ms" => 8_000,
      "acceptance_criteria_checked" => 1,
      "issues_found" => 0
    }
  end

  defp full_reviewer do
    checks = for i <- 1..5, do: %{"check" => "c#{i}", "status" => "met"}

    %{
      "dispatched" => true,
      "summary" => @summary,
      "duration_ms" => 8_000,
      "acceptance_criteria_checked" => 1,
      "issues_found" => 0,
      "status" => "approved",
      "issue_counts" => %{"critical" => 0, "important" => 0, "minor" => 0},
      "issues" => [],
      "acceptance_criteria" => [%{"criterion" => "X", "status" => "met"}],
      "project_checks" => checks,
      "testing_strategy" => %{"status" => "passed"},
      "patterns" => %{"status" => "passed"},
      "pitfalls" => %{"status" => "passed"},
      "security_considerations" => %{"status" => "passed"},
      "schema_version" => "1.0"
    }
  end

  defp reviewer_failure_fields(body) do
    body.failures
    |> Enum.find(%{errors: []}, &(&1.field == "reviewer_result"))
    |> Map.fetch!(:errors)
    |> Enum.map(& &1.field)
  end
end
