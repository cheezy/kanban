defmodule KanbanWeb.AgentsChannelTest do
  @moduledoc """
  Tests for `KanbanWeb.AgentsChannel` on `me:agents` (W2766,
  docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §7.7).
  """
  # async: false - tests switch the global :plans_enforced application env
  # and the coalescer interval on, and the channel process shares the test's
  # sandbox connection.
  use KanbanWeb.ChannelCase, async: false

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.DevicesFixtures
  import Kanban.PlansHelpers
  import Kanban.TasksFixtures

  alias Kanban.Agents
  alias Kanban.Boards
  alias Kanban.Columns
  alias Kanban.Notifications
  alias Kanban.Notifications.Notification
  alias Kanban.Repo
  alias KanbanWeb.AgentsChannel
  alias KanbanWeb.API.Me.AgentJSON
  alias KanbanWeb.Coalescer
  alias KanbanWeb.SocketToken
  alias KanbanWeb.UserSocket

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

    %{user: user, scope: scope, device: device}
  end

  defp columns(board), do: board |> Columns.list_columns() |> Map.new(&{&1.name, &1})

  defp with_board(%{user: user} = ctx) do
    board = ai_optimized_board_fixture(user)
    Map.merge(ctx, %{board: board, cols: columns(board)})
  end

  defp agent_task(column, attrs),
    do: task_fixture(column, Map.merge(%{created_by_agent: "Claude"}, attrs))

  defp join_result(device) do
    {token, _expires_at} = SocketToken.sign(device)
    {:ok, socket} = connect(UserSocket, %{"token" => token})
    subscribe_and_join(socket, AgentsChannel, "me:agents")
  end

  defp join!(device) do
    {:ok, _reply, socket} = join_result(device)
    socket
  end

  defp expected(scope, timezone \\ nil),
    do: AgentJSON.index(%{overview: Agents.list_agents_for_app(scope, timezone: timezone)})

  defp agent_names(%{data: %{agents: agents}}), do: Enum.map(agents, & &1.name)

  # A zone and a completion time on opposite sides of a midnight from UTC:
  # from 02:00 UTC, two hours ago in a zone whose midnight was an hour ago
  # (today in UTC, yesterday there); before it, 23:00 UTC yesterday in UTC+2
  # (today there, yesterday in UTC).
  defp zone_splitting_today(%DateTime{hour: hour} = now) when hour >= 2 do
    midnight_hour = DateTime.add(now, -3600).hour

    zone =
      if midnight_hour <= 12,
        do: "Etc/GMT+#{midnight_hour}",
        else: "Etc/GMT-#{24 - midnight_hour}"

    {zone, now |> DateTime.add(-7200) |> DateTime.truncate(:second)}
  end

  defp zone_splitting_today(now) do
    yesterday_23 = %{
      DateTime.add(now, -86_400)
      | hour: 23,
        minute: 0,
        second: 0,
        microsecond: {0, 0}
    }

    {"Etc/GMT-2", yesterday_23}
  end

  # Receives "agents" pushes until one satisfies `fun`, failing after 1s.
  defp assert_agents_until(fun) do
    assert_receive %Phoenix.Socket.Message{event: "agents", payload: payload}, 1_000
    if fun.(payload), do: payload, else: assert_agents_until(fun)
  end

  defp agents_topics(socket) do
    Kanban.PubSub |> Registry.keys(socket.channel_pid) |> Enum.filter(&(&1 =~ ~r/^agents:/))
  end

  defp pending?(socket),
    do: :sys.get_state(socket.channel_pid).assigns.coalescer |> Coalescer.pending?()

  describe "join" do
    setup :with_board

    test "join pushes the roster and goal progress", ctx do
      goal = task_fixture(ctx.cols["Backlog"], %{type: :goal})
      agent_task(ctx.cols["Doing"], %{parent_id: goal.id, title: "Implement it"})
      task_fixture(ctx.cols["Ready"], %{parent_id: goal.id})

      socket = join!(ctx.device)

      assert_push "agents", payload
      assert payload == expected(ctx.scope)
      assert agent_names(payload) == ["Claude"]
      assert %{data: %{goals: [%{id: goal_id, counts: %{total: 2, doing: 1}}]}} = payload
      assert goal_id == goal.id
      assert agents_topics(socket) == ["agents:#{ctx.board.id}"]
    end

    test "the roster is taken in the device's time zone", ctx do
      # A completion that falls on today in one of UTC and the device's zone
      # and on yesterday in the other, so the zone changes the "today" count.
      {zone, completed_at} = zone_splitting_today(DateTime.utc_now())

      device = ctx.device |> Ecto.Changeset.change(time_zone: zone) |> Repo.update!()

      ctx.cols["Done"]
      |> agent_task(%{created_by_agent: "Codex"})
      |> Ecto.Changeset.change(status: :completed, completed_at: completed_at)
      |> Repo.update!()

      join!(device)

      assert_push "agents", payload
      assert payload == expected(ctx.scope, zone)
      refute payload == expected(ctx.scope, nil)
    end

    test "join refused without paid access", ctx do
      enforce_plans()

      assert {:error, %{reason: "plan_required"}} = join_result(ctx.device)
      refute_push "agents", _payload, 50
    end
  end

  test "a person with no boards joins with an empty roster", ctx do
    socket = join!(ctx.device)

    assert_push "agents", %{data: %{agents: [], goals: []}}
    assert agents_topics(socket) == []
    assert Notifications.topic(ctx.user) in Registry.keys(Kanban.PubSub, socket.channel_pid)
  end

  describe "access after the join" do
    setup :with_board

    test "a device revoked after joining gets no further push and the channel stops", ctx do
      socket = join!(ctx.device)
      assert_push "agents", _payload
      ref = Process.monitor(socket.channel_pid)

      ctx.device |> Ecto.Changeset.change(revoked_at: DateTime.utc_now(:second)) |> Repo.update!()
      send(socket.channel_pid, {:agent_event, %{kind: :claim, board_id: ctx.board.id}})

      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 1_000
      refute_push "agents", _payload, 50
    end
  end

  describe "rebuilds" do
    setup :with_board

    test "an agent event pushes an updated roster", ctx do
      agent_task(ctx.cols["Doing"], %{})
      join!(ctx.device)
      assert_push "agents", payload
      assert agent_names(payload) == ["Claude"]

      agent_task(ctx.cols["Doing"], %{created_by_agent: "Codex"})

      payload = assert_agents_until(&("Codex" in agent_names(&1)))
      assert payload == expected(ctx.scope)
    end

    test "an unchanged rebuild pushes nothing", ctx do
      agent_task(ctx.cols["Doing"], %{})
      socket = join!(ctx.device)
      assert_push "agents", _payload

      send(socket.channel_pid, {:agent_event, %{kind: :claim, board_id: ctx.board.id}})

      # The event scheduled a rebuild, the rebuild ran and found nothing new.
      assert pending?(socket)
      Process.sleep(60)
      refute pending?(socket)
      refute_push "agents", _payload, 50
    end

    test "a notification that is not an access change is ignored", ctx do
      socket = join!(ctx.device)
      assert_push "agents", _payload

      send(
        socket.channel_pid,
        {:notification_created, %Notification{event_type: :goal_completed}}
      )

      send(socket.channel_pid, {:notifications_read, 0})

      refute pending?(socket)
    end

    test "board_access_changed re-subscribes the agents topics", ctx do
      owner = user_fixture()
      gained = ai_optimized_board_fixture(owner)
      agent_task(columns(gained)["Doing"], %{created_by_agent: "Gemini"})
      socket = join!(ctx.device)
      assert_push "agents", payload
      refute "Gemini" in agent_names(payload)

      {:ok, _member} = Boards.add_user_to_board(gained, ctx.user, :read_only, owner)

      assert_agents_until(&("Gemini" in agent_names(&1)))
      assert "agents:#{gained.id}" in agents_topics(socket)

      {:ok, _removed} = Boards.remove_user_from_board(gained, ctx.user, owner)

      assert_agents_until(&("Gemini" not in agent_names(&1)))
      refute "agents:#{gained.id}" in agents_topics(socket)
    end
  end
end
