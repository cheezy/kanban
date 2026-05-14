defmodule KanbanWeb.MarketingComponents do
  @moduledoc """
  Function components used on the public marketing surfaces (the landing page,
  the about page, etc.). They reference the Stride design tokens defined in
  `assets/css/app.css` under the `.stride-marketing` scope — render any
  marketing component inside an element carrying that class so the tokens
  (`--ink`, `--ink-2`, `--line`, `--stride-orange`, `--stride-violet`, ...)
  resolve.

  These are the codebase counterpart to the React design references under
  `design_handoff_stride/design_source/screens/`. Treat that JSX as Figma —
  read it, mirror it, do not import it.
  """
  use KanbanWeb, :html

  @doc """
  Renders the top navigation bar used on the landing page.

  Mirrors `MktNav` from `design_handoff_stride/design_source/screens/landing.jsx`.

  ## Auth state

    * Unauthenticated (`current_scope` is `nil`) → renders a "Sign in" link and
      a dark "Start free" pill button.
    * Authenticated → renders a single dark "Go to boards" pill button.

  ## Examples

      <.marketing_nav current_scope={@current_scope} />
  """
  attr :current_scope, :map,
    default: nil,
    doc: "The `@current_scope` assign — `nil` when no user is signed in."

  def marketing_nav(assigns) do
    ~H"""
    <nav
      class="flex items-center gap-6 h-14 px-9"
      style="border-bottom: 1px solid var(--line);"
    >
      <.link href={~p"/"} class="flex items-center gap-2">
        <span
          class="inline-flex items-center justify-center rounded-md text-white text-xs font-bold"
          style="width: 22px; height: 22px; background: linear-gradient(135deg, var(--stride-orange) 0%, var(--stride-violet) 100%); letter-spacing: -0.02em;"
        >
          S
        </span>
        <span class="text-sm font-semibold" style="letter-spacing: -0.015em;">
          {gettext("Stride")}
        </span>
      </.link>

      <span class="hidden md:inline-block w-px" style="height: 18px; background: var(--line);"></span>

      <div
        class="hidden md:flex items-center gap-[18px] text-[13px]"
        style="color: var(--ink-2);"
      >
        <.link href="#product" class="hover:opacity-70 transition-opacity">
          {gettext("Product")}
        </.link>
        <.link href="#workflows" class="hover:opacity-70 transition-opacity">
          {gettext("Workflows")}
        </.link>
        <.link href="#pricing" class="hover:opacity-70 transition-opacity">
          {gettext("Pricing")}
        </.link>
        <.link
          href={~p"/resources"}
          class="inline-flex items-center gap-[3px] hover:opacity-70 transition-opacity"
          title={gettext("API · Docs · Changelog")}
        >
          {gettext("Resources")}
          <.icon name="hero-chevron-down" class="w-2 h-2" />
        </.link>
        <.link href={~p"/about"} class="hover:opacity-70 transition-opacity">
          {gettext("About")}
        </.link>
      </div>

      <span class="flex-1"></span>

      <%= if @current_scope do %>
        <.link
          href={~p"/boards"}
          class="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-md text-xs font-medium text-white hover:opacity-90 transition-opacity"
          style="background: var(--ink);"
        >
          {gettext("Go to boards")}
          <.icon name="hero-arrow-right" class="w-3 h-3" />
        </.link>
      <% else %>
        <.link
          href={~p"/users/log-in"}
          class="text-[13px] hover:opacity-70 transition-opacity"
          style="color: var(--ink-2);"
        >
          {gettext("Sign in")}
        </.link>
        <.link
          href={~p"/users/register"}
          class="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-md text-xs font-medium text-white hover:opacity-90 transition-opacity"
          style="background: var(--ink);"
        >
          {gettext("Start free")}
          <.icon name="hero-arrow-right" class="w-3 h-3" />
        </.link>
      <% end %>
    </nav>
    """
  end

  @doc """
  Renders the landing-page hero — release pill, two-tone headline, sub-copy,
  primary + secondary CTAs, microcopy, and the realistic `marketing_mini_board`
  showing live-looking task cards.

  Mirrors the hero section of `Landing_Editorial` in
  `design_handoff_stride/design_source/screens/landing.jsx` (lines ~149-199).

  ## Auth state

    * Unauthenticated → primary CTA is "Start free" linking to `~p"/users/register"`.
    * Authenticated   → primary CTA becomes "Go to my boards" linking to `~p"/boards"`.

  ## Examples

      <.marketing_hero current_scope={@current_scope} />
  """
  attr :current_scope, :map,
    default: nil,
    doc: "The `@current_scope` assign — `nil` when no user is signed in."

  def marketing_hero(assigns) do
    ~H"""
    <section class="px-16 pt-20 pb-14" style="border-bottom: 1px solid var(--line);">
      <div class="flex items-center gap-2 mb-6">
        <span
          class="inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full text-[11px] font-medium"
          style="background: var(--stride-violet-soft); color: var(--stride-violet-ink);"
        >
          <.icon name="hero-sparkles" class="w-2.5 h-2.5" />
          {gettext("v2.4 · Atomic claims w/ capability matching")}
        </span>
        <span class="text-xs" style="color: var(--ink-3);">
          {gettext("Now in beta →")}
        </span>
      </div>

      <h1
        class="m-0 font-semibold"
        style="font-size: clamp(40px, 6vw, 72px); letter-spacing: -0.04em; line-height: 0.98; max-width: 1100px; color: var(--ink); text-wrap: pretty;"
      >
        {gettext("Tasks are conversations.")}
        <br />
        <span style="color: var(--ink-4);">
          {gettext("Your kanban can speak both ways.")}
        </span>
      </h1>

      <p
        class="mt-6"
        style="max-width: 620px; font-size: 17.5px; line-height: 1.5; color: var(--ink-2); text-wrap: pretty;"
      >
        {gettext(
          "Stride is an AI-native kanban. Humans plan, review, and approve. Agents claim, build, and ship. Same board. One workflow. No glue code."
        )}
      </p>

      <div class="flex flex-wrap items-center gap-3.5 mt-8">
        <%= if @current_scope do %>
          <.link
            href={~p"/boards"}
            class="inline-flex items-center gap-1.5 px-4 py-2.5 rounded-md text-sm font-medium text-white hover:opacity-90 transition-opacity"
            style="background: var(--ink);"
          >
            {gettext("Go to my boards")}
            <.icon name="hero-arrow-right" class="w-3 h-3" />
          </.link>
        <% else %>
          <.link
            href={~p"/users/register"}
            class="inline-flex items-center gap-1.5 px-4 py-2.5 rounded-md text-sm font-medium text-white hover:opacity-90 transition-opacity"
            style="background: var(--ink);"
          >
            {gettext("Start free")}
            <.icon name="hero-arrow-right" class="w-3 h-3" />
          </.link>
        <% end %>

        <.link
          href={~p"/resources"}
          class="inline-flex items-center gap-1.5 px-4 py-2.5 rounded-md text-sm font-medium hover:opacity-90 transition-opacity"
          style="background: transparent; color: var(--ink); border: 1px solid var(--line-strong);"
        >
          <.icon name="hero-cpu-chip" class="w-3 h-3" />
          {gettext("Read the agent API")}
        </.link>

        <span
          class="inline-flex items-center gap-1.5 ml-1.5 text-xs"
          style="color: var(--ink-3);"
        >
          <.icon name="hero-check" class="w-2.5 h-2.5" />
          {gettext("Free for solo · self-host on day one")}
        </span>
      </div>

      <div class="mt-16" style="max-width: 1200px;">
        <.marketing_mini_board />
      </div>
    </section>
    """
  end

  @doc """
  Renders the static 4-column mini-Kanban illustration used in the landing
  hero. Mirrors the `MiniBoard` function in `landing.jsx` (lines ~6-99).

  This component is a **visual mock** — it never reads real data. Card content
  is hardcoded so the marketing page does not depend on board state.

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
                <.mini_avatar who={task.who} />
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

  # 16×16 type icon — the MiniBoard only renders "work" type, so we keep a
  # single private component rather than a full TypeIcon primitive.
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

  attr :who, :map, required: true

  defp mini_avatar(assigns) do
    ~H"""
    <span
      class="inline-flex items-center justify-center text-white font-semibold"
      style={[
        "width: 14px; height: 14px; font-size: 6px; letter-spacing: -0.02em;",
        "background: #{avatar_color(@who)};",
        "border-radius: #{if @who.kind == :agent, do: "4px", else: "50%"};"
      ]}
    >
      {avatar_initials(@who.name)}
    </span>
    """
  end

  defp avatar_color(%{kind: :agent, palette: palette}) do
    case palette do
      "agent-claude" -> "oklch(70% 0.16 47)"
      "agent-cursor" -> "oklch(60% 0.16 240)"
      "agent-aider" -> "oklch(60% 0.14 155)"
      "agent-codex" -> "oklch(60% 0.18 277)"
      _ -> "var(--ink-3)"
    end
  end

  defp avatar_color(%{kind: :human, palette: palette}) when is_binary(palette) do
    case palette do
      "human-blue" -> "oklch(60% 0.10 240)"
      "human-amber" -> "oklch(60% 0.10 60)"
      "human-green" -> "oklch(60% 0.10 155)"
      "human-pink" -> "oklch(60% 0.10 320)"
      _ -> "var(--ink-3)"
    end
  end

  defp avatar_color(_), do: "var(--ink-3)"

  defp avatar_initials(name) when is_binary(name) do
    name
    |> String.split(" ", trim: true)
    |> Enum.take(2)
    |> Enum.map_join("", &String.first/1)
    |> String.upcase()
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
