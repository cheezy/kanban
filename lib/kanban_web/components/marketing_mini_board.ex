defmodule KanbanWeb.MarketingMiniBoard do
  @moduledoc """
  Standalone visual mock of a 5-column Stride Kanban board, rendered inside
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
      data-decorative="true"
      aria-hidden="true"
      style="background: var(--surface); border: 1px solid var(--line); border-radius: 12px; box-shadow: var(--shadow-lg);"
    >
      <div
        class="flex items-center gap-1.5 px-2.5"
        style="height: 32px; background: var(--surface-2); border-bottom: 1px solid var(--line);"
      >
        <%!-- dark-mode-ignore: brand status dot (red), fixed contrast on both themes --%>
        <span class="rounded-full" style="width: 10px; height: 10px; background: oklch(75% 0.13 25);">
        </span>
        <%!-- dark-mode-ignore: brand status dot (yellow), fixed contrast on both themes --%>
        <span class="rounded-full" style="width: 10px; height: 10px; background: oklch(80% 0.13 80);">
        </span>
        <%!-- dark-mode-ignore: brand status dot (green), fixed contrast on both themes --%>
        <span class="rounded-full" style="width: 10px; height: 10px; background: oklch(70% 0.14 145);">
        </span>
        <span
          class="inline-flex items-center ml-2.5 text-[11.5px] font-medium"
          style="color: var(--ink-2);"
        >
          <span
            class="inline-flex items-center justify-center mr-1.5 text-primary-content font-bold"
            style="width: 12px; height: 12px; border-radius: 3px; background: var(--stride-orange); font-size: 7.5px; font-family: var(--font-mono); letter-spacing: -0.02em;"
          >
            STR
          </span>
          {gettext("Stride core")}
        </span>
      </div>

      <div
        class="grid p-2 gap-2"
        style="grid-template-columns: repeat(5, 1fr); background: var(--surface-sunken);"
      >
        <div
          :for={col <- @columns}
          class="rounded-lg p-2"
          style="background: linear-gradient(to bottom right, var(--surface-2), var(--surface-sunken)); border: 1px solid var(--line); box-shadow: var(--shadow-sm);"
        >
          <div
            class="flex items-center gap-2"
            style="padding: 4px 4px 6px 4px; border-bottom: 1px solid var(--line); margin-bottom: 6px;"
          >
            <span
              aria-hidden="true"
              style={"width: 8px; height: 8px; border-radius: 50%; background: var(--st-#{col.id}); flex-shrink: 0;"}
            >
            </span>
            <span
              class="text-[11.5px] font-semibold"
              style="letter-spacing: -0.005em; color: var(--ink);"
            >
              {col.name}
            </span>
            <span
              class="text-[10.5px]"
              style="font-family: var(--font-mono); color: var(--ink-3); background: var(--surface); padding: 0 5px; border-radius: 3px; font-weight: 500;"
            >
              {col.count}
            </span>
          </div>
          <div class="flex flex-col gap-1.5">
            <article
              :for={task <- col.tasks}
              class="flex flex-col gap-1.5 p-[8px_10px]"
              style="background: var(--surface); border: 1px solid var(--line); border-radius: 6px; box-shadow: var(--shadow-sm); border-left: 1px solid var(--line);"
            >
              <div class="flex items-center gap-1.5" style="min-height: 16px; padding-left: 10px;">
                <.mini_type_icon />
                <span
                  class="text-[10.5px] ident"
                  style="font-family: var(--font-mono); color: var(--ink-3); letter-spacing: -0.01em;"
                >
                  {task.id}
                </span>
                <.mini_priority_dot level={task.priority} />
              </div>
              <div class="flex items-start gap-1.5">
                <div
                  class="text-[11px] font-medium flex-1 min-w-0"
                  style="line-height: 1.35; letter-spacing: -0.005em; color: var(--ink);"
                >
                  {task.title}
                </div>
                <Avatar.avatar
                  kind={task.who.kind}
                  name={task.who.name}
                  palette={task.who.palette}
                  size={16}
                />
              </div>
              <.mini_meta_row :if={Map.get(task, :meta, []) != []} items={task.meta} />
            </article>
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

  attr :items, :list, required: true

  defp mini_meta_row(assigns) do
    ~H"""
    <div
      class="flex items-center gap-2 flex-wrap text-[9.5px]"
      style="color: var(--ink-3);"
    >
      <span
        :for={item <- @items}
        class="inline-flex items-center gap-[3px]"
        style={"color: #{Map.get(item, :color, "var(--ink-3)")};"}
      >
        <.icon :if={Map.get(item, :icon)} name={item.icon} class="w-2.5 h-2.5" />{item.text}
      </span>
    </div>
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
        id: :backlog,
        name: gettext("Backlog"),
        count: 24,
        tasks: [
          %{
            id: "W201",
            title: gettext("Audit log for column reordering"),
            priority: "medium",
            who: %{name: "Jamie K", kind: :human, palette: "human-green"},
            meta: [
              %{icon: "hero-document", text: "2"},
              %{icon: "hero-check", text: "4"}
            ]
          },
          %{
            id: "W202",
            title: gettext("Audit untranslated strings in shared chrome"),
            priority: "high",
            who: %{name: "Rohan S", kind: :human, palette: "human-green"},
            meta: [
              %{icon: "hero-document", text: "5"},
              %{icon: "hero-link", text: "1", color: "var(--st-blocked)"}
            ]
          }
        ]
      },
      %{
        id: :ready,
        name: gettext("Ready"),
        count: 8,
        tasks: [
          %{
            id: "W198",
            title: gettext("Persist field_visibility on board edit"),
            priority: "high",
            who: %{name: "Jamie K", kind: :human, palette: "human-green"},
            meta: [
              %{icon: "hero-document", text: "3"},
              %{icon: "hero-check", text: "6"}
            ]
          },
          %{
            id: "W199",
            title: gettext("Reuse existing large task when splitting fails"),
            priority: "critical",
            who: %{name: "Rohan S", kind: :human, palette: "human-green"},
            meta: [
              %{icon: "hero-document", text: "2"},
              %{icon: "hero-check", text: "5"}
            ]
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
            meta: [
              %{icon: "hero-document", text: "3"},
              %{icon: "hero-check", text: "5"}
            ]
          },
          %{
            id: "W194",
            title: gettext("Replace blue link styling in marketing templates"),
            priority: "medium",
            who: %{name: "Cursor", kind: :agent, palette: "agent-cursor"},
            meta: [
              %{icon: "hero-document", text: "4"},
              %{icon: "hero-link", text: "1", color: "var(--st-blocked)"},
              %{icon: "hero-check", text: "3"}
            ]
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
            title: gettext("Add after_goal to hook-metadata serializer"),
            priority: "high",
            who: %{name: "Claude", kind: :agent, palette: "agent-claude"},
            meta: [
              %{icon: "hero-check", text: gettext("5 criteria")},
              %{icon: "hero-check-badge", text: gettext("0 issues"), color: "var(--st-done)"},
              %{icon: "hero-document", text: gettext("4 files")}
            ]
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
            title: gettext("Rewrite UserLive.Settings per board-settings design"),
            priority: "high",
            who: %{name: "Claude", kind: :agent, palette: "agent-claude"},
            meta: [
              %{icon: "hero-clock", text: gettext("cycle 1h 24m")},
              %{icon: "hero-document", text: gettext("6 files")},
              %{icon: nil, text: gettext("actual: medium")}
            ]
          }
        ]
      }
    ]
  end
end
