defmodule KanbanWeb.TargetLive.Show do
  @moduledoc """
  Read-only drill-down for a single delivery target at `/targets/:id`, listing
  the target's member goals (via `KanbanWeb.GoalCard`), each linking to its own
  goal drill-down.

  Mounts inside the `:require_authenticated_user` live_session and fetches the
  target board-scope-aware via `Kanban.Targets.get_target/2` — which only
  returns a target that has at least one member goal on a board the viewer can
  access. A target with no accessible goals redirects back to `/boards` with a
  flash, mirroring `KanbanWeb.GoalLive.Show`.
  """
  use KanbanWeb, :live_view

  alias Kanban.Targets
  alias KanbanWeb.GoalCard

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope

    case Targets.get_target(scope, id) do
      {:ok, target} ->
        {:ok,
         socket
         |> assign(:target, target)
         |> assign(:member_goals, Targets.list_member_goals(scope, target))
         |> assign(:page_title, target.name)}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Target not found"))
         |> push_navigate(to: ~p"/boards")}
    end
  end

  defp format_date(%Date{} = date), do: Calendar.strftime(date, "%b %-d, %Y")

  # A member goal is a %Task{} whose :children association is not loaded and
  # which has no :promoted flag. GoalCard renders an empty progress bar for a
  # truthy-but-unloaded :children and a "Promote children" button when
  # :promoted is falsy (invalid nested in the surrounding <.link> and unhandled
  # here). Pass a curated display map: the fields GoalCard reads, with
  # :promoted set so the button is suppressed and :children omitted so the
  # progress bar is skipped.
  defp goal_card_task(goal) do
    goal
    |> Map.take([:id, :identifier, :title, :type, :priority, :description])
    |> Map.put(:promoted, true)
  end
end
