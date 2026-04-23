defmodule Kanban.Messages.MessageTest do
  use Kanban.DataCase

  import Kanban.AccountsFixtures

  alias Kanban.Messages.Message
  alias Kanban.Messages.MessageDismissal
  alias Kanban.Repo

  describe "changeset/2" do
    test "requires title and body" do
      changeset = Message.changeset(%Message{}, %{})

      assert %{title: ["can't be blank"], body: ["can't be blank"]} = errors_on(changeset)
    end

    test "rejects blank title" do
      changeset = Message.changeset(%Message{}, %{title: "", body: "some body"})

      assert %{title: ["can't be blank"]} = errors_on(changeset)
    end

    test "rejects blank body" do
      changeset = Message.changeset(%Message{}, %{title: "some title", body: ""})

      assert %{body: ["can't be blank"]} = errors_on(changeset)
    end

    test "accepts valid attributes without sender" do
      changeset =
        Message.changeset(%Message{}, %{title: "announcement", body: "site will be down"})

      assert changeset.valid?
    end

    test "accepts valid attributes with sender_id" do
      user = user_fixture()

      changeset =
        Message.changeset(%Message{}, %{
          title: "announcement",
          body: "site will be down",
          sender_id: user.id
        })

      assert changeset.valid?
    end

    test "accepts very long body text (several KB)" do
      body = String.duplicate("abcdefghij ", 600)
      changeset = Message.changeset(%Message{}, %{title: "long", body: body})

      assert changeset.valid?
    end
  end

  describe "database constraints" do
    test "can insert a message with a sender" do
      user = user_fixture()

      {:ok, message} =
        %Message{}
        |> Message.changeset(%{
          title: "hello",
          body: "world",
          sender_id: user.id
        })
        |> Repo.insert()

      assert message.id
      assert message.sender_id == user.id
    end

    test "sender_id becomes nil when the sender user is deleted" do
      user = user_fixture()

      {:ok, message} =
        %Message{}
        |> Message.changeset(%{title: "hi", body: "there", sender_id: user.id})
        |> Repo.insert()

      Repo.delete!(user)

      reloaded = Repo.get!(Message, message.id)
      assert reloaded.sender_id == nil
    end

    test "deleting a message cascades to its dismissals" do
      user = user_fixture()

      {:ok, message} =
        %Message{}
        |> Message.changeset(%{title: "t", body: "b"})
        |> Repo.insert()

      {:ok, _dismissal} =
        %MessageDismissal{}
        |> MessageDismissal.changeset(%{message_id: message.id, user_id: user.id})
        |> Repo.insert()

      Repo.delete!(message)

      assert Repo.all(MessageDismissal) == []
    end
  end

  describe "associations" do
    test "has_many :dismissals is preloadable" do
      user = user_fixture()

      {:ok, message} =
        %Message{}
        |> Message.changeset(%{title: "t", body: "b"})
        |> Repo.insert()

      {:ok, _} =
        %MessageDismissal{}
        |> MessageDismissal.changeset(%{message_id: message.id, user_id: user.id})
        |> Repo.insert()

      reloaded = Message |> Repo.get!(message.id) |> Repo.preload(:dismissals)

      assert length(reloaded.dismissals) == 1
    end
  end
end
