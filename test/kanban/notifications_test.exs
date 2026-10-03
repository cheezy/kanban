defmodule Kanban.NotificationsTest do
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.NotificationsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.Boards
  alias Kanban.Notifications
  alias Kanban.Notifications.Notification
  alias Kanban.Notifications.Preference

  @all_types [
    :review_requested,
    :task_assigned,
    :claim_expired,
    :goal_completed,
    :weekly_digest,
    :comment_added,
    :mentioned,
    :task_reviewed,
    :task_unclaimed,
    :board_access_changed,
    :after_goal_failed,
    :target_status_changed
  ]

  defp scope(user), do: Scope.for_user(user)

  defp board_with_member(access \\ :modify) do
    owner = user_fixture()
    member = user_fixture()
    board = board_fixture(owner)
    {:ok, _} = Boards.add_user_to_board(board, member, access, owner)
    %{owner: owner, member: member, board: board}
  end

  describe "event_types/0" do
    test "returns every event type including the reserved and follow-on types" do
      assert Notifications.event_types() == @all_types
    end
  end

  describe "default_preference/1" do
    test "turns in-app on for every type and email off only for noisy types" do
      for type <- @all_types do
        pref = Notifications.default_preference(type)
        assert %Preference{event_type: ^type, in_app: true, id: nil, user_id: nil} = pref
        assert pref.email == type not in [:goal_completed, :comment_added]
      end
    end

    test "accepts the string form" do
      assert %Preference{event_type: :review_requested} =
               Notifications.default_preference("review_requested")
    end

    test "raises for an unknown event type" do
      assert_raise ArgumentError, fn -> Notifications.default_preference(:bogus) end
      assert_raise ArgumentError, fn -> Notifications.default_preference("bogus") end
    end
  end

  describe "topic/1 and subscribe/1" do
    test "returns the same per-user topic for a scope, a user and an id" do
      user = user_fixture()
      expected = "user:#{user.id}:notifications"

      assert Notifications.topic(user) == expected
      assert user |> scope() |> Notifications.topic() == expected
      assert Notifications.topic(user.id) == expected
    end

    test "subscribe/1 delivers created notifications only for the subscribed user" do
      user = user_fixture()
      other = user_fixture()
      user_id = user.id

      :ok = user |> scope() |> Notifications.subscribe()

      {:ok, [_]} = Notifications.notify(:board_access_changed, [other], %{title: "Not yours"})
      refute_receive {:notification_created, _}

      {:ok, [_]} = Notifications.notify(:board_access_changed, [user], %{title: "Yours"})
      assert_receive {:notification_created, %Notification{user_id: ^user_id, title: "Yours"}}
    end
  end

  describe "notify/3" do
    test "inserts one row per recipient with the given attributes" do
      %{owner: owner, member: member, board: board} = board_with_member()

      assert {:ok, [n1, n2]} =
               Notifications.notify(:review_requested, [owner, member], %{
                 title: "W1 is ready for review",
                 body: "Plain text body",
                 url_path: "/review",
                 actor_name: "Claude",
                 board_id: board.id,
                 metadata: %{"identifier" => "W1"}
               })

      assert n1.user_id == owner.id
      assert n2.user_id == member.id

      for n <- [n1, n2] do
        assert n.event_type == :review_requested
        assert n.board_id == board.id
        assert n.title == "W1 is ready for review"
        assert n.url_path == "/review"
        assert n.actor_name == "Claude"
        assert n.metadata == %{"identifier" => "W1"}
        assert is_nil(n.read_at)
      end
    end

    test "accepts string-keyed attributes and a string event type" do
      user = user_fixture()
      board = board_fixture(user)

      assert {:ok, [n]} =
               Notifications.notify("goal_completed", [user], %{
                 "title" => "G1 is done",
                 "board_id" => board.id
               })

      assert n.event_type == :goal_completed
      assert n.title == "G1 is done"
      assert n.board_id == board.id
    end

    test "ignores nil recipients and duplicates without raising" do
      u1 = user_fixture()
      u2 = user_fixture()

      assert {:ok, inserted} =
               Notifications.notify(:board_access_changed, [u1, nil, u1, u2], %{title: "Hello"})

      assert Enum.map(inserted, & &1.user_id) == [u1.id, u2.id]
    end

    test "returns {:ok, []} for an empty recipient list" do
      assert {:ok, []} = Notifications.notify(:board_access_changed, [], %{title: "Nobody"})
    end

    test "defaults a nil metadata to an empty map instead of raising" do
      user = user_fixture()

      assert {:ok, [%Notification{metadata: %{}}]} =
               Notifications.notify(:board_access_changed, [user], %{title: "x", metadata: nil})
    end

    test "a repeated dedupe_key inserts and broadcasts nothing the second time" do
      user = user_fixture()
      attrs = %{title: "Once", dedupe_key: "board_access_changed:1:42"}

      assert {:ok, [_]} = Notifications.notify(:board_access_changed, [user], attrs)

      :ok = Notifications.subscribe(user)
      assert {:ok, []} = Notifications.notify(:board_access_changed, [user], attrs)
      refute_receive {:notification_created, _}

      assert Notification |> where(user_id: ^user.id) |> Repo.aggregate(:count) == 1
    end

    test "the same dedupe_key still notifies a different recipient" do
      u1 = user_fixture()
      u2 = user_fixture()
      attrs = %{title: "Shared key", dedupe_key: "board_access_changed:9:100"}

      {:ok, [_]} = Notifications.notify(:board_access_changed, [u1], attrs)

      assert {:ok, [n]} = Notifications.notify(:board_access_changed, [u1, u2], attrs)
      assert n.user_id == u2.id
    end

    test "nil dedupe keys never collide" do
      user = user_fixture()

      {:ok, [_]} = Notifications.notify(:board_access_changed, [user], %{title: "A"})
      {:ok, [_]} = Notifications.notify(:board_access_changed, [user], %{title: "B"})

      assert Notification |> where(user_id: ^user.id) |> Repo.aggregate(:count) == 2
    end

    test "skips a recipient whose in-app and email preferences are both off" do
      %{owner: muted, member: listening, board: board} = board_with_member()
      preference_fixture(muted, :review_requested, %{in_app: false, email: false})

      assert {:ok, [n]} =
               Notifications.notify(:review_requested, [muted, listening], %{
                 title: "Review",
                 board_id: board.id
               })

      assert n.user_id == listening.id
      assert n.in_app
    end

    test "stores a hidden, unbroadcast row for a recipient with in-app off but email on" do
      %{owner: email_only, member: listening, board: board} = board_with_member()
      preference_fixture(email_only, :review_requested, %{in_app: false, email: true})
      :ok = Notifications.subscribe(email_only)

      assert {:ok, [hidden, visible]} =
               Notifications.notify(:review_requested, [email_only, listening], %{
                 title: "Review",
                 board_id: board.id
               })

      assert %Notification{user_id: user_id, in_app: false} = hidden
      assert user_id == email_only.id
      assert visible.in_app
      refute_receive {:notification_created, _}
      assert email_only |> scope() |> Notifications.list_notifications() == []
      assert email_only |> scope() |> Notifications.unread_count() == 0
      assert {:error, :not_found} = email_only |> scope() |> Notifications.mark_read(hidden.id)
    end

    test "only the matching event type's preference is applied" do
      user = user_fixture()
      board = board_fixture(user)
      preference_fixture(user, :review_requested, %{in_app: false})
      preference_fixture(user, :task_assigned, %{in_app: true, email: false})

      assert {:ok, [_]} =
               Notifications.notify(:task_assigned, [user], %{
                 title: "Assigned",
                 board_id: board.id
               })
    end

    test "accepts every event type in atom and string form, including the reserved types" do
      user = user_fixture()
      board = board_fixture(user)

      for type <- Notifications.event_types() do
        attrs = %{title: "#{type}", board_id: board.id}

        assert {:ok, [%Notification{event_type: ^type}]} =
                 Notifications.notify(type, [user], attrs)

        assert {:ok, [%Notification{event_type: ^type}]} =
                 type |> Atom.to_string() |> Notifications.notify([user], attrs)
      end

      for type <- [:comment_added, :mentioned] do
        assert {:ok, [_]} = Notifications.notify(type, [user], %{title: "x", board_id: board.id})
      end
    end

    test "rejects an unknown event type without inserting" do
      user = user_fixture()

      assert {:error, :invalid_event_type} =
               Notifications.notify("bogus", [user], %{title: "x"})

      assert {:error, :invalid_event_type} = Notifications.notify(:bogus, [user], %{title: "x"})
      assert {:error, :invalid_event_type} = Notifications.notify(nil, [user], %{title: "x"})

      assert Repo.aggregate(Notification, :count) == 0
    end

    test "returns a changeset error and inserts nothing for anyone when attrs are invalid" do
      u1 = user_fixture()
      u2 = user_fixture()

      assert {:error, %Ecto.Changeset{} = changeset} =
               Notifications.notify(:board_access_changed, [u1, u2], %{body: "no title"})

      assert %{title: ["can't be blank"]} = errors_on(changeset)
      assert Repo.aggregate(Notification, :count) == 0
    end

    test "rejects url paths that are not app-relative" do
      user = user_fixture()

      for path <- [
            "//evil.example",
            "https://evil.example",
            "/\\evil.example",
            "review",
            "/\t/evil.example",
            "/\n/evil.example",
            "/\r/evil.example",
            "/review\n"
          ] do
        assert {:error, changeset} =
                 Notifications.notify(:board_access_changed, [user], %{title: "x", url_path: path})

        assert %{url_path: [_]} = errors_on(changeset)
      end

      assert {:ok, [_]} =
               Notifications.notify(:board_access_changed, [user], %{
                 title: "x",
                 url_path: "/users/notifications?tab=all#top"
               })
    end

    test "requires a board for event types that are not account-level" do
      user = user_fixture()

      for type <- Notifications.event_types() -- Notification.board_less_event_types() do
        assert {:error, changeset} = Notifications.notify(type, [user], %{title: "x"})
        assert %{board_id: ["is required for this event type"]} = errors_on(changeset)
      end

      for type <- Notification.board_less_event_types() do
        assert {:ok, [%Notification{board_id: nil}]} =
                 Notifications.notify(type, [user], %{title: "x"})
      end
    end

    test "rejects board-scoped url paths and task metadata on board-less notifications" do
      user = user_fixture()

      for path <- ["/boards/12", "/boards/12/tasks/3", "/boards/12?tab=x", "/boards/12#top"] do
        assert {:error, changeset} =
                 Notifications.notify(:board_access_changed, [user], %{title: "x", url_path: path})

        assert %{url_path: ["must not point inside a board on a board-less notification"]} =
                 errors_on(changeset)
      end

      for metadata <- [%{"task_id" => 1}, %{task_title: "Secret"}, %{"Identifier" => "W1"}] do
        assert {:error, changeset} =
                 Notifications.notify(:weekly_digest, [user], %{title: "x", metadata: metadata})

        assert %{metadata: ["must not carry task data on a board-less notification"]} =
                 errors_on(changeset)
      end

      assert {:ok, [_]} =
               Notifications.notify(:board_access_changed, [user], %{
                 title: "Removed from a board",
                 url_path: "/boards",
                 metadata: %{"change" => "removed", "tokens_revoked" => 2}
               })
    end

    test "allows board-scoped url paths and task metadata when the board is named" do
      user = user_fixture()
      board = board_fixture(user)

      assert {:ok, [n]} =
               Notifications.notify(:board_access_changed, [user], %{
                 title: "Added to a board",
                 board_id: board.id,
                 url_path: "/boards/#{board.id}/tasks/2",
                 metadata: %{"task_identifier" => "W2"}
               })

      assert n.metadata == %{"task_identifier" => "W2"}
    end

    test "requires a board when a task is referenced" do
      user = user_fixture()
      board = board_fixture(user)
      task = task_fixture(column_fixture(board))

      assert {:error, changeset} =
               Notifications.notify(:board_access_changed, [user], %{title: "x", task_id: task.id})

      assert %{board_id: ["is required when a task is referenced"]} = errors_on(changeset)

      assert {:ok, [n]} =
               Notifications.notify(:task_assigned, [user], %{
                 title: "x",
                 task_id: task.id,
                 board_id: board.id
               })

      assert n.task_id == task.id
    end

    test "rejects a task that does not belong to the given board" do
      user = user_fixture()
      board = board_fixture(user)
      other_board = board_fixture(user)
      task = task_fixture(column_fixture(other_board))

      assert {:error, changeset} =
               Notifications.notify(:task_assigned, [user], %{
                 title: "x",
                 task_id: task.id,
                 board_id: board.id
               })

      assert %{task_id: ["does not belong to the board"]} = errors_on(changeset)
      assert Repo.aggregate(Notification, :count) == 0
    end

    test "the database rejects a task reference without a board" do
      user = user_fixture()
      board = board_fixture(user)
      task = task_fixture(column_fixture(board))
      now = NaiveDateTime.utc_now()

      assert_raise Postgrex.Error, ~r/notifications_task_requires_board/, fn ->
        Repo.insert_all("notifications", [
          %{
            user_id: user.id,
            task_id: task.id,
            event_type: "board_access_changed",
            title: "x",
            metadata: %{},
            inserted_at: now,
            updated_at: now
          }
        ])
      end
    end

    test "drops recipients who do not belong to the named board" do
      %{owner: owner, member: member, board: board} = board_with_member()
      outsider = user_fixture()
      :ok = Notifications.subscribe(outsider)

      assert {:ok, inserted} =
               Notifications.notify(:review_requested, [owner, outsider, member], %{
                 title: "Review",
                 board_id: board.id
               })

      assert Enum.map(inserted, & &1.user_id) == [owner.id, member.id]
      refute_receive {:notification_created, _}
      assert Notification |> where(user_id: ^outsider.id) |> Repo.aggregate(:count) == 0
    end

    test "drops a recipient removed from the board before the event is emitted" do
      %{owner: owner, member: member, board: board} = board_with_member()
      {:ok, _} = Boards.remove_user_from_board(board, member, owner)

      assert {:ok, []} =
               Notifications.notify(:claim_expired, [member], %{
                 title: "Claim expired",
                 board_id: board.id
               })
    end

    test "attributes cannot redirect a notification to another user or event type" do
      recipient = user_fixture()
      other = user_fixture()

      assert {:ok, [n]} =
               Notifications.notify(:board_access_changed, [recipient], %{
                 title: "x",
                 user_id: other.id,
                 event_type: :task_assigned
               })

      assert n.user_id == recipient.id
      assert n.event_type == :board_access_changed
    end
  end

  describe "cascades" do
    test "deleting a task removes its notifications" do
      user = user_fixture()
      board = board_fixture(user)
      task = task_fixture(column_fixture(board))

      {:ok, [n]} =
        Notifications.notify(:task_assigned, [user], %{
          title: "x",
          task_id: task.id,
          board_id: board.id
        })

      Repo.delete!(task)
      refute Repo.get(Notification, n.id)
    end

    test "deleting a board removes its notifications" do
      user = user_fixture()
      board = board_fixture(user)

      {:ok, [n]} = Notifications.notify(:task_assigned, [user], %{title: "x", board_id: board.id})

      Repo.delete!(board)
      refute Repo.get(Notification, n.id)
    end

    test "deleting a user removes their notifications and preferences" do
      user = user_fixture()
      n = notification_fixture(user)
      pref = preference_fixture(user, :task_assigned)

      Repo.delete!(user)
      refute Repo.get(Notification, n.id)
      refute Repo.get(Preference, pref.id)
    end
  end

  describe "list_notifications/2" do
    test "lists only the scoped user's notifications, newest first" do
      user = user_fixture()
      other = user_fixture()
      first = notification_fixture(user)
      second = notification_fixture(user)
      _theirs = notification_fixture(other)

      ids = user |> scope() |> Notifications.list_notifications() |> Enum.map(& &1.id)
      assert ids == [second.id, first.id]
    end

    test "filters to unread notifications" do
      user = user_fixture()
      read = notification_fixture(user)
      unread = notification_fixture(user)
      {:ok, _} = user |> scope() |> Notifications.mark_read(read.id)

      assert [%Notification{id: id}] =
               user |> scope() |> Notifications.list_notifications(unread_only: true)

      assert id == unread.id
    end

    test "limits and clamps the page size" do
      user = user_fixture()
      for _ <- 1..3, do: notification_fixture(user)

      assert length(user |> scope() |> Notifications.list_notifications(limit: 2)) == 2
      assert length(user |> scope() |> Notifications.list_notifications(limit: 0)) == 1
      assert length(user |> scope() |> Notifications.list_notifications(limit: "bad")) == 3
    end

    test "pages with a :before cursor without overlap" do
      user = user_fixture()
      [a, b, c] = for _ <- 1..3, do: notification_fixture(user)

      [first_page_last | _] =
        user |> scope() |> Notifications.list_notifications(limit: 2) |> Enum.reverse()

      assert first_page_last.id == b.id

      older_ids =
        user
        |> scope()
        |> Notifications.list_notifications(before: first_page_last)
        |> Enum.map(& &1.id)

      assert older_ids == [a.id]

      refute c.id == first_page_last.id
    end

    test "hides notifications for a board the user was removed from" do
      %{owner: owner, member: member, board: board} = board_with_member()

      {:ok, [n]} =
        Notifications.notify(:task_assigned, [member], %{title: "On board", board_id: board.id})

      assert [%Notification{id: id}] = member |> scope() |> Notifications.list_notifications()
      assert id == n.id
      assert member |> scope() |> Notifications.unread_count() == 1

      {:ok, _} = Boards.remove_user_from_board(board, member, owner)

      assert member |> scope() |> Notifications.list_notifications() == []
      assert member |> scope() |> Notifications.unread_count() == 0
    end

    test "always lists a notification with a nil board_id, even for a user with no boards" do
      %{owner: owner, member: member, board: board} = board_with_member()
      {:ok, _} = Boards.remove_user_from_board(board, member, owner)

      {:ok, [n]} =
        Notifications.notify(:board_access_changed, [member], %{title: "You were removed"})

      assert [%Notification{id: id, board_id: nil}] =
               member |> scope() |> Notifications.list_notifications()

      assert id == n.id
    end
  end

  describe "unread_count/1" do
    test "counts only the scoped user's unread notifications" do
      user = user_fixture()
      other = user_fixture()
      read = notification_fixture(user)
      notification_fixture(user)
      notification_fixture(user)
      notification_fixture(other)
      {:ok, _} = user |> scope() |> Notifications.mark_read(read.id)

      assert user |> scope() |> Notifications.unread_count() == 2
      assert other |> scope() |> Notifications.unread_count() == 1
    end
  end

  describe "mark_read/2" do
    test "marks the notification read and broadcasts the new unread count" do
      user = user_fixture()
      n = notification_fixture(user)
      :ok = Notifications.subscribe(user)

      assert {:ok, %Notification{read_at: %DateTime{}}} =
               user |> scope() |> Notifications.mark_read(n.id)

      assert_receive {:notifications_read, 0}
    end

    test "accepts a string id" do
      user = user_fixture()
      n = notification_fixture(user)

      assert {:ok, %Notification{}} =
               user |> scope() |> Notifications.mark_read(Integer.to_string(n.id))
    end

    test "is idempotent for an already-read notification" do
      user = user_fixture()
      n = notification_fixture(user)

      {:ok, %Notification{read_at: read_at}} = user |> scope() |> Notifications.mark_read(n.id)

      assert {:ok, %Notification{read_at: ^read_at}} =
               user |> scope() |> Notifications.mark_read(n.id)
    end

    test "returns :not_found for another user's notification and leaves it unread" do
      owner = user_fixture()
      intruder = user_fixture()
      n = notification_fixture(owner)

      assert {:error, :not_found} = intruder |> scope() |> Notifications.mark_read(n.id)
      assert is_nil(Repo.get!(Notification, n.id).read_at)
    end

    test "returns :not_found for unknown and malformed ids" do
      user = user_fixture()

      assert {:error, :not_found} = user |> scope() |> Notifications.mark_read(-1)
      assert {:error, :not_found} = user |> scope() |> Notifications.mark_read("abc")
      assert {:error, :not_found} = user |> scope() |> Notifications.mark_read(nil)
    end

    test "returns :not_found for a notification hidden by board removal" do
      %{owner: owner, member: member, board: board} = board_with_member()

      {:ok, [n]} =
        Notifications.notify(:task_assigned, [member], %{title: "x", board_id: board.id})

      {:ok, _} = Boards.remove_user_from_board(board, member, owner)

      assert {:error, :not_found} = member |> scope() |> Notifications.mark_read(n.id)
    end
  end

  describe "mark_all_read/1" do
    test "marks every unread notification read, broadcasts and leaves other users alone" do
      user = user_fixture()
      other = user_fixture()
      notification_fixture(user)
      notification_fixture(user)
      theirs = notification_fixture(other)
      :ok = Notifications.subscribe(user)

      assert {:ok, 2} = user |> scope() |> Notifications.mark_all_read()
      assert_receive {:notifications_read, 0}
      assert user |> scope() |> Notifications.unread_count() == 0
      assert is_nil(Repo.get!(Notification, theirs.id).read_at)
    end

    test "leaves notifications hidden by board removal unread" do
      %{owner: owner, member: member, board: board} = board_with_member()

      {:ok, [hidden]} =
        Notifications.notify(:task_assigned, [member], %{title: "x", board_id: board.id})

      visible = notification_fixture(member)
      {:ok, _} = Boards.remove_user_from_board(board, member, owner)

      assert {:ok, 1} = member |> scope() |> Notifications.mark_all_read()
      assert Repo.get!(Notification, visible.id).read_at
      assert is_nil(Repo.get!(Notification, hidden.id).read_at)
    end

    test "returns {:ok, 0} when nothing is unread" do
      user = user_fixture()
      assert {:ok, 0} = user |> scope() |> Notifications.mark_all_read()
    end
  end

  describe "get_preferences/1 and update_preference/3" do
    test "returns defaults for every event type when the user has no rows" do
      user = user_fixture()
      prefs = user |> scope() |> Notifications.get_preferences()

      assert Enum.map(prefs, & &1.event_type) == @all_types

      for pref <- prefs do
        default = Notifications.default_preference(pref.event_type)
        assert pref.id == nil
        assert pref.user_id == user.id
        assert {pref.in_app, pref.email} == {default.in_app, default.email}
      end
    end

    test "update_preference/3 inserts then updates the same row" do
      user = user_fixture()

      assert {:ok, %Preference{id: id, email: false}} =
               user
               |> scope()
               |> Notifications.update_preference(:review_requested, %{email: false})

      assert {:ok, %Preference{id: ^id, email: true}} =
               user
               |> scope()
               |> Notifications.update_preference("review_requested", %{"email" => true})

      assert Preference |> where(user_id: ^user.id) |> Repo.aggregate(:count) == 1
    end

    test "an omitted flag keeps its current value" do
      user = user_fixture()

      {:ok, _} =
        user |> scope() |> Notifications.update_preference(:claim_expired, %{in_app: false})

      assert {:ok, %Preference{in_app: false, email: false}} =
               user |> scope() |> Notifications.update_preference(:claim_expired, %{email: false})

      assert {:ok, %Preference{in_app: false, email: true}} =
               user |> scope() |> Notifications.update_preference(:claim_expired, %{email: true})
    end

    test "get_preferences/1 merges saved rows with defaults" do
      user = user_fixture()

      {:ok, saved} =
        user |> scope() |> Notifications.update_preference(:goal_completed, %{email: true})

      prefs = user |> scope() |> Notifications.get_preferences()

      assert Enum.find(prefs, &(&1.event_type == :goal_completed)).id == saved.id
      assert Enum.find(prefs, &(&1.event_type == :goal_completed)).email
      assert Enum.find(prefs, &(&1.event_type == :comment_added)).id == nil
    end

    test "rejects an unknown event type" do
      user = user_fixture()

      assert {:error, :invalid_event_type} =
               user |> scope() |> Notifications.update_preference("bogus", %{email: true})
    end

    test "never touches another user's preference" do
      user = user_fixture()
      other = user_fixture()

      {:ok, _} =
        other |> scope() |> Notifications.update_preference(:task_assigned, %{email: false})

      {:ok, _} =
        user |> scope() |> Notifications.update_preference(:task_assigned, %{email: true})

      other_pref =
        other
        |> scope()
        |> Notifications.get_preferences()
        |> Enum.find(&(&1.event_type == :task_assigned))

      refute other_pref.email
    end
  end

  describe "unsubscribe/2" do
    test "turns email off and leaves in-app unchanged" do
      user = user_fixture()
      preference_fixture(user, :review_requested, %{in_app: true, email: true})

      assert :ok = Notifications.unsubscribe(user.id, :review_requested)

      pref =
        user
        |> scope()
        |> Notifications.get_preferences()
        |> Enum.find(&(&1.event_type == :review_requested))

      assert pref.in_app
      refute pref.email
    end

    test "is idempotent" do
      user = user_fixture()

      assert :ok = Notifications.unsubscribe(user.id, :weekly_digest)
      assert :ok = Notifications.unsubscribe(user.id, "weekly_digest")

      assert Preference |> where(user_id: ^user.id) |> Repo.aggregate(:count) == 1
    end

    test "returns :not_found for a deleted user and an error for an unknown type" do
      user = user_fixture()

      assert {:error, :invalid_event_type} = Notifications.unsubscribe(user.id, :bogus)

      Repo.delete!(user)
      assert {:error, :not_found} = Notifications.unsubscribe(user.id, :review_requested)
    end
  end
end
