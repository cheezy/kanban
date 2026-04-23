defmodule Kanban.MessagesTest do
  use Kanban.DataCase

  import Kanban.AccountsFixtures
  import Kanban.MessagesFixtures

  alias Kanban.Messages
  alias Kanban.Messages.Message
  alias Kanban.Messages.MessageDismissal

  describe "list_messages/0" do
    test "returns messages newest first" do
      sender = user_fixture()

      old = message_fixture(sender, %{title: "old"})
      # Force a later inserted_at on the newer message to avoid tie ordering.
      :timer.sleep(5)
      new = message_fixture(sender, %{title: "new"})

      assert [first, second] = Messages.list_messages()
      assert first.id == new.id
      assert second.id == old.id
    end

    test "returns [] when there are no messages" do
      assert Messages.list_messages() == []
    end
  end

  describe "create_message/2" do
    test "with valid attrs returns {:ok, %Message{}} with sender set" do
      sender = user_fixture()

      assert {:ok, %Message{} = msg} =
               Messages.create_message(sender, %{title: "t", body: "b"})

      assert msg.title == "t"
      assert msg.body == "b"
      assert msg.sender_id == sender.id
    end

    test "with missing title returns {:error, changeset}" do
      sender = user_fixture()

      assert {:error, %Ecto.Changeset{} = cs} =
               Messages.create_message(sender, %{body: "b"})

      assert %{title: ["can't be blank"]} = errors_on(cs)
    end

    test "with missing body returns {:error, changeset}" do
      sender = user_fixture()

      assert {:error, %Ecto.Changeset{} = cs} =
               Messages.create_message(sender, %{title: "t"})

      assert %{body: ["can't be blank"]} = errors_on(cs)
    end
  end

  describe "delete_message/1" do
    test "removes the message and cascades its dismissals" do
      sender = user_fixture()
      reader = user_fixture()

      message = message_fixture(sender)
      _dismissal = message_dismissal_fixture(message, reader)

      assert {:ok, %Message{}} = Messages.delete_message(message)
      assert Repo.get(Message, message.id) == nil
      assert Repo.all(MessageDismissal) == []
    end
  end

  describe "list_undismissed_for_user/1" do
    test "returns only messages the user has NOT dismissed" do
      sender = user_fixture()
      reader = user_fixture()

      dismissed = message_fixture(sender, %{title: "dismissed"})
      undismissed = message_fixture(sender, %{title: "undismissed"})
      message_dismissal_fixture(dismissed, reader)

      assert [only] = Messages.list_undismissed_for_user(reader)
      assert only.id == undismissed.id
    end

    test "returns messages newest first" do
      sender = user_fixture()
      reader = user_fixture()

      old = message_fixture(sender, %{title: "old"})
      :timer.sleep(5)
      new = message_fixture(sender, %{title: "new"})

      assert [first, second] = Messages.list_undismissed_for_user(reader)
      assert first.id == new.id
      assert second.id == old.id
    end

    test "returns [] when there are no messages at all" do
      reader = user_fixture()

      assert Messages.list_undismissed_for_user(reader) == []
    end

    test "returns [] when all messages are dismissed" do
      sender = user_fixture()
      reader = user_fixture()

      m1 = message_fixture(sender)
      m2 = message_fixture(sender)
      message_dismissal_fixture(m1, reader)
      message_dismissal_fixture(m2, reader)

      assert Messages.list_undismissed_for_user(reader) == []
    end

    test "ignores dismissals from other users" do
      sender = user_fixture()
      reader_a = user_fixture()
      reader_b = user_fixture()

      message = message_fixture(sender)
      message_dismissal_fixture(message, reader_a)

      assert [only] = Messages.list_undismissed_for_user(reader_b)
      assert only.id == message.id
      assert Messages.list_undismissed_for_user(reader_a) == []
    end
  end

  describe "dismiss_message/2" do
    test "inserts a MessageDismissal" do
      sender = user_fixture()
      reader = user_fixture()
      message = message_fixture(sender)

      assert {:ok, %MessageDismissal{}} = Messages.dismiss_message(reader, message.id)
      assert Repo.aggregate(MessageDismissal, :count) == 1
    end

    test "is idempotent - calling twice does not raise or duplicate" do
      sender = user_fixture()
      reader = user_fixture()
      message = message_fixture(sender)

      assert {:ok, _} = Messages.dismiss_message(reader, message.id)
      assert {:ok, _} = Messages.dismiss_message(reader, message.id)

      assert Repo.aggregate(MessageDismissal, :count) == 1
    end

    test "two users dismissing the same message are isolated" do
      sender = user_fixture()
      reader_a = user_fixture()
      reader_b = user_fixture()
      message = message_fixture(sender)

      assert {:ok, _} = Messages.dismiss_message(reader_a, message.id)
      assert {:ok, _} = Messages.dismiss_message(reader_b, message.id)

      assert Repo.aggregate(MessageDismissal, :count) == 2
    end

    test "returns {:error, changeset} for a non-existent message_id" do
      reader = user_fixture()

      assert {:error, %Ecto.Changeset{} = cs} =
               Messages.dismiss_message(reader, 999_999_999)

      errors = errors_on(cs)
      assert "does not exist" in Map.get(errors, :message_id, [])
    end
  end

  describe "end-to-end" do
    test "create -> list undismissed -> dismiss -> list is empty" do
      sender = user_fixture()
      reader = user_fixture()

      message = message_fixture(sender)
      assert [^message] = Messages.list_undismissed_for_user(reader)

      {:ok, _} = Messages.dismiss_message(reader, message.id)
      assert Messages.list_undismissed_for_user(reader) == []
    end
  end
end
