defmodule KanbanWeb.ReviewReportHelpers.Explorer do
  @moduledoc """
  Explorer-side read predicates and labels for a task's `explorer_result`.

  Split out of `KanbanWeb.ReviewReportHelpers` (W2003), which had grown past
  the module-size guidance in `AGENTS.md`. The reviewer-side surface —
  `review_panel_visible?/1`, `has_reviewer_result?/1`, `section_note/2` and
  the structured-status machinery — stays in the parent module; everything
  here reads `explorer_result` only.

  Every function is pure: no DB access, no scope resolution. These are
  display predicates and must not become an authorization decision point.
  """
  use Gettext, backend: KanbanWeb.Gettext

  alias KanbanWeb.ReviewReportHelpers

  @doc """
  True when the task carries a non-empty `explorer_result` map.

  Mirrors `KanbanWeb.ReviewReportHelpers.has_reviewer_result?/1` — the
  `map_size/1` guard is what rejects the empty map, since `%{}` matches ANY
  map in Elixir. Tolerates both the atom-keyed task struct and a raw
  string-keyed task map, matching the key-tolerance convention the parent
  module's accessors follow. Pure; no DB access.
  """
  @spec has_explorer_result?(map()) :: boolean()
  def has_explorer_result?(%{explorer_result: %{} = result}), do: map_size(result) > 0
  def has_explorer_result?(%{"explorer_result" => %{} = result}), do: map_size(result) > 0
  def has_explorer_result?(_), do: false

  @doc """
  True when the explorer-result section should render: the task carries a
  non-empty `explorer_result` AND the task has reached review or done.

  The review-or-done half is `KanbanWeb.ReviewReportHelpers.review_or_done?/1`
  — the single definition of that gate, shared with the completion and
  changed-files panels (W1962). See its `@doc` for why the rule is keyed off
  `review_status`/`status` rather than the column name or `needs_review`, and
  why an `:in_progress` task with a `review_status` counts.

  A task that has not yet reached review never shows the section even when its
  `explorer_result` is populated. Pure; no DB access.
  """
  @spec explorer_panel_visible?(map()) :: boolean()
  def explorer_panel_visible?(task) do
    has_explorer_result?(task) and ReviewReportHelpers.review_or_done?(task)
  end

  @doc """
  User-visible label for an `explorer_result`/`reviewer_result` skip reason.

  Matches on the five binary enum values as they arrive from the JSONB
  column. An unrecognized binary falls through to itself rather than
  raising, so a legacy or future enum entry never crashes the task view —
  the same passthrough shape as `KanbanWeb.TaskTokens.hook_stage_label/1`.
  Never converts the incoming value to an atom.
  """
  @spec skip_reason_label(term()) :: String.t()
  def skip_reason_label("no_subagent_support"), do: gettext("No subagent support")
  def skip_reason_label("small_task_0_1_key_files"), do: gettext("Small task (0-1 key files)")
  def skip_reason_label("trivial_change_docs_only"), do: gettext("Trivial change (docs only)")
  def skip_reason_label("self_reported_exploration"), do: gettext("Self-reported exploration")
  def skip_reason_label("self_reported_review"), do: gettext("Self-reported review")
  def skip_reason_label(other) when is_binary(other), do: other
  def skip_reason_label(_), do: ""
end
