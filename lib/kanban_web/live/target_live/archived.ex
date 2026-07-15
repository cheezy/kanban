defmodule KanbanWeb.TargetLive.Archived do
  @moduledoc """
  Archived delivery targets at `/targets/archived`, with a per-row Unarchive
  action.

  The archived mirror of the active-target surfaces: mounts inside the
  `:require_authenticated_user` live_session and lists via
  `Kanban.Targets.list_archived_targets/1`, which board-scopes visibility
  exactly as `list_targets/1` does — a target is visible through its accessible
  member goals, so an archived target with no member goal on a board the caller
  can reach is not listed here at all.

  Unarchiving delegates to `Kanban.Targets.unarchive_target/2`, which is
  *owner*-gated via `get_owned_target/2`. That asymmetry is deliberate and
  load-bearing: listing is board-scoped but mutation is owner-scoped, so a user
  who shares a board can SEE a colleague's archived target and will get
  `{:error, :not_found}` on unarchive. The row action is a convenience; the
  context call is the authorization. The same branch covers a race with a
  concurrent delete.

  On success the list is re-read from the context and re-assigned, which drops
  the now-active target from the rendered list without a page reload. All Ecto
  access lives in `Kanban.Targets`; this LiveView issues no queries.
  """
  use KanbanWeb, :live_view

  alias Kanban.Targets
  alias KanbanWeb.TimeAgo

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Archived targets"))
     |> load_targets()}
  end

  # The row is only rendered for targets the caller can SEE (board-scoped), which
  # is a strictly wider set than the ones they may unarchive (owner-scoped).
  # unarchive_target/2 re-checks ownership server-side, so a not-owned id — or a
  # stale row whose target was deleted meanwhile — is refused here, not trusted.
  #
  # The id is parsed before it reaches the context: it arrives from the client
  # over the socket and an uncastable value (`"abc"`) would raise
  # Ecto.Query.CastError inside the query and take the LiveView down. A
  # malformed id is indistinguishable from a missing one, so it lands in the
  # same not-found branch. Mirrors ArchiveLive.Index's parse_id/1.
  @impl true
  def handle_event("unarchive", %{"id" => id}, socket) do
    with {:ok, target_id} <- parse_id(id),
         {:ok, _target} <- Targets.unarchive_target(socket.assigns.current_scope, target_id) do
      {:noreply, target_unarchived(socket)}
    else
      {:error, %Ecto.Changeset{}} -> {:noreply, flash_error(socket, unarchive_failed_message())}
      _ -> {:noreply, flash_error(socket, not_found_message())}
    end
  end

  defp parse_id(id) when is_integer(id), do: {:ok, id}

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_id(_), do: :error

  defp target_unarchived(socket) do
    socket
    |> put_flash(:info, gettext("Target unarchived successfully"))
    |> load_targets()
  end

  defp flash_error(socket, message), do: put_flash(socket, :error, message)

  defp not_found_message, do: gettext("Target not found")

  defp unarchive_failed_message, do: gettext("Failed to unarchive target")

  # Re-reads the list from the context after a mutation so the unarchived target
  # drops out of the render. Shared with mount/3 so both paths build the assign
  # identically.
  defp load_targets(socket) do
    assign(socket, :targets, Targets.list_archived_targets(socket.assigns.current_scope))
  end

  defp format_date(%Date{} = date), do: Calendar.strftime(date, "%b %-d, %Y")
end
