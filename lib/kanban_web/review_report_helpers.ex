defmodule KanbanWeb.ReviewReportHelpers do
  @moduledoc """
  Verdict derivation for a task's review, read from the structured
  `reviewer_result` field with a fallback to the legacy markdown
  `review_report`. Centralises that logic so both `KanbanWeb.ReviewLive` and
  the shared `KanbanWeb.ReviewReportPanel` component derive the testing,
  patterns, pitfalls, and security-considerations verdict cells from the same
  source of truth.

  This module owns the structured-field reads, the incomplete-section rules
  and the per-section value/passed accessors. Three siblings carry the rest:
  `MarkdownReport` does the legacy markdown parsing this module delegates to,
  `Tokens` renders the pills and check rows and calls back into the public API
  here, and `Explorer` holds the explorer-result predicates (W2003/W2004).

  Every function is pure. Pass a map that may contain a `:review_report`
  string key (the LiveView struct) or a binary `"review_report"` key (raw
  task map). Functions return `nil` when the section is missing, so callers
  can render an em-dash default.
  """
  use Gettext, backend: KanbanWeb.Gettext

  alias KanbanWeb.ReviewReportHelpers.MarkdownReport

  @incomplete_sections [:testing_strategy, :patterns, :pitfalls, :security_considerations]

  # The completion fields worth rendering, and so the ones that make the
  # Completion section worth showing. The first four are exactly the set the
  # inline guard in `KanbanWeb.TaskLive.ViewComponent` requires today;
  # `completion_notes` widens it by one so a task carrying only notes still
  # renders (W1962). That call site was swapped onto this predicate in W1963,
  # so this list is now the only place the field set is written.
  @completion_fields [
    :completed_at,
    :completed_by,
    :completed_by_agent,
    :completion_summary,
    :completion_notes
  ]

  @doc """
  Returns `true` when a review section is a genuine gap: the task supplied
  content for it, but the review left it missing or `not_assessed`. Drives the
  loud incomplete-section warnings on the Review queue (W1071). A section the
  task did not supply is never flagged — only true gaps. Pure; no DB access.
  """
  def section_incomplete?(task, section) when section in @incomplete_sections do
    section_supplied?(task, section) and
      effective_section_status(task, section) in [
        nil,
        "not_assessed"
      ]
  end

  def section_incomplete?(_task, _section), do: false

  @doc """
  The list of section atoms the task supplied but the review left missing or
  unassessed — the sections the Review queue should warn about.
  """
  def incomplete_sections(task) do
    Enum.filter(@incomplete_sections, &section_incomplete?(task, &1))
  end

  @doc "Human-readable label for an incomplete review section."
  def section_label(:testing_strategy), do: gettext("Testing strategy")
  def section_label(:patterns), do: gettext("Patterns")
  def section_label(:pitfalls), do: gettext("Pitfalls")
  def section_label(:security_considerations), do: gettext("Security considerations")

  @doc """
  The reviewer's note string for one of the four review sections
  (`:testing_strategy`, `:patterns`, `:pitfalls`, `:security_considerations`).

  Reads the structured `reviewer_result[section]["note"]` the reviewer agent
  emits alongside each section status and returns the trimmed string, or
  `nil` when the reviewer_result, the section map, or the note is missing,
  blank, or not a binary. Tolerates both atom-keyed and string-keyed task
  maps, matching the module's other accessors. Pure; no DB access.
  """
  def section_note(task, section) when section in @incomplete_sections do
    case reviewer_result(task) do
      %{} = result -> result |> Map.get(Atom.to_string(section)) |> note_from_section()
      _ -> nil
    end
  end

  def section_note(_task, _section), do: nil

  defp note_from_section(%{"note" => note}) when is_binary(note) do
    case String.trim(note) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp note_from_section(_), do: nil

  @doc """
  True when the task has anything the review panel can render — a non-empty
  structured `reviewer_result` or a non-empty `review_report` markdown
  string. Drives panel visibility in both the task edit form and the
  read-only task view (W1085). Pure; no DB access.
  """
  def review_panel_visible?(task) do
    has_reviewer_result?(task) or has_review_report?(task)
  end

  @doc """
  True when the task carries a non-empty `reviewer_result` map.
  """
  def has_reviewer_result?(%{reviewer_result: %{} = result}), do: map_size(result) > 0
  def has_reviewer_result?(_), do: false

  @doc """
  True when the task carries a non-empty `review_report` binary (whitespace
  counts as content, matching the original predicate).
  """
  def has_review_report?(%{review_report: report}) when is_binary(report) and report != "",
    do: true

  def has_review_report?(_), do: false

  @doc """
  True when the task has reached review or done — `review_status` is set, or
  `status` is `:completed`.

  This is the ONE definition of that gate (W1962). Every panel predicate that
  needs it — `completion_panel_visible?/1`, `changed_files_panel_visible?/1`
  and `KanbanWeb.ReviewReportHelpers.Explorer.explorer_panel_visible?/1` —
  calls this rather than restating the boolean, so refining the rule refines
  every panel at once instead of letting them drift apart.

  The gate is deliberately NOT keyed off the column name or `needs_review`.
  Note `status` and `review_status` are independent, so an `:in_progress`
  task IS review-or-done once `review_status` is set — which is the intended
  behaviour, not an oversight: `AgentWorkflow.move_to_doing/3` returns a
  `changes_requested` or `rejected` task to Doing without clearing
  `review_status`, and its review record stays relevant across that round
  trip.

  Tolerates both the atom-keyed task struct and a raw string-keyed task map,
  matching the key-tolerance convention this module's accessors follow. Pure;
  no DB access.
  """
  @spec review_or_done?(map()) :: boolean()
  def review_or_done?(task) when is_map(task) do
    not is_nil(fetch_field(task, :review_status)) or
      fetch_field(task, :status) in [:completed, "completed"]
  end

  def review_or_done?(_), do: false

  @doc """
  True when the Completion section should render: the task is review-or-done
  AND carries at least one completion field worth showing (W1962).

  The field set carries over every field the inline guard in
  `KanbanWeb.TaskLive.ViewComponent` requires today — `completed_at`,
  `completed_by`, `completed_by_agent`, `completion_summary` — and widens it
  by one, `completion_notes`, so a task carrying only notes still renders.
  That call site was swapped onto this predicate in W1963, which is also what
  makes the whole Completion section visible during Review and not only once
  the task is Done. An unloaded `completed_by` association reads as absent
  rather than as content, since a not-yet-preloaded assoc is no evidence the
  task was completed by anyone.

  Widening the gate never widens access: this decides section visibility
  inside an already-authorized view, never who may open the task. Pure; no
  DB access.
  """
  @spec completion_panel_visible?(map()) :: boolean()
  def completion_panel_visible?(task) do
    review_or_done?(task) and has_completion_content?(task)
  end

  @doc """
  True when the changed-files section should render: the task is
  review-or-done AND its `changed_files` list is non-empty (W1962).

  `changed_files` defaults to `[]` rather than `nil` in `Kanban.Tasks.Task`,
  so the empty-list check is the meaningful one; `nil` and non-list values
  are still tolerated and read as absent. Pure; no DB access.
  """
  @spec changed_files_panel_visible?(map()) :: boolean()
  def changed_files_panel_visible?(task) do
    review_or_done?(task) and has_changed_files?(task)
  end

  # Only ever reached through the panel predicates above, whose `and`
  # short-circuits on `review_or_done?/1` — so `task` is always a map here.
  defp has_completion_content?(task) do
    Enum.any?(@completion_fields, &completion_field_present?(task, &1))
  end

  defp completion_field_present?(task, field) do
    present_completion_value?(fetch_field(task, field))
  end

  defp present_completion_value?(%Ecto.Association.NotLoaded{}), do: false
  defp present_completion_value?(value), do: not is_nil(value)

  defp has_changed_files?(task), do: present_list?(fetch_field(task, :changed_files))

  # The explorer-side surface — has_explorer_result?/1,
  # explorer_panel_visible?/1 and skip_reason_label/1 — moved to
  # KanbanWeb.ReviewReportHelpers.Explorer in W2003 to bring this module back
  # toward the size guidance in AGENTS.md. Import from there, not from here.

  # `project_checks_gap/1` was removed with the checklist-coverage gate: it
  # compared a review's project_checks count against Kanban's OWN checklist size,
  # so every project with a shorter (or absent) CODE-REVIEW.md saw a bogus
  # "N of 25 checks" warning. The caller's checklist length is not knowable here.

  defp effective_section_status(task, :testing_strategy),
    do:
      structured_or_derived(task, "testing_strategy", "testing", testing_strategy_present?(task))

  defp effective_section_status(task, :patterns),
    do: structured_or_derived(task, "patterns", "pattern", patterns_present?(task))

  defp effective_section_status(task, :pitfalls),
    do: structured_or_derived(task, "pitfalls", "pitfall", pitfalls_present?(task))

  defp effective_section_status(task, :security_considerations),
    do:
      structured_or_derived(
        task,
        "security_considerations",
        "security",
        security_considerations_present?(task)
      )

  defp section_supplied?(task, :testing_strategy), do: testing_strategy_present?(task)
  defp section_supplied?(task, :patterns), do: patterns_present?(task)
  defp section_supplied?(task, :pitfalls), do: pitfalls_present?(task)

  defp section_supplied?(task, :security_considerations),
    do: security_considerations_present?(task)

  @doc """
  Human-readable value for the testing-strategy verdict cell.

  Prefers the structured `reviewer_result["testing_strategy"]["status"]`
  when present; falls back to regex extraction from `review_report`.
  Returns a localized string or `nil` when no source has a value.
  """
  def testing_strategy_value(task) do
    case structured_or_derived(
           task,
           "testing_strategy",
           "testing",
           testing_strategy_present?(task)
         ) do
      nil -> testing_strategy_value_from_report(task)
      status -> structured_status_label(status)
    end
  end

  defp testing_strategy_value_from_report(task) do
    case MarkdownReport.report_section(task, ~r/required\s+test\s+cases|testing\s+strategy/i) do
      nil ->
        nil

      body ->
        n = MarkdownReport.count_list_items(body)

        cond do
          MarkdownReport.all_present_heading?(
            task,
            ~r/required\s+test\s+cases|testing\s+strategy/i
          ) ->
            ngettext(
              "%{n} case · all present",
              "%{n} cases · all present",
              n,
              n: n
            )

          n > 0 ->
            ngettext("%{n} case", "%{n} cases", n, n: n)

          true ->
            gettext("reviewed")
        end
    end
  end

  @doc """
  Tone toggle for the testing-strategy verdict cell. Prefers structured
  `reviewer_result["testing_strategy"]["status"]` when present; falls back
  to the regex path. Returns `true`/`false`/`nil`.
  """
  def testing_strategy_passed(task) do
    case structured_or_derived(
           task,
           "testing_strategy",
           "testing",
           testing_strategy_present?(task)
         ) do
      nil -> testing_strategy_passed_from_report(task)
      status -> structured_status_passed(status)
    end
  end

  defp testing_strategy_passed_from_report(task) do
    cond do
      MarkdownReport.all_present_heading?(task, ~r/required\s+test\s+cases|testing\s+strategy/i) ->
        true

      MarkdownReport.report_section(task, ~r/required\s+test\s+cases|testing\s+strategy/i) ->
        true

      true ->
        nil
    end
  end

  @testing_strategy_categories ~w(unit_tests integration_tests manual_tests edge_cases coverage_target)

  @doc """
  Per-category breakdown of the task's own `testing_strategy` field for the
  Review checks panel. Returns one map per non-empty category, in the fixed
  order unit_tests → integration_tests → manual_tests → edge_cases →
  coverage_target:

      %{key: "unit_tests", label: "Unit tests", items: ["..."], passed: true}

  `items` is the category's list of strings; `coverage_target` (a single
  string) becomes a one-item list. `passed` prefers a per-category verdict
  at `reviewer_result["testing_strategy"]["categories"][key]["status"]`
  when the reviewer supplied one, and falls back to the section-level
  testing-strategy verdict so each category shows the most specific status
  available. Returns `[]` when the task carries no testing strategy.
  """
  def testing_strategy_breakdown(task) do
    case fetch_field(task, :testing_strategy) do
      %{} = strategy when map_size(strategy) > 0 ->
        @testing_strategy_categories
        |> Enum.map(&breakdown_category(task, strategy, &1))
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp breakdown_category(task, strategy, key) do
    case category_items(Map.get(strategy, key)) do
      [] ->
        nil

      items ->
        %{key: key, label: category_label(key), items: items, passed: category_passed(task, key)}
    end
  end

  defp category_items(value) when is_binary(value) do
    case String.trim(value) do
      "" -> []
      trimmed -> [trimmed]
    end
  end

  defp category_items(value) when is_list(value) do
    value
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp category_items(_), do: []

  defp category_label("unit_tests"), do: gettext("Unit tests")
  defp category_label("integration_tests"), do: gettext("Integration tests")
  defp category_label("manual_tests"), do: gettext("Manual tests")
  defp category_label("edge_cases"), do: gettext("Edge cases")
  defp category_label("coverage_target"), do: gettext("Coverage target")

  defp category_passed(task, key) do
    case category_status(task, key) do
      nil -> testing_strategy_passed(task)
      status -> structured_status_passed(status)
    end
  end

  defp category_status(task, key) do
    with %{} = result <- reviewer_result(task),
         %{"categories" => %{} = categories} <- Map.get(result, "testing_strategy"),
         %{"status" => status} when is_binary(status) <- Map.get(categories, key) do
      status
    else
      _ -> nil
    end
  end

  @doc """
  Human-readable value for the patterns verdict cell. Prefers structured
  `reviewer_result["patterns"]["status"]` when present; falls back to the
  regex `Patterns followed` section in `review_report`.
  """
  def patterns_value(task) do
    case structured_or_derived(task, "patterns", "pattern", patterns_present?(task)) do
      nil ->
        case MarkdownReport.report_section(task, ~r/patterns\s+followed/i) do
          nil -> nil
          _body -> gettext("followed")
        end

      status ->
        structured_status_label(status)
    end
  end

  @doc """
  Tone toggle for the patterns verdict cell. Prefers structured field;
  falls back to regex.
  """
  def patterns_passed(task) do
    case structured_or_derived(task, "patterns", "pattern", patterns_present?(task)) do
      nil ->
        if MarkdownReport.report_section(task, ~r/patterns\s+followed/i), do: true, else: nil

      status ->
        structured_status_passed(status)
    end
  end

  @doc """
  Human-readable value for the pitfalls verdict cell. Prefers structured
  `reviewer_result["pitfalls"]["status"]` when present; falls back to the
  regex `Pitfalls` section in `review_report`.
  """
  def pitfalls_value(task) do
    case structured_or_derived(task, "pitfalls", "pitfall", pitfalls_present?(task)) do
      nil ->
        case MarkdownReport.report_section(task, ~r/pitfalls/i) do
          nil ->
            nil

          body ->
            if MarkdownReport.pitfalls_violated?(body) do
              gettext("violated")
            else
              gettext("none violated")
            end
        end

      status ->
        structured_status_label(status)
    end
  end

  @doc """
  Tone toggle for the pitfalls verdict cell. Prefers structured field;
  falls back to regex.
  """
  def pitfalls_passed(task) do
    case structured_or_derived(task, "pitfalls", "pitfall", pitfalls_present?(task)) do
      nil ->
        case MarkdownReport.report_section(task, ~r/pitfalls/i) do
          nil -> nil
          body -> not MarkdownReport.pitfalls_violated?(body)
        end

      status ->
        structured_status_passed(status)
    end
  end

  @doc """
  Human-readable value for the security-considerations verdict cell. Prefers
  structured `reviewer_result["security_considerations"]["status"]` when
  present; otherwise derives a verdict from the categorized `issues` list.
  Returns a localized string or `nil` — there is no legacy `review_report`
  regex section for security considerations, so a thin/legacy payload yields
  `nil` and the caller renders an em-dash default.
  """
  def security_considerations_value(task) do
    case structured_or_derived(
           task,
           "security_considerations",
           "security",
           security_considerations_present?(task)
         ) do
      nil -> nil
      status -> structured_status_label(status)
    end
  end

  @doc """
  Tone toggle for the security-considerations verdict cell. Prefers the
  structured field, otherwise derives from the issues list. Returns
  `true`/`false`/`nil`, keeping neutral (`nil`) tone for absent verdicts.
  """
  def security_considerations_passed(task) do
    case structured_or_derived(
           task,
           "security_considerations",
           "security",
           security_considerations_present?(task)
         ) do
      nil -> nil
      status -> structured_status_passed(status)
    end
  end

  # --- Structured-field lookup --------------------------------------------

  defp structured_section_status(task, key) do
    case reviewer_result(task) do
      %{} = result ->
        case Map.get(result, key) do
          %{"status" => status} when is_binary(status) -> status
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # Resolves a section status from the structured `reviewer_result[key].status`
  # first, then — when that is absent — derives one from the structured
  # `reviewer_result["issues"]` list (a verdict the reviewer agent emits today),
  # so the section verdict cells render even when the reviewer did not emit an
  # explicit per-section status object. Returns `nil` only when neither source
  # has a value, so the caller can still fall back to legacy regex extraction.
  defp structured_or_derived(task, key, category, metadata_present?) do
    structured_section_status(task, key) ||
      issues_derived_status(task, category, metadata_present?)
  end

  # Derives a section verdict from the categorized issues[] list:
  #   * a matching-category issue → "failed"
  #   * no matching issue, but the task carried that metadata → "passed"
  #   * no matching issue and no metadata → "not_assessed"
  # Returns `nil` when reviewer_result has no `issues` list, so callers fall
  # through to the regex path for legacy/thin payloads.
  defp issues_derived_status(task, category, metadata_present?) do
    case reviewer_result(task) do
      %{"issues" => issues} when is_list(issues) ->
        cond do
          Enum.any?(issues, fn issue -> issue_category(issue) == category end) -> "failed"
          metadata_present? -> "passed"
          true -> "not_assessed"
        end

      _ ->
        nil
    end
  end

  defp issue_category(%{"category" => category}), do: category
  defp issue_category(%{category: category}), do: category
  defp issue_category(_), do: nil

  defp testing_strategy_present?(task), do: present_map?(fetch_field(task, :testing_strategy))
  defp patterns_present?(task), do: present_string?(fetch_field(task, :patterns_to_follow))
  defp pitfalls_present?(task), do: present_list?(fetch_field(task, :pitfalls))

  defp security_considerations_present?(task),
    do: present_list?(fetch_field(task, :security_considerations))

  defp fetch_field(task, key) do
    Map.get(task, key) || Map.get(task, Atom.to_string(key))
  end

  defp present_map?(value) when is_map(value), do: map_size(value) > 0
  defp present_map?(_), do: false

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_), do: false

  defp present_list?(value) when is_list(value), do: value != []
  defp present_list?(_), do: false

  defp reviewer_result(%{reviewer_result: %{} = result}), do: result
  defp reviewer_result(%{"reviewer_result" => %{} = result}), do: result
  defp reviewer_result(_), do: nil

  defp structured_status_label("passed"), do: gettext("passed")
  defp structured_status_label("failed"), do: gettext("failed")
  defp structured_status_label("not_assessed"), do: gettext("not assessed")
  defp structured_status_label(_), do: nil

  defp structured_status_passed("passed"), do: true
  defp structured_status_passed("failed"), do: false
  defp structured_status_passed(_), do: nil

  # The legacy markdown/regex parsing layer moved to
  # KanbanWeb.ReviewReportHelpers.MarkdownReport, and the presentation-token
  # layer to KanbanWeb.ReviewReportHelpers.Tokens, both in W2004 to bring this
  # module under the size guidance in AGENTS.md. This module still CALLS
  # MarkdownReport for its regex fallbacks; Tokens calls back into here.

  @doc """
  Reads the reviewer's one-line security rationale. Returns `nil` for
  absent/blank/non-string notes so the paragraph is omitted rather than
  rendering empty.
  """
  @spec security_considerations_note(map()) :: String.t() | nil
  def security_considerations_note(task),
    do: section_note(task, :security_considerations)

  @doc """
  Extracts the per-consideration mitigation breakdown from
  `reviewer_result["security_considerations"]["considerations"]` (W1866/W1867).

  Returns a list of `%{consideration: string, status: string | nil, detail:
  string | nil}` maps — one per well-formed entry — or `[]` when the breakdown is
  absent, `nil`, not a list, or the `reviewer_result` carries none. Entries
  without a non-blank `consideration` string are dropped so the read side never
  renders an empty row: the write-side validator already rejects those, but
  legacy or partial data must not crash the queue. `detail` is the reviewer's
  optional `evidence` (preferred) or `note` string, whichever is present.
  """
  @spec security_considerations_breakdown(map()) :: [
          %{consideration: String.t(), status: String.t() | nil, detail: String.t() | nil}
        ]
  def security_considerations_breakdown(task) do
    task
    |> raw_considerations()
    |> Enum.filter(&is_map/1)
    |> Enum.map(&normalize_consideration/1)
    |> Enum.reject(&is_nil/1)
  end

  # The raw considerations list from the reviewer_result, or [] when absent, nil,
  # or not a list. Kept separate so the public function stays a flat pipeline.
  defp raw_considerations(task) do
    with %{} = result <- reviewer_result(task),
         %{"considerations" => considerations} when is_list(considerations) <-
           Map.get(result, "security_considerations") do
      considerations
    else
      _ -> []
    end
  end

  defp normalize_consideration(entry) do
    case Map.get(entry, "consideration") do
      text when is_binary(text) ->
        case String.trim(text) do
          "" ->
            nil

          trimmed ->
            %{
              consideration: trimmed,
              status: consideration_status(entry),
              detail: consideration_detail(entry)
            }
        end

      _ ->
        nil
    end
  end

  defp consideration_status(entry) do
    case Map.get(entry, "status") do
      status when is_binary(status) -> status
      _ -> nil
    end
  end

  # The reviewer may attach an optional rationale under either "evidence" or
  # "note" (neither is server-validated); prefer evidence, fall back to note.
  defp consideration_detail(entry) do
    trimmed_value(entry, "evidence") || trimmed_value(entry, "note")
  end

  defp trimmed_value(entry, key) do
    case Map.get(entry, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end
end
