defmodule Kanban.Push.PushWorkerTest do
  @moduledoc """
  Tests for `Kanban.Push.PushWorker`: enqueueing from `notify/3`, the §7.8
  send-time checks, dead tokens and the push telemetry. Pushes only ever
  reach the `Kanban.Push.APNsMock` and `Kanban.Push.FCMMock` doubles.
  """
  # async: false - the lost-plan test switches the global :plans_enforced
  # application env on through Kanban.PlansHelpers.
  use Kanban.DataCase, async: false
  use Oban.Testing, repo: Kanban.Repo

  import Mox
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.DevicesFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.PlansHelpers
  import Kanban.TasksFixtures
  import Kanban.TelemetryHelpers

  alias Kanban.Accounts.Scope
  alias Kanban.Columns
  alias Kanban.Decisions
  alias Kanban.Devices
  alias Kanban.Devices.Device
  alias Kanban.Notifications
  alias Kanban.Organizations.SecurityPolicies
  alias Kanban.Push.APNsMock
  alias Kanban.Push.FCMMock
  alias Kanban.Push.PushWorker
  alias Kanban.Tasks

  @sent [:kanban, :push, :sent]
  @failed [:kanban, :push, :failed]
  @held [:kanban, :push, :held]

  setup :verify_on_exit!

  setup do
    owner = user_fixture()
    board = ai_optimized_board_fixture(owner)
    cols = board |> Columns.list_columns() |> Map.new(&{&1.name, &1})
    attach_telemetry([@sent, @failed, @held])
    %{owner: owner, board: board, cols: cols, scope: Scope.for_user(owner)}
  end

  defp pending_review!(ctx) do
    attrs = %{
      needs_review: true,
      completed_at: DateTime.truncate(DateTime.utc_now(), :second),
      completed_by_agent: "Claude"
    }

    {:ok, task} = ctx.cols["Review"] |> task_fixture() |> Tasks.update_task(attrs)
    task
  end

  defp ios_device!(ctx, attrs \\ %{}) do
    device_fixture(
      ctx.scope,
      Map.merge(%{push_token: "ios-#{System.unique_integer([:positive])}"}, attrs)
    )
  end

  defp android_device!(ctx, attrs \\ %{}) do
    device_fixture(
      ctx.scope,
      Map.merge(
        %{
          client_id: "stride-android",
          platform: :android,
          name: "Test Pixel",
          push_token: "android-#{System.unique_integer([:positive])}"
        },
        attrs
      )
    )
  end

  defp notify_review!(ctx, task) do
    {:ok, notifications} =
      Notifications.notify(:review_requested, [ctx.owner], %{
        title: "#{task.identifier}: #{task.title}",
        url_path: "/review",
        board_id: ctx.board.id,
        task_id: task.id,
        dedupe_key: "push-test:#{System.unique_integer([:positive])}"
      })

    Enum.find(notifications, &(&1.user_id == ctx.owner.id))
  end

  defp switch(ctx, event, on) do
    {:ok, _view} =
      Notifications.update_push_settings(
        ctx.scope,
        %{"switches" => %{Atom.to_string(event) => on}},
        via: :web,
        feature: :notifications
      )
  end

  defp perform(notification), do: perform_job(PushWorker, %{notification_id: notification.id})

  describe "enqueue" do
    test "enqueues a job on the :push queue for an eligible recipient", ctx do
      ios_device!(ctx)
      task = pending_review!(ctx)
      n = notify_review!(ctx, task)

      assert_enqueued(worker: PushWorker, queue: :push, args: %{notification_id: n.id})
    end

    test "a rolled-back notify enqueues no push", ctx do
      ios_device!(ctx)
      task = pending_review!(ctx)
      Repo.delete_all(Oban.Job)

      assert {:error, :boom} =
               Repo.transaction(fn ->
                 notify_review!(ctx, task)
                 assert_enqueued(worker: PushWorker)
                 Repo.rollback(:boom)
               end)

      refute_enqueued(worker: PushWorker)
    end
  end

  describe "perform/1" do
    test "sends to every active device and emits sent", ctx do
      ios = ios_device!(ctx, %{locale: "ja-JP"})
      android = android_device!(ctx, %{locale: "en-US"})
      task = pending_review!(ctx)
      n = notify_review!(ctx, task)
      test_pid = self()

      expect(APNsMock, :send, fn %Device{id: id}, payload ->
        send(test_pid, {:ios, id, payload})
        :ok
      end)

      expect(FCMMock, :send, fn %Device{id: id}, payload ->
        send(test_pid, {:android, id, payload})
        :ok
      end)

      assert :ok = perform(n)

      assert_received {:ios, ios_id, ios_payload}
      assert ios_id == ios.id
      assert ios_payload.title == "#{task.identifier} のレビュー準備ができました"
      assert ios_payload.collapse_id == "review:task:#{task.id}"
      assert ios_payload.badge == 1
      assert ios_payload.data.route == "review"

      assert_received {:android, android_id, android_payload}
      assert android_id == android.id
      assert android_payload.title == "#{task.identifier} is ready for review"
      assert android_payload.body =~ task.title

      assert_received {:telemetry_event, @sent, %{count: 1},
                       %{platform: :ios, event_type: :review_requested}}

      assert_received {:telemetry_event, @sent, %{count: 1},
                       %{platform: :android, event_type: :review_requested}}
    end

    test "a review approved before delivery is held as resolved", ctx do
      ios_device!(ctx)
      task = pending_review!(ctx)
      n = notify_review!(ctx, task)

      task |> Ecto.Changeset.change(review_status: :approved) |> Repo.update!()

      assert :ok = perform(n)

      assert_received {:telemetry_event, @held, %{count: 1},
                       %{event_type: :review_requested, reason: :resolved}}

      refute_received {:telemetry_event, @sent, _, _}
    end

    test "a push-only released decision is sent while open and held once resolved", ctx do
      ios_device!(ctx)
      task = task_fixture(ctx.cols["Ready"])

      {:ok, _} =
        Notifications.update_preference(ctx.scope, :task_unclaimed, %{in_app: false, email: false})

      {:ok, [n]} =
        Notifications.notify(:task_unclaimed, [ctx.owner], %{
          title: "#{task.identifier}: #{task.title}",
          board_id: ctx.board.id,
          task_id: task.id
        })

      refute n.in_app
      expect(APNsMock, :send, fn _device, _payload -> :ok end)

      assert :ok = perform(n)
      assert_received {:telemetry_event, @sent, _, %{event_type: :task_unclaimed}}

      task |> Ecto.Changeset.change(column_id: ctx.cols["Doing"].id) |> Repo.update!()

      assert :ok = perform(n)

      assert_received {:telemetry_event, @held, _,
                       %{event_type: :task_unclaimed, reason: :resolved}}
    end

    test "a push-only expired claim is sent", ctx do
      ios_device!(ctx)
      now = DateTime.truncate(DateTime.utc_now(), :second)

      task =
        ctx.cols["Doing"]
        |> task_fixture()
        |> Ecto.Changeset.change(%{
          status: :in_progress,
          assigned_to_id: ctx.owner.id,
          claimed_at: DateTime.add(now, -7200),
          claim_expires_at: DateTime.add(now, -3600)
        })
        |> Repo.update!()

      {:ok, _} =
        Notifications.update_preference(ctx.scope, :claim_expired, %{in_app: false, email: false})

      {:ok, [n]} =
        Notifications.notify(:claim_expired, [ctx.owner], %{
          title: "#{task.identifier}: #{task.title}",
          board_id: ctx.board.id,
          task_id: task.id
        })

      refute n.in_app
      expect(APNsMock, :send, fn _device, _payload -> :ok end)

      assert :ok = perform(n)
      assert_received {:telemetry_event, @sent, _, %{event_type: :claim_expired}}
    end

    test "a review ranked below the 100-item cap is still sent", ctx do
      ios_device!(ctx)
      tasks = for _ <- 1..101, do: pending_review!(ctx)
      listed = ctx.scope |> Decisions.build() |> MapSet.new(& &1.id)
      task = Enum.find(tasks, &(not MapSet.member?(listed, "review:task:#{&1.id}")))
      n = notify_review!(ctx, task)
      test_pid = self()

      expect(APNsMock, :send, fn _device, payload ->
        send(test_pid, {:payload, payload})
        :ok
      end)

      assert :ok = perform(n)
      assert_received {:payload, payload}
      assert payload.title == "#{task.identifier} is ready for review"
      assert payload.badge == 101
    end

    test "a push switched off after the enqueue is held as mode", ctx do
      ios_device!(ctx)
      n = notify_review!(ctx, pending_review!(ctx))

      switch(ctx, :review_requested, false)

      assert :ok = perform(n)

      assert_received {:telemetry_event, @held, %{count: 1},
                       %{event_type: :review_requested, reason: :mode}}
    end

    test "an unregistered token is cleared and failed emitted", ctx do
      device = ios_device!(ctx)
      n = notify_review!(ctx, pending_review!(ctx))

      expect(APNsMock, :send, fn _device, _payload -> :unregistered end)

      assert :ok = perform(n)
      assert Repo.reload!(device).push_token == nil

      assert_received {:telemetry_event, @failed, %{count: 1},
                       %{platform: :ios, event_type: :review_requested, reason: :unregistered}}
    end

    test "a revoked device gets nothing", ctx do
      kept = ios_device!(ctx)
      also_kept = android_device!(ctx)
      revoked = ios_device!(ctx)
      {:ok, revoked} = Devices.revoke_device(ctx.scope, revoked)
      # Revoking clears the token; put one back so only revoked_at keeps it out.
      revoked |> Ecto.Changeset.change(push_token: "left-behind") |> Repo.update!()
      n = notify_review!(ctx, pending_review!(ctx))
      test_pid = self()

      expect(APNsMock, :send, fn %Device{id: id}, _payload ->
        send(test_pid, {:sent_to, id})
        :ok
      end)

      expect(FCMMock, :send, fn %Device{id: id}, _payload ->
        send(test_pid, {:sent_to, id})
        :ok
      end)

      assert :ok = perform(n)

      assert_received {:sent_to, first}
      assert_received {:sent_to, second}
      assert Enum.sort([first, second]) == Enum.sort([kept.id, also_kept.id])
      refute_received {:sent_to, _}
      refute_received {:telemetry_event, @failed, _, _}
    end

    test "a device revoked while the job runs gets nothing", ctx do
      first = ios_device!(ctx)
      second = ios_device!(ctx)
      n = notify_review!(ctx, pending_review!(ctx))
      test_pid = self()

      expect(APNsMock, :send, 1, fn %Device{id: id}, _payload ->
        {:ok, _} = Devices.revoke_device(ctx.scope, Repo.get!(Device, second.id))
        send(test_pid, {:sent_to, id})
        :ok
      end)

      assert :ok = perform(n)
      assert_received {:sent_to, sent_id}
      assert sent_id == first.id
      refute_received {:sent_to, _}
    end

    test "a switched-off push with no device left emits nothing", ctx do
      device = ios_device!(ctx)
      n = notify_review!(ctx, pending_review!(ctx))
      {:ok, _} = Devices.revoke_device(ctx.scope, device)
      switch(ctx, :review_requested, false)

      assert :ok = perform(n)
      refute_received {:telemetry_event, _, _, _}
    end

    test "a lost plan between enqueue and send sends nothing", ctx do
      ios_device!(ctx)
      n = notify_review!(ctx, pending_review!(ctx))
      assert_enqueued(worker: PushWorker, args: %{notification_id: n.id})

      enforce_plans()

      assert :ok = perform(n)
      refute_received {:telemetry_event, @sent, _, _}
      refute_received {:telemetry_event, @held, _, _}
    end

    test "a rate-limited push is retried and other errors are not", ctx do
      ios_device!(ctx)
      n = notify_review!(ctx, pending_review!(ctx))

      expect(APNsMock, :send, fn _device, _payload -> {:error, :rate_limited} end)
      assert {:error, :rate_limited} = perform(n)

      assert_received {:telemetry_event, @failed, _, %{reason: :rate_limited}}

      expect(APNsMock, :send, fn _device, _payload -> {:error, :bad_collapse_id} end)
      assert :ok = perform(n)
      assert_received {:telemetry_event, @failed, _, %{reason: :rejected}}

      expect(APNsMock, :send, fn _device, _payload -> {:error, :service_unavailable} end)
      assert {:error, :unavailable} = perform(n)
    end

    test "hides the title when the Organization's policy says so", ctx do
      org = organization_fixture()
      organization_member_fixture(org, ctx.owner, :org_admin)

      {:ok, _} =
        SecurityPolicies.update_policy(ctx.owner, %{"hide_titles_in_notifications" => "true"})

      ios_device!(ctx)
      task = pending_review!(ctx)
      n = notify_review!(ctx, task)
      test_pid = self()

      expect(APNsMock, :send, fn _device, payload ->
        send(test_pid, {:payload, payload})
        :ok
      end)

      assert :ok = perform(n)
      assert_received {:payload, payload}
      assert payload.title == "#{task.identifier} is ready for review"
      refute (payload.body || "") =~ task.title
    end

    test "pushes a board-less target update collapsed by target id", ctx do
      ios_device!(ctx)
      switch(ctx, :target_status_changed, true)

      {:ok, [n]} =
        Notifications.notify(:target_status_changed, [ctx.owner], %{
          title: "Q4 launch",
          url_path: "/targets/977",
          board_id: nil,
          metadata: %{"status" => "at_risk", "target_date" => "2026-12-01"},
          dedupe_key: "target_status:977:at_risk:1"
        })

      assert_enqueued(worker: PushWorker, args: %{notification_id: n.id})
      test_pid = self()

      expect(APNsMock, :send, fn _device, payload ->
        send(test_pid, {:payload, payload})
        :ok
      end)

      assert :ok = perform(n)
      assert_received {:payload, payload}
      assert payload.collapse_id == "target_status_changed:977"
      assert payload.title == "Q4 launch is at risk"
      assert payload.data.route == "target"
    end

    test "skips a notification that is gone or whose devices were all revoked", ctx do
      device = ios_device!(ctx)
      n = notify_review!(ctx, pending_review!(ctx))
      {:ok, _} = Devices.revoke_device(ctx.scope, device)

      assert :ok = perform(n)
      assert :ok = perform_job(PushWorker, %{notification_id: -1})
      refute_received {:telemetry_event, _, _, _}
    end
  end

  describe "quiet hours" do
    test "a push due inside quiet hours is held, not sent", ctx do
      ios_device!(ctx)
      n = notify_review!(ctx, pending_review!(ctx))
      quiet_around_now!(ctx.owner, "Europe/London")

      assert :ok = perform(n)

      assert_received {:telemetry_event, @held, %{count: 1},
                       %{event_type: :review_requested, reason: :quiet_hours}}

      # Held, never dropped: the notification is still there for Now.
      assert Repo.get(Kanban.Notifications.Notification, n.id)
    end

    test "uses the settings time zone, not the device zone", ctx do
      ios_device!(ctx, %{time_zone: "Asia/Tokyo"})
      n = notify_review!(ctx, pending_review!(ctx))
      # Quiet now in Tokyo, the device's zone, but the settings say London.
      quiet_around_now!(ctx.owner, "Asia/Tokyo", "Europe/London")

      expect(APNsMock, :send, fn _device, _payload -> :ok end)
      assert :ok = perform(n)
      assert_received {:telemetry_event, @sent, %{count: 1}, %{event_type: :review_requested}}

      # Quiet now in London, the settings' zone: held.
      n = notify_review!(ctx, pending_review!(ctx))
      quiet_around_now!(ctx.owner, "Europe/London")

      assert :ok = perform(n)
      assert_received {:telemetry_event, @held, _, %{reason: :quiet_hours}}
    end

    test "disabled quiet hours never hold", ctx do
      ios_device!(ctx)
      n = notify_review!(ctx, pending_review!(ctx))
      quiet_around_now!(ctx.owner, "Europe/London")
      set_quiet!(ctx.owner, quiet_hours_enabled: false)

      expect(APNsMock, :send, fn _device, _payload -> :ok end)
      assert :ok = perform(n)
      assert_received {:telemetry_event, @sent, %{count: 1}, %{event_type: :review_requested}}
    end

    test "a switch turned off wins over quiet hours", ctx do
      ios_device!(ctx)
      n = notify_review!(ctx, pending_review!(ctx))
      switch(ctx, :review_requested, false)
      quiet_around_now!(ctx.owner, "Europe/London")

      assert :ok = perform(n)
      assert_received {:telemetry_event, @held, _, %{reason: :mode}}
    end
  end

  # Quiet hours from an hour ago to an hour from now on the clock in
  # `window_zone`, read in `settings_zone`.
  defp quiet_around_now!(user, window_zone, settings_zone \\ nil) do
    local = DateTime.now!(window_zone)

    clock = fn seconds ->
      local |> DateTime.add(seconds) |> DateTime.to_time() |> Time.truncate(:second)
    end

    set_quiet!(user,
      quiet_hours_enabled: true,
      quiet_start: clock.(-3600),
      quiet_end: clock.(3600),
      time_zone: settings_zone || window_zone
    )
  end

  defp set_quiet!(user, set) do
    {1, _} =
      Kanban.Notifications.PushSettings
      |> where([s], s.user_id == ^user.id)
      |> Repo.update_all(set: set)

    :ok
  end

  describe "failure_reason/1" do
    test "keeps known reasons and bounds the rest" do
      assert PushWorker.failure_reason(:not_configured) == :not_configured
      assert PushWorker.failure_reason(:rate_limited) == :rate_limited
      assert PushWorker.failure_reason(:timeout) == :unavailable
      assert PushWorker.failure_reason(:internal) == :unavailable
      assert PushWorker.failure_reason(:payload_too_large) == :rejected
      assert PushWorker.failure_reason("anything") == :rejected
    end
  end
end
