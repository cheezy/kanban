defmodule KanbanWeb.Admin.UserLive.Index do
  use KanbanWeb, :live_view

  # Defense-in-depth: the router's `live_session :admin` already declares
  # `{KanbanWeb.UserAuth, :require_admin}` for this route, but we re-declare it
  # here so the LiveView itself cannot be reached by a non-admin even if the
  # route is ever re-grouped or the on_mount hook is dropped from the
  # live_session declaration.
  on_mount {KanbanWeb.UserAuth, :require_admin}

  alias Kanban.Accounts
  alias Kanban.Accounts.User
  alias Kanban.Boards
  alias Kanban.Metrics.UserActivity

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("User Administration"))
     |> refresh()}
  end

  @impl true
  def handle_event("disable", %{"id" => id}, socket) do
    with_user(socket, id, fn user, actor ->
      user
      |> Accounts.disable_user(actor)
      |> respond(socket, gettext("Account disabled."))
    end)
  end

  @impl true
  def handle_event("enable", %{"id" => id}, socket) do
    with_user(socket, id, fn user, _actor ->
      user
      |> Accounts.enable_user()
      |> respond(socket, gettext("Account enabled."))
    end)
  end

  @impl true
  def handle_event("resend_confirmation", %{"id" => id}, socket) do
    with_user(socket, id, fn user, _actor ->
      user
      |> Accounts.deliver_user_confirmation_instructions(&url(~p"/users/confirm/#{&1}"))
      |> respond(socket, gettext("Confirmation email sent."))
    end)
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    with_user(socket, id, fn user, actor ->
      user
      |> Accounts.delete_user(actor)
      |> respond(socket, gettext("Account deleted."))
    end)
  end

  # Every event re-resolves BOTH the actor and the target from the database. The
  # row's buttons are a UI hint; this is the enforcement, and re-reading the
  # target is also what keeps a stale id (a second click on an already-deleted
  # row) from crashing the LiveView.
  defp with_user(socket, id, fun) do
    case authorized_actor(socket) do
      nil ->
        halt_non_admin(socket)

      actor ->
        case fetch_user(id) do
          nil -> {:noreply, put_flash(socket, :error, gettext("User not found."))}
          user -> fun.(user, actor)
        end
    end
  end

  defp respond({:ok, _result}, socket, message) do
    {:noreply,
     socket
     |> put_flash(:info, message)
     |> refresh()}
  end

  defp respond({:error, reason}, socket, _message) do
    {:noreply, put_flash(socket, :error, error_message(reason))}
  end

  # Mount and every mutating event route through here, so the aggregates can
  # never go stale against the user list they annotate. Each aggregate is one
  # query for the whole table — a per-user read would be an N+1 across it.
  defp refresh(socket) do
    socket
    |> assign(:users, Accounts.list_users())
    |> assign(:board_counts, Boards.board_counts_by_user())
    |> assign(:user_activity, activity_by_user())
  end

  # list_user_activity/1 joins metrics_events to users, so it returns only the
  # users that have activity. Index it by id and let activity_stat/3 default the
  # rest to @empty_activity, rather than filtering the user list down to it.
  defp activity_by_user do
    []
    |> UserActivity.list_user_activity()
    |> Map.new(&{&1.user_id, &1})
  end

  defp error_message(:unauthorized), do: gettext("You must be an admin to perform this action.")
  defp error_message(:cannot_disable_self), do: gettext("You cannot disable your own account.")
  defp error_message(:cannot_delete_self), do: gettext("You cannot delete your own account.")
  defp error_message(:last_admin), do: gettext("You cannot remove the last admin.")

  defp error_message(:user_has_boards),
    do: gettext("This user still belongs to a board and cannot be deleted.")

  defp error_message(:already_confirmed), do: gettext("This account is already confirmed.")
  defp error_message(_reason), do: gettext("Something went wrong. Please try again.")

  # current_scope is loaded at mount and never refreshed, so it still claims
  # admin for someone since disabled or demoted — and nothing tears down an open
  # socket when a user is disabled. Re-read the actor from the database on every
  # event, or a disabled admin could keep acting through their existing socket,
  # including re-enabling themselves. This also gives the context a fresh actor,
  # so its own authorization is checking live state rather than the same stale
  # struct.
  defp authorized_actor(socket) do
    with %{user: %{id: id}} <- socket.assigns[:current_scope],
         %User{type: :admin, disabled_at: nil} = actor <- Accounts.get_user(id) do
      actor
    else
      _ -> nil
    end
  end

  defp halt_non_admin(socket) do
    {:noreply, put_flash(socket, :error, gettext("You must be an admin to perform this action."))}
  end

  # Postgres bigint is the upper bound: Integer.parse/1 accepts any numeral, and
  # Repo.get/2 raises on one that overflows the column, so range-check before
  # the lookup rather than rescuing.
  @max_bigint 9_223_372_036_854_775_807

  # Accepts the string id from phx-value-id and returns nil rather than raising
  # for a malformed, out-of-range, or already-deleted id.
  defp fetch_user(id) when is_binary(id) do
    case Integer.parse(id) do
      {int_id, ""} -> fetch_user(int_id)
      _ -> nil
    end
  end

  defp fetch_user(id) when is_integer(id) and id > 0 and id <= @max_bigint,
    do: Accounts.get_user(id)

  defp fetch_user(_id), do: nil

  defp board_count(board_counts, user), do: Map.get(board_counts, user.id, 0)

  # A user with no recorded activity is absent from the aggregate, not zeroed by
  # it. Map.fetch!/2 on the way out so a mistyped key fails loudly instead of
  # rendering an empty cell.
  @empty_activity %{
    total_actions: 0,
    tasks_claimed: 0,
    tasks_completed: 0,
    tasks_created: 0,
    last_activity: nil
  }

  defp activity_stat(user_activity, user, key) do
    user_activity
    |> Map.get(user.id, @empty_activity)
    |> Map.fetch!(key)
  end

  # metrics_events has no Ecto schema, so last_activity arrives as a
  # NaiveDateTime rather than a cast DateTime. Both are matched; anything else
  # (including nil, for a user with no activity) renders the placeholder.
  defp format_last_activity(%DateTime{} = dt), do: Calendar.strftime(dt, "%b %d, %Y %H:%M")

  defp format_last_activity(%NaiveDateTime{} = ndt),
    do: Calendar.strftime(ndt, "%b %d, %Y %H:%M")

  defp format_last_activity(_last_activity), do: gettext("N/A")

  # The raw :type atom would render as English at every locale.
  defp type_label(:admin), do: gettext("Admin")
  defp type_label(:user), do: gettext("User")

  defp display_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp display_name(_user), do: "—"

  defp format_created(%{inserted_at: inserted_at}),
    do: Calendar.strftime(inserted_at, "%b %d, %Y")

  defp disabled?(%{disabled_at: nil}), do: false
  defp disabled?(_user), do: true

  defp confirmed?(%{confirmed_at: nil}), do: false
  defp confirmed?(_user), do: true
end
