defmodule Kanban.Notifications.DigestTest do
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Boards
  alias Kanban.Columns
  alias Kanban.Notifications.Digest
  alias Kanban.Tasks.Task

  # Monday of ISO week 2026-W45; the window is the previous ISO week,
  # 2026-10-26 00:00 to 2026-11-02 00:00 UTC.
  @now ~U[2026-11-02 13:00:00Z]

  defp board_with_columns(user, attrs \\ %{}) do
    board = ai_optimized_board_fixture(user, attrs)
    cols = board |> Columns.list_columns() |> Map.new(&{&1.name, &1})
    %{board: board, cols: cols}
  end

  defp completed(column, at, attrs \\ %{}) do
    task = task_fixture(column, attrs)
    Task |> where(id: ^task.id) |> Repo.update_all(set: [completed_at: at])
    task
  end

  defp pending_review(column, hours_ago, attrs \\ %{}) do
    task = task_fixture(column, attrs)

    updated_at =
      @now
      |> DateTime.add(-hours_ago, :hour)
      |> DateTime.to_naive()

    Task
    |> where(id: ^task.id)
    |> Repo.update_all(
      set: [
        needs_review: true,
        updated_at: updated_at,
        review_requested_at: DateTime.from_naive!(updated_at, "Etc/UTC")
      ]
    )

    task
  end

  defp build(user), do: Digest.build(user, now: @now)

  describe "build/2 returns :empty" do
    test "for a user with no boards" do
      assert build(user_fixture()) == :empty
      assert Digest.build(user_fixture()) == :empty
    end

    test "when nothing was done and nothing is waiting for review" do
      user = user_fixture()
      %{cols: cols} = board_with_columns(user)
      task_fixture(cols["Ready"])
      task_fixture(cols["Doing"])
      completed(cols["Done"], ~U[2026-10-20 10:00:00Z])

      assert build(user) == :empty
    end
  end

  describe "build/2" do
    setup do
      user = user_fixture()
      %{user: user} |> Map.merge(board_with_columns(user, %{name: "Main board"}))
    end

    test "counts tasks completed in the previous full ISO week", ctx do
      completed(ctx.cols["Done"], ~U[2026-10-26 00:00:00Z])
      completed(ctx.cols["Done"], ~U[2026-11-01 23:59:59Z])
      completed(ctx.cols["Done"], ~U[2026-10-25 23:59:59Z])
      completed(ctx.cols["Done"], ~U[2026-11-02 00:00:00Z])

      assert %{window_start: ~D[2026-10-26], window_end: ~D[2026-11-01], tasks_done: 2} =
               build(ctx.user)
    end

    test "consecutive weekly digests count a Monday-afternoon completion once", ctx do
      completed(ctx.cols["Done"], ~U[2026-10-26 18:00:00Z])

      assert Digest.build(ctx.user, now: ~U[2026-10-26 13:00:00Z]) == :empty
      assert %{tasks_done: 1} = Digest.build(ctx.user, now: @now)
      assert Digest.build(ctx.user, now: ~U[2026-11-09 13:00:00Z]) == :empty
    end

    test "counts goals separately and ignores tasks still in Review", ctx do
      completed(ctx.cols["Done"], ~U[2026-10-30 10:00:00Z])
      completed(ctx.cols["Done"], ~U[2026-10-30 10:00:00Z], %{type: :defect})
      completed(ctx.cols["Done"], ~U[2026-10-30 10:00:00Z], %{type: :goal})
      completed(ctx.cols["Review"], ~U[2026-10-30 10:00:00Z])

      digest = build(ctx.user)

      assert %{tasks_done: 2, goals_completed: 1} = digest
      assert [%{name: "Main board", done_this_week: 2, goals_completed: 1}] = digest.boards
    end

    test "reports open, doing and review counts per board", ctx do
      task_fixture(ctx.cols["Backlog"])
      task_fixture(ctx.cols["Ready"])
      task_fixture(ctx.cols["Doing"])
      completed(ctx.cols["Review"], ~U[2026-10-30 10:00:00Z])
      completed(ctx.cols["Done"], ~U[2026-10-30 10:00:00Z])

      assert %{boards: [row]} = build(ctx.user)
      assert %{id: id, open: 2, doing: 1, review: 1, done_this_week: 1} = row
      assert id == ctx.board.id
    end

    test "lists pending reviews oldest first, five at most", ctx do
      for hours <- [3, 50, 10, 200, 1, 26, 7] do
        pending_review(ctx.cols["Review"], hours, %{title: "Waiting #{hours}h"})
      end

      assert %{reviews: reviews, tasks_done: 0} = build(ctx.user)
      assert reviews.count == 7
      assert reviews.oldest_age_hours == 200
      assert Enum.map(reviews.oldest, & &1.age_hours) == [200, 50, 26, 10, 7]

      assert [
               %{title: "Waiting 200h", board_name: "Main board", identifier: "W" <> _} = first
               | _
             ] =
               reviews.oldest

      assert first.board_id == ctx.board.id
    end

    test "ages a review from when it entered Review, not from a later edit", ctx do
      task = pending_review(ctx.cols["Review"], 1)

      Task
      |> where(id: ^task.id)
      |> Repo.update_all(set: [review_requested_at: DateTime.add(@now, -72, :hour)])

      assert %{reviews: %{oldest_age_hours: 72, oldest: [%{age_hours: 72}]}} = build(ctx.user)
    end

    test "never includes another user's boards or reviews", ctx do
      completed(ctx.cols["Done"], ~U[2026-10-30 10:00:00Z])

      other = user_fixture()
      %{cols: other_cols} = board_with_columns(other, %{name: "Secret"})
      completed(other_cols["Done"], ~U[2026-10-30 10:00:00Z])
      pending_review(other_cols["Review"], 5)

      digest = build(ctx.user)

      assert Enum.map(digest.boards, & &1.name) == ["Main board"]
      assert digest.tasks_done == 1
      assert digest.reviews.count == 0
      assert digest.reviews.oldest_age_hours == nil
    end

    test "includes boards the user can only read", ctx do
      owner = user_fixture()
      %{board: shared, cols: shared_cols} = board_with_columns(owner, %{name: "Shared"})
      {:ok, _} = Boards.add_user_to_board(shared, ctx.user, :read_only, owner)
      pending_review(shared_cols["Review"], 4)

      digest = build(ctx.user)

      assert digest.reviews.count == 1
      assert "Shared" in Enum.map(digest.boards, & &1.name)
    end

    test "shows the ten busiest boards and counts the rest", ctx do
      for n <- 1..11 do
        %{cols: cols} = board_with_columns(ctx.user, %{name: "Board #{n}"})
        for _ <- 1..n, do: completed(cols["Done"], ~U[2026-10-30 10:00:00Z])
      end

      digest = build(ctx.user)

      assert length(digest.boards) == 10
      assert digest.more_boards == 2
      assert hd(digest.boards).name == "Board 11"
      assert digest.tasks_done == Enum.sum(1..11)
    end
  end

  describe "iso_week/1" do
    test "formats the ISO week with its week-numbering year" do
      assert Digest.iso_week(@now) == "2026-W45"
      assert Digest.iso_week(~U[2027-01-01 13:00:00Z]) == "2026-W53"
      assert Digest.iso_week(~U[2026-01-05 13:00:00Z]) == "2026-W02"
    end
  end

  describe "parse_now/1" do
    test "reads an ISO 8601 now argument, truncated to the second" do
      assert Digest.parse_now(%{"now" => "2026-11-02T13:00:00.123Z"}) == @now
    end

    test "falls back to the current time when missing or invalid" do
      for args <- [%{}, %{"now" => "not-a-time"}, %{"now" => 5}] do
        assert DateTime.diff(DateTime.utc_now(), Digest.parse_now(args)) in 0..5
      end
    end
  end
end
