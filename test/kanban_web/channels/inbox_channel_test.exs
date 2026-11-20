defmodule KanbanWeb.InboxChannelTest do
  @moduledoc """
  Tests for `KanbanWeb.InboxChannel` on `me:inbox` (W2766,
  docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §7.7).
  """
  # async: false - tests switch the global :plans_enforced application env
  # and the coalescer interval on, and the channel process shares the test's
  # sandbox connection.
  use KanbanWeb.ChannelCase, async: false

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.DevicesFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.PlansHelpers
  import Kanban.TasksFixtures
  import Kanban.TelemetryHelpers
  import Kanban.WorkspacesFixtures

  alias Kanban.Boards
  alias Kanban.Columns
  alias Kanban.Decisions
  alias Kanban.Devices
  alias Kanban.Notifications
  alias Kanban.Notifications.Notification
  alias Kanban.Repo
  alias Kanban.Tasks
  alias KanbanWeb.API.Me.DecisionJSON
  alias KanbanWeb.Coalescer
  alias KanbanWeb.InboxChannel
  alias KanbanWeb.SocketToken
  alias KanbanWeb.UserSocket

  @built [:kanban, :decisions, :built]

  setup do
    previous = Application.fetch_env(:kanban, Coalescer)
    Application.put_env(:kanban, Coalescer, interval_ms: 20)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:kanban, Coalescer, value)
        :error -> Application.delete_env(:kanban, Coalescer)
      end
    end)

    user = user_fixture()
    scope = user_scope_fixture(user)
    {device, _issued} = device_with_tokens_fixture(scope, %{device_class: :phone})
    board = ai_optimized_board_fixture(user)

    %{user: user, scope: scope, device: device, board: board, cols: columns(board)}
  end

  defp columns(board), do: board |> Columns.list_columns() |> Map.new(&{&1.name, &1})

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp pending_task!(column) do
    task =
      column
      |> task_fixture()
      |> Ecto.Changeset.change(
        needs_review: true,
        completed_at: now(),
        completed_by_agent: "Claude",
        review_requested_at: DateTime.add(now(), -600)
      )
      |> Repo.update!()

    task
  end

  defp connect!(device) do
    {token, _expires_at} = SocketToken.sign(device)
    {:ok, socket} = connect(UserSocket, %{"token" => token})
    socket
  end

  defp join!(device) do
    {:ok, _reply, socket} = device |> connect!() |> subscribe_and_join(InboxChannel, "me:inbox")
    socket
  end

  defp expected(scope) do
    DecisionJSON.index(%{decisions: Decisions.build_with_summary(scope, device_class: :phone)})
  end

  defp item_ids(%{data: %{items: items}}), do: Enum.map(items, & &1.id)

  # Receives "decisions" pushes until one satisfies `fun`, failing after 1s.
  defp assert_decisions_until(fun) do
    assert_receive %Phoenix.Socket.Message{event: "decisions", payload: payload}, 1_000

    if fun.(payload), do: payload, else: assert_decisions_until(fun)
  end

  defp topics(socket), do: Registry.keys(Kanban.PubSub, socket.channel_pid)

  defp board_topics(socket), do: socket |> topics() |> Enum.filter(&(&1 =~ ~r/^board:/))

  # Waits for the channel process to finish what it is handling.
  defp settle(socket), do: :sys.get_state(socket.channel_pid)

  describe "join" do
    test "join pushes the full decisions list", ctx do
      review = pending_task!(ctx.cols["Review"])
      attach_telemetry(@built, any_process: true)

      join!(ctx.device)

      assert_push "decisions", payload
      assert payload == expected(ctx.scope)
      assert item_ids(payload) == ["review:task:#{review.id}"]
      assert %{data: %{summary: %{waiting: 1}}} = payload
      assert_receive {:telemetry_event, @built, %{count: 1}, %{source: :channel}}
    end

    test "subscribes to the person's notifications and every board they can see", ctx do
      other = ai_optimized_board_fixture(ctx.user)
      stranger_board = ai_optimized_board_fixture(user_fixture())

      socket = join!(ctx.device)
      assert_push "decisions", _payload

      assert Notifications.topic(ctx.user) in topics(socket)

      assert socket |> board_topics() |> Enum.sort() ==
               Enum.sort(["board:#{ctx.board.id}", "board:#{other.id}"])

      refute "board:#{stranger_board.id}" in topics(socket)
    end

    test "join refused without paid access", ctx do
      enforce_plans()
      attach_telemetry([:kanban, :plan, :feature_refused], any_process: true)

      assert {:error, %{reason: "plan_required"}} =
               ctx.device |> connect!() |> subscribe_and_join(InboxChannel, "me:inbox")

      assert_receive {:telemetry_event, [:kanban, :plan, :feature_refused], %{count: 1},
                      %{feature: :mobile_app, surface: :channel}}

      refute_push "decisions", _payload, 50
    end

    test "a device revoked after connecting cannot join", ctx do
      socket = connect!(ctx.device)
      {:ok, _revoked} = Devices.revoke_device(ctx.scope, ctx.device)

      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(socket, InboxChannel, "me:inbox")
    end

    test "boards outside the plan are never subscribed", ctx do
      organization = organization_fixture()
      organization_member_fixture(organization, ctx.user)
      workspace = org_workspace_fixture(organization)

      paid =
        ctx.user
        |> ai_optimized_board_fixture()
        |> Ecto.Changeset.change(workspace_id: workspace.id)
        |> Repo.update!()

      free_review = pending_task!(ctx.cols["Review"])
      paid_review = pending_task!(columns(paid)["Review"])
      enforce_plans()

      socket = join!(ctx.device)

      assert_push "decisions", payload
      assert item_ids(payload) == ["review:task:#{paid_review.id}"]
      refute "review:task:#{free_review.id}" in item_ids(payload)
      assert board_topics(socket) == ["board:#{paid.id}"]
    end
  end

  describe "access after the join" do
    test "a user disabled after joining gets no further push and the channel stops", ctx do
      socket = join!(ctx.device)
      assert_push "decisions", _payload
      ref = Process.monitor(socket.channel_pid)

      ctx.user |> Ecto.Changeset.change(disabled_at: now()) |> Repo.update!()
      send(socket.channel_pid, {Kanban.Tasks, :task_updated, pending_task!(ctx.cols["Review"])})

      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 1_000
      refute_push "decisions", _payload, 50
    end

    test "a person whose plan no longer includes the app gets no further push", ctx do
      socket = join!(ctx.device)
      assert_push "decisions", _payload
      ref = Process.monitor(socket.channel_pid)

      enforce_plans()
      send(socket.channel_pid, {Kanban.Tasks, :task_updated, pending_task!(ctx.cols["Review"])})

      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 1_000
      refute_push "decisions", _payload, 50
    end
  end

  describe "rebuilds" do
    test "a new review pushes an updated list", ctx do
      first = pending_task!(ctx.cols["Review"])
      join!(ctx.device)
      assert_push "decisions", _payload

      {:ok, second} =
        ctx.cols["Review"]
        |> task_fixture()
        |> Tasks.update_task(%{
          needs_review: true,
          completed_at: now(),
          completed_by_agent: "Claude"
        })

      payload =
        assert_decisions_until(&("review:task:#{second.id}" in item_ids(&1)))

      assert "review:task:#{first.id}" in item_ids(payload)
    end

    test "an unchanged rebuild pushes nothing", ctx do
      task = pending_task!(ctx.cols["Review"])
      join!(ctx.device)
      assert_push "decisions", _payload
      attach_telemetry(@built, any_process: true)

      Phoenix.PubSub.broadcast(
        Kanban.PubSub,
        "board:#{ctx.board.id}",
        {Kanban.Tasks, :task_updated, task}
      )

      assert_receive {:telemetry_event, @built, _measurements, %{source: :channel}}, 1_000
      refute_push "decisions", _payload, 100
    end

    test "a burst of 100 events rebuilds and pushes once", ctx do
      task = pending_task!(ctx.cols["Review"])
      socket = join!(ctx.device)
      assert_push "decisions", _payload
      attach_telemetry(@built, any_process: true)

      for _ <- 1..100 do
        send(socket.channel_pid, {Kanban.Tasks, :task_updated, task})
      end

      task |> Ecto.Changeset.change(title: "Renamed while bursting") |> Repo.update!()

      assert_receive {:telemetry_event, @built, _measurements, %{source: :channel}}, 1_000
      assert_push "decisions", %{data: %{items: [%{summary: %{title: "Renamed while bursting"}}]}}
      refute_receive {:telemetry_event, @built, _measurements, _metadata}, 100
      refute_push "decisions", _payload, 50
    end

    test "a read notification asks for a rebuild", ctx do
      socket = join!(ctx.device)
      assert_push "decisions", _payload
      attach_telemetry(@built, any_process: true)

      Notifications.Broadcaster.broadcast(ctx.user.id, {:notifications_read, 0})

      assert_receive {:telemetry_event, @built, _measurements, %{source: :channel}}, 1_000
      settle(socket)
    end

    test "web and app open at once each get the change", ctx do
      {tablet, _issued} = device_with_tokens_fixture(ctx.scope, %{device_class: :tablet})
      phone = join!(ctx.device)
      assert_push "decisions", _payload
      tablet_socket = join!(tablet)
      assert_push "decisions", _payload

      # The web's own subscriber on the same board topic.
      Phoenix.PubSub.subscribe(Kanban.PubSub, "board:#{ctx.board.id}")
      review = pending_task!(ctx.cols["Review"])

      Phoenix.PubSub.broadcast(
        Kanban.PubSub,
        "board:#{ctx.board.id}",
        {Kanban.Tasks, :task_updated, review}
      )

      assert_receive {Kanban.Tasks, :task_updated, _task}

      for socket <- [phone, tablet_socket] do
        assert_receive %Phoenix.Socket.Message{
                         event: "decisions",
                         topic: "me:inbox",
                         payload: payload
                       },
                       1_000

        assert item_ids(payload) == ["review:task:#{review.id}"]
        settle(socket)
      end
    end
  end

  describe "access changes" do
    setup ctx do
      owner = user_fixture()
      shared = ai_optimized_board_fixture(owner)
      {:ok, _member} = Boards.add_user_to_board(shared, ctx.user, :modify, owner)
      %{owner: owner, shared: shared}
    end

    test "board_access_changed re-subscribes and drops the old board", ctx do
      shared_review = pending_task!(columns(ctx.shared)["Review"])
      socket = join!(ctx.device)

      assert_push "decisions", payload
      assert "review:task:#{shared_review.id}" in item_ids(payload)
      assert "board:#{ctx.shared.id}" in board_topics(socket)

      {:ok, _removed} = Boards.remove_user_from_board(ctx.shared, ctx.user, ctx.owner)

      assert_decisions_until(&("review:task:#{shared_review.id}" not in item_ids(&1)))
      settle(socket)
      refute "board:#{ctx.shared.id}" in board_topics(socket)

      # A change on the dropped board no longer reaches the channel.
      attach_telemetry(@built, any_process: true)

      Phoenix.PubSub.broadcast(
        Kanban.PubSub,
        "board:#{ctx.shared.id}",
        {Kanban.Tasks, :task_updated, shared_review}
      )

      refute_receive {:telemetry_event, @built, _measurements, _metadata}, 100
    end

    test "a board_access_changed notification subscribes a board the person gained", ctx do
      socket = join!(ctx.device)
      assert_push "decisions", _payload
      gained = ai_optimized_board_fixture(ctx.owner)
      gained_review = pending_task!(columns(gained)["Review"])

      {:ok, _member} = Boards.add_user_to_board(gained, ctx.user, :read_only, ctx.owner)

      assert_decisions_until(&("review:task:#{gained_review.id}" in item_ids(&1)))
      assert "board:#{gained.id}" in board_topics(socket)
    end

    test "a notification of an access change sent directly triggers the re-read", ctx do
      socket = join!(ctx.device)
      assert_push "decisions", _payload
      gained = ai_optimized_board_fixture(ctx.owner)

      Repo.insert!(%Kanban.Boards.BoardUser{
        board_id: gained.id,
        user_id: ctx.user.id,
        access: :read_only
      })

      send(
        socket.channel_pid,
        {:notification_created, %Notification{event_type: :board_access_changed}}
      )

      assert_eventually(fn -> "board:#{gained.id}" in board_topics(socket) end)
    end
  end

  defp assert_eventually(fun, attempts \\ 50) do
    cond do
      fun.() ->
        true

      attempts == 0 ->
        flunk("condition never became true")

      true ->
        Process.sleep(20)
        assert_eventually(fun, attempts - 1)
    end
  end
end
