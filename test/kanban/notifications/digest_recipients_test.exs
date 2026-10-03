defmodule Kanban.Notifications.DigestRecipientsTest do
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.NotificationsFixtures

  alias Kanban.Accounts.User
  alias Kanban.Boards
  alias Kanban.Notifications
  alias Kanban.Notifications.DigestRecipients

  defp with_board(user) do
    board_fixture(user)
    user
  end

  defp disable(user) do
    User
    |> where(id: ^user.id)
    |> Repo.update_all(set: [disabled_at: DateTime.utc_now(:second)])

    user
  end

  test "includes opted-in members and excludes everyone else, in id order" do
    by_default = with_board(user_fixture())
    opted_in = with_board(user_fixture())
    preference_fixture(opted_in, :weekly_digest, %{in_app: true, email: true})

    owner = user_fixture()
    reader = user_fixture()
    {:ok, _} = owner |> board_fixture() |> Boards.add_user_to_board(reader, :read_only, owner)

    opted_out = with_board(user_fixture())
    preference_fixture(opted_out, :weekly_digest, %{in_app: true, email: false})
    _unconfirmed = with_board(unconfirmed_user_fixture())
    _disabled = user_fixture() |> with_board() |> disable()
    _no_boards = user_fixture()

    assert Notifications.list_digest_recipients() ==
             Enum.sort([by_default.id, opted_in.id, owner.id, reader.id])
  end

  test "a preference for another event type does not opt a user out" do
    user = with_board(user_fixture())
    preference_fixture(user, :task_assigned, %{in_app: true, email: false})

    assert DigestRecipients.list_digest_recipients() == [user.id]
  end

  describe "get_digest_recipient/1" do
    test "returns the user while they qualify" do
      user = with_board(user_fixture())

      assert %User{id: id} = DigestRecipients.get_digest_recipient(user.id)
      assert id == user.id
    end

    test "returns nil once they no longer qualify" do
      opted_out = with_board(user_fixture())
      Notifications.unsubscribe(opted_out.id, :weekly_digest)
      disabled = user_fixture() |> with_board() |> disable()

      assert DigestRecipients.get_digest_recipient(opted_out.id) == nil
      assert DigestRecipients.get_digest_recipient(disabled.id) == nil
      assert DigestRecipients.get_digest_recipient(user_fixture().id) == nil
      assert DigestRecipients.get_digest_recipient(-1) == nil
    end
  end
end
