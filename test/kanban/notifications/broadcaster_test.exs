defmodule Kanban.Notifications.BroadcasterTest do
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.Notifications.Broadcaster

  describe "topic/1" do
    test "is the same per-user topic for a scope, a user and an id" do
      user = user_fixture()
      expected = "user:#{user.id}:notifications"

      assert Broadcaster.topic(user.id) == expected
      assert Broadcaster.topic(user) == expected
      assert user |> Scope.for_user() |> Broadcaster.topic() == expected
    end

    test "differs between users" do
      refute Broadcaster.topic(1) == Broadcaster.topic(2)
    end
  end

  describe "subscribe/1 and broadcast/2" do
    test "a subscriber receives only its own user's messages" do
      user = user_fixture()
      other = user_fixture()

      assert :ok = user |> Scope.for_user() |> Broadcaster.subscribe()

      assert :ok = Broadcaster.broadcast(user.id, {:notifications_read, 3})
      assert_receive {:notifications_read, 3}

      assert :ok = Broadcaster.broadcast(other.id, {:notifications_read, 7})
      refute_receive {:notifications_read, 7}
    end

    test "broadcast/2 delivers on the topic topic/1 names" do
      user = user_fixture()
      Phoenix.PubSub.subscribe(Kanban.PubSub, "user:#{user.id}:notifications")

      Broadcaster.broadcast(user.id, :ping)

      assert_receive :ping
    end
  end
end
