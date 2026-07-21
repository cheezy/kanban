defmodule KanbanWeb.Admin.UserLive.IndexTest do
  use KanbanWeb.ConnCase

  import Phoenix.LiveViewTest
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Swoosh.TestAssertions

  alias Kanban.Accounts
  alias Kanban.Accounts.User

  defp register_and_log_in_admin(%{conn: conn}) do
    admin = admin_fixture()
    %{conn: log_in_user(conn, admin), user: admin}
  end

  # Seeds a metrics_events row for the activity columns. Mirrors the helper in
  # test/kanban/metrics/user_activity_test.exs (W1705) — metrics_events has no
  # Ecto schema, so there is no context writer or fixture to call. `user_id`
  # must be a numeric string or the aggregation's regex predicate skips the row.
  defp event!(user, metric_name) do
    Kanban.Repo.insert_all("metrics_events", [
      %{
        metric_name: metric_name,
        measurement: 1.0,
        metadata: %{"user_id" => to_string(user.id)},
        recorded_at: DateTime.utc_now(),
        inserted_at: DateTime.utc_now()
      }
    ])
  end

  describe "access control" do
    setup :register_and_log_in_user

    test "non-admin user is redirected to / with a flash error", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/", flash: flash}}} = live(conn, ~p"/admin/users")

      assert flash["error"] =~ "admin"
    end

    test "unauthenticated visitor is redirected to the login page" do
      conn = Phoenix.ConnTest.build_conn()

      assert {:error, {:redirect, %{to: redirect_to}}} = live(conn, ~p"/admin/users")

      assert redirect_to == ~p"/users/log-in"
    end
  end

  describe "admin access" do
    setup :register_and_log_in_admin

    test "renders every user's email", %{conn: conn, user: admin} do
      other = user_fixture()

      {:ok, _live, html} = live(conn, ~p"/admin/users")

      assert html =~ admin.email
      assert html =~ other.email
    end

    test "renders the page title", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/admin/users")

      assert html =~ "User Administration"
    end

    test "mount assigns the full users list", %{conn: conn, user: admin} do
      other = user_fixture()

      {:ok, live, _html} = live(conn, ~p"/admin/users")

      user_ids = :sys.get_state(live.pid).socket.assigns.users |> Enum.map(& &1.id)
      assert admin.id in user_ids
      assert other.id in user_ids
    end

    test "renders a user's board count, and zero for a user with no boards", %{conn: conn} do
      with_boards = user_fixture()
      _board_one = board_fixture(with_boards)
      _board_two = board_fixture(with_boards)
      without_boards = user_fixture()

      {:ok, live, _html} = live(conn, ~p"/admin/users")

      # Target the Boards cell by id: several columns now render tabular-nums,
      # so a bare .tabular-nums match would pass on any of them.
      assert has_element?(live, "#user-#{with_boards.id}-boards", "2")
      assert has_element?(live, "#user-#{without_boards.id}-boards", "0")
    end

    test "renders a user's activity metrics", %{conn: conn} do
      active = user_fixture()
      event!(active, "kanban.api.task_claimed")
      event!(active, "kanban.api.task_completed")
      event!(active, "kanban.api.task_created")
      event!(active, "kanban.api.task_created")

      {:ok, live, _html} = live(conn, ~p"/admin/users")

      # Distinct values per metric, anchored so "1" cannot match "12".
      assert has_element?(live, "#user-#{active.id}-total-actions", ~r/^\s*4\s*$/)
      assert has_element?(live, "#user-#{active.id}-tasks-claimed", ~r/^\s*1\s*$/)
      assert has_element?(live, "#user-#{active.id}-tasks-completed", ~r/^\s*1\s*$/)
      assert has_element?(live, "#user-#{active.id}-tasks-created", ~r/^\s*2\s*$/)

      # Assert the shape, not a literal clock value, so the test cannot flake on
      # a rollover. Proves last_activity formatted rather than raising on the
      # NaiveDateTime or falling through to the placeholder.
      assert has_element?(
               live,
               "#user-#{active.id}-last-activity",
               ~r/^\s*\w{3} \d{2}, \d{4} \d{2}:\d{2}\s*$/
             )
    end

    test "renders zeros and a placeholder for a user with no recorded activity", %{conn: conn} do
      idle = user_fixture()

      {:ok, live, _html} = live(conn, ~p"/admin/users")

      # The aggregate's join is inner, so an idle user is absent from it — the
      # row must still render rather than being dropped from the table.
      assert has_element?(live, "#user-#{idle.id}")

      assert has_element?(live, "#user-#{idle.id}-total-actions", ~r/^\s*0\s*$/)
      assert has_element?(live, "#user-#{idle.id}-tasks-claimed", ~r/^\s*0\s*$/)
      assert has_element?(live, "#user-#{idle.id}-tasks-completed", ~r/^\s*0\s*$/)
      assert has_element?(live, "#user-#{idle.id}-tasks-created", ~r/^\s*0\s*$/)
      assert has_element?(live, "#user-#{idle.id}-last-activity", "N/A")
    end

    test "a mutating event re-reads the activity metrics", %{conn: conn} do
      user = user_fixture()
      event!(user, "kanban.api.task_claimed")

      {:ok, live, _html} = live(conn, ~p"/admin/users")

      assert has_element?(live, "#user-#{user.id}-total-actions", ~r/^\s*1\s*$/)

      # Seed AFTER mount, so the assertion below can only pass if the event
      # re-runs the fetch. A mount-only assign would survive the click at 1.
      event!(user, "kanban.api.task_completed")

      live |> element("#user-#{user.id} button", "Disable") |> render_click()

      assert has_element?(live, "#user-#{user.id}-total-actions", ~r/^\s*2\s*$/)
    end

    test "renders a user with a nil name without crashing", %{conn: conn} do
      user = user_fixture()
      assert user.name == nil

      {:ok, _live, html} = live(conn, ~p"/admin/users")

      assert html =~ user.email
    end

    test "renders a user's name when they have one", %{conn: conn} do
      named = user_fixture(%{name: "Ada Lovelace"})

      {:ok, live, _html} = live(conn, ~p"/admin/users")

      assert has_element?(live, "#user-#{named.id}", "Ada Lovelace")
    end

    # Each badge variant maps to exactly one column, so asserting on the variant
    # inside a row pins that column's rendered output:
    #   badge-success -> Confirmed: Yes    badge-error -> Disabled: Yes
    #   badge-primary -> Type: admin
    test "renders an unconfirmed user without the confirmed badge", %{conn: conn} do
      unconfirmed = unconfirmed_user_fixture()
      assert unconfirmed.confirmed_at == nil

      {:ok, live, html} = live(conn, ~p"/admin/users")

      assert html =~ unconfirmed.email
      refute has_element?(live, "#user-#{unconfirmed.id} .badge-success")
      assert has_element?(live, "#user-#{unconfirmed.id} .badge-ghost", "No")
    end

    test "renders the confirmed badge for a confirmed user", %{conn: conn} do
      user = user_fixture()

      {:ok, live, _html} = live(conn, ~p"/admin/users")

      assert has_element?(live, "#user-#{user.id} .badge-success", "Yes")
    end

    test "renders the disabled badge only for a disabled user", %{conn: conn} do
      disabled = user_fixture()
      enabled = user_fixture()
      {:ok, _} = Accounts.disable_user(disabled, admin_fixture())

      {:ok, live, _html} = live(conn, ~p"/admin/users")

      assert has_element?(live, "#user-#{disabled.id} .badge-error", "Yes")
      refute has_element?(live, "#user-#{enabled.id} .badge-error")
      assert has_element?(live, "#user-#{enabled.id} .badge-ghost", "No")
    end

    test "renders the admin badge only for an admin", %{conn: conn, user: admin} do
      plain = user_fixture()

      {:ok, live, _html} = live(conn, ~p"/admin/users")

      assert has_element?(live, "#user-#{admin.id} .badge-primary", "Admin")
      refute has_element?(live, "#user-#{plain.id} .badge-primary")
      assert has_element?(live, "#user-#{plain.id} .badge", "User")
    end

    test "renders the Created header and each user's formatted creation date", %{
      conn: conn,
      user: admin
    } do
      # Back-date one user so the assertion pins an exact known string rather
      # than whatever "now" happens to be, and covers a single-digit day.
      back_dated =
        user_fixture()
        |> Ecto.Changeset.change(inserted_at: ~U[2024-03-05 09:30:00Z])
        |> Kanban.Repo.update!()

      {:ok, _live, html} = live(conn, ~p"/admin/users")

      assert html =~ "Created"
      assert html =~ "Mar 05, 2024"
      assert html =~ Calendar.strftime(admin.inserted_at, "%b %d, %Y")
      refute html =~ to_string(back_dated.inserted_at)
    end

    test "renders the Created column between the Type and Confirmed columns", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/admin/users")

      assert [_ | _] =
               headers =
               Regex.scan(~r{<th[^>]*>\s*([^<]+?)\s*</th>}, html, capture: :all_but_first)

      headers = List.flatten(headers)

      type_at = Enum.find_index(headers, &(&1 == "Type"))
      created_at = Enum.find_index(headers, &(&1 == "Created"))
      confirmed_at = Enum.find_index(headers, &(&1 == "Confirmed"))

      assert created_at == type_at + 1
      assert confirmed_at == created_at + 1
    end

    test "each user occupies exactly two rows under a single tbody", %{conn: conn} do
      user = user_fixture()

      {:ok, live, _html} = live(conn, ~p"/admin/users")

      assert has_element?(live, "tbody#user-#{user.id} > tr:nth-child(2)")
      refute has_element?(live, "tbody#user-#{user.id} > tr:nth-child(3)")
    end

    test "the per-user stat spans stay addressable inside the user's tbody", %{conn: conn} do
      user = user_fixture()

      {:ok, live, _html} = live(conn, ~p"/admin/users")

      for suffix <- ~w(boards total-actions tasks-claimed tasks-completed tasks-created
                       last-activity) do
        assert has_element?(live, "tbody#user-#{user.id} ##{"user-#{user.id}-#{suffix}"}"),
               "expected #user-#{user.id}-#{suffix} to live inside the user's tbody"
      end
    end

    test "the identity row carries the email and the metrics row carries the stats", %{conn: conn} do
      user = user_fixture()

      {:ok, live, _html} = live(conn, ~p"/admin/users")

      assert has_element?(live, "tbody#user-#{user.id} > tr:first-child", user.email)
      assert has_element?(live, "tbody#user-#{user.id} > tr:last-child #user-#{user.id}-boards")
    end

    test "the action cell spans both of the user's rows", %{conn: conn} do
      user = user_fixture()

      {:ok, live, _html} = live(conn, ~p"/admin/users")

      assert has_element?(
               live,
               ~s(tbody#user-#{user.id} > tr:first-child td[rowspan="2"] button),
               "Delete"
             )
    end

    test "escapes a name containing HTML metacharacters" do
      # The name changeset rejects HTML metacharacters, so a hostile name can
      # only reach the table through a direct write. Force one in to prove the
      # template escapes rather than relying on that validation alone.
      admin = admin_fixture()

      # change/2 skips the name changeset's validations, which is the point.
      user_fixture()
      |> Ecto.Changeset.change(name: "<script>alert('xss')</script>")
      |> Kanban.Repo.update!()

      conn = log_in_user(Phoenix.ConnTest.build_conn(), admin)
      {:ok, _live, html} = live(conn, ~p"/admin/users")

      refute html =~ "<script>alert('xss')</script>"
      assert html =~ "&lt;script&gt;"
    end
  end

  describe "disable / enable events" do
    setup :register_and_log_in_admin

    test "disable sets disabled_at and flips the row's badge", %{conn: conn} do
      user = user_fixture()
      {:ok, live, _html} = live(conn, ~p"/admin/users")
      refute has_element?(live, "#user-#{user.id} .badge-error")

      html = live |> element("#user-#{user.id} button", "Disable") |> render_click()

      assert html =~ "Account disabled."
      assert has_element?(live, "#user-#{user.id} .badge-error", "Yes")
      assert Accounts.get_user!(user.id).disabled_at != nil
    end

    test "enable clears disabled_at and flips the row's badge", %{conn: conn} do
      user = user_fixture()
      {:ok, _} = Accounts.disable_user(user, admin_fixture())
      {:ok, live, _html} = live(conn, ~p"/admin/users")
      assert has_element?(live, "#user-#{user.id} .badge-error")

      html = live |> element("#user-#{user.id} button", "Enable") |> render_click()

      assert html =~ "Account enabled."
      refute has_element?(live, "#user-#{user.id} .badge-error")
      assert Accounts.get_user!(user.id).disabled_at == nil
    end

    # The acting admin here is the only admin in the system, so this is also the
    # last-enabled-admin case as it can actually occur through the UI: because
    # every event re-reads the actor and requires an enabled admin, a *different*
    # target can never be the last enabled admin (the actor would be a second
    # one). The last_admin guard is therefore unreachable from this page and is
    # covered at the context level in admin_management_test.exs, where a stale
    # actor struct can reach it.
    test "an admin cannot disable their own account, which is also the last admin", %{
      conn: conn,
      user: admin
    } do
      {:ok, live, _html} = live(conn, ~p"/admin/users")

      html = live |> element("#user-#{admin.id} button", "Disable") |> render_click()

      assert html =~ "You cannot disable your own account."
      assert Accounts.get_user!(admin.id).disabled_at == nil
    end

    test "the sole admin remains enabled after a refused self-disable", %{conn: conn, user: admin} do
      {:ok, live, _html} = live(conn, ~p"/admin/users")

      _ = render_click(live, "disable", %{"id" => to_string(admin.id)})

      reloaded = Accounts.get_user!(admin.id)
      assert reloaded.disabled_at == nil
      assert reloaded.type == :admin
    end
  end

  describe "resend confirmation event" do
    setup :register_and_log_in_admin

    test "sends a confirmation email to an unconfirmed user", %{conn: conn} do
      unconfirmed = unconfirmed_user_fixture()
      {:ok, live, _html} = live(conn, ~p"/admin/users")
      flush_emails()

      html =
        live
        |> element("#user-#{unconfirmed.id} button", "Resend confirmation")
        |> render_click()

      assert html =~ "Confirmation email sent."
      assert_email_sent(to: [{"", unconfirmed.email}])
    end

    test "the resend control is present but disabled for a confirmed user", %{conn: conn} do
      confirmed = user_fixture()
      unconfirmed = unconfirmed_user_fixture()

      {:ok, live, _html} = live(conn, ~p"/admin/users")

      assert has_element?(live, "#user-#{confirmed.id} button[disabled]", "Resend confirmation")
      refute has_element?(live, "#user-#{unconfirmed.id} button[disabled]", "Resend confirmation")
    end

    test "the disabled resend control explains itself with a tooltip", %{conn: conn} do
      confirmed = user_fixture()
      unconfirmed = unconfirmed_user_fixture()

      {:ok, live, _html} = live(conn, ~p"/admin/users")

      assert has_element?(
               live,
               ~s(#user-#{confirmed.id} button[title="This account is already confirmed."]),
               "Resend confirmation"
             )

      refute has_element?(live, "#user-#{unconfirmed.id} button[title]", "Resend confirmation")
    end

    test "a confirmed and disabled user keeps both the resend and enable controls", %{conn: conn} do
      user = user_fixture()
      {:ok, _} = Accounts.disable_user(user, admin_fixture())

      {:ok, live, _html} = live(conn, ~p"/admin/users")

      assert has_element?(live, "#user-#{user.id} button[disabled]", "Resend confirmation")
      assert has_element?(live, "#user-#{user.id} button", "Enable")
    end

    test "an unconfirmed and disabled user keeps the resend control enabled", %{conn: conn} do
      user = unconfirmed_user_fixture()
      {:ok, _} = Accounts.disable_user(user, admin_fixture())

      {:ok, live, _html} = live(conn, ~p"/admin/users")

      refute has_element?(live, "#user-#{user.id} button[disabled]", "Resend confirmation")
    end

    test "resending to an already-confirmed user is refused without sending", %{conn: conn} do
      confirmed = user_fixture()
      {:ok, live, _html} = live(conn, ~p"/admin/users")
      flush_emails()

      html = render_click(live, "resend_confirmation", %{"id" => to_string(confirmed.id)})

      assert html =~ "This account is already confirmed."
      assert_no_email_sent()
    end
  end

  describe "delete event" do
    setup :register_and_log_in_admin

    test "deletes a user with no boards and drops the row", %{conn: conn} do
      user = user_fixture()
      {:ok, live, _html} = live(conn, ~p"/admin/users")

      html = live |> element("#user-#{user.id} button", "Delete") |> render_click()

      assert html =~ "Account deleted."
      refute has_element?(live, "#user-#{user.id}")
      assert Kanban.Repo.get(User, user.id) == nil
    end

    test "the delete control is disabled for a user with boards", %{conn: conn} do
      with_board = user_fixture()
      _board = board_fixture(with_board)
      without_board = user_fixture()

      {:ok, live, _html} = live(conn, ~p"/admin/users")

      assert has_element?(live, "#user-#{with_board.id} button[disabled]", "Delete")
      refute has_element?(live, "#user-#{without_board.id} button[disabled]", "Delete")
    end

    # The disabled button is a UI hint; the event is what must refuse.
    test "delete is refused server-side for a user with boards", %{conn: conn} do
      user = user_fixture()
      _board = board_fixture(user)
      {:ok, live, _html} = live(conn, ~p"/admin/users")

      html = render_click(live, "delete", %{"id" => to_string(user.id)})

      assert html =~ "This user still belongs to a board and cannot be deleted."
      assert Kanban.Repo.get(User, user.id) != nil
    end

    test "an admin cannot delete their own account", %{conn: conn, user: admin} do
      {:ok, live, _html} = live(conn, ~p"/admin/users")

      html = live |> element("#user-#{admin.id} button", "Delete") |> render_click()

      assert html =~ "You cannot delete your own account."
      assert Kanban.Repo.get(User, admin.id) != nil
    end

    test "a second delete of the same user flashes not-found instead of crashing", %{conn: conn} do
      user = user_fixture()
      {:ok, live, _html} = live(conn, ~p"/admin/users")
      _ = render_click(live, "delete", %{"id" => to_string(user.id)})

      html = render_click(live, "delete", %{"id" => to_string(user.id)})

      assert html =~ "User not found."
    end

    test "a malformed id flashes not-found instead of crashing", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/admin/users")

      html = render_click(live, "delete", %{"id" => "not-an-id"})

      assert html =~ "User not found."
    end

    # Integer.parse/1 accepts this happily; Repo.get/2 raises on bigint overflow.
    test "an out-of-range numeric id flashes not-found instead of crashing", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/admin/users")

      html = render_click(live, "delete", %{"id" => "99999999999999999999"})

      assert html =~ "User not found."
    end

    test "an integer id from a tampered payload is handled", %{conn: conn} do
      user = user_fixture()
      {:ok, live, _html} = live(conn, ~p"/admin/users")

      html = render_click(live, "delete", %{"id" => user.id})

      assert html =~ "Account deleted."
      assert Kanban.Repo.get(User, user.id) == nil
    end

    test "a non-scalar id from a tampered payload flashes not-found", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/admin/users")

      html = render_click(live, "delete", %{"id" => %{"nested" => "value"}})

      assert html =~ "User not found."
    end
  end

  # An open socket keeps the current_scope it was mounted with, and nothing tears
  # it down when its user is disabled or demoted. Every event therefore re-reads
  # the actor from the database; these tests change the actor in the DB behind
  # the live socket's back and assert the event is refused anyway.
  describe "per-event actor re-authorization (stale socket)" do
    setup :register_and_log_in_admin

    defp demote_in_db(admin) do
      {:ok, _} = Accounts.update_user_type(admin, :user)
    end

    defp disable_in_db(admin) do
      admin
      |> Ecto.Changeset.change(disabled_at: DateTime.utc_now(:second))
      |> Kanban.Repo.update!()
    end

    # The escalation this guards: enable_user/1 has no context guard, so without
    # a fresh actor a disabled admin could re-enable their own account and undo
    # the disable entirely.
    test "a disabled admin cannot re-enable themselves through an open socket", %{
      conn: conn,
      user: admin
    } do
      {:ok, view, _html} = live(conn, ~p"/admin/users")
      disable_in_db(admin)

      render_hook(view, "enable", %{"id" => to_string(admin.id)})

      assert render(view) =~ "admin"
      assert Accounts.get_user!(admin.id).disabled_at != nil
    end

    test "a disabled admin cannot disable anyone through an open socket", %{
      conn: conn,
      user: admin
    } do
      user = user_fixture()
      {:ok, view, _html} = live(conn, ~p"/admin/users")
      disable_in_db(admin)

      render_hook(view, "disable", %{"id" => to_string(user.id)})

      assert render(view) =~ "admin"
      assert Accounts.get_user!(user.id).disabled_at == nil
    end

    test "a disabled admin cannot delete anyone through an open socket", %{
      conn: conn,
      user: admin
    } do
      user = user_fixture()
      {:ok, view, _html} = live(conn, ~p"/admin/users")
      disable_in_db(admin)

      render_hook(view, "delete", %{"id" => to_string(user.id)})

      assert render(view) =~ "admin"
      assert Kanban.Repo.get(User, user.id) != nil
    end

    test "a demoted admin cannot act through an open socket", %{conn: conn, user: admin} do
      user = user_fixture()
      {:ok, view, _html} = live(conn, ~p"/admin/users")
      demote_in_db(admin)

      render_hook(view, "disable", %{"id" => to_string(user.id)})

      assert render(view) =~ "admin"
      assert Accounts.get_user!(user.id).disabled_at == nil
    end

    test "a demoted admin cannot resend confirmations through an open socket", %{
      conn: conn,
      user: admin
    } do
      unconfirmed = unconfirmed_user_fixture()
      {:ok, view, _html} = live(conn, ~p"/admin/users")
      demote_in_db(admin)
      flush_emails()

      render_hook(view, "resend_confirmation", %{"id" => to_string(unconfirmed.id)})

      assert render(view) =~ "admin"
      assert_no_email_sent()
    end
  end

  describe "hide users with no boards filter" do
    setup :register_and_log_in_admin

    test "the checkbox is present, wired, and unchecked by default with all users shown",
         %{conn: conn} do
      with_boards = user_fixture()
      _board = board_fixture(with_boards)
      without_boards = user_fixture()

      {:ok, live, _html} = live(conn, ~p"/admin/users")

      # The filter checkbox exists and its form is wired to the toggle event.
      assert has_element?(
               live,
               "form#hide-users-without-boards-form[phx-change='toggle_hide_users_without_boards']"
             )

      assert has_element?(live, "#hide_users_without_boards")
      # Unchecked by default — no `checked` attribute on first render.
      refute has_element?(live, "#hide_users_without_boards[checked]")

      # Both the board-owning and board-less users are visible.
      assert has_element?(live, "#user-#{with_boards.id}")
      assert has_element?(live, "#user-#{without_boards.id}")
    end

    test "checking the box hides users with no boards and keeps users with boards",
         %{conn: conn} do
      with_boards = user_fixture()
      _board = board_fixture(with_boards)
      without_boards = user_fixture()

      {:ok, live, _html} = live(conn, ~p"/admin/users")

      render_hook(live, "toggle_hide_users_without_boards", %{
        "hide_users_without_boards" => "true"
      })

      assert has_element?(live, "#user-#{with_boards.id}")
      refute has_element?(live, "#user-#{without_boards.id}")
    end

    test "unchecking the box shows the zero-board users again", %{conn: conn} do
      with_boards = user_fixture()
      _board = board_fixture(with_boards)
      without_boards = user_fixture()

      {:ok, live, _html} = live(conn, ~p"/admin/users")

      render_hook(live, "toggle_hide_users_without_boards", %{
        "hide_users_without_boards" => "true"
      })

      refute has_element?(live, "#user-#{without_boards.id}")

      # An unchecked box omits the param entirely, so the toggle parses to false.
      render_hook(live, "toggle_hide_users_without_boards", %{})

      assert has_element?(live, "#user-#{with_boards.id}")
      assert has_element?(live, "#user-#{without_boards.id}")
    end

    test "shows an all-filtered message when the filter hides every user", %{conn: conn} do
      # The admin (no boards) plus this board-less user means checking the filter
      # empties the visible list even though users still exist.
      _without_boards = user_fixture()

      {:ok, live, _html} = live(conn, ~p"/admin/users")

      html =
        render_hook(live, "toggle_hide_users_without_boards", %{
          "hide_users_without_boards" => "true"
        })

      assert html =~ "No users have boards."
      refute has_element?(live, "table")
    end
  end

  # The user fixtures deliver their own confirmation emails, so the test
  # mailbox is not empty by the time an event fires. Drain it first, or the
  # assertions below match a fixture's email instead of the event's.
  defp flush_emails do
    receive do
      {:email, _} -> flush_emails()
    after
      0 -> :ok
    end
  end
end
