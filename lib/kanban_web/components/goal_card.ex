defmodule KanbanWeb.GoalCard do
  @moduledoc """
  Violet-treated card variant for `task.type == :goal`. A goal lives in a
  column like any task, but carries child progress and uses its own
  accent color (defaulting to `--stride-violet*` when the caller does
  not supply one).

  Mirrors the `GoalCard` JSX block at lines 189-265 of
  `design_handoff_stride/design_source/screens/board-kanban.jsx`.

  ## Expected task shape

  Same duck-typed approach as `KanbanWeb.TaskCard`: works with both
  `%Kanban.Tasks.Task{}` structs (using `:identifier`, `:title`,
  `:priority`) and plain maps the LiveView assembles for fields the
  schema does not carry directly:

    * `:summary` — optional short description rendered under the title
      (falls back to `:description` when present).
    * `:children` — `%{done, total, review, doing, ready}` map driving
      the segmented progress bar. Omitted when nil.
    * `:author` — `%{kind, name, palette}` avatar map for the top-right
      slot. Optional.
    * `:goal_color`, `:goal_soft`, `:goal_ink` — optional override
      tokens. Default to `var(--stride-violet)`, `--stride-violet-soft`,
      `--stride-violet-ink`.
    * `:promoted` — boolean. When false (default), the "Promote
      children to Ready" affordance is shown.
  """
  use KanbanWeb, :html

  alias KanbanWeb.Avatar

  @default_color "var(--stride-violet)"
  @default_soft "var(--stride-violet-soft)"
  @default_ink "var(--stride-violet-ink)"

  @doc """
  Renders a goal-type task card.

  ## Attrs

    * `task` — task struct or map (see module @moduledoc). Required.
    * `column` — column atom (`:backlog | :ready | :doing | :review | :done`).
      Currently informational; kept for parity with TaskCard. Default `:backlog`.
    * `dense` — when true, tighter padding. Default false.
  """
  attr :task, :map, required: true
  attr :column, :atom, default: :backlog
  attr :dense, :boolean, default: false

  def goal_card(assigns) do
    assigns = derive_assigns(assigns)

    ~H"""
    <article style={[
      "background: #{@soft};",
      "border: 1px solid #{@color};",
      "border-radius: 6px;",
      "padding: #{@padding};",
      "box-shadow: var(--shadow-sm), inset 3px 0 0 #{@color};",
      "display: flex; flex-direction: column; gap: #{@gap}px;",
      "cursor: grab; position: relative;"
    ]}>
      <.top_row task={@task} color={@color} ink={@ink} author={@author} />

      <div style={[
        "font-size: 13px; line-height: 1.3; letter-spacing: -0.005em;",
        "font-weight: 600; color: var(--ink); text-wrap: pretty;"
      ]}>
        {@task.title}
      </div>

      <p
        :if={present?(@summary)}
        style="margin: 0; font-size: 11px; line-height: 1.4; color: var(--ink-2); text-wrap: pretty;"
      >
        {@summary}
      </p>

      <.progress :if={@children} children={@children} ink={@ink} />

      <button
        :if={not @promoted}
        type="button"
        phx-click="promote_goal_to_ready"
        phx-value-id={Map.get(@task, :id)}
        title={gettext("Move goal and tasks to Ready")}
        style={[
          "margin-top: 2px; padding: 4px 8px; border-radius: 4px;",
          "background: #{@color}; color: white; border: none;",
          "font-size: 11px; font-weight: 500; cursor: pointer;",
          "display: inline-flex; align-items: center; gap: 5px; align-self: flex-start;"
        ]}
      >
        {gettext("Promote children to Ready")}
        <.icon name="hero-arrow-right" class="w-2.5 h-2.5" />
      </button>
    </article>
    """
  end

  defp derive_assigns(assigns) do
    task = assigns.task
    summary = Map.get(task, :summary) || Map.get(task, :description)

    assigns
    |> assign(:children, Map.get(task, :children))
    |> assign(:color, Map.get(task, :goal_color, @default_color))
    |> assign(:soft, Map.get(task, :goal_soft, @default_soft))
    |> assign(:ink, Map.get(task, :goal_ink, @default_ink))
    |> assign(:summary, summary)
    |> assign(:author, Map.get(task, :author))
    |> assign(:promoted, Map.get(task, :promoted, false))
    |> assign(:padding, padding_for(assigns.dense))
    |> assign(:gap, if(assigns.dense, do: 5, else: 7))
  end

  defp padding_for(true), do: "6px 8px 6px 12px"
  defp padding_for(_), do: "9px 11px 9px 14px"

  # --- Sub-renderers -------------------------------------------------------

  attr :task, :map, required: true
  attr :color, :string, required: true
  attr :ink, :string, required: true
  attr :author, :map, default: nil

  defp top_row(assigns) do
    ~H"""
    <div style="display: flex; align-items: center; gap: 6px;">
      <span
        aria-hidden="true"
        style={[
          "width: 16px; height: 16px; border-radius: 4px;",
          "background: #{@color}; color: white;",
          "display: inline-flex; align-items: center; justify-content: center;"
        ]}
      >
        <.icon name="hero-flag" class="w-2.5 h-2.5" />
      </span>
      <span class="ident" style={"font-size: 10.5px; color: #{@ink}; font-weight: 600;"}>
        {@task.identifier}
      </span>
      <span style={[
        "font-size: 9.5px; padding: 0 5px; border-radius: 3px;",
        "background: #{@color}; color: white;",
        "font-family: var(--font-mono); letter-spacing: 0.02em; font-weight: 600;"
      ]}>
        {gettext("GOAL")}
      </span>
      <.priority_dot level={Map.get(@task, :priority, :medium)} />
      <span style="flex: 1;"></span>
      <Avatar.avatar
        :if={@author}
        kind={@author.kind}
        name={@author.name}
        palette={Map.get(@author, :palette)}
        size={16}
      />
    </div>
    """
  end

  attr :children, :map, required: true
  attr :ink, :string, required: true

  defp progress(assigns) do
    total = Map.get(assigns.children, :total, 0)
    done = Map.get(assigns.children, :done, 0)
    review = Map.get(assigns.children, :review, 0)
    doing = Map.get(assigns.children, :doing, 0)
    ready = Map.get(assigns.children, :ready, 0)
    pct = if total > 0, do: round(done / total * 100), else: 0

    assigns =
      assigns
      |> assign(:total, total)
      |> assign(:done, done)
      |> assign(:review, review)
      |> assign(:doing, doing)
      |> assign(:ready, ready)
      |> assign(:pct, pct)

    ~H"""
    <div>
      <div style={[
        "display: flex; align-items: baseline; gap: 6px; margin-bottom: 4px;",
        "font-size: 10.5px; font-family: var(--font-mono);"
      ]}>
        <span style={"color: #{@ink}; font-weight: 600;"}>{@done}/{@total}</span>
        <span style="color: var(--ink-3);">
          {gettext("children complete")} · {@pct}%
        </span>
      </div>
      <div style={[
        "height: 4px; border-radius: 2px;",
        "background: rgba(255, 255, 255, 0.6); overflow: hidden;",
        "display: flex;"
      ]}>
        <span
          :if={@done > 0}
          style={"width: #{segment_pct(@done, @total)}%; background: var(--st-done);"}
        >
        </span>
        <span
          :if={@review > 0}
          style={"width: #{segment_pct(@review, @total)}%; background: var(--st-review);"}
        >
        </span>
        <span
          :if={@doing > 0}
          style={"width: #{segment_pct(@doing, @total)}%; background: var(--st-doing);"}
        >
        </span>
        <span
          :if={@ready > 0}
          style={"width: #{segment_pct(@ready, @total)}%; background: var(--st-ready);"}
        >
        </span>
      </div>
    </div>
    """
  end

  attr :level, :atom, required: true

  defp priority_dot(assigns) do
    assigns = assign(assigns, :color, priority_color(assigns.level))

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

  # --- Helpers -------------------------------------------------------------

  defp segment_pct(_count, 0), do: 0
  defp segment_pct(count, total), do: round(count / total * 100)

  defp priority_color(:critical), do: "var(--pri-critical)"
  defp priority_color(:high), do: "var(--pri-high)"
  defp priority_color(:medium), do: "var(--pri-medium)"
  defp priority_color(:low), do: "var(--pri-low)"
  defp priority_color(_), do: "var(--ink-4)"

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(s) when is_binary(s), do: String.trim(s) != ""
  defp present?(_), do: false
end
