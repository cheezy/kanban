defmodule KanbanWeb.DemoBoardLive do
  @moduledoc """
  The public `/demo` page: a read-only sample board on which agents claim
  tasks, run their hooks and move cards to Done, replayed from the static
  script in `KanbanWeb.DemoBoard`.

  Nothing here reads or writes the database. Every visitor's LiveView
  process holds its own replay, so two tabs replay independently and a
  reconnect starts again from the first move. A `Process.send_after/3`
  timer advances the replay; it is armed only on the connected mount and
  dies with the process when the visitor leaves.

  Above the columns, the goals strip shows the sample goal's progress, taken
  from the replay on every move.

  The page is read-only: it renders no form, drag hook or click binding, and
  every event and live patch that reaches it is ignored.

  It is a page for visitors, so it renders in the marketing layout, with the
  marketing header and footer, and never in the app shell. It looks the same
  to everyone, signed in or not.
  """
  use KanbanWeb, :live_view

  alias KanbanWeb.Avatar
  alias KanbanWeb.ColumnHeader
  alias KanbanWeb.DemoBoard
  alias KanbanWeb.GoalsStrip
  alias KanbanWeb.TaskCard

  @default_tick_ms 3_000

  @impl true
  def mount(_params, session, socket) do
    Gettext.put_locale(KanbanWeb.Gettext, session["locale"] || "en")

    socket =
      socket
      |> assign(DemoBoard.new())
      |> assign(
        page_title: gettext("Live demo board"),
        meta_description: meta_description(),
        tick_token: nil,
        tick_timer: nil
      )

    {:ok, if(connected?(socket), do: schedule_tick(socket), else: socket)}
  end

  @doc "The page's meta description, in the current locale."
  @spec meta_description() :: String.t()
  def meta_description do
    gettext(
      "Watch AI agents claim tasks, run their hooks and move cards to Done on a sample Stride board. No sign-up needed."
    )
  end

  # A live_patch to /demo (only a crafted one: the page renders no patch
  # link) changes nothing, rather than crashing the view.
  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:tick, token}, %{assigns: %{tick_token: token}} = socket) do
    replay = socket.assigns |> Map.take([:index, :board, :events]) |> DemoBoard.advance()

    {:noreply, socket |> assign(replay) |> schedule_tick()}
  end

  # A tick from a timer this view has already replaced.
  def handle_info({:tick, _stale}, socket), do: {:noreply, socket}

  # The page is read-only. A crafted event (a move, a delete, a form submit)
  # is ignored here, so it can never reach a board context function.
  @impl true
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # Arms the next tick. A fresh token per tick means a tick from an earlier
  # timer is recognised as stale and ignored. An interval of 0 (the test
  # config) arms no timer, and tests send the tick themselves.
  defp schedule_tick(socket) do
    if socket.assigns.tick_timer, do: Process.cancel_timer(socket.assigns.tick_timer)

    token = make_ref()

    timer =
      case tick_ms() do
        ms when is_integer(ms) and ms > 0 -> Process.send_after(self(), {:tick, token}, ms)
        _ -> nil
      end

    assign(socket, tick_token: token, tick_timer: timer)
  end

  defp tick_ms, do: Application.get_env(:kanban, :demo_board_tick_ms, @default_tick_ms)

  @impl true
  def render(assigns) do
    ~H"""
    <%!-- The marketing layout gives the page its header and footer. The board
          sits in a .stride-screen scope, as it does on a real board. --%>
    <main>
      <div class="stride-screen flex flex-col gap-5 py-[18px]" data-demo-board>
        <header class="px-4 md:px-7 flex flex-col md:flex-row md:items-end gap-3">
          <div class="flex flex-col gap-1 flex-1 min-w-0">
            <h1 class="m-0 text-[18px] font-semibold tracking-tight" style="color: var(--ink);">
              {gettext("Live demo board")}
            </h1>
            <p class="m-0 text-[12.5px]" style="color: var(--ink-2); text-wrap: pretty;">
              {gettext(
                "A replay of AI agents working a sample board: they claim tasks, run their hooks and move cards to Done. Nothing here is saved."
              )}
            </p>
          </div>
          <.link
            href={~p"/users/register"}
            class="inline-flex items-center gap-1.5 px-3.5 py-2 rounded-md text-sm font-medium hover:opacity-90 transition-opacity self-start"
            style="background: var(--ink); color: var(--surface);"
            data-demo-cta
          >
            {gettext("Start now")}
            <.icon name="hero-arrow-right" class="w-3 h-3" />
          </.link>
        </header>

        <%!-- No board is passed, so each goal pill renders as plain text, not a link. --%>
        <div data-demo-goals>
          <GoalsStrip.goals_strip goals={DemoBoard.goals(@board)} />
        </div>

        <div class="px-4 md:px-7 flex gap-3 overflow-x-auto pb-1">
          <section
            :for={column <- DemoBoard.columns()}
            data-demo-column={column}
            aria-label={DemoBoard.column_name(column)}
            class="flex flex-col flex-1 min-w-[220px] rounded-lg"
            style="background: var(--surface-sunken); border: 1px solid var(--line);"
          >
            <ColumnHeader.column_header
              column={%{name: DemoBoard.column_name(column)}}
              status={column}
              count={DemoBoard.task_count(@board, column)}
            />
            <div class="flex flex-col gap-2 p-2 min-h-[64px]">
              <div :for={card <- DemoBoard.cards_in(@board, column)} data-demo-card={card.identifier}>
                <TaskCard.task_card task={card} column={column} read_only />
              </div>
            </div>
          </section>
        </div>

        <section class="px-4 md:px-7 flex flex-col gap-2" aria-labelledby="demo-activity-heading">
          <h2
            id="demo-activity-heading"
            class="m-0 text-[12.5px] font-semibold tracking-tight"
            style="color: var(--ink);"
          >
            {gettext("Agent activity")}
          </h2>
          <ol class="m-0 p-0 list-none flex flex-col gap-1.5" aria-live="polite" data-demo-activity>
            <li :if={@events == []} class="text-[12.5px]" style="color: var(--ink-3);">
              {gettext("Waiting for the first agent…")}
            </li>
            <.activity_row :for={step <- @events} step={step} />
          </ol>
        </section>
      </div>
    </main>
    """
  end

  attr :step, :map, required: true

  defp activity_row(assigns) do
    assigns = assign(assigns, :agent, DemoBoard.agent(assigns.step.agent))

    ~H"""
    <li
      class="flex flex-wrap items-center gap-2 text-[12.5px] rounded-md px-2.5 py-1.5"
      style="background: var(--surface); border: 1px solid var(--line); color: var(--ink);"
      data-demo-event={@step.card}
    >
      <Avatar.avatar kind={@agent.kind} name={@agent.name} palette={@agent.palette} size={16} />
      <span class="flex-1 min-w-0">{DemoBoard.describe(@step)}</span>
      <code style="font-family: var(--font-mono); font-size: 11px; color: var(--ink-2);">
        {@step.hook}
      </code>
      <span
        data-demo-result={@step.result}
        style={[
          "font-size: 11px; font-weight: 600; padding: 0 6px; border-radius: 999px;",
          "border: 1px solid var(--line);",
          result_colors(@step.result)
        ]}
      >
        {DemoBoard.result_label(@step.result)}
      </span>
    </li>
    """
  end

  defp result_colors(:passed), do: "background: var(--st-done-soft); color: var(--st-done);"
  defp result_colors(:failed), do: "background: var(--st-blocked-soft); color: var(--st-blocked);"
end
