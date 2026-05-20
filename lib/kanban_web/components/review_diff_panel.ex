defmodule KanbanWeb.ReviewDiffPanel do
  @moduledoc """
  "Changed files" panel for the Review detail view at `/review`.

  Surfaces the list of file paths the agent touched, with a header
  showing the file count and an optional "N failing tests" pill on the
  right. Real unified-diff content is intentionally out of scope —
  `Kanban.Tasks.Task` does not persist diffs, only the comma-separated
  `actual_files_changed` string. The parent LiveView is responsible for
  splitting that string into the `:files` list this component consumes.

  When given `on_file_click`, each file row becomes a button that emits
  the named phx-click event with a `path` value; the parent LiveView
  manages `selected_changed_file` selection state. Without
  `on_file_click`, rows render as plain `<li>` (legacy display).

  The `selected_file` attr accepts a per-file payload map (see
  `docs/diff-contract.md`). Inline diff rendering is staged for a
  follow-up task — until then the panel only highlights the active row
  and the `diff` field of the payload is unused.

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
    * `selected_file` — optional per-file payload (the shape defined in
      `docs/diff-contract.md`: `%{"path" => string, "diff" => string | nil}`).
      When `path` matches an entry in `files`, that row renders with the
      active state; the optional `diff` field is reserved for the inline
      diff render that follows in a later task. Until then, callers may
      pass `%{"path" => path, "diff" => nil}` — the panel still
      highlights correctly.
    * `on_file_click` — optional `phx-click` event name. When set, each
      row becomes a button that pushes `{event, %{"path" => path}}`. When
      `nil`, rows render as plain `<span>` (legacy display behavior).
  """
  attr :files, :list, required: true
  attr :failing_tests_count, :integer, default: nil
  attr :selected_file, :map, default: nil
  attr :on_file_click, :string, default: nil

  def review_diff_panel(assigns) do
    assigns =
      assigns
      |> assign(:file_count, length(assigns.files))
      |> assign(:show_failing_pill?, show_failing_pill?(assigns.failing_tests_count))
      |> assign(:selected_file_path, selected_file_path(assigns.selected_file))

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
          data-review-diff-panel-file-path={file}
          data-review-diff-panel-file-active={
            if file == @selected_file_path, do: "true", else: "false"
          }
          style={[
            "font-family: var(--font-mono); font-size: 11.5px;",
            "line-height: 1.6;",
            "overflow-wrap: anywhere; word-break: break-all;",
            "border-radius: 4px;"
          ]}
        >
          <button
            :if={@on_file_click}
            type="button"
            phx-click={@on_file_click}
            phx-value-path={file}
            aria-pressed={if file == @selected_file_path, do: "true", else: "false"}
            data-review-diff-panel-file-button
            style={[
              "all: unset; display: block; width: 100%;",
              "padding: 2px 8px; border-radius: 4px; cursor: pointer;",
              "font: inherit;",
              "color: var(--ink);",
              "background: #{if file == @selected_file_path, do: "var(--surface)", else: "transparent"};",
              "border-left: 2px solid #{if file == @selected_file_path, do: "var(--stride-orange)", else: "transparent"};",
              "font-weight: #{if file == @selected_file_path, do: "600", else: "500"};"
            ]}
          >
            {file}
          </button>
          <span
            :if={!@on_file_click}
            style="display: block; padding: 2px 8px; color: var(--ink);"
          >
            {file}
          </span>
        </li>
      </ul>
    </section>
    """
  end

  defp show_failing_pill?(nil), do: false
  defp show_failing_pill?(0), do: false
  defp show_failing_pill?(n) when is_integer(n) and n > 0, do: true
  defp show_failing_pill?(_), do: false

  defp selected_file_path(%{"path" => path}) when is_binary(path), do: path
  defp selected_file_path(_), do: nil
end
