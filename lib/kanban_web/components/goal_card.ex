defmodule KanbanWeb.GoalCard do
  @moduledoc """
  Goal-type task card variant. **Stub created by W533 so TaskCard can
  delegate today; W534 enriches this with the full violet treatment and
  its own test suite.**

  Renders a minimal violet-tinted card so the goal-type branch on
  TaskCard has a working delegation target. The full design (progress
  bar, child counts, goal swatch) lands in W534.
  """
  use KanbanWeb, :html

  @doc """
  Renders a goal-type task card (stub — see module @moduledoc).

  ## Attrs

    * `task` — a map (or `%Kanban.Tasks.Task{}`) with `:identifier`,
      `:title`. Required.
    * `column` — the column atom (`:backlog | :ready | :doing | :review
      | :done`). Used by the full W534 implementation to vary the card
      treatment per column.
    * `dense` — when true, tighter padding. Default false.
  """
  attr :task, :map, required: true
  attr :column, :atom, default: :backlog
  attr :dense, :boolean, default: false

  def goal_card(assigns) do
    ~H"""
    <article
      data-goal-card-stub="true"
      style={[
        "background: var(--stride-violet-soft);",
        "border: 1px solid var(--line);",
        "border-left: 3px solid var(--stride-violet);",
        "border-radius: 6px;",
        "padding: #{if @dense, do: "6px 8px", else: "8px 10px"};",
        "box-shadow: var(--shadow-sm);",
        "display: flex; flex-direction: column; gap: #{if @dense, do: 4, else: 6}px;",
        "color: var(--stride-violet-ink);"
      ]}
    >
      <div style="display: flex; align-items: center; gap: 6px;">
        <.icon name="hero-flag" class="w-3 h-3" />
        <span class="ident" style="font-size: 10.5px;">{@task.identifier}</span>
      </div>
      <div style="font-size: 12.5px; font-weight: 600; line-height: 1.35;">
        {@task.title}
      </div>
    </article>
    """
  end
end
