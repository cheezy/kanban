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

  The Archive action renders only when the derived status is `:complete` and
  the target is not already archived, and delegates to
  `Kanban.Targets.archive_target/2`, which re-derives that status server-side —
  the hidden button is a UI affordance, never the gate. On success the page
  navigates back to `/boards`, since an archived target is filtered out of
  every active-target listing.

  An archived target remains a valid destination here: `get_owned_target/2`
  deliberately ignores `archived_at`, so one drill-down serves both states and
  `KanbanWeb.TargetLive.Archived` links each of its rows straight to this page.
  When the target being viewed is archived the header says so — an indicator
  pill carrying the same `TimeAgo` age the archived listing shows — suppresses
  the Archive button (re-archiving would only re-stamp `archived_at`), and
  points its back-link at `/targets/archived` rather than `/boards`, returning
  the reader to the listing they arrived from. That listing is board-scoped
  while this page stays owner-scoped, so a member can see — and click — a
  colleague's archived row and land on the not-found flash; the asymmetry is
  the same one the listing's Unarchive button already carries.
  """
  use KanbanWeb, :live_view

  alias Kanban.Targets
  alias KanbanWeb.TargetGoalRow
  alias KanbanWeb.TargetProgressHeader
  alias KanbanWeb.TimeAgo

  @empty_flow %{done: 0, review: 0, doing: 0, ready: 0, backlog: 0, total: 0}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope
    timezone = KanbanWeb.Timezone.browser_timezone(socket)

    case Targets.get_owned_target(scope, id) do
      {:ok, target} ->
        {:ok, assign_target_progress(socket, scope, target, timezone)}

      {:error, :not_found} ->
        {:ok, target_not_found(socket)}
    end
  end

  # The button is gated on the derived :complete status, but that gate is a UI
  # affordance only — Targets.archive_target/2 re-checks ownership AND
  # completeness server-side, so a stale page (the target changed in another
  # tab) is refused here rather than trusted.
  @impl true
  def handle_event("archive_target", _params, socket) do
    case Targets.archive_target(socket.assigns.current_scope, socket.assigns.target.id) do
      {:ok, _target} -> {:noreply, target_archived(socket)}
      {:error, :not_complete} -> {:noreply, flash_error(socket, not_complete_message())}
      {:error, :not_found} -> {:noreply, target_not_found(socket)}
      {:error, %Ecto.Changeset{}} -> {:noreply, flash_error(socket, archive_failed_message())}
    end
  end

  defp target_archived(socket) do
    socket
    |> put_flash(:info, gettext("Target archived successfully"))
    |> push_navigate(to: ~p"/boards")
  end

  # Shared by mount/3 and the archive event so both render the same message and
  # destination for a target that is missing or not the caller's.
  defp target_not_found(socket) do
    socket
    |> put_flash(:error, gettext("Target not found"))
    |> push_navigate(to: ~p"/boards")
  end

  defp flash_error(socket, message), do: put_flash(socket, :error, message)

  defp not_complete_message, do: gettext("Only a complete target can be archived")

  defp archive_failed_message, do: gettext("Failed to archive target")

  # Anchor status on the viewer's local calendar day (not the server's UTC day)
  # so the target-detail badge agrees with the boards TargetsStrip and the
  # agents delivery-health band. See D123.
  defp assign_target_progress(socket, scope, target, timezone) do
    progress = Targets.get_target_progress(scope, target, Kanban.Timezone.local_today(timezone))

    socket
    |> assign(:target, target)
    |> assign(:archived?, not is_nil(target.archived_at))
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
