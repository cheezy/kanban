defmodule Kanban.Tasks.WorkflowSteps do
  @moduledoc """
  The write-side contract for `Kanban.Tasks.Task.workflow_steps` (D239).

  Owns two things: the shape check that runs before a completion is persisted,
  and the canonical `reason_code` vocabulary that makes the skip breakdown in
  `Kanban.Tasks.Compliance.skip_reasons/1` aggregate instead of fragmenting.

  Extracted from `Kanban.Tasks.AgentWorkflow`, which was over the 500-line
  guideline in `AGENTS.md` and had no reason to own a vocabulary that the
  read side and the API schema documentation both need to reference.

  ## The problem this solves

  `reason` is required when a step is skipped, but it is only required to be a
  string, so agents write free prose. Measured against the production board at
  the time of writing: **73 skipped entries produced 58 distinct reason
  strings, averaging 145 characters**. Grouping verbatim is very nearly one row
  per entry — a breakdown with no aggregation in it.

  `Kanban.Tasks.Compliance` deliberately declined to fix this on the read side
  (D233): any prose-to-bucket mapping written today is fitted to the agents
  that happen to exist now and silently mis-files wording it did not
  anticipate. So the fix belongs here, where the value is written.

  ## The vocabulary, derived rather than invented

  The six codes below were derived by classifying all 73 skipped entries
  persisted on the production board, not by inventing terms. Each code is a
  cluster that actually occurred, with its observed frequency:

    * `:decision_matrix_skip` (21) — the Step 3 decision matrix says this row
      skips this step. The single most common skip, and the only one that is
      purely mechanical.
    * `:ran_inline` (21) — the step's work was performed, but in the main loop
      rather than by a dispatched subagent. Covers "explored inline",
      "implemented inline", and self-reported exploration.
    * `:hook_body_empty` (16) — plugin mode: the `.stride.md` section body is
      empty, so the hook is a no-op. Only reachable for `after_doing` and
      `before_review`.
    * `:subsumed_by_task_spec` (10) — the task specification itself already
      settled what this step would have decided.
    * `:folded_into_prior_step` (3) — an earlier step already produced this
      step's output, most often an explorer that returned a complete plan.
    * `:matrix_deviation` (2) — the matrix called for this step and it was
      deliberately not run. Recorded as a deviation rather than dressed up as
      a sanctioned skip, which is the distinction worth preserving: it is the
      one code that marks non-compliance rather than compliance.

  ## Why this is additive, and why nothing is rejected that used to be accepted

  `reason_code` is **optional** and sits alongside the free-text `reason`,
  which stays required-when-skipped and stays unconstrained. That shape is
  deliberate: rejecting a non-canonical `reason` would be a `422` on a
  completion, which locks out every agent — including other runtimes' plugins —
  that has not been updated. The code aggregates; the prose stays readable on
  the task detail page and keeps a novel skip reason visible verbatim instead
  of vanishing into a bucket.

  A `reason_code` that is present but not recognized IS rejected. That is the
  deliberate half of the contract: a typo must not open its own silent bucket,
  which is the failure mode this whole defect is an instance of.

  ## Decision: `name` is NOT constrained (D239)

  D239 also asked whether `name` should be constrained to the six canonical
  step names. **It is not, and that is a decision rather than an omission.**

  The measured evidence points both ways and back-compat wins:

    * The production board carries **only** the six canonical names — 264
      entries, 44 of each, zero deviation. There is no fragmentation there to
      fix, so a constraint would buy nothing on the data that actually feeds
      the dashboard.
    * `kanban_dev` additionally carries five PascalCase names from a different
      runtime (`Explore`, `Plan`, `Implement`, `Review`, `Verify`). Those rows
      exist today. Constraining `name` would `422` completions from whatever
      writes them, mid-flight, for no aggregation benefit.

  So `name` keeps its `is_binary/1` check. `Compliance.step_dispatch_rates/1`
  continues to group by whatever was written, which keeps an invented or
  misspelled step visible as its own row — the fragmentation stays observable
  rather than being hidden behind a rejection.
  """

  @canonical_step_names ~w(explorer planner implementation reviewer after_doing before_review)

  @skip_reason_codes [
    :decision_matrix_skip,
    :ran_inline,
    :hook_body_empty,
    :subsumed_by_task_spec,
    :folded_into_prior_step,
    :matrix_deviation
  ]

  @doc """
  The exhaustive list of allowed `workflow_steps[].reason_code` atoms.

  Single source of truth for the API layer, the schema documentation served at
  `GET /api/agent/onboarding`, tests, and every plugin skill — the same list
  must appear byte-identical in each so server-side aggregation groups
  identical codes.

  Distinct from `Kanban.Tasks.CompletionValidation.skip_reasons/0`, which
  constrains `explorer_result`/`reviewer_result` and was derived for a
  different decision. That enum covers two phases; this one covers six, and
  the observed reasons do not overlap.
  """
  def skip_reason_codes, do: @skip_reason_codes

  @doc """
  The six canonical `workflow_steps[].name` values, in workflow order.

  Advisory only — `name` is deliberately not constrained (see the moduledoc).
  Exposed for documentation and tests rather than for rejection.
  """
  def canonical_step_names, do: @canonical_step_names

  @doc """
  Validates the shape of a `workflow_steps` param onto the given changeset.

  Adds an error to `:workflow_steps` when the value is not a list, when any
  entry is not a well-formed step map, or when any entry carries an
  unrecognized `reason_code`. A `nil` param leaves the changeset untouched so
  omitting the field never blanks a stored value.
  """
  def validate_shape(changeset, params) do
    case Map.get(params, "workflow_steps") do
      nil ->
        changeset

      value when is_list(value) ->
        validate_entries(changeset, value)

      _ ->
        Ecto.Changeset.add_error(changeset, :workflow_steps, "must be a list of step maps")
    end
  end

  defp validate_entries(changeset, value) do
    cond do
      not Enum.all?(value, &valid_step?/1) ->
        Ecto.Changeset.add_error(
          changeset,
          :workflow_steps,
          "each entry must be a map with a 'name' key and either duration_ms (when dispatched) or reason (when skipped)"
        )

      not Enum.all?(value, &valid_reason_code?/1) ->
        Ecto.Changeset.add_error(
          changeset,
          :workflow_steps,
          "reason_code must be one of: #{Enum.map_join(@skip_reason_codes, ", ", &to_string/1)}"
        )

      true ->
        changeset
    end
  end

  @doc """
  Returns true when the step map carries the keys its `dispatched` value
  requires. Accepts string- or atom-keyed maps.
  """
  def valid_step?(%{} = step) do
    name = fetch_step_field(step, "name")
    dispatched = fetch_step_field(step, "dispatched")

    cond do
      not is_binary(name) -> false
      dispatched == true -> is_integer(fetch_step_field(step, "duration_ms"))
      dispatched == false -> is_binary(fetch_step_field(step, "reason"))
      true -> false
    end
  end

  def valid_step?(_), do: false

  @doc """
  Returns true when the step either carries no `reason_code` at all — the
  back-compat path every payload written before D239 takes — or carries one
  that is in `skip_reason_codes/0`.
  """
  def valid_reason_code?(%{} = step) do
    case fetch_step_field(step, "reason_code") do
      nil -> true
      code -> recognized_code?(code)
    end
  end

  def valid_reason_code?(_), do: false

  defp recognized_code?(code) when is_atom(code), do: code in @skip_reason_codes

  defp recognized_code?(code) when is_binary(code) do
    # String.to_existing_atom/1 rather than String.to_atom/1: an unrecognized
    # code from an API payload must never mint an atom (atom-table exhaustion).
    # The rescue turns "no such atom" into the same rejection as "known atom,
    # wrong list", so both land on the deliberate-rejection path.
    String.to_existing_atom(code) in @skip_reason_codes
  rescue
    ArgumentError -> false
  end

  defp recognized_code?(_), do: false

  defp fetch_step_field(step, key) do
    case Map.fetch(step, key) do
      {:ok, value} -> value
      :error -> Map.get(step, safe_existing_atom(key))
    end
  end

  defp safe_existing_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end
end
