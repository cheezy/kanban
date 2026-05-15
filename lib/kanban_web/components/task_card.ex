defmodule KanbanWeb.TaskCard do
  @moduledoc """
  Rich task tile shown inside a kanban column. Mirrors the `TaskCard`
  JSX block at lines 45-188 of
  `design_handoff_stride/design_source/screens/board-kanban.jsx`.

  Renders type icon + identifier + priority dot + claimed/completed/
  author avatar + title + optional goal chip + per-column footer
  (doing-hook chip, review diff+tests, backlog/ready meta, done cycle
  time). A `dense` variant tightens padding for compact columns. When
  `task.type == :goal`, delegates to `KanbanWeb.GoalCard.goal_card/1`.

  ## Expected task shape

  The component uses `Map.get/3` so it works on both `%Kanban.Tasks.Task{}`
  structs (with the canonical fields `:identifier`, `:type`, `:priority`,
  `:title`) and on plain maps assembled by the LiveView for fields the
  schema doesn't carry directly (`:claimed_by`, `:completed_by`,
  `:author`, `:goal`, `:hook`, `:diff`, `:tests_passed`,
  `:tests_total`). Each avatar field, when present, is a
  `%{kind, name, palette}` map ready to pass to
  `KanbanWeb.Avatar.avatar/1`.
  """
  use KanbanWeb, :html

  alias KanbanWeb.Avatar
  alias KanbanWeb.GoalCard

  @doc """
  Renders a task card.

  ## Attrs

    * `task` — task struct or map (see module @moduledoc for fields).
      Required.
    * `column` — the column atom this card is rendered in
      (`:backlog | :ready | :doing | :review | :done`). Drives the
      per-column footer rendering. Default `:backlog`.
    * `dense` — when true, tighter padding and gap. Default false.
  """
  attr :task, :map, required: true
  attr :column, :atom, default: :backlog
  attr :dense, :boolean, default: false

  def task_card(assigns) do
    if assigns.task.type == :goal do
      ~H"""
      <GoalCard.goal_card task={@task} column={@column} dense={@dense} />
      """
    else
      regular_card(assigns)
    end
  end

  defp regular_card(assigns) do
    goal = Map.get(assigns.task, :goal)

    assigns =
      assigns
      |> assign(:goal, goal)
      |> assign(:padding, if(assigns.dense, do: "6px 8px", else: "8px 10px"))
      |> assign(:gap, if(assigns.dense, do: 4, else: 6))
      |> assign(:left_border, left_border_for(goal))

    ~H"""
    <article style={[
      "background: var(--surface); border: 1px solid var(--line);",
      "border-radius: 6px; padding: #{@padding};",
      "box-shadow: var(--shadow-sm);",
      "display: flex; flex-direction: column; gap: #{@gap}px;",
      "cursor: grab; position: relative; overflow: hidden;",
      "border-left: #{@left_border};"
    ]}>
      <.top_row task={@task} column={@column} />
      <div style={[
        "font-size: 12.5px; line-height: 1.35; letter-spacing: -0.005em;",
        "color: var(--ink); font-weight: 500; text-wrap: pretty;"
      ]}>
        {@task.title}
      </div>
      <.goal_chip :if={@goal} goal={@goal} />
      <.doing_hook :if={@column == :doing} hook={Map.get(@task, :hook)} />
      <.review_diff :if={@column == :review} task={@task} />
      <.backlog_meta :if={@column in [:backlog, :ready] and not @dense} task={@task} />
      <span
        :if={@column == :done and Map.get(@task, :cycle_time)}
        class="ident"
        style="font-size: 10.5px;"
      >
        {gettext("cycle %{time}", time: @task.cycle_time)}
      </span>
    </article>
    """
  end

  # --- Sub-renderers -------------------------------------------------------

  attr :task, :map, required: true
  attr :column, :atom, required: true

  defp top_row(assigns) do
    assigns = assign(assigns, :primary_avatar, primary_avatar(assigns.task, assigns.column))

    ~H"""
    <div style="display: flex; align-items: center; gap: 6px; min-height: 16px;">
      <.type_icon type={@task.type} />
      <span class="ident" style="font-size: 10.5px;">{@task.identifier}</span>
      <.priority_dot level={@task.priority} />
      <span style="flex: 1;"></span>
      <Avatar.avatar
        :if={@primary_avatar}
        kind={@primary_avatar.kind}
        name={@primary_avatar.name}
        palette={Map.get(@primary_avatar, :palette)}
        size={16}
      />
    </div>
    """
  end

  attr :type, :atom, required: true

  defp type_icon(%{type: :defect} = assigns) do
    ~H"""
    <span style="color: var(--st-blocked); display: inline-flex;">
      <.icon name="hero-bug-ant" class="w-3 h-3" />
    </span>
    """
  end

  defp type_icon(%{type: :goal} = assigns) do
    ~H"""
    <span style="color: var(--stride-violet); display: inline-flex;">
      <.icon name="hero-flag" class="w-3 h-3" />
    </span>
    """
  end

  defp type_icon(assigns) do
    # Default: :work
    ~H"""
    <span style="color: var(--st-ready); display: inline-flex;">
      <.icon name="hero-document-text" class="w-3 h-3" />
    </span>
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

  attr :goal, :map, required: true

  defp goal_chip(assigns) do
    ~H"""
    <div style={[
      "display: inline-flex; align-items: center; gap: 4px;",
      "font-size: 10.5px; color: #{Map.get(@goal, :ink, "var(--ink-3)")};",
      "align-self: flex-start;"
    ]}>
      <.icon name="hero-flag" class="w-2.5 h-2.5" />
      <span class="ident" style="font-size: 10px; opacity: 0.85;">
        {Map.get(@goal, :identifier) || Map.get(@goal, :id)}
      </span>
      <span style="overflow: hidden; text-overflow: ellipsis; white-space: nowrap; max-width: 130px;">
        {Map.get(@goal, :short) || Map.get(@goal, :name)}
      </span>
    </div>
    """
  end

  attr :hook, :map, default: nil

  defp doing_hook(assigns) do
    ~H"""
    <div
      :if={@hook}
      style={[
        "display: flex; align-items: center; gap: 5px;",
        "padding: 3px 6px; border-radius: 4px;",
        "background: #{hook_bg(@hook[:status])};",
        "color: #{hook_fg(@hook[:status])};",
        "font-size: 11px; font-family: var(--font-mono);"
      ]}
    >
      <.icon
        :if={@hook[:status] == :running}
        name="hero-arrow-path"
        class="w-2.5 h-2.5 motion-safe:animate-spin"
      />
      <.icon :if={@hook[:status] != :running} name="hero-check" class="w-2.5 h-2.5" />
      {@hook[:name]} · {if @hook[:status] == :running, do: gettext("running"), else: gettext("ok")}
    </div>
    """
  end

  attr :task, :map, required: true

  defp review_diff(assigns) do
    diff = Map.get(assigns.task, :diff)
    passed = Map.get(assigns.task, :tests_passed)
    total = Map.get(assigns.task, :tests_total)
    assigns = assigns |> assign(:diff, diff) |> assign(:passed, passed) |> assign(:total, total)

    ~H"""
    <div
      :if={@diff}
      style={[
        "display: flex; align-items: center; gap: 8px;",
        "font-size: 11px; font-family: var(--font-mono); color: var(--ink-3);"
      ]}
    >
      <span style="color: var(--st-done);">+{Map.get(@diff, :added, 0)}</span>
      <span style="color: var(--st-blocked);">−{Map.get(@diff, :removed, 0)}</span>
      <span :if={@total}>·</span>
      <span :if={@total} style={"color: #{tests_color(@passed, @total)};"}>
        {@passed}/{@total} {gettext("tests")}
      </span>
    </div>
    """
  end

  attr :task, :map, required: true

  defp backlog_meta(assigns) do
    key_files = Map.get(assigns.task, :key_files_count)
    deps = Map.get(assigns.task, :deps_count)
    acceptance = Map.get(assigns.task, :acceptance_count)
    needs_review = Map.get(assigns.task, :needs_review, false)

    assigns =
      assigns
      |> assign(:key_files, key_files)
      |> assign(:deps, deps)
      |> assign(:acceptance, acceptance)
      |> assign(:needs_review, needs_review)
      |> assign(:any_meta?, key_files || deps || acceptance || needs_review)

    ~H"""
    <div
      :if={@any_meta?}
      style={[
        "display: flex; align-items: center; gap: 8px;",
        "color: var(--ink-3); font-size: 10.5px;"
      ]}
    >
      <span :if={@key_files} style="display: inline-flex; align-items: center; gap: 3px;">
        <.icon name="hero-document" class="w-2.5 h-2.5" />{@key_files}
      </span>
      <span
        :if={@deps && @deps > 0}
        style="display: inline-flex; align-items: center; gap: 3px; color: var(--st-blocked);"
      >
        <.icon name="hero-link" class="w-2.5 h-2.5" />{@deps}
      </span>
      <span :if={@acceptance} style="display: inline-flex; align-items: center; gap: 3px;">
        <.icon name="hero-check" class="w-2.5 h-2.5" />{@acceptance}
      </span>
      <span
        :if={@needs_review}
        style={[
          "margin-left: auto; padding: 0 5px; border-radius: 3px;",
          "background: var(--st-review-soft); color: var(--st-review);",
          "font-family: var(--font-mono); font-size: 9.5px; font-weight: 600;"
        ]}
      >
        {gettext("review")}
      </span>
    </div>
    """
  end

  # --- Helpers -------------------------------------------------------------

  defp priority_color(:critical), do: "var(--pri-critical)"
  defp priority_color(:high), do: "var(--pri-high)"
  defp priority_color(:medium), do: "var(--pri-medium)"
  defp priority_color(:low), do: "var(--pri-low)"
  defp priority_color(_), do: "var(--ink-4)"

  # The primary avatar slot at the top-right of the card: prefer
  # claimed_by, then column-dependent completed_by, then author.
  defp primary_avatar(task, column) do
    claimed = Map.get(task, :claimed_by)
    completed = Map.get(task, :completed_by)
    author = Map.get(task, :author)

    cond do
      claimed -> claimed
      column in [:review, :done] and completed -> completed
      author -> author
      true -> nil
    end
  end

  defp left_border_for(nil), do: "1px solid var(--line)"
  defp left_border_for(%{color: color}), do: "3px solid #{color}"
  defp left_border_for(_), do: "1px solid var(--line)"

  defp hook_bg(:running), do: "var(--st-doing-soft)"
  defp hook_bg(_), do: "var(--st-done-soft)"

  defp hook_fg(:running), do: "var(--st-doing)"
  defp hook_fg(_), do: "var(--st-done)"

  defp tests_color(passed, total) when passed == total, do: "var(--st-done)"
  defp tests_color(_passed, _total), do: "var(--st-blocked)"
end
