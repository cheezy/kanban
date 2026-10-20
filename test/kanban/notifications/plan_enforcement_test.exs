defmodule Kanban.Notifications.PlanEnforcementTest do
  @moduledoc """
  Notifications while paid plans are enforced: nothing is generated or sent
  for free boards or for users without paid access, and account emails stay
  available to everyone.
  """
  # async: false - these tests switch the global :plans_enforced application
  # env on through Kanban.PlansHelpers.
  use Kanban.DataCase, async: false
  use Oban.Testing, repo: Kanban.Repo

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.NotificationsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.PlansHelpers
  import Kanban.TargetsFixtures
  import Kanban.TasksFixtures
  import Kanban.TelemetryHelpers
  import Kanban.WorkspacesFixtures
  import Swoosh.TestAssertions

  alias Kanban.Accounts.UserNotifier
  alias Kanban.Boards
  alias Kanban.Boards.Board
  alias Kanban.Boards.BoardUser
  alias Kanban.Columns
  alias Kanban.Notifications
  alias Kanban.Notifications.Digest
  alias Kanban.Notifications.DigestFanoutWorker
  alias Kanban.Notifications.DigestWorker
  alias Kanban.Notifications.EmailWorker
  alias Kanban.Notifications.Events
  alias Kanban.Notifications.Notification
  alias Kanban.Notifications.TargetStatusWorker
  alias Kanban.Targets.DeliveryTarget
  alias Kanban.Tasks
  alias Kanban.Tasks.Task

  @created [:kanban, :notification, :created]
  @skipped [:kanban, :notification, :email_skipped]

  # Monday of ISO week 2026-W45; the digest window is 2026-10-26 to 2026-11-02.
  @now ~U[2026-11-02 13:00:00Z]

  defp board_with_member do
    owner = user_fixture()
    member = user_fixture()
    board = board_fixture(owner)
    {:ok, _} = Boards.add_user_to_board(board, member, :modify, owner)
    Repo.delete_all(Notification)
    %{owner: owner, member: member, board: board}
  end

  # Moves the board into a new Organization's workspace and adds `members` to
  # that Organization, which gives them paid access.
  defp make_paid(%Board{id: id} = board, members \\ []) do
    organization = organization_fixture()
    workspace = org_workspace_fixture(organization)

    {1, _} =
      Board |> where([b], b.id == ^id) |> Repo.update_all(set: [workspace_id: workspace.id])

    Enum.each(members, &organization_member_fixture(organization, &1))
    board
  end

  defp make_free(%Board{id: id} = board, owner) do
    workspace = personal_workspace_fixture(owner)

    {1, _} =
      Board |> where([b], b.id == ^id) |> Repo.update_all(set: [workspace_id: workspace.id])

    board
  end

  defp review_requested(board, recipients) do
    Notifications.notify(:review_requested, recipients, %{
      title: "W1 is ready for review",
      url_path: "/review",
      board_id: board.id
    })
  end

  defp rows, do: Notification |> order_by(:id) |> Repo.all()

  # user_fixture/1 sends an account-confirmation email to the test process.
  defp flush_emails do
    receive do
      {:email, _email} -> flush_emails()
    after
      0 -> :ok
    end
  end

  defp run_email_job(notification) do
    flush_emails()
    perform_job(EmailWorker, %{notification_id: notification.id})
  end

  describe "notify/3 with enforcement on" do
    setup :enforce_plans

    test "a free board's event inserts no row, enqueues no email and returns {:ok, []}" do
      %{owner: owner, member: member, board: board} = board_with_member()
      attach_telemetry(@created)

      assert {:ok, []} = review_requested(board, [owner, member])

      assert rows() == []
      refute_enqueued(worker: EmailWorker)
      refute_received {:telemetry_event, @created, _, _}
    end

    test "a free board's event is dropped whether board_id is an integer or a string" do
      %{member: member, board: board} = board_with_member()

      assert {:ok, []} =
               Notifications.notify(:review_requested, [member], %{
                 "title" => "Review",
                 "board_id" => Integer.to_string(board.id)
               })

      assert rows() == []
    end

    test "a paid board's event is delivered as before to a member with paid access" do
      %{member: member, board: board} = board_with_member()
      make_paid(board, [member])

      assert {:ok, [%Notification{user_id: user_id, board_id: board_id} = row]} =
               review_requested(board, [member])

      assert user_id == member.id
      assert board_id == board.id
      assert_enqueued(worker: EmailWorker, args: %{notification_id: row.id})
    end

    test "a free member of a paid board gets the row but no email job" do
      %{owner: owner, member: free_member, board: board} = board_with_member()
      make_paid(board, [owner])

      assert {:ok, rows} = review_requested(board, [owner, free_member])
      by_user = Map.new(rows, &{&1.user_id, &1})

      assert Map.keys(by_user) |> Enum.sort() == Enum.sort([owner.id, free_member.id])
      assert_enqueued(worker: EmailWorker, args: %{notification_id: by_user[owner.id].id})
      refute_enqueued(worker: EmailWorker, args: %{notification_id: by_user[free_member.id].id})
    end

    test "an invalid event type is still refused before the plan is checked" do
      %{member: member, board: board} = board_with_member()

      assert {:error, :invalid_event_type} =
               Notifications.notify(:bogus, [member], %{title: "x", board_id: board.id})
    end

    test "a board-less event is not gated by notify/3" do
      user = user_fixture()

      assert %Notification{board_id: nil} = notification_fixture(user)
    end
  end

  describe "notify/3 with enforcement off" do
    test "a free board's event is delivered unchanged" do
      %{member: member, board: board} = board_with_member()

      assert {:ok, [%Notification{} = row]} = review_requested(board, [member])
      assert_enqueued(worker: EmailWorker, args: %{notification_id: row.id})
    end
  end

  describe "Events.board_access_changed/4 with enforcement on" do
    setup :enforce_plans

    setup do
      owner = user_fixture()
      editor = user_fixture()
      board = board_fixture(owner)
      # A member, so only the plan gate can stop an add or an access change.
      {:ok, _} = Boards.add_user_to_board(board, editor, :modify, owner)
      Repo.delete_all(Notification)
      %{owner: owner, editor: editor, board: board}
    end

    test "produces nothing for any change on a free board", ctx do
      for change <- [:added, :access_changed, :removed] do
        assert :ok =
                 Events.board_access_changed(ctx.board, ctx.editor, change,
                   actor: ctx.owner,
                   access: :modify
                 )
      end

      assert rows() == []
    end

    test "notifies an add and a removal on a paid board", ctx do
      make_paid(ctx.board)

      assert :ok =
               Events.board_access_changed(ctx.board, ctx.editor, :added,
                 actor: ctx.owner,
                 access: :modify
               )

      assert :ok = Events.board_access_changed(ctx.board, ctx.editor, :removed, actor: ctx.owner)

      assert [%Notification{board_id: board_id}, %Notification{board_id: nil}] = rows()
      assert board_id == ctx.board.id
    end

    test "reads the board's plan fresh rather than from a stale preloaded workspace", ctx do
      make_paid(ctx.board)
      board = Board |> Repo.get!(ctx.board.id) |> Repo.preload(:workspace)
      refute is_nil(board.workspace.organization_id)
      make_free(board, ctx.owner)

      # A removal carries no board_id, so only this check can stop it.
      assert :ok = Events.board_access_changed(board, ctx.editor, :removed, actor: ctx.owner)

      assert rows() == []
    end
  end

  describe "EmailWorker with enforcement switched on after the job was queued" do
    test "skips a free board's notification with :plan_locked and sends nothing" do
      %{member: member, board: board} = board_with_member()
      {:ok, [notification]} = review_requested(board, [member])
      assert_enqueued(worker: EmailWorker, args: %{notification_id: notification.id})

      enforce_plans()
      attach_telemetry(@skipped)

      assert :ok = run_email_job(notification)

      refute_email_sent()
      id = notification.id

      assert_receive {:telemetry_event, @skipped, %{count: 1},
                      %{notification_id: ^id, reason: :plan_locked}}

      assert Repo.get!(Notification, id).emailed_at == nil
    end

    test "skips a board-less notification for a user without paid access" do
      user = user_fixture()
      notification = notification_fixture(user)

      enforce_plans()
      attach_telemetry(@skipped)

      assert :ok = run_email_job(notification)

      refute_email_sent()
      assert_receive {:telemetry_event, @skipped, _, %{reason: :plan_locked}}
    end

    test "delivers a board-less notification for an Organization member" do
      user = user_fixture()
      organization_member_fixture(organization_fixture(), user)
      notification = notification_fixture(user)

      enforce_plans()

      assert :ok = run_email_job(notification)
      assert_email_sent(to: [{"", user.email}])
    end

    test "delivers when the board became paid between generation and send" do
      %{member: member, board: board} = board_with_member()
      {:ok, [notification]} = review_requested(board, [member])

      enforce_plans()
      make_paid(board, [member])

      assert :ok = run_email_job(notification)
      assert Repo.get!(Notification, notification.id).emailed_at
    end

    test "skips a paid board's notification for a free member with :plan_locked" do
      %{member: member, board: board} = board_with_member()
      {:ok, [notification]} = review_requested(board, [member])

      enforce_plans()
      make_paid(board)
      attach_telemetry(@skipped)

      assert :ok = run_email_job(notification)

      refute_email_sent()
      id = notification.id

      assert_receive {:telemetry_event, @skipped, %{count: 1},
                      %{notification_id: ^id, reason: :plan_locked}}

      assert Repo.get!(Notification, id).emailed_at == nil
    end

    test "a deleted board's job finds nothing to send" do
      %{member: member, board: board} = board_with_member()
      {:ok, [notification]} = review_requested(board, [member])

      enforce_plans()
      Repo.delete!(board)
      attach_telemetry(@skipped)

      assert :ok = run_email_job(notification)
      assert_receive {:telemetry_event, @skipped, _, %{reason: :not_found}}
    end
  end

  describe "EmailWorker with enforcement off" do
    test "delivers a free board's notification" do
      %{member: member, board: board} = board_with_member()
      {:ok, [notification]} = review_requested(board, [member])

      assert :ok = run_email_job(notification)
      assert Repo.get!(Notification, notification.id).emailed_at
    end
  end

  describe "weekly digest with enforcement on" do
    setup :enforce_plans

    defp board_with_columns(user) do
      board = ai_optimized_board_fixture(user)
      cols = board |> Columns.list_columns() |> Map.new(&{&1.name, &1})
      %{board: board, cols: cols}
    end

    defp completed(column) do
      task = task_fixture(column)

      Task
      |> where(id: ^task.id)
      |> Repo.update_all(set: [completed_at: ~U[2026-10-30 10:00:00Z]])

      task
    end

    defp pending_review(column) do
      task = task_fixture(column)

      Task
      |> where(id: ^task.id)
      |> Repo.update_all(set: [needs_review: true, review_requested_at: ~U[2026-11-01 10:00:00Z]])

      task
    end

    test "Digest.build lists only paid boards and their pending reviews" do
      user = user_fixture()
      free = board_with_columns(user)
      paid = board_with_columns(user)
      make_paid(paid.board)

      for %{cols: cols} <- [free, paid] do
        completed(cols["Done"])
        pending_review(cols["Review"])
      end

      assert %{boards: [row], tasks_done: 1, reviews: reviews} = Digest.build(user, now: @now)
      assert row.id == paid.board.id
      assert reviews.count == 1
      assert [%{board_id: board_id}] = reviews.oldest
      assert board_id == paid.board.id
    end

    test "Digest.build is :empty when only free boards had activity" do
      user = user_fixture()
      free = board_with_columns(user)
      completed(free.cols["Done"])
      pending_review(free.cols["Review"])

      quiet_paid = board_with_columns(user)
      make_paid(quiet_paid.board)

      assert Digest.build(user, now: @now) == :empty
    end

    test "the fan-out enqueues only users with paid access who belong to a paid board" do
      free_user = user_fixture()
      board_fixture(free_user)
      paid_user = user_fixture()
      paid_board = paid_user |> board_fixture() |> make_paid([paid_user])
      # A free member of a paid board gets no digest either. Boards no longer
      # take members from outside their Organization, but a row from an older
      # add or a board move can still be there, so it is inserted directly.
      free_member = user_fixture()

      Repo.insert!(%BoardUser{
        board_id: paid_board.id,
        user_id: free_member.id,
        access: :modify
      })

      assert :ok = perform_job(DigestFanoutWorker, %{now: DateTime.to_iso8601(@now)})

      assert [paid_id] =
               [worker: DigestWorker] |> all_enqueued() |> Enum.map(& &1.args["user_id"])

      assert paid_id == paid_user.id
      assert Notifications.list_digest_recipients() == [paid_user.id]
    end

    test "a digest job for a user with no paid board sends nothing" do
      user = user_fixture()
      %{cols: cols} = board_with_columns(user)
      completed(cols["Done"])
      flush_emails()

      assert :ok =
               perform_job(DigestWorker, %{
                 user_id: user.id,
                 week: "2026-W45",
                 now: DateTime.to_iso8601(@now)
               })

      refute_email_sent()
      assert Notification |> where(event_type: :weekly_digest) |> Repo.all() == []
    end

    test "a digest job for a free member of a paid board sends nothing" do
      user = user_fixture()
      %{board: board, cols: cols} = board_with_columns(user)
      make_paid(board)
      completed(cols["Done"])
      flush_emails()

      assert :ok =
               perform_job(DigestWorker, %{
                 user_id: user.id,
                 week: "2026-W45",
                 now: DateTime.to_iso8601(@now)
               })

      refute_email_sent()
    end

    test "a digest job for a user with paid activity sends the digest" do
      user = user_fixture()
      %{board: board, cols: cols} = board_with_columns(user)
      make_paid(board, [user])
      completed(cols["Done"])
      flush_emails()

      assert :ok =
               perform_job(DigestWorker, %{
                 user_id: user.id,
                 week: "2026-W45",
                 now: DateTime.to_iso8601(@now)
               })

      assert_email_sent(to: [{"", user.email}])
    end
  end

  describe "target status sweep with enforcement on" do
    setup :enforce_plans

    @target_date ~D[2026-07-21]
    @at_risk_now ~U[2026-06-09 00:17:00Z]

    defp at_risk_target(owner) do
      board = board_fixture(owner)
      doing = column_fixture(board, %{name: "Doing"})
      target = delivery_target_fixture(owner, %{name: "Q3 launch", target_date: @target_date})

      DeliveryTarget
      |> where(id: ^target.id)
      |> Repo.update_all(set: [inserted_at: ~N[2026-06-01 00:00:00]])

      goal = task_fixture(doing, %{type: :goal})
      {:ok, goal} = Tasks.update_task(goal, %{target_id: target.id})
      task_fixture(doing, %{parent_id: goal.id})
      target
    end

    defp sweep, do: perform_job(TargetStatusWorker, %{"now" => DateTime.to_iso8601(@at_risk_now)})

    defp status_rows,
      do: Notification |> where(event_type: :target_status_changed) |> Repo.all()

    test "skips an owner without paid access and leaves the watermark unset" do
      owner = user_fixture()
      target = at_risk_target(owner)

      assert :ok = sweep()

      assert status_rows() == []
      assert Repo.get!(DeliveryTarget, target.id).last_notified_status == nil
    end

    test "notifies an owner who joined an Organization after an earlier skipped sweep" do
      owner = user_fixture()
      target = at_risk_target(owner)
      assert :ok = sweep()
      assert status_rows() == []

      organization_member_fixture(organization_fixture(), owner)
      assert :ok = sweep()

      assert [%Notification{user_id: user_id}] = status_rows()
      assert user_id == owner.id
      assert Repo.get!(DeliveryTarget, target.id).last_notified_status == "at_risk"
    end
  end

  describe "account emails with enforcement on" do
    setup :enforce_plans

    test "confirmation, password reset and email-change emails still send to a free user" do
      user = user_fixture()
      flush_emails()

      assert {:ok, _} =
               UserNotifier.deliver_confirmation_instructions(user, "https://example.test/c")

      assert_email_sent(to: [{"", user.email}])

      assert {:ok, _} =
               UserNotifier.deliver_reset_password_instructions(user, "https://example.test/r")

      assert_email_sent(to: [{"", user.email}])

      assert {:ok, _} =
               UserNotifier.deliver_update_email_instructions(user, "https://example.test/u")

      assert_email_sent(to: [{"", user.email}])
    end
  end
end
