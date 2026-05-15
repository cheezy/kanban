defmodule KanbanWeb.TaskDetailHeader do
  @moduledoc """
  Header band for the task detail surface — the strip that anchors both
  the pane (DelayedModal) variant and the full-screen variant.

  Renders the type-accent icon, identifier, status pill, optional AI pill,
  priority dot, the complexity · priority label, an owner avatar, the
  task title, and a close affordance.

  Mirrors the pane-variant header at
  `design_handoff_stride/design_source/screens/task-detail.jsx` lines
  189-202 and the full-screen header at lines 385-412.

  ## Expected task shape

  The component reads fields off `task` via `Map.get/3` so it works on
  both `%Kanban.Tasks.Task{}` structs and plain maps assembled by the
  LiveView (`:author`, `:ai_generated?`). Recognized fields:

  | Field            | Type    | Notes                              |
  |------------------|---------|------------------------------------|
  | `:identifier`    | string  | e.g. `"W542"`                      |
  | `:title`         | string  | task title                         |
  | `:type`          | atom    | `:work \\| :defect \\| :goal`        |
  | `:status`        | atom    | `:open \\| :ready \\| :in_progress \\| :review \\| :completed` |
  | `:priority`      | atom    | `:critical \\| :high \\| :medium \\| :low` |
  | `:complexity`    | atom    | `:small \\| :medium \\| :large`      |
  | `:ai_generated?` | bool    | drives the AI pill                 |
  | `:author`        | map     | `%{kind, name, palette}` for Avatar |
  """
  use KanbanWeb, :html

  alias KanbanWeb.Avatar
  alias KanbanWeb.BoardHeader

  @doc """
  Renders the task-detail header band.

  ## Attrs

    * `task` — task map (see module @moduledoc for fields). Required.
    * `on_close` — phx-click event name pushed when the close affordance
      is activated. When `nil`, the close affordance is omitted (used
      when the parent provides its own close UI elsewhere).
    * `variant` — `:pane` (default, used in DelayedModal) or `:full`
      (used in the full-screen route). Drives outer padding only.
  """
  attr :task, :map, required: true
  attr :on_close, :string, default: nil
  attr :variant, :atom, default: :pane, values: [:pane, :full]

  def detail_header(assigns) do
    assigns = derive_assigns(assigns)

    ~H"""
    <div
      data-detail-header
      style={[
        "padding: #{@padding};",
        "border-bottom: 1px solid var(--line);",
        "background: var(--surface);",
        "display: flex; flex-direction: column; gap: 8px;"
      ]}
    >
      <div style="display: flex; align-items: center; gap: 8px; flex-wrap: wrap;">
        <.type_icon type={@type} />
        <span
          class="ident"
          style="font-size: 11.5px; color: var(--ink-2);"
        >
          {@identifier}
        </span>

        <span style={[
          "display: inline-flex; align-items: center; gap: 3px;",
          "padding: 2px 7px; border-radius: 999px;",
          "background: #{@status_bg}; color: #{@status_fg};",
          "border: 1px solid transparent;",
          "font-size: 10.5px; font-weight: 600; letter-spacing: -0.005em;"
        ]}>
          {@status_label}
        </span>

        <BoardHeader.ai_pill :if={@ai_generated?} />

        <.priority_dot :if={@priority} priority={@priority} />

        <span
          :if={@complexity || @priority}
          style="font-size: 11px; color: var(--ink-3);"
        >
          {meta_label(@complexity, @priority)}
        </span>

        <span style="flex: 1;"></span>

        <Avatar.avatar
          :if={@author}
          kind={Map.get(@author, :kind, :human)}
          name={Map.get(@author, :name, "")}
          palette={Map.get(@author, :palette)}
          size={20}
        />

        <button
          :if={@on_close}
          type="button"
          phx-click={@on_close}
          aria-label={gettext("Close task detail")}
          style={[
            "background: transparent; border: 1px solid var(--line);",
            "border-radius: 4px; padding: 1px 6px;",
            "font-family: var(--font-mono); font-size: 10px;",
            "color: var(--ink-3); cursor: pointer;"
          ]}
        >
          {gettext("Esc")}
        </button>
      </div>

      <h1 style={[
        "margin: 0; font-size: 19px; font-weight: 600;",
        "letter-spacing: -0.02em; line-height: 1.3;",
        "text-wrap: pretty; color: var(--ink);"
      ]}>
        {@title}
      </h1>
    </div>
    """
  end

  defp derive_assigns(assigns) do
    assigns
    |> assign_task_fields()
    |> assign_status_styling()
    |> assign(:padding, padding_for(assigns.variant))
  end

  defp assign_task_fields(assigns) do
    task = assigns.task

    assigns
    |> assign(:identifier, Map.get(task, :identifier, ""))
    |> assign(:title, Map.get(task, :title, ""))
    |> assign(:type, Map.get(task, :type, :work))
    |> assign(:status, Map.get(task, :status, :open))
    |> assign(:priority, Map.get(task, :priority))
    |> assign(:complexity, Map.get(task, :complexity))
    |> assign(:ai_generated?, ai_generated?(task))
    |> assign(:author, Map.get(task, :author))
  end

  defp assign_status_styling(assigns) do
    status = assigns.status

    assigns
    |> assign(:status_label, status_label(status))
    |> assign(:status_bg, status_soft(status))
    |> assign(:status_fg, status_ink(status))
  end

  # --- Sub-components ------------------------------------------------------

  attr :type, :atom, required: true

  defp type_icon(%{type: :defect} = assigns) do
    ~H"""
    <span style="color: var(--st-blocked); display: inline-flex;">
      <.icon name="hero-bug-ant" class="w-4 h-4" />
    </span>
    """
  end

  defp type_icon(%{type: :goal} = assigns) do
    ~H"""
    <span style="color: var(--stride-violet); display: inline-flex;">
      <.icon name="hero-flag" class="w-4 h-4" />
    </span>
    """
  end

  defp type_icon(assigns) do
    ~H"""
    <span style="color: var(--st-ready); display: inline-flex;">
      <.icon name="hero-document-text" class="w-4 h-4" />
    </span>
    """
  end

  attr :priority, :atom, required: true

  defp priority_dot(assigns) do
    assigns = assign(assigns, :color, priority_color(assigns.priority))

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

  defp ai_generated?(task) do
    Map.get(task, :ai_generated?, false) || Map.get(task, :ai_generated, false)
  end

  defp padding_for(:full), do: "20px 32px 16px"
  defp padding_for(_), do: "14px 22px 12px"

  defp status_label(:open), do: gettext("Open")
  defp status_label(:ready), do: gettext("Ready")
  defp status_label(:in_progress), do: gettext("Doing")
  defp status_label(:review), do: gettext("Review")
  defp status_label(:completed), do: gettext("Done")
  defp status_label(:blocked), do: gettext("Blocked")

  defp status_label(other) when is_atom(other),
    do: other |> Atom.to_string() |> String.capitalize()

  defp status_label(_), do: gettext("Open")

  defp status_soft(:open), do: "var(--st-backlog-soft)"
  defp status_soft(:ready), do: "var(--st-ready-soft)"
  defp status_soft(:in_progress), do: "var(--st-doing-soft)"
  defp status_soft(:review), do: "var(--st-review-soft)"
  defp status_soft(:completed), do: "var(--st-done-soft)"
  defp status_soft(:blocked), do: "var(--st-blocked-soft)"
  defp status_soft(_), do: "var(--st-backlog-soft)"

  defp status_ink(:open), do: "var(--st-backlog)"
  defp status_ink(:ready), do: "var(--st-ready)"
  defp status_ink(:in_progress), do: "var(--st-doing)"
  defp status_ink(:review), do: "var(--st-review)"
  defp status_ink(:completed), do: "var(--st-done)"
  defp status_ink(:blocked), do: "var(--st-blocked)"
  defp status_ink(_), do: "var(--st-backlog)"

  defp priority_color(:critical), do: "var(--pri-critical)"
  defp priority_color(:high), do: "var(--pri-high)"
  defp priority_color(:medium), do: "var(--pri-medium)"
  defp priority_color(:low), do: "var(--pri-low)"
  defp priority_color(_), do: "var(--ink-4)"

  defp meta_label(nil, nil), do: ""
  defp meta_label(complexity, nil), do: complexity_word(complexity)
  defp meta_label(nil, priority), do: priority_word(priority)

  defp meta_label(complexity, priority) do
    "#{priority_word(priority)} · #{complexity_word(complexity)}"
  end

  defp complexity_word(:small), do: gettext("Small")
  defp complexity_word(:medium), do: gettext("Medium")
  defp complexity_word(:large), do: gettext("Large")

  defp complexity_word(other) when is_atom(other),
    do: other |> Atom.to_string() |> String.capitalize()

  defp complexity_word(_), do: ""

  defp priority_word(:critical), do: gettext("Critical")
  defp priority_word(:high), do: gettext("High")
  defp priority_word(:medium), do: gettext("Medium")
  defp priority_word(:low), do: gettext("Low")

  defp priority_word(other) when is_atom(other),
    do: other |> Atom.to_string() |> String.capitalize()

  defp priority_word(_), do: ""
end
