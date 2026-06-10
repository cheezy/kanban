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

  import KanbanWeb.TaskVisuals

  alias KanbanWeb.Avatar
  alias KanbanWeb.BoardHeader
  alias KanbanWeb.TaskTokens

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

        <.status_pill status={@status} variant={:detail} />

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

  # --- Helpers -------------------------------------------------------------

  defp padding_for(:full), do: "20px 32px 16px"
  defp padding_for(_), do: "14px 22px 12px"

  defp meta_label(nil, nil), do: ""
  defp meta_label(complexity, nil), do: TaskTokens.complexity_word(complexity)
  defp meta_label(nil, priority), do: TaskTokens.priority_word(priority)

  defp meta_label(complexity, priority) do
    "#{TaskTokens.priority_word(priority)} · #{TaskTokens.complexity_word(complexity)}"
  end
end
