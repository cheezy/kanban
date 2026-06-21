defmodule KanbanWeb.MetricsLive.Base do
  @moduledoc """
  Shared base for the five metrics LiveViews
  (CycleTime, LeadTime, Throughput, WaitTime, Dashboard).

  Provides a `__using__/1` macro that injects identical `mount/3`,
  `handle_params/3`, and `handle_event("filter_change", ...)` clauses,
  plus public helpers `assign_metrics_state/5` and `handle_filter_change/3`.

  The using module MUST implement `c:load_data/1`, which receives the
  socket (with `:board`, `:time_range`, `:agent_name`, `:exclude_weekends`
  already assigned) and returns the socket with metric-specific assigns.

  The using module MUST `use KanbanWeb, :live_view` BEFORE
  `use KanbanWeb.MetricsLive.Base, ...` so that the generated code can
  resolve `assign/2`, `put_flash/2`, `push_navigate/2`, `gettext/1`,
  and the `~p` sigil at the call site.

  ## Relationship to `KanbanWeb.MetricsLive.Helpers`

  This module is kept distinct from `KanbanWeb.MetricsLive.Helpers` on
  purpose. The two modules serve different layers:

    * `Base` is a LiveView mixin — it injects callback implementations,
      depends on `Phoenix.Component`, and operates on sockets. It is the
      lifecycle layer.

    * `Helpers` is a pure-function utility module — formatters, param
      parsers, date math, statistical helpers. It has no LiveView
      dependency and is consumed by `Base` and by each metric module.

  `Base` calls into `Helpers`; the reverse is not true. Merging the two
  would mix a LiveView mixin with pure utilities and would couple every
  Helpers caller (including tests) to the LiveView dependency. Keep them
  separate.
  """

  import Phoenix.Component, only: [assign: 3]

  alias Kanban.Boards
  alias Kanban.Metrics
  alias KanbanWeb.MetricsLive.Helpers

  @callback load_data(socket :: Phoenix.LiveView.Socket.t()) ::
              Phoenix.LiveView.Socket.t()

  defmacro __using__(opts) do
    page_title = Keyword.fetch!(opts, :page_title)

    quote location: :keep do
      @behaviour KanbanWeb.MetricsLive.Base

      @impl Phoenix.LiveView
      def mount(_params, _session, socket) do
        {:ok,
         assign(socket,
           time_range: :last_30_days,
           agent_name: nil,
           exclude_weekends: false,
           timezone: KanbanWeb.Timezone.browser_timezone(socket)
         )}
      end

      @impl Phoenix.LiveView
      def handle_params(%{"id" => board_id} = params, _uri, socket) do
        user = socket.assigns.current_scope.user

        case Kanban.Boards.get_board(board_id, user) do
          {:ok, board} ->
            {:noreply,
             KanbanWeb.MetricsLive.Base.assign_metrics_state(
               socket,
               board,
               params,
               unquote(page_title),
               &__MODULE__.load_data/1
             )}

          {:error, :not_found} ->
            {:noreply,
             socket
             |> put_flash(:error, gettext("Board not found"))
             |> push_navigate(to: ~p"/boards")}
        end
      end

      @impl Phoenix.LiveView
      def handle_event("filter_change", params, socket) do
        {:noreply,
         KanbanWeb.MetricsLive.Base.handle_filter_change(
           socket,
           params,
           &__MODULE__.load_data/1
         )}
      end

      defoverridable mount: 3, handle_params: 3, handle_event: 3
    end
  end

  @doc """
  Assigns the standard metrics page state and invokes the metric-specific
  data loader. Called from the macro-generated `handle_params/3` after a
  successful board lookup.
  """
  def assign_metrics_state(socket, board, params, page_title, load_data_fn) do
    {:ok, agents} = Metrics.get_agents(board.id)
    user_access = Boards.get_user_access(board.id, socket.assigns.current_scope.user.id)

    socket
    |> assign(:page_title, page_title)
    |> assign(:board, board)
    |> assign(:user_access, user_access)
    |> assign(:agents, agents)
    |> assign(:time_range, Helpers.parse_time_range(params["time_range"]))
    |> assign(:agent_name, Helpers.parse_agent_name(params["agent_name"]))
    |> assign(:exclude_weekends, Helpers.parse_exclude_weekends(params["exclude_weekends"]))
    |> load_data_fn.()
  end

  @doc """
  Reassigns the three filter values from the given params and invokes the
  metric-specific data loader. Called from the macro-generated
  `handle_event("filter_change", ...)`.
  """
  def handle_filter_change(socket, params, load_data_fn) do
    socket
    |> assign(:time_range, Helpers.parse_time_range(params["time_range"]))
    |> assign(:agent_name, Helpers.parse_agent_name(params["agent_name"]))
    |> assign(:exclude_weekends, Helpers.parse_exclude_weekends(params["exclude_weekends"]))
    |> load_data_fn.()
  end

  @doc """
  Shared `c:load_data/1` body for the cycle-time and lead-time LiveViews
  (W1084).

  Builds the standard opts (time_range, exclude_weekends, plus agent_name
  only when one is selected — a nil agent_name key is never inserted),
  fetches stats and tasks via the supplied functions, and assigns
  `:summary_stats`, `:tasks`, `:grouped_tasks`, and the metric-specific
  daily series under `daily_assign_key`.

    * `stats_fn` — `(board_id, opts -> {:ok, map})`, e.g.
      `&Metrics.get_cycle_time_stats/2`
    * `tasks_fn` — `(board_id, opts -> [map])`, a capture of the caller's
      private task loader. The loaders stay local on purpose: cycle time
      has an AI/regular two-path dispatch that lead time does not share.
    * `time_field` — the per-task seconds field, `:cycle_time_seconds` or
      `:lead_time_seconds`
    * `daily_assign_key` — `:daily_cycle_times` or `:daily_lead_times`
  """
  def load_metric_data(socket, stats_fn, tasks_fn, time_field, daily_assign_key) do
    opts = [
      time_range: socket.assigns.time_range,
      exclude_weekends: socket.assigns.exclude_weekends,
      timezone: Map.get(socket.assigns, :timezone, "Etc/UTC")
    ]

    opts =
      if socket.assigns.agent_name do
        Keyword.put(opts, :agent_name, socket.assigns.agent_name)
      else
        opts
      end

    {:ok, stats} = stats_fn.(socket.assigns.board.id, opts)
    tasks = tasks_fn.(socket.assigns.board.id, opts)

    socket
    |> assign(:summary_stats, stats)
    |> assign(:tasks, tasks)
    |> assign(:grouped_tasks, Helpers.group_tasks_by_completion_date(tasks))
    |> assign(daily_assign_key, Helpers.calculate_daily_times(tasks, time_field))
  end
end
