defmodule KanbanWeb.MarketingMiniBoard do
  @moduledoc """
  Standalone visual mock of a 4-column Stride Kanban board, rendered inside
  the landing-page hero. Lives in its own module so the parent
  `KanbanWeb.MarketingComponents` stays under the project's 500-line module
  size guideline.

  Mirrors the `MiniBoard` function in
  `design_handoff_stride/design_source/screens/landing.jsx` (lines ~6-99).

  The mini-board is a **pure visual mock** — it never reads real data. Card
  content is hardcoded so the marketing page does not depend on board state.

  Render inside the `.stride-marketing` CSS scope so the design tokens
  (`--surface`, `--line`, `--st-*`, `--pri-*`) resolve.
  """
  use KanbanWeb, :html

  alias KanbanWeb.Avatar

  @doc """
  Renders the 4-column mini-board: titlebar (traffic lights, STR badge,
  "Stride core", agents-online status) + Ready / Doing / Review / Done
  columns with realistic task cards.

  ## Examples

      <.marketing_mini_board />
  """
  def marketing_mini_board(assigns) do
    assigns = assign(assigns, :columns, mini_board_columns())

    ~H"""
    <div
      class="overflow-hidden"
      style="background: var(--surface); border: 1px solid var(--line); border-radius: 12px; box-shadow: var(--shadow-lg);"
    >
      <div
        class="flex items-center gap-1.5 px-2.5"
        style="height: 32px; background: var(--surface-2); border-bottom: 1px solid var(--line);"
      >
        <span class="rounded-full" style="width: 10px; height: 10px; background: oklch(75% 0.13 25);">
        </span>
        <span class="rounded-full" style="width: 10px; height: 10px; background: oklch(80% 0.13 80);">
        </span>
        <span class="rounded-full" style="width: 10px; height: 10px; background: oklch(70% 0.14 145);">
        </span>
        <span
          class="inline-flex items-center ml-2.5 text-[11.5px] font-medium"
          style="color: var(--ink-2);"
        >
          <span
            class="inline-flex items-center justify-center mr-1.5 text-white font-bold"
            style="width: 12px; height: 12px; border-radius: 3px; background: var(--stride-orange); font-size: 7.5px; font-family: var(--font-mono); letter-spacing: -0.02em;"
          >
            STR
          </span>
          {gettext("Stride core")}
        </span>
        <span class="flex-1"></span>
        <span
          class="inline-flex items-center gap-1.5 text-[10.5px]"
          style="color: var(--st-done);"
        >
          <span class="rounded-full" style="width: 5px; height: 5px; background: currentColor;">
          </span>
          {gettext("4 agents online")}
        </span>
      </div>

      <div
        class="grid"
        style="grid-template-columns: repeat(4, 1fr); gap: 1px; background: var(--line);"
      >
        <div :for={col <- @columns} style="background: var(--surface);">
          <div
            class="flex items-center gap-1.5 px-2.5 py-1.5"
            style="border-bottom: 1px solid var(--line);"
          >
            <span
              class="rounded-full"
              style={"width: 7px; height: 7px; background: var(--st-#{col.id});"}
            >
            </span>
            <span class="text-[11.5px] font-semibold">{col.name}</span>
            <span class="text-[10.5px]" style="font-family: var(--font-mono); color: var(--ink-3);">
              {col.count}
            </span>
          </div>
          <div class="flex flex-col gap-1.5 p-1.5">
            <div
              :for={task <- col.tasks}
              class="flex flex-col gap-[3px] p-[6px_7px]"
              style="background: var(--surface); border: 1px solid var(--line); border-radius: 5px;"
            >
              <div class="flex items-center gap-1">
                <.mini_type_icon />
                <span
                  class="text-[9.5px]"
                  style="font-family: var(--font-mono); color: var(--ink-3); letter-spacing: -0.01em;"
                >
                  {task.id}
                </span>
                <.mini_priority_dot level={task.priority} />
                <span class="flex-1"></span>
                <Avatar.avatar
                  kind={task.who.kind}
                  name={task.who.name}
                  palette={task.who.palette}
                  size={14}
                />
              </div>
              <div class="text-[10.5px] font-medium" style="line-height: 1.3;">
                {task.title}
              </div>
              <div
                :if={Map.get(task, :hook)}
                class="text-[9.5px]"
                style="color: var(--st-doing); font-family: var(--font-mono);"
              >
                {task.hook}
              </div>
              <div
                :if={Map.get(task, :diff_plus)}
                class="text-[9.5px]"
                style="color: var(--ink-3); font-family: var(--font-mono);"
              >
                <span style="color: var(--st-done);">{task.diff_plus}</span>
                <span style="color: var(--st-blocked);">{task.diff_minus}</span> · {task.tests} ✓
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp mini_type_icon(assigns) do
    ~H"""
    <span
      class="inline-flex items-center justify-center tone-work"
      style="width: 14px; height: 14px; border-radius: 4px;"
    >
      <svg
        width="9"
        height="9"
        viewBox="0 0 16 16"
        fill="none"
        stroke="currentColor"
        stroke-width="1.6"
        stroke-linecap="round"
      >
        <path d="M3 5h10M3 8h10M3 11h7" />
      </svg>
    </span>
    """
  end

  attr :level, :string, required: true

  defp mini_priority_dot(assigns) do
    ~H"""
    <span
      class="rounded-full"
      style={"width: 6px; height: 6px; background: var(--pri-#{@level});"}
    >
    </span>
    """
  end

  defp mini_board_columns do
    [
      %{
        id: :ready,
        name: gettext("Ready"),
        count: 8,
        tasks: [
          %{
            id: "W198",
            title: gettext("Persist field_visibility on board edit"),
            priority: "high",
            who: %{name: "Jamie K", kind: :human, palette: "human-green"}
          },
          %{
            id: "W199",
            title: gettext("Rotate API tokens without breaking claims"),
            priority: "critical",
            who: %{name: "Rohan S", kind: :human, palette: "human-green"}
          }
        ]
      },
      %{
        id: :doing,
        name: gettext("Doing"),
        count: 3,
        tasks: [
          %{
            id: "W193",
            title: gettext("Stream task_moved via PubSub"),
            priority: "high",
            who: %{name: "Claude", kind: :agent, palette: "agent-claude"},
            hook: gettext("before_doing · ok")
          },
          %{
            id: "W194",
            title: gettext("Inline TaskDetail panel"),
            priority: "medium",
            who: %{name: "Cursor", kind: :agent, palette: "agent-cursor"},
            hook: gettext("running")
          }
        ]
      },
      %{
        id: :review,
        name: gettext("Review"),
        count: 5,
        tasks: [
          %{
            id: "W189",
            title: gettext("Capability filter on claim endpoint"),
            priority: "high",
            who: %{name: "Claude", kind: :agent, palette: "agent-claude"},
            diff_plus: "+142",
            diff_minus: "−38",
            tests: "47/47"
          }
        ]
      },
      %{
        id: :done,
        name: gettext("Done"),
        count: 142,
        tasks: [
          %{
            id: "W185",
            title: gettext("Add before_review hook (PR creation)"),
            priority: "high",
            who: %{name: "Claude", kind: :agent, palette: "agent-claude"}
          }
        ]
      }
    ]
  end
end
