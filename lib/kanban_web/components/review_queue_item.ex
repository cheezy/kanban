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

  alias KanbanWeb.Avatar
  alias KanbanWeb.AvatarPalette
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
        "padding: 12px 16px;",
        "border: 0; border-left: 2px solid #{if @selected, do: "var(--stride-orange)", else: "transparent"};",
        "border-bottom: 1px solid var(--line);",
        "background: #{if @selected, do: "var(--surface-sunken)", else: "transparent"};",
        "cursor: pointer;",
        "font: inherit; color: var(--ink);"
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
          {format_age(@item.completed_at)}
        </time>
      </div>

      <div
        data-review-queue-item-title
        style={[
          "font-size: 12.5px; font-weight: 500;",
          "line-height: 1.35; color: var(--ink);"
        ]}
      >
        {@item.title}
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
    </button>
    """
  end

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

  defp format_age(%DateTime{} = dt) do
    DateTime.utc_now()
    |> DateTime.diff(dt, :second)
    |> age_label()
  end

  defp age_label(seconds) when seconds < 5, do: gettext("just now")
  defp age_label(seconds) when seconds < 60, do: gettext("%{s}s ago", s: seconds)
  defp age_label(seconds) when seconds < 3600, do: gettext("%{m}m ago", m: div(seconds, 60))

  defp age_label(seconds) when seconds < 86_400,
    do: gettext("%{h}h ago", h: div(seconds, 3600))

  defp age_label(seconds), do: gettext("%{d}d ago", d: div(seconds, 86_400))
end
