defmodule KanbanWeb.GoalChildRow do
  @moduledoc """
  Compact row rendered inside the per-goal view's hierarchy table.
  Mirrors the `row-hover` block at lines 119-145 of
  `design_handoff_stride/design_source/screens/extras.jsx` (`GoalView`).

  Renders: priority dot, identifier, title (truncated), status pill,
  owner avatar + name (or "unassigned" when nil), and a chevron-right
  affordance. Clicking the row emits the configured phx event.
  """
  use KanbanWeb, :html

  alias KanbanWeb.Avatar
  alias KanbanWeb.TaskTokens

  @doc """
  Renders a single child-task row.

  ## Attrs

    * `task` — task struct or map (`Map.get/3` access). Recognized
      fields: `:identifier`, `:title`, `:priority`, `:status`,
      `:assigned_to` (map `%{kind, name, palette}` or nil).
    * `on_click` — phx event name pushed when the row is clicked.
      When `nil`, the row is rendered without a click handler.
  """
  attr :task, :map, required: true
  attr :on_click, :string, default: nil

  def goal_child_row(assigns) do
    assigns = derive_assigns(assigns)

    ~H"""
    <div
      data-goal-child-row
      phx-click={@on_click}
      phx-value-id={@task_id}
      style={[
        "display: grid; grid-template-columns: 22px 56px 1fr 120px 100px 18px;",
        "align-items: center; gap: 10px;",
        "padding: 8px 14px; border-bottom: 1px solid var(--line);",
        if(@on_click, do: "cursor: pointer;", else: "")
      ]}
    >
      <.priority_dot priority={@priority} />

      <span class="ident" style="font-size: 11px; color: var(--ink-2);">
        {@identifier}
      </span>

      <span style={[
        "font-size: 12.5px; font-weight: 500; color: var(--ink);",
        "overflow: hidden; text-overflow: ellipsis; white-space: nowrap;"
      ]}>
        {@title}
      </span>

      <.status_pill status={@status} />

      <.owner_cell owner={@owner} />

      <span style="color: var(--ink-4); display: inline-flex; justify-content: flex-end;">
        <.icon name="hero-chevron-right" class="w-3 h-3" />
      </span>
    </div>
    """
  end

  # --- Sub-components ----------------------------------------------------

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

  attr :status, :atom, required: true

  defp status_pill(assigns) do
    assigns =
      assigns
      |> assign(:bg, TaskTokens.status_soft(assigns.status))
      |> assign(:fg, TaskTokens.status_ink(assigns.status))
      |> assign(:label, TaskTokens.status_label(assigns.status))

    ~H"""
    <span style={[
      "display: inline-flex; align-items: center;",
      "padding: 1px 7px; border-radius: 999px;",
      "background: #{@bg}; color: #{@fg};",
      "font-size: 10.5px; font-weight: 600;"
    ]}>
      {@label}
    </span>
    """
  end

  attr :owner, :map, default: nil

  defp owner_cell(%{owner: nil} = assigns) do
    ~H"""
    <span class="ident" style="font-size: 11px; color: var(--ink-3); font-style: italic;">
      {gettext("unassigned")}
    </span>
    """
  end

  defp owner_cell(assigns) do
    ~H"""
    <span style="display: inline-flex; align-items: center; gap: 6px; font-size: 11.5px;">
      <Avatar.avatar
        kind={Map.get(@owner, :kind, :human)}
        name={Map.get(@owner, :name, "")}
        palette={Map.get(@owner, :palette)}
        size={16}
      />
      <span style="color: var(--ink-2); overflow: hidden; text-overflow: ellipsis; white-space: nowrap;">
        {Map.get(@owner, :name)}
      </span>
    </span>
    """
  end

  # --- Assign derivation -------------------------------------------------

  defp derive_assigns(assigns) do
    task = assigns.task

    assigns
    |> assign(:task_id, Map.get(task, :id))
    |> assign(:identifier, Map.get(task, :identifier, ""))
    |> assign(:title, Map.get(task, :title, ""))
    |> assign(:status, Map.get(task, :status, :open))
    |> assign(:priority, Map.get(task, :priority))
    |> assign(:owner, pick_owner(task))
  end

  defp pick_owner(task) do
    case Map.get(task, :assigned_to) do
      %{name: _} = user -> user
      _ -> nil
    end
  end
end
