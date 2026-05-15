defmodule KanbanWeb.TaskMetadataGrid do
  @moduledoc """
  Type-aware metadata grid for the task detail surface. Renders the
  right-rail FieldRow block from
  `design_handoff_stride/design_source/screens/task-detail.jsx`
  (full-screen variant lines 482-520) as a `120px / 1fr` two-column grid
  with `--line` row dividers.

  Rows surfaced (in display order):

    * Status — status pill
    * Column — task.column.name
    * Board — passed via attr (column.board not preloaded)
    * Author — `assigned_to || created_by` rendered via `KanbanWeb.Avatar`
    * Goal — parent goal chip (icon + identifier + truncated title)
    * Complexity — gettext word (omitted for goal type)
    * Priority — colored dot + gettext word (omitted for goal type)
    * Needs review — "Required" pill or "Auto" muted text
    * Created / Started / Completed — `Calendar.strftime/2` timestamps

  Defect-specific rows (severity, reproduction) are intentionally
  deferred: those fields do not exist on `Kanban.Tasks.Task` yet, so the
  defect render path matches the work render path until they land.
  """
  use KanbanWeb, :html

  alias KanbanWeb.Avatar
  alias KanbanWeb.AvatarPalette
  alias KanbanWeb.TaskTokens

  @doc """
  Renders the metadata grid for a task.

  ## Attrs

    * `task` — task struct or map (see module @moduledoc for fields).
      Required. Reads via `Map.get/3` so it tolerates partial maps and
      lazy-loaded associations.
    * `parent_goal` — optional preloaded parent goal map with
      `:identifier` and `:title`. When `nil`, the Goal row is omitted.
    * `board_name` — the enclosing board's display name. When `nil`,
      the Board row is omitted.
  """
  attr :task, :map, required: true
  attr :parent_goal, :map, default: nil
  attr :board_name, :string, default: nil

  def metadata_grid(assigns) do
    assigns = derive_assigns(assigns)

    ~H"""
    <div
      data-metadata-grid
      style={[
        "display: grid; grid-template-columns: 120px 1fr;",
        "background: var(--surface);",
        "font-size: 12px; color: var(--ink);"
      ]}
    >
      <.row label={gettext("Status")}>
        <.status_pill status={@status} />
      </.row>

      <.row :if={@column_name} label={gettext("Column")}>
        <span style="color: var(--ink-2);">{@column_name}</span>
      </.row>

      <.row :if={@board_name} label={gettext("Board")}>
        <span style="color: var(--ink-2);">{@board_name}</span>
      </.row>

      <.row :if={@owner} label={gettext("Author")}>
        <span style="display: inline-flex; align-items: center; gap: 6px;">
          <Avatar.avatar
            kind={owner_kind(@owner)}
            name={owner_name(@owner)}
            palette={owner_palette(@owner)}
            size={20}
          />
          <span style="color: var(--ink-2);">{owner_name(@owner)}</span>
        </span>
      </.row>

      <.row :if={@parent_goal} label={gettext("Goal")}>
        <span style="display: inline-flex; align-items: center; gap: 6px;">
          <span style="color: var(--stride-violet); display: inline-flex;">
            <.icon name="hero-flag" class="w-3.5 h-3.5" />
          </span>
          <span class="ident" style="font-size: 11px; color: var(--ink-2);">
            {goal_identifier(@parent_goal)}
          </span>
          <span style="color: var(--ink-2);">{goal_title(@parent_goal)}</span>
        </span>
      </.row>

      <.row :if={@show_metrics? and @complexity} label={gettext("Complexity")}>
        <span style="color: var(--ink-2);">{TaskTokens.complexity_word(@complexity)}</span>
      </.row>

      <.row :if={@show_metrics? and @priority} label={gettext("Priority")}>
        <span style="display: inline-flex; align-items: center; gap: 6px;">
          <.priority_dot priority={@priority} />
          <span style="color: var(--ink-2);">{TaskTokens.priority_word(@priority)}</span>
        </span>
      </.row>

      <.row label={gettext("Needs review")}>
        <.needs_review_cell required?={@needs_review} />
      </.row>

      <.row :if={@created_at} label={gettext("Created")}>
        <span style="color: var(--ink-3); font-variant-numeric: tabular-nums;">
          {@created_at}
        </span>
      </.row>

      <.row :if={@started_at} label={gettext("Started")}>
        <span style="color: var(--ink-3); font-variant-numeric: tabular-nums;">
          {@started_at}
        </span>
      </.row>

      <.row :if={@completed_at} label={gettext("Completed")}>
        <span style="color: var(--ink-3); font-variant-numeric: tabular-nums;">
          {@completed_at}
        </span>
      </.row>
    </div>
    """
  end

  # --- Assign derivation -------------------------------------------------

  defp derive_assigns(assigns) do
    assigns
    |> assign_core()
    |> assign_owner()
    |> assign_timestamps()
    |> assign_show_metrics()
  end

  defp assign_core(assigns) do
    task = assigns.task

    assigns
    |> assign(:type, Map.get(task, :type, :work))
    |> assign(:status, Map.get(task, :status, :open))
    |> assign(:priority, Map.get(task, :priority))
    |> assign(:complexity, Map.get(task, :complexity))
    |> assign(:needs_review, Map.get(task, :needs_review, false))
    |> assign(:column_name, column_name(task))
  end

  defp assign_owner(assigns) do
    assign(assigns, :owner, pick_owner(assigns.task))
  end

  defp assign_timestamps(assigns) do
    task = assigns.task

    assigns
    |> assign(:created_at, format_dt(Map.get(task, :inserted_at)))
    |> assign(:started_at, format_dt(Map.get(task, :claimed_at)))
    |> assign(:completed_at, format_dt(Map.get(task, :completed_at)))
  end

  defp assign_show_metrics(assigns) do
    assign(assigns, :show_metrics?, assigns.type != :goal)
  end

  # --- Sub-components ----------------------------------------------------

  attr :label, :string, required: true
  slot :inner_block, required: true

  defp row(assigns) do
    ~H"""
    <div
      class="ucase"
      style={[
        "padding: 8px 12px; color: var(--ink-3);",
        "border-bottom: 1px solid var(--line);",
        "font-size: 9.5px; letter-spacing: 0.05em;"
      ]}
    >
      {@label}
    </div>
    <div style={[
      "padding: 8px 12px; border-bottom: 1px solid var(--line);"
    ]}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :status, :atom, required: true

  defp status_pill(assigns) do
    assigns =
      assigns
      |> assign(:bg, TaskTokens.status_soft(assigns.status))
      |> assign(:fg, TaskTokens.status_ink(assigns.status))
      |> assign(:label, TaskTokens.status_label(assigns.status))

    ~H"""
    <span style={[
      "display: inline-flex; align-items: center; gap: 3px;",
      "padding: 2px 7px; border-radius: 999px;",
      "background: #{@bg}; color: #{@fg};",
      "border: 1px solid transparent;",
      "font-size: 10.5px; font-weight: 600; letter-spacing: -0.005em;"
    ]}>
      {@label}
    </span>
    """
  end

  attr :priority, :atom, required: true

  defp priority_dot(assigns) do
    assigns = assign(assigns, :color, TaskTokens.priority_color(assigns.priority))

    ~H"""
    <span
      aria-hidden="true"
      style={[
        "width: 6px; height: 6px; border-radius: 50%;",
        "background: #{@color}; flex-shrink: 0;"
      ]}
    >
    </span>
    """
  end

  attr :required?, :boolean, required: true

  defp needs_review_cell(%{required?: true} = assigns) do
    ~H"""
    <span style={[
      "display: inline-flex; align-items: center; gap: 3px;",
      "padding: 2px 7px; border-radius: 999px;",
      "background: var(--st-review-soft); color: var(--st-review);",
      "font-size: 10.5px; font-weight: 600;"
    ]}>
      {gettext("Required")}
    </span>
    """
  end

  defp needs_review_cell(assigns) do
    ~H"""
    <span style="color: var(--ink-3); font-style: italic;">{gettext("Auto")}</span>
    """
  end

  # --- Field accessors ---------------------------------------------------

  defp column_name(task) do
    case Map.get(task, :column) do
      %{name: name} when is_binary(name) -> name
      _ -> nil
    end
  end

  defp pick_owner(task) do
    case Map.get(task, :assigned_to) do
      %{name: _} = user -> user
      %{} = user when map_size(user) > 0 -> user
      _ -> Map.get(task, :created_by)
    end
    |> case do
      %Ecto.Association.NotLoaded{} -> nil
      other -> other
    end
  end

  defp owner_kind(owner) do
    case Map.get(owner, :kind) do
      :agent -> :agent
      _ -> :human
    end
  end

  defp owner_name(owner) do
    Map.get(owner, :name) || Map.get(owner, :email) || gettext("Unknown")
  end

  defp owner_palette(owner) do
    case Map.get(owner, :palette) do
      palette when is_binary(palette) -> palette
      _ -> resolve_owner_palette(owner)
    end
  end

  defp resolve_owner_palette(owner) do
    case owner_kind(owner) do
      :agent -> owner |> Map.get(:name) |> AvatarPalette.for_agent()
      _ -> owner |> Map.get(:id) |> AvatarPalette.for_human()
    end
  end

  defp goal_identifier(goal), do: Map.get(goal, :identifier, "")
  defp goal_title(goal), do: Map.get(goal, :title, "")

  # --- Formatting --------------------------------------------------------

  defp format_dt(nil), do: nil

  defp format_dt(%DateTime{} = dt) do
    Calendar.strftime(dt, "%B %d, %Y at %I:%M %p")
  end

  defp format_dt(%NaiveDateTime{} = dt) do
    Calendar.strftime(dt, "%B %d, %Y at %I:%M %p")
  end

  defp format_dt(_), do: nil
end
