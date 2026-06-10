defmodule KanbanWeb.ReviewQueueItem do
  @moduledoc """
  Left-rail row in the Review Queue at `/review`.

  Each row condenses one pending-review task into a single horizontal
  card: board chip, identifier, priority dot, optional "needs attention"
  pill, completed-at relative timestamp, title, and an agent line. The
  selected row gets a `surface-sunken` background and a 2px
  `stride-orange` left border.

  Purely presentational — the LiveView passes the task in via `:item` and
  wires `:on_click` to a `phx-click` event that toggles selection.
  """
  use KanbanWeb, :html

  alias KanbanWeb.TimeAgo

  alias KanbanWeb.Avatar
  alias KanbanWeb.AvatarPalette
  alias KanbanWeb.ReviewReportHelpers
  alias KanbanWeb.TaskTokens

  @accents ~w(stride-orange st-ready st-doing stride-violet st-backlog st-blocked)

  @doc """
  Renders one queue row.

  ## Attrs

    * `item` — required. A `%Kanban.Tasks.Task{}` with `:column` and the
      column's `:board` preloaded. The task may also expose a `:flag`
      atom (e.g. `:needs_attention`); when absent, the flag pill is
      omitted.
    * `selected` — boolean, defaults to `false`. Toggles the selected
      styling (surface-sunken background + stride-orange left border).
    * `on_click` — required. The `phx-click` event name fired when the
      row is clicked. The task's id is sent as `phx-value-id`.
  """
  attr :item, :map, required: true
  attr :selected, :boolean, default: false
  attr :on_click, :string, required: true

  def review_queue_item(assigns) do
    task = assigns.item
    board = board_for(task)

    assigns =
      assigns
      |> assign(:board, board)
      |> assign(:accent, accent_for(board))
      |> assign(:chip_label, chip_label_for(board))
      |> assign(:flag?, flag_set?(task))
      |> assign(:agent_name, agent_name_for(task))
      |> assign(:files_count, files_count_for(task))
      |> assign(:completed_by_user, completed_by_user_for(task))

    ~H"""
    <button
      type="button"
      data-review-queue-item
      data-review-queue-item-id={@item.id}
      phx-click={@on_click}
      phx-value-id={@item.id}
      aria-pressed={if @selected, do: "true", else: "false"}
      style={[
        "display: flex; flex-direction: column; gap: 6px;",
        "width: 100%; text-align: left;",
        "padding: 12px 16px 12px #{if @selected, do: "12px", else: "16px"};",
        "border: 0; border-left: #{if @selected, do: "4px", else: "0px"} solid #{if @selected, do: "var(--stride-orange)", else: "transparent"};",
        "border-bottom: 1px solid var(--line);",
        "background: #{if @selected, do: "var(--surface)", else: "transparent"};",
        "box-shadow: #{if @selected, do: "inset 0 0 0 1px var(--stride-orange-soft, oklch(96% 0.05 47))", else: "none"};",
        "cursor: pointer;",
        "font: inherit; color: var(--ink);",
        "transition: background-color 120ms ease, border-color 120ms ease;"
      ]}
    >
      <div style="display: flex; align-items: center; gap: 6px; flex-wrap: wrap;">
        <span
          data-review-queue-item-board-chip
          aria-hidden="true"
          style={[
            "display: inline-flex; align-items: center; justify-content: center;",
            "width: 18px; height: 14px; border-radius: 3px;",
            "background: #{@accent}; color: var(--surface);",
            "font-size: 8.5px; font-weight: 700;",
            "font-family: var(--font-mono);"
          ]}
        >
          {@chip_label}
        </span>

        <span
          data-review-queue-item-ident
          style={[
            "font-size: 11px; font-family: var(--font-mono);",
            "color: var(--ink-3);"
          ]}
        >
          {@item.identifier}
        </span>

        <span
          data-review-queue-item-priority-dot
          aria-hidden="true"
          style={[
            "width: 7px; height: 7px; border-radius: 50%;",
            "background: #{TaskTokens.priority_color(@item.priority)};",
            "flex-shrink: 0;"
          ]}
        />

        <span
          :if={@flag?}
          data-review-queue-item-flag
          style={[
            "padding: 1px 6px; border-radius: 999px;",
            "background: var(--st-blocked-soft); color: var(--st-blocked);",
            "font-size: 10px; font-weight: 500;"
          ]}
        >
          {gettext("needs attention")}
        </span>

        <span style="flex: 1;" />

        <time
          :if={@item.completed_at}
          data-review-queue-item-timestamp
          datetime={DateTime.to_iso8601(@item.completed_at)}
          style={[
            "font-size: 11px; font-family: var(--font-mono);",
            "color: var(--ink-3);"
          ]}
        >
          {TimeAgo.format_age(@item.completed_at, :fine)}
        </time>
      </div>

      <div
        data-review-queue-item-title
        style={[
          "display: flex; align-items: flex-start; gap: 6px;",
          "font-size: 12.5px; font-weight: #{if @selected, do: "600", else: "500"};",
          "line-height: 1.35; color: var(--ink);"
        ]}
      >
        <span style="flex: 1; min-width: 0;">{@item.title}</span>
        <span
          :if={@selected}
          data-review-queue-item-selected-indicator
          style="color: var(--stride-orange); flex-shrink: 0; display: inline-flex;"
        >
          <.icon name="hero-chevron-right" class="w-4 h-4" />
        </span>
      </div>

      <div
        data-review-queue-item-meta
        style={[
          "display: flex; align-items: center; gap: 8px;",
          "font-size: 11px; color: var(--ink-3);",
          "font-family: var(--font-mono); flex-wrap: wrap;"
        ]}
      >
        <Avatar.avatar
          :if={@agent_name}
          kind={:agent}
          name={@agent_name}
          palette={AvatarPalette.for_agent(@agent_name)}
          size={14}
        />
        <span :if={@agent_name} style="color: var(--ink-2);">{@agent_name}</span>
        <span :if={@files_count && @agent_name}>·</span>
        <span :if={@files_count} style="color: var(--ink-2);">
          {ngettext("%{count} file", "%{count} files", @files_count, count: @files_count)}
        </span>

        <span style="flex: 1;" />

        <span
          :if={@completed_by_user}
          data-review-queue-item-completed-by
          title={
            gettext("Completed by %{name}",
              name: completed_by_display_name(@completed_by_user)
            )
          }
          style="display: inline-flex; align-items: center;"
        >
          <Avatar.avatar
            kind={:human}
            name={completed_by_display_name(@completed_by_user)}
            palette={AvatarPalette.for_human(@completed_by_user.id)}
            size={18}
          />
        </span>
      </div>

      <.summary_pills item={@item} />
    </button>
    """
  end

  attr :item, :map, required: true

  defp summary_pills(assigns) do
    assigns = assign(assigns, :pills, summary_pill_data(assigns.item))

    ~H"""
    <div
      data-review-queue-item-summary
      style="display: flex; align-items: center; gap: 4px; flex-wrap: wrap;"
    >
      <span
        :for={pill <- @pills}
        data-review-queue-item-summary-pill={pill.marker}
        data-review-queue-item-summary-pill-state={pill.state}
        title={pill.tip}
        style={[
          "display: inline-flex; align-items: center; gap: 4px;",
          "padding: 1px 6px; border-radius: 999px;",
          "font-size: 10px; font-weight: 600;",
          "letter-spacing: 0.04em; text-transform: uppercase;",
          "font-family: var(--font-mono);",
          pill_style(pill.state)
        ]}
      >
        <span
          aria-hidden="true"
          style={[
            "width: 6px; height: 6px; border-radius: 50%;",
            "background: #{pill_dot_color(pill.state)};"
          ]}
        />
        {pill.label}
      </span>
    </div>
    """
  end

  defp summary_pill_data(item) do
    [
      %{
        marker: "acceptance",
        label: gettext("ACC"),
        state: pill_state(acceptance_passed?(item)),
        tip: gettext("Acceptance criteria")
      },
      %{
        marker: "testing",
        label: gettext("TST"),
        state: pill_state(ReviewReportHelpers.testing_strategy_passed(item)),
        tip: gettext("Testing strategy")
      },
      %{
        marker: "patterns",
        label: gettext("PAT"),
        state: pill_state(ReviewReportHelpers.patterns_passed(item)),
        tip: gettext("Patterns followed")
      },
      %{
        marker: "pitfalls",
        label: gettext("PIT"),
        state: pill_state(ReviewReportHelpers.pitfalls_passed(item)),
        tip: gettext("Pitfalls")
      }
    ]
  end

  # Acceptance pill state is driven by the structured reviewer_result.status
  # first, then by structured acceptance_criteria. It never flips to failed
  # purely from a legacy issues_found count — a thin/legacy reviewer_result
  # stays neutral so the pill cannot contradict the (neutral) status pill (D56).
  defp acceptance_passed?(%{reviewer_result: %{"status" => "approved"}}), do: true
  defp acceptance_passed?(%{reviewer_result: %{"status" => "changes_requested"}}), do: false

  defp acceptance_passed?(%{reviewer_result: %{} = result}) do
    case Map.get(result, "acceptance_criteria") do
      list when is_list(list) and list != [] ->
        not any_not_met?(list)

      _ ->
        nil
    end
  end

  defp acceptance_passed?(_), do: nil

  defp any_not_met?(criteria) when is_list(criteria) do
    Enum.any?(criteria, fn
      %{"status" => "not_met"} -> true
      _ -> false
    end)
  end

  defp any_not_met?(_), do: false

  defp pill_state(true), do: :passed
  defp pill_state(false), do: :failed
  defp pill_state(_), do: :neutral

  defp pill_style(:passed) do
    "background: var(--st-done-soft, oklch(96% 0.05 155)); " <>
      "color: var(--st-done, oklch(50% 0.14 155));"
  end

  defp pill_style(:failed) do
    "background: var(--st-blocked-soft, oklch(96% 0.04 25)); " <>
      "color: var(--st-blocked, oklch(50% 0.18 25));"
  end

  defp pill_style(:neutral) do
    "background: var(--surface-2); color: var(--ink-3);"
  end

  defp pill_dot_color(:passed), do: "var(--st-done, oklch(60% 0.14 155))"
  defp pill_dot_color(:failed), do: "var(--st-blocked, oklch(60% 0.18 25))"
  defp pill_dot_color(:neutral), do: "var(--ink-3)"

  defp board_for(%{column: %{board: %{} = board}}), do: board
  defp board_for(_), do: nil

  defp accent_for(nil), do: "var(--ink-3)"

  defp accent_for(%{id: id}) when is_integer(id) do
    idx = rem(id, length(@accents))
    token = Enum.at(@accents, idx)
    "var(--#{token})"
  end

  defp accent_for(_), do: "var(--ink-3)"

  defp chip_label_for(nil), do: "·"

  defp chip_label_for(%{name: name}) when is_binary(name) and name != "" do
    name
    |> String.upcase()
    |> String.replace(~r/[^A-Z0-9]/, "")
    |> String.slice(0, 3)
    |> case do
      "" -> "·"
      chars -> chars
    end
  end

  defp chip_label_for(_), do: "·"

  defp flag_set?(%{flag: flag}) when not is_nil(flag), do: true
  defp flag_set?(_), do: false

  defp agent_name_for(%{completed_by_agent: agent}) when is_binary(agent) and agent != "",
    do: agent

  defp agent_name_for(%{created_by_agent: agent}) when is_binary(agent) and agent != "",
    do: agent

  defp agent_name_for(_), do: nil

  defp files_count_for(%{actual_files_changed: files}) when is_binary(files) and files != "" do
    files
    |> String.split(",", trim: true)
    |> length()
    |> case do
      0 -> nil
      n -> n
    end
  end

  defp files_count_for(_), do: nil

  defp completed_by_user_for(%{completed_by: %{} = user}) when not is_nil(user), do: user
  defp completed_by_user_for(_), do: nil

  defp completed_by_display_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp completed_by_display_name(%{email: email}) when is_binary(email), do: email
  defp completed_by_display_name(_), do: ""
end
