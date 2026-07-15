defmodule KanbanWeb.Admin.UserLive.Index do
  use KanbanWeb, :live_view

  # Defense-in-depth: the router's `live_session :admin` already declares
  # `{KanbanWeb.UserAuth, :require_admin}` for this route, but we re-declare it
  # here so the LiveView itself cannot be reached by a non-admin even if the
  # route is ever re-grouped or the on_mount hook is dropped from the
  # live_session declaration.
  on_mount {KanbanWeb.UserAuth, :require_admin}

  alias Kanban.Accounts
  alias Kanban.Boards

  @impl true
  def mount(_params, _session, socket) do
    # One query for every row's board count — a per-user count would be an N+1
    # across the whole user list.
    board_counts = Boards.board_counts_by_user()

    {:ok,
     socket
     |> assign(:page_title, gettext("User Administration"))
     |> assign(:users, Accounts.list_users())
     |> assign(:board_counts, board_counts)}
  end

  defp board_count(board_counts, user), do: Map.get(board_counts, user.id, 0)

  # The raw :type atom would render as English at every locale.
  defp type_label(:admin), do: gettext("Admin")
  defp type_label(:user), do: gettext("User")

  defp display_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp display_name(_user), do: "—"

  defp disabled?(%{disabled_at: nil}), do: false
  defp disabled?(_user), do: true

  defp confirmed?(%{confirmed_at: nil}), do: false
  defp confirmed?(_user), do: true
end
