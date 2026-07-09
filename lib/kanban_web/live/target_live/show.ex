defmodule KanbanWeb.TargetLive.Show do
  @moduledoc """
  Read-only drill-down for a single delivery target at `/targets/:id`.

  Renders the `KanbanWeb.TargetProgressHeader` hero (aggregate percentage,
  segmented progress bar, status badge) followed by a table of
  `KanbanWeb.TargetGoalRow` rows — one per member goal — mirroring the Goal
  view (`KanbanWeb.GoalLive.Show`).

  Mounts inside the `:require_authenticated_user` live_session and loads the
  target owner-scoped via `Kanban.Targets.get_owned_target/2` (so a freshly
  created, still-memberless target is viewable by its owner and renders the
  hero at 0% with an empty table), then loads its progress —
  `%{summary, goals}` — via `Kanban.Targets.get_target_progress/2`, which
  board-scopes every member-goal read. A target the caller does not own
  redirects back to `/boards` with a flash.

  All Ecto access lives in the `Kanban.Targets` context; this LiveView only
  derives the aggregate flow (a pure sum across the per-goal flows) for the
  hero's segmented bar.
  """
  use KanbanWeb, :live_view

  alias Kanban.Targets
  alias KanbanWeb.TargetGoalRow
  alias KanbanWeb.TargetProgressHeader

  @empty_flow %{done: 0, review: 0, doing: 0, ready: 0, backlog: 0, total: 0}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope
    timezone = KanbanWeb.Timezone.browser_timezone(socket)

    case Targets.get_owned_target(scope, id) do
      {:ok, target} ->
        {:ok, assign_target_progress(socket, scope, target, timezone)}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Target not found"))
         |> push_navigate(to: ~p"/boards")}
    end
  end

  # Anchor status on the viewer's local calendar day (not the server's UTC day)
  # so the target-detail badge agrees with the boards TargetsStrip and the
  # agents delivery-health band. See D123.
  defp assign_target_progress(socket, scope, target, timezone) do
    progress = Targets.get_target_progress(scope, target, Kanban.Timezone.local_today(timezone))

    socket
    |> assign(:target, target)
    |> assign(:summary, progress.summary)
    |> assign(:goals, progress.goals)
    |> assign(:aggregate_flow, aggregate_flow(progress.goals))
    |> assign(:page_title, target.name)
  end

  # Sums the per-goal flow maps into one aggregate %{done, review, doing,
  # ready, backlog, total} for the hero's segmented bar. Pure derivation over
  # the list the context already returned — no query.
  defp aggregate_flow(goals) do
    Enum.reduce(goals, @empty_flow, fn %{flow: flow}, acc ->
      Map.new(acc, fn {key, value} -> {key, value + Map.get(flow, key, 0)} end)
    end)
  end
end
