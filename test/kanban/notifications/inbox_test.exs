defmodule Kanban.Notifications.InboxTest do
  @moduledoc """
  Direct tests of `Kanban.Notifications.Inbox`; `Kanban.Notifications`
  delegates its read and mark functions here.
  """
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.NotificationsFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.Notifications.Broadcaster
  alias Kanban.Notifications.Inbox
  alias Kanban.Notifications.Notification

  setup do
    user = user_fixture()
    %{user: user, scope: Scope.for_user(user)}
  end

  # Rows inserted in one test share a second, so spread them out explicitly.
  defp notifications!(user, count) do
    base = DateTime.utc_now()

    for offset <- 1..count do
      notification = notification_fixture(user)
      at = DateTime.add(base, offset - count, :second)

      notification
      |> Ecto.Changeset.change(inserted_at: at)
      |> Repo.update!()
    end
  end

  defp ids(rows), do: Enum.map(rows, & &1.id)

  describe "list_notifications/2" do
    test "lists only the user's own in-app rows, newest first", ctx do
      [oldest, middle, newest] = notifications!(ctx.user, 3)
      notification_fixture(user_fixture())

      hidden = notification_fixture(ctx.user)
      hidden |> Ecto.Changeset.change(in_app: false) |> Repo.update!()

      assert ids(Inbox.list_notifications(ctx.scope)) == [newest.id, middle.id, oldest.id]
    end

    test ":unread_only leaves out read rows", ctx do
      [read, unread] = notifications!(ctx.user, 2)
      {:ok, _} = Inbox.mark_read(ctx.scope, read.id)

      assert ids(Inbox.list_notifications(ctx.scope, unread_only: true)) == [unread.id]
      assert length(Inbox.list_notifications(ctx.scope, unread_only: false)) == 2
    end

    test ":limit is clamped to at least one and defaults when not an integer", ctx do
      [_, _, newest] = notifications!(ctx.user, 3)

      assert ids(Inbox.list_notifications(ctx.scope, limit: 1)) == [newest.id]
      assert ids(Inbox.list_notifications(ctx.scope, limit: 0)) == [newest.id]
      assert ids(Inbox.list_notifications(ctx.scope, limit: -5)) == [newest.id]
      assert length(Inbox.list_notifications(ctx.scope, limit: "2")) == 3
    end

    test ":before returns only rows older than the cursor", ctx do
      [oldest, middle, newest] = notifications!(ctx.user, 3)

      assert ids(Inbox.list_notifications(ctx.scope, before: newest)) == [middle.id, oldest.id]
      assert Inbox.list_notifications(ctx.scope, before: oldest) == []
    end

    test ":before breaks a timestamp tie by id", ctx do
      [first, second] = notifications!(ctx.user, 2)

      second
      |> Ecto.Changeset.change(inserted_at: first.inserted_at)
      |> Repo.update!()

      assert ids(Inbox.list_notifications(ctx.scope, before: Repo.reload!(second))) == [
               first.id
             ]
    end
  end

  describe "unread_count/1" do
    test "counts the user's visible unread rows only", ctx do
      [read, _unread, hidden] = notifications!(ctx.user, 3)
      {:ok, _} = Inbox.mark_read(ctx.scope, read.id)
      hidden |> Ecto.Changeset.change(in_app: false) |> Repo.update!()
      notification_fixture(user_fixture())

      assert Inbox.unread_count(ctx.scope) == 1
    end
  end

  describe "mark_read/2" do
    test "stamps read_at and broadcasts the new unread count", ctx do
      [first, _second] = notifications!(ctx.user, 2)
      Broadcaster.subscribe(ctx.scope)

      assert {:ok, %Notification{read_at: %DateTime{}} = marked} =
               Inbox.mark_read(ctx.scope, Integer.to_string(first.id))

      assert marked.id == first.id
      assert Repo.reload!(first).read_at
      assert_receive {:notifications_read, 1}
    end

    test "an already-read row succeeds without changing read_at", ctx do
      [notification] = notifications!(ctx.user, 1)
      {:ok, marked} = Inbox.mark_read(ctx.scope, notification.id)

      assert {:ok, again} = Inbox.mark_read(ctx.scope, notification.id)
      assert again.read_at == marked.read_at
    end

    test "returns :not_found for another user's, a hidden, a missing or a bad id", ctx do
      other = notification_fixture(user_fixture())
      [hidden] = notifications!(ctx.user, 1)
      hidden |> Ecto.Changeset.change(in_app: false) |> Repo.update!()

      for id <- [other.id, hidden.id, -1, "abc", nil] do
        assert Inbox.mark_read(ctx.scope, id) == {:error, :not_found}
      end

      assert is_nil(Repo.reload!(other).read_at)
    end
  end

  describe "mark_all_read/1" do
    test "marks every visible unread row and broadcasts zero", ctx do
      notifications!(ctx.user, 2)
      other = notification_fixture(user_fixture())
      Broadcaster.subscribe(ctx.scope)

      assert Inbox.mark_all_read(ctx.scope) == {:ok, 2}
      assert Inbox.unread_count(ctx.scope) == 0
      assert_receive {:notifications_read, 0}
      assert is_nil(Repo.reload!(other).read_at)

      assert Inbox.mark_all_read(ctx.scope) == {:ok, 0}
    end
  end
end
