defmodule Kanban.Notifications.DeliveryTest do
  @moduledoc """
  Direct tests of `Kanban.Notifications.Delivery.notify/3`;
  `Kanban.Notifications.notify/3` delegates here.
  """
  # async: false - the plan test switches the global :plans_enforced
  # application env on through Kanban.PlansHelpers.
  use Kanban.DataCase, async: false
  use Oban.Testing, repo: Kanban.Repo

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.DevicesFixtures
  import Kanban.PlansHelpers
  import Kanban.TasksFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.Boards
  alias Kanban.Notifications
  alias Kanban.Notifications.Broadcaster
  alias Kanban.Notifications.Delivery
  alias Kanban.Notifications.EmailWorker
  alias Kanban.Notifications.Notification
  alias Kanban.Notifications.Preferences
  alias Kanban.Push.PushWorker

  setup do
    owner = user_fixture()
    member = user_fixture()
    board = board_fixture(owner)
    {:ok, _} = Boards.add_user_to_board(board, member, :modify, owner)
    # Drop the member's "added to board" notice and its email job.
    Repo.delete_all(Notification)
    Repo.delete_all(Oban.Job)
    %{owner: owner, member: member, board: board}
  end

  defp attrs(ctx, extra \\ %{}),
    do: Map.merge(%{title: "W1: Review", board_id: ctx.board.id}, extra)

  defp set_preference!(user, type, attrs) do
    {:ok, _} = user |> Scope.for_user() |> Preferences.update_preference(type, attrs)
  end

  defp email_job_ids,
    do: all_enqueued(worker: EmailWorker) |> Enum.map(& &1.args["notification_id"]) |> Enum.sort()

  describe "notify/3" do
    test "inserts one row per board member, skipping nil, duplicates and non-members", ctx do
      outsider = user_fixture()

      assert {:ok, inserted} =
               Delivery.notify(
                 :review_requested,
                 [ctx.owner, nil, ctx.member, ctx.owner, outsider],
                 attrs(ctx)
               )

      assert inserted |> Enum.map(& &1.user_id) |> Enum.sort() ==
               Enum.sort([ctx.owner.id, ctx.member.id])

      assert Enum.all?(inserted, &(&1.event_type == :review_requested and &1.in_app))
      assert Repo.aggregate(Notification, :count) == 2
    end

    test "broadcasts each in-app row and enqueues email for email-on recipients", ctx do
      set_preference!(ctx.member, :review_requested, %{email: false})
      Broadcaster.subscribe(ctx.owner)
      Broadcaster.subscribe(ctx.member)

      {:ok, inserted} = Delivery.notify("review_requested", [ctx.owner, ctx.member], attrs(ctx))
      by_user = Map.new(inserted, &{&1.user_id, &1})

      assert_receive {:notification_created, %Notification{user_id: id1}}
      assert_receive {:notification_created, %Notification{user_id: id2}}
      assert Enum.sort([id1, id2]) == Enum.sort([ctx.owner.id, ctx.member.id])

      assert email_job_ids() == [by_user[ctx.owner.id].id]
    end

    test "an email-only recipient gets a hidden, unbroadcast, emailed row", ctx do
      set_preference!(ctx.member, :review_requested, %{in_app: false})
      Broadcaster.subscribe(ctx.member)

      assert {:ok, [row]} = Delivery.notify(:review_requested, [ctx.member], attrs(ctx))

      refute row.in_app
      refute_receive {:notification_created, _}
      assert email_job_ids() == [row.id]
    end

    test "a push-only recipient gets a row only when a push can reach them", ctx do
      set_preference!(ctx.member, :claim_expired, %{in_app: false, email: false})

      assert {:ok, []} = Delivery.notify(:claim_expired, [ctx.member], attrs(ctx))

      device_fixture(Scope.for_user(ctx.member), %{push_token: "tok-delivery"})

      assert {:ok, [hidden]} =
               Delivery.notify(:claim_expired, [ctx.member], attrs(ctx, %{dedupe_key: "c1"}))

      refute hidden.in_app
      assert_enqueued(worker: PushWorker, args: %{notification_id: hidden.id})
      refute_enqueued(worker: EmailWorker)
    end

    test "the same dedupe_key inserts once per recipient", ctx do
      first = Delivery.notify(:review_requested, [ctx.member], attrs(ctx, %{dedupe_key: "k"}))
      assert {:ok, [_]} = first

      Broadcaster.subscribe(ctx.member)

      assert {:ok, []} =
               Delivery.notify(:review_requested, [ctx.member], attrs(ctx, %{dedupe_key: "k"}))

      refute_receive {:notification_created, _}
      assert Repo.aggregate(Notification, :count) == 1
    end

    test "rejects an unknown event type", ctx do
      assert Delivery.notify(:bogus, [ctx.member], attrs(ctx)) == {:error, :invalid_event_type}
      assert Delivery.notify("bogus", [ctx.member], attrs(ctx)) == {:error, :invalid_event_type}
      assert Repo.aggregate(Notification, :count) == 0
    end

    test "rejects a task that is not on the board, inserting nothing", ctx do
      other_board = board_fixture(ctx.owner)
      task = task_fixture(column_fixture(other_board))

      assert {:error, %Ecto.Changeset{action: :insert} = changeset} =
               Delivery.notify(:review_requested, [ctx.member], attrs(ctx, %{task_id: task.id}))

      assert {"does not belong to the board", _} = changeset.errors[:task_id]
      assert Repo.aggregate(Notification, :count) == 0
    end

    test "applies the board rules to string keys and string ids", ctx do
      task = task_fixture(column_fixture(ctx.board))
      foreign_task = task_fixture(column_fixture(board_fixture(ctx.owner)))
      outsider = user_fixture()

      string_attrs = fn task_id ->
        %{
          "title" => "W1: Review",
          "board_id" => Integer.to_string(ctx.board.id),
          "task_id" => Integer.to_string(task_id)
        }
      end

      # The board's members only, and the task must be on the board.
      assert {:ok, [row]} =
               Delivery.notify(:review_requested, [ctx.member, outsider], string_attrs.(task.id))

      assert {row.user_id, row.board_id, row.task_id} == {ctx.member.id, ctx.board.id, task.id}

      assert {:error, %Ecto.Changeset{}} =
               Delivery.notify(:review_requested, [ctx.member], string_attrs.(foreign_task.id))
    end

    test "invalid attributes insert nothing for anyone", ctx do
      assert {:error, %Ecto.Changeset{}} =
               Delivery.notify(:review_requested, [ctx.owner, ctx.member], %{
                 board_id: ctx.board.id
               })

      assert Repo.aggregate(Notification, :count) == 0
      refute_enqueued(worker: EmailWorker)
    end

    test "drops every event on a free board while plans are enforced", ctx do
      enforce_plans()
      Broadcaster.subscribe(ctx.member)

      assert Delivery.notify(:review_requested, [ctx.owner, ctx.member], attrs(ctx)) == {:ok, []}

      assert Repo.aggregate(Notification, :count) == 0
      refute_receive {:notification_created, _}
      refute_enqueued(worker: EmailWorker)
    end

    test "is what Kanban.Notifications.notify/3 runs", ctx do
      assert {:ok, [row]} = Notifications.notify(:review_requested, [ctx.member], attrs(ctx))
      assert Repo.get!(Notification, row.id).user_id == ctx.member.id
    end
  end
end
