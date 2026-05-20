defmodule KanbanWeb.ReviewDiffPanel do
  @moduledoc """
  "Changed files" panel for the Review detail view at `/review`.

  Surfaces the list of file paths the agent touched, with a header
  showing the file count and an optional "N failing tests" pill on the
  right. Real unified-diff content is intentionally out of scope —
  `Kanban.Tasks.Task` does not persist diffs, only the comma-separated
  `actual_files_changed` string. The parent LiveView is responsible for
  splitting that string into the `:files` list this component consumes.

  Purely presentational. No expand/collapse, no click handlers, no diff
  syntax highlighting.

  ## Per-file diff contract

  The structured per-file diff field this component will consume once
  inline diff rendering lands is defined in `docs/diff-contract.md`.
  That doc is the single source of truth for the field name, encoding,
  500-line truncation marker, and binary-file placeholder used across
  the six Stride plugin repos.
  """
  use KanbanWeb, :html

  @doc """
  Renders the changed-files panel.

  ## Attrs

    * `files` — required. List of file path strings. Empty list renders
      the empty state.
    * `failing_tests_count` — optional. Integer count of failing tests.
      When `nil` or `0`, the failing-tests pill is omitted.
  """
  attr :files, :list, required: true
  attr :failing_tests_count, :integer, default: nil

  def review_diff_panel(assigns) do
    assigns =
      assigns
      |> assign(:file_count, length(assigns.files))
      |> assign(:show_failing_pill?, show_failing_pill?(assigns.failing_tests_count))

    ~H"""
    <section
      data-review-diff-panel
      style={[
        "display: flex; flex-direction: column; gap: 8px;",
        "padding: 12px 16px; color: var(--ink);"
      ]}
    >
      <header
        data-review-diff-panel-header
        style="display: flex; align-items: center; gap: 10px; flex-wrap: wrap;"
      >
        <span
          data-review-diff-panel-title
          style="font-size: 11.5px; color: var(--ink-3); font-family: var(--font-mono);"
        >
          {ngettext("%{count} file", "%{count} files", @file_count, count: @file_count)}
        </span>

        <span style="flex: 1;" />

        <span
          :if={@show_failing_pill?}
          data-review-diff-panel-failing-tests
          style={[
            "padding: 1px 8px; border-radius: 999px;",
            "background: var(--st-blocked-soft); color: var(--st-blocked);",
            "font-size: 10.5px; font-weight: 500;"
          ]}
        >
          {ngettext(
            "%{count} failing test",
            "%{count} failing tests",
            @failing_tests_count,
            count: @failing_tests_count
          )}
        </span>
      </header>

      <p
        :if={@file_count == 0}
        data-review-diff-panel-empty
        style={[
          "margin: 0; padding: 8px 0;",
          "font-size: 12px; color: var(--ink-3); font-style: italic;"
        ]}
      >
        {gettext("No files changed.")}
      </p>

      <ul
        :if={@file_count > 0}
        data-review-diff-panel-list
        style={[
          "margin: 0; padding: 8px 12px; list-style: none;",
          "background: var(--surface-sunken); border-radius: 6px;",
          "display: flex; flex-direction: column; gap: 2px;"
        ]}
      >
        <li
          :for={file <- @files}
          data-review-diff-panel-file
          style={[
            "font-family: var(--font-mono); font-size: 11.5px;",
            "color: var(--ink); line-height: 1.6;",
            "overflow-wrap: anywhere; word-break: break-all;"
          ]}
        >
          {file}
        </li>
      </ul>
    </section>
    """
  end

  defp show_failing_pill?(nil), do: false
  defp show_failing_pill?(0), do: false
  defp show_failing_pill?(n) when is_integer(n) and n > 0, do: true
  defp show_failing_pill?(_), do: false
end
