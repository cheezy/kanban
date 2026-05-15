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
      <.title_row task={@task} column={@column} />
      <p
        :if={Map.get(@task, :type) == :goal and present_text?(Map.get(@task, :description))}
        style={[
          "margin: 0; font-size: 11.5px; line-height: 1.45;",
          "color: var(--ink-3); text-wrap: pretty;",
          "display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical;",
          "overflow: hidden;"
        ]}
      >
        {@task.description}
      </p>
      <.goal_chip :if={@goal} goal={@goal} />
      <.review_footer :if={@column == :review} task={@task} />
      <.done_footer :if={@column == :done} task={@task} />
      <.backlog_meta
        :if={@column in [:backlog, :ready, :doing] and not @dense}
        task={@task}
      />
    </article>
    """
  end

  # --- Sub-renderers -------------------------------------------------------

  attr :task, :map, required: true
  attr :column, :atom, required: true

  defp top_row(assigns) do
    ~H"""
    <div style="display: flex; align-items: center; gap: 6px; min-height: 16px; padding-left: 10px;">
      <.type_icon type={@task.type} />
      <span class="ident" style="font-size: 10.5px;">{@task.identifier}</span>
      <.priority_dot level={@task.priority} />
    </div>
    """
  end

  attr :task, :map, required: true
  attr :column, :atom, required: true

  defp title_row(assigns) do
    assigns = assign(assigns, :primary_avatar, primary_avatar(assigns.task, assigns.column))

    ~H"""
    <div style="display: flex; align-items: flex-start; gap: 6px;">
      <div style={[
        "flex: 1; min-width: 0;",
        "font-size: 12.5px; line-height: 1.35; letter-spacing: -0.005em;",
        "color: var(--ink); font-weight: 500; text-wrap: pretty;"
      ]}>
        {@task.title}
      </div>
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

  attr :task, :map, required: true

  defp review_footer(assigns) do
    skipped? = Map.get(assigns.task, :reviewer_skipped?, false)

    assigns =
      assigns
      |> assign(:skipped?, skipped?)
      |> assign(:skip_reason, Map.get(assigns.task, :reviewer_skip_reason))
      |> assign(:criteria, Map.get(assigns.task, :criteria_checked))
      |> assign(:issues, Map.get(assigns.task, :issues_found))
      |> assign(:files, Map.get(assigns.task, :files_changed_count))

    ~H"""
    <div
      :if={(@skipped? or @criteria) || @issues || @files}
      style={[
        "display: flex; align-items: center; gap: 8px; flex-wrap: wrap;",
        "font-size: 10.5px; color: var(--ink-3);"
      ]}
    >
      <span
        :if={@skipped?}
        style="display: inline-flex; align-items: center; gap: 3px; color: var(--ink-3);"
      >
        <.icon name="hero-no-symbol" class="w-2.5 h-2.5" />
        {gettext("self-reviewed")}{if @skip_reason, do: " · #{format_reason(@skip_reason)}", else: ""}
      </span>

      <span
        :if={not @skipped? and @criteria}
        style="display: inline-flex; align-items: center; gap: 3px;"
      >
        <.icon name="hero-check" class="w-2.5 h-2.5" />
        {ngettext("%{count} criterion", "%{count} criteria", @criteria, count: @criteria)}
      </span>

      <span
        :if={not @skipped? and is_integer(@issues)}
        style={[
          "display: inline-flex; align-items: center; gap: 3px;",
          "color: #{issues_color(@issues)};"
        ]}
      >
        <.icon name={issues_icon(@issues)} class="w-2.5 h-2.5" />
        {ngettext("%{count} issue", "%{count} issues", @issues, count: @issues)}
      </span>

      <span
        :if={@files}
        style="display: inline-flex; align-items: center; gap: 3px;"
      >
        <.icon name="hero-document" class="w-2.5 h-2.5" />
        {ngettext("%{count} file", "%{count} files", @files, count: @files)}
      </span>
    </div>
    """
  end

  attr :task, :map, required: true

  defp done_footer(assigns) do
    cycle = Map.get(assigns.task, :cycle_time)
    files = Map.get(assigns.task, :files_changed_count)
    actual = Map.get(assigns.task, :actual_complexity)

    assigns =
      assigns
      |> assign(:cycle, cycle)
      |> assign(:files, files)
      |> assign(:actual, actual)

    ~H"""
    <div
      :if={@cycle || @files || @actual}
      style={[
        "display: flex; align-items: center; gap: 8px; flex-wrap: wrap;",
        "font-size: 10.5px; color: var(--ink-3);"
      ]}
    >
      <span
        :if={@cycle}
        class="ident"
        style="display: inline-flex; align-items: center; gap: 3px;"
      >
        <.icon name="hero-clock" class="w-2.5 h-2.5" />
        {gettext("cycle %{time}", time: @cycle)}
      </span>

      <span
        :if={@files}
        style="display: inline-flex; align-items: center; gap: 3px;"
      >
        <.icon name="hero-document" class="w-2.5 h-2.5" />
        {ngettext("%{count} file", "%{count} files", @files, count: @files)}
      </span>

      <span
        :if={@actual}
        style="display: inline-flex; align-items: center; gap: 3px;"
      >
        {gettext("actual: %{size}", size: Atom.to_string(@actual))}
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

  defp issues_color(0), do: "var(--st-done)"
  defp issues_color(n) when is_integer(n) and n > 0, do: "var(--st-blocked)"
  defp issues_color(_), do: "var(--ink-3)"

  defp issues_icon(0), do: "hero-check-badge"
  defp issues_icon(_), do: "hero-exclamation-triangle"

  # Stride's reviewer skip-reason enum surfaces directly from the API
  # payload as a snake_case string. The card has very limited room, so
  # the format here is "decision matrix" / "self-reported" / etc. —
  # punchy enough to read at a glance without truncating.
  defp format_reason("decision_matrix_skip"), do: gettext("decision matrix")
  defp format_reason("small_task_0_1_key_files"), do: gettext("small task")
  defp format_reason("trivial_change_docs_only"), do: gettext("trivial change")
  defp format_reason("self_reported_exploration"), do: gettext("self-explored")
  defp format_reason("self_reported_review"), do: gettext("self-reviewed")
  defp format_reason("no_subagent_support"), do: gettext("no subagent")
  defp format_reason(other) when is_binary(other), do: other
  defp format_reason(_), do: ""

  defp present_text?(nil), do: false
  defp present_text?(""), do: false
  defp present_text?(s) when is_binary(s), do: String.trim(s) != ""
  defp present_text?(_), do: false
end
