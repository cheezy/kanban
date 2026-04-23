defmodule Kanban.Messages.MessageDismissalTest do
  use Kanban.DataCase

  import Kanban.AccountsFixtures

  alias Kanban.Messages.Message
  alias Kanban.Messages.MessageDismissal
  alias Kanban.Repo

  defp message_fixture do
    {:ok, message} =
      %Message{}
      |> Message.changeset(%{title: "announce", body: "body text"})
      |> Repo.insert()

    message
  end

  describe "changeset/2" do
    test "requires message_id and user_id" do
      changeset = MessageDismissal.changeset(%MessageDismissal{}, %{})

      errors = errors_on(changeset)
      assert "can't be blank" in Map.get(errors, :message_id, [])
      assert "can't be blank" in Map.get(errors, :user_id, [])
    end

    test "sets dismissed_at to the current time when not provided" do
      message = message_fixture()
      user = user_fixture()

      before_insert = DateTime.utc_now()

      changeset =
        MessageDismissal.changeset(%MessageDismissal{}, %{
          message_id: message.id,
          user_id: user.id
        })

      assert changeset.valid?
      dismissed_at = Ecto.Changeset.get_field(changeset, :dismissed_at)
      assert %DateTime{} = dismissed_at
      assert DateTime.compare(dismissed_at, before_insert) in [:gt, :eq]
    end

    test "accepts an explicit dismissed_at value" do
      message = message_fixture()
      user = user_fixture()
      explicit = ~U[2026-01-01 12:00:00.000000Z]

      changeset =
        MessageDismissal.changeset(%MessageDismissal{}, %{
          message_id: message.id,
          user_id: user.id,
          dismissed_at: explicit
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :dismissed_at) == explicit
    end
  end

  describe "database constraints" do
    test "duplicate (message_id, user_id) raises unique constraint error" do
      message = message_fixture()
      user = user_fixture()

      {:ok, _first} =
        %MessageDismissal{}
        |> MessageDismissal.changeset(%{message_id: message.id, user_id: user.id})
        |> Repo.insert()

      {:error, changeset} =
        %MessageDismissal{}
        |> MessageDismissal.changeset(%{message_id: message.id, user_id: user.id})
        |> Repo.insert()

      errors = errors_on(changeset)
      assert "has already been taken" in Map.get(errors, :message_id, [])
    end

    test "deleting the referenced user cascades to dismissals" do
      message = message_fixture()
      user = user_fixture()

      {:ok, _dismissal} =
        %MessageDismissal{}
        |> MessageDismissal.changeset(%{message_id: message.id, user_id: user.id})
        |> Repo.insert()

      Repo.delete!(user)

      assert Repo.all(MessageDismissal) == []
    end

    test "deleting the referenced message cascades to dismissals" do
      message = message_fixture()
      user = user_fixture()

      {:ok, _dismissal} =
        %MessageDismissal{}
        |> MessageDismissal.changeset(%{message_id: message.id, user_id: user.id})
        |> Repo.insert()

      Repo.delete!(message)

      assert Repo.all(MessageDismissal) == []
    end

    test "rejects insertion when message_id references a non-existent row" do
      user = user_fixture()

      {:error, changeset} =
        %MessageDismissal{}
        |> MessageDismissal.changeset(%{message_id: 999_999_999, user_id: user.id})
        |> Repo.insert()

      errors = errors_on(changeset)
      assert "does not exist" in Map.get(errors, :message_id, [])
    end
  end
end
