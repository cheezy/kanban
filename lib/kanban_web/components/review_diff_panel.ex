defmodule KanbanWeb.ReviewDiffPanel do
  @moduledoc """
  "Changed files" panel for the Review detail view at `/review`.

  Surfaces the list of file paths the agent touched and the unified
  diff for the currently selected file. The file list shows a header
  with the file count and an optional "N failing tests" pill. The
  parent LiveView is responsible for splitting `actual_files_changed`
  into the `:files` list this component consumes (via `parse_files/1`
  in `KanbanWeb.ReviewLive`).

  When given `on_file_click`, each file row becomes a button that emits
  the named phx-click event with a `path` value; the parent LiveView
  manages `selected_changed_file` selection state. When the LiveView
  passes a per-file payload via `selected_file`, that file's unified
  diff is rendered below the list.

  ## Per-file diff contract

  The per-file `diff` field shape is defined in `docs/diff-contract.md`
  — single source of truth for field name, encoding, the 500-line
  truncation marker, and the binary-file placeholder used across the
  six Stride plugin repos.

  ## Diff rendering

  The diff is parsed line-by-line by classifying the leading character:

    * `+` — addition (rendered with the addition color)
    * `-` — removal (rendered with the removal color)
    * `@@` — hunk header (rendered with the hunk-header color)
    * `---` / `+++` — patch headers (rendered with the hunk-header color)
    * anything else, including a leading space or empty line — context

  Truncation is signaled by the exact marker line
  `[diff truncated at 500 lines]` from the contract doc. When present,
  the panel shows a notice and a "view full diff in repo" link if the
  per-file payload carries a `"diff_url"` string. Binary files are
  signaled by the exact placeholder `[binary file — no diff captured]`
  and render with no patch parsing.

  ## Dependency decision

  We render diffs with a small in-module parser plus scoped CSS in
  `assets/css/app.css`. We considered `diff2html` (raised as an open
  question in the requirements doc) and chose to roll our own because
  (a) per-file diffs are capped at 500 lines, (b) diff2html ships
  styling we cannot easily theme through CSS custom properties,
  (c) the unified-patch line classification reduces to a 4-way pattern
  match. No new dependency is added.
  """
  use KanbanWeb, :html

  @truncation_marker "[diff truncated at 500 lines]"
  @binary_placeholder "[binary file — no diff captured]"

  @doc """
  The exact truncation marker line plugins append to a diff when they
  capped it at 500 lines. Exposed so tests and other callers can build
  fixtures without duplicating the literal string (see
  `docs/diff-contract.md` for the source of truth).
  """
  def truncation_marker, do: @truncation_marker

  @doc """
  The exact placeholder string a plugin emits for binary-file entries
  instead of unified-patch text. Source of truth lives in
  `docs/diff-contract.md`; this accessor exists so other callers can
  reference the literal without duplicating it.
  """
  def binary_placeholder, do: @binary_placeholder

  @doc """
  Renders the changed-files panel.

  ## Attrs

    * `files` — required. List of file path strings. Empty list renders
      the empty state.
    * `failing_tests_count` — optional. Integer count of failing tests.
      When `nil` or `0`, the failing-tests pill is omitted.
    * `selected_file` — optional per-file payload (the shape defined in
      `docs/diff-contract.md`):
      `%{"path" => string, "diff" => string | nil, "diff_url" => string | nil}`.
      When `path` matches an entry in `files`, that row renders with the
      active state and the diff content area renders the file's diff.
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
      |> assign(:diff_view, diff_view(assigns.selected_file))

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

      <.diff_content :if={@selected_file_path} view={@diff_view} />
    </section>
    """
  end

  attr :view, :map, required: true

  defp diff_content(%{view: %{mode: :binary}} = assigns) do
    ~H"""
    <p
      data-review-diff-panel-diff
      data-review-diff-panel-diff-mode="binary"
      style={[
        "margin: 0; padding: 12px;",
        "background: var(--surface-sunken); border-radius: 6px;",
        "font-size: 12px; color: var(--ink-2); font-style: italic;"
      ]}
    >
      {gettext("Binary file changed — no diff preview.")}
    </p>
    """
  end

  defp diff_content(%{view: %{mode: :empty}} = assigns) do
    ~H"""
    <p
      data-review-diff-panel-diff
      data-review-diff-panel-diff-mode="empty"
      style={[
        "margin: 0; padding: 12px;",
        "background: var(--surface-sunken); border-radius: 6px;",
        "font-size: 12px; color: var(--ink-3); font-style: italic;"
      ]}
    >
      {gettext("No diff available for this file.")}
    </p>
    """
  end

  defp diff_content(%{view: %{mode: :patch}} = assigns) do
    ~H"""
    <div
      data-review-diff-panel-diff
      data-review-diff-panel-diff-mode={if @view.truncated?, do: "truncated", else: "full"}
      style={[
        "margin: 0; padding: 0;",
        "background: var(--surface-sunken); border-radius: 6px;",
        "overflow: hidden;"
      ]}
    >
      <pre
        data-review-diff-panel-diff-body
        style={[
          "margin: 0; padding: 8px 12px;",
          "font-family: var(--font-mono); font-size: 11.5px;",
          "line-height: 1.1; color: var(--ink);",
          "white-space: pre-wrap; word-break: break-all;",
          "overflow-x: auto;"
        ]}
      >{render_diff_lines(@view.lines)}</pre>
      <div
        :if={@view.truncated?}
        data-review-diff-panel-diff-truncated
        style={[
          "display: flex; align-items: center; gap: 8px; flex-wrap: wrap;",
          "padding: 6px 12px; border-top: 1px solid var(--line);",
          "background: var(--surface-2);",
          "font-size: 11.5px; color: var(--ink-2);"
        ]}
      >
        <span>
          {gettext("Diff truncated at 500 lines.")}
        </span>
        <a
          :if={@view.diff_url}
          data-review-diff-panel-diff-link
          href={@view.diff_url}
          target="_blank"
          rel="noopener"
          style="color: var(--stride-orange); text-decoration: underline;"
        >
          {gettext("View full diff in repo")}
        </a>
      </div>
    </div>
    """
  end

  defp render_diff_lines(lines) do
    lines
    |> Enum.map(&render_diff_line/1)
    |> Enum.intersperse("\n")
  end

  defp render_diff_line({class, text}) do
    {:safe, escaped} = Phoenix.HTML.html_escape(text)

    {:safe,
     [
       ~s(<span data-diff-line="),
       class,
       ~s(" class="stride-diff-line stride-diff-line-),
       class,
       ~s(">),
       escaped,
       "</span>"
     ]}
  end

  defp show_failing_pill?(nil), do: false
  defp show_failing_pill?(0), do: false
  defp show_failing_pill?(n) when is_integer(n) and n > 0, do: true
  defp show_failing_pill?(_), do: false

  defp selected_file_path(%{"path" => path}) when is_binary(path), do: path
  defp selected_file_path(_), do: nil

  # Builds the rendering state for the selected file. Three modes:
  #
  #   * `:empty` — no diff field on the payload, or empty/whitespace string
  #   * `:binary` — the diff value is exactly the binary placeholder
  #   * `:patch` — the diff is unified-patch text; further marked truncated
  #     when it contains the truncation marker
  #
  # The `lines` list is a list of `{class, text}` tuples where `class` is
  # one of `"add"`, `"del"`, `"hunk"`, `"file"`, `"context"`, or
  # `"truncation"`. The truncation marker line is filtered out of `lines`
  # and surfaced via `truncated?` so the UI can render its own notice.
  defp diff_view(nil), do: %{mode: :empty}

  defp diff_view(%{"diff" => diff} = payload) when is_binary(diff) do
    cond do
      String.trim(diff) == "" ->
        %{mode: :empty}

      diff == @binary_placeholder ->
        %{mode: :binary}

      true ->
        truncated? = String.contains?(diff, @truncation_marker)

        %{
          mode: :patch,
          truncated?: truncated?,
          diff_url: diff_url(payload),
          lines: parse_diff_lines(diff)
        }
    end
  end

  defp diff_view(_), do: %{mode: :empty}

  defp diff_url(%{"diff_url" => url}) when is_binary(url) and url != "", do: url
  defp diff_url(_), do: nil

  defp parse_diff_lines(diff) do
    diff
    |> sanitize()
    |> String.trim_trailing("\n")
    |> String.split("\n", trim: false)
    |> Enum.reject(&(&1 == @truncation_marker))
    |> Enum.map(&classify_line/1)
  end

  # Drop NUL bytes defensively — the contract doc requires UTF-8 unified
  # patch text, but if a malformed plugin sends embedded \0 we strip
  # rather than crash the pre tag.
  defp sanitize(diff), do: String.replace(diff, "\0", "")

  defp classify_line("@@" <> _ = line), do: {"hunk", line}
  defp classify_line("+" <> _ = line), do: {"add", line}
  defp classify_line("-" <> _ = line), do: {"del", line}
  defp classify_line(line), do: {"context", line}
end
