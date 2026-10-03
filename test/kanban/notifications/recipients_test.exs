defmodule Kanban.Notifications.RecipientsTest do
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.NotificationsFixtures

  alias Kanban.Boards
  alias Kanban.Notifications
  alias Kanban.Notifications.Recipients

  defp default(type), do: Notifications.default_preference(type)

  describe "resolve/4" do
    test "drops nil entries and duplicates and keeps recipient order" do
      u1 = user_fixture()
      u2 = user_fixture()

      assert [%{user_id: id1}, %{user_id: id2}] =
               Recipients.resolve(
                 :board_access_changed,
                 [u2, nil, u1, u2],
                 nil,
                 default(:board_access_changed)
               )

      assert [id1, id2] == [u2.id, u1.id]
    end

    test "applies the default preference when no row is saved" do
      user = user_fixture()

      assert [%{in_app: true, email: true}] =
               Recipients.resolve(:review_requested, [user], nil, default(:review_requested))

      assert [%{in_app: true, email: false}] =
               Recipients.resolve(:goal_completed, [user], nil, default(:goal_completed))
    end

    test "applies saved preferences per channel and drops users with both channels off" do
      email_only = user_fixture()
      muted = user_fixture()
      preference_fixture(email_only, :task_assigned, %{in_app: false, email: true})
      preference_fixture(muted, :task_assigned, %{in_app: false, email: false})

      assert [%{user_id: user_id, in_app: false, email: true}] =
               Recipients.resolve(
                 :task_assigned,
                 [email_only, muted],
                 nil,
                 default(:task_assigned)
               )

      assert user_id == email_only.id
    end

    test "keeps only current members of a named board" do
      owner = user_fixture()
      member = user_fixture()
      outsider = user_fixture()
      board = board_fixture(owner)
      {:ok, _} = Boards.add_user_to_board(board, member, :modify, owner)

      ids =
        :review_requested
        |> Recipients.resolve([owner, outsider, member], board.id, default(:review_requested))
        |> Enum.map(& &1.user_id)

      assert ids == [owner.id, member.id]
    end

    test "returns an empty list for no recipients" do
      assert [] = Recipients.resolve(:task_assigned, [], nil, default(:task_assigned))
      assert [] = Recipients.resolve(:task_assigned, nil, 1, default(:task_assigned))
    end
  end
end
