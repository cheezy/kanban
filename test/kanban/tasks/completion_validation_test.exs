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

  defp error_for(errors, field) do
    Enum.find(errors, fn {f, _msg} -> f == field end)
  end
end
