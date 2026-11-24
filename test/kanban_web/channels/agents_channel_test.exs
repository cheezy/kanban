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
  import Kanban.OrganizationsFixtures
  import Kanban.PlansHelpers
  import Kanban.TasksFixtures
  import Kanban.WorkspacesFixtures

  alias Kanban.Agents
  alias Kanban.Boards
  alias Kanban.Boards.AccessSignal
  alias Kanban.Columns
  alias Kanban.Notifications
  alias Kanban.Notifications.Notification
  alias Kanban.Organizations
  alias Kanban.Repo
  alias Kanban.Workspaces
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

  defp board_topics(socket) do
    Kanban.PubSub |> Registry.keys(socket.channel_pid) |> Enum.filter(&(&1 =~ ~r/^board:/))
  end

  # A board in an Organization's workspace that `user` reaches only as an
  # org-admin, with no board_users row, so removing them from the
  # Organization ends the access without a board_access_changed notification.
  # The board's owner is a second org-admin, so `user` is not the last one.
  defp derived_org_board(user) do
    organization = organization_fixture()
    owner = user_fixture()
    organization_member_fixture(organization, owner, :org_admin)
    organization_member_fixture(organization, user, :org_admin)
    workspace = org_workspace_fixture(organization)

    board =
      owner
      |> ai_optimized_board_fixture()
      |> Ecto.Changeset.change(workspace_id: workspace.id)
      |> Repo.update!()

    agent_task(columns(board)["Doing"], %{created_by_agent: "Gemini"})
    {organization, board}
  end

  # An Organization where `user` and a second org-admin, `owner`, are
  # org-admins, its workspace, and a personal board of `owner`'s with a
  # Gemini task that `user` cannot see yet.
  defp org_with_personal_board(user) do
    organization = organization_fixture()
    owner = user_fixture()
    organization_member_fixture(organization, owner, :org_admin)
    organization_member_fixture(organization, user, :org_admin)
    workspace = org_workspace_fixture(organization)
    board = ai_optimized_board_fixture(owner)
    agent_task(columns(board)["Doing"], %{created_by_agent: "Gemini"})
    %{organization: organization, owner: owner, workspace: workspace, moved: board}
  end

  defp remove_org_admin!(organization, user),
    do: {:ok, _membership} = Organizations.remove_org_admin(admin_fixture(), organization, user)

  # Counts the :rebuild messages the channel process receives while `fun` runs
  # and until its coalescer has nothing pending.
  defp count_rebuilds(socket, fun) do
    :erlang.trace(socket.channel_pid, true, [:receive])
    fun.()
    assert_eventually(fn -> not pending?(socket) end)
    :erlang.trace(socket.channel_pid, false, [:receive])
    count_traced_rebuilds(socket.channel_pid, 0)
  end

  defp count_traced_rebuilds(pid, count) do
    receive do
      {:trace, ^pid, :receive, :rebuild} -> count_traced_rebuilds(pid, count + 1)
      {:trace, ^pid, :receive, _other} -> count_traced_rebuilds(pid, count)
    after
      0 -> count
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
      assert board_topics(socket) == ["board:#{ctx.board.id}"]
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

    test "an org-admin removal drops the lost board's agents topic and no further agents_changed push arrives for it",
         ctx do
      {organization, lost} = derived_org_board(ctx.user)
      socket = join!(ctx.device)
      assert_push "agents", payload
      assert "Gemini" in agent_names(payload)
      assert "agents:#{lost.id}" in agents_topics(socket)
      assert "board:#{lost.id}" in board_topics(socket)

      remove_org_admin!(organization, ctx.user)

      payload = assert_agents_until(&("Gemini" not in agent_names(&1)))
      assert payload == expected(ctx.scope)
      refute "agents:#{lost.id}" in agents_topics(socket)
      refute "board:#{lost.id}" in board_topics(socket)

      Phoenix.PubSub.broadcast(
        Kanban.PubSub,
        "agents:#{lost.id}",
        {:agent_event, %{kind: :claim, board_id: lost.id}}
      )

      agent_task(columns(lost)["Doing"], %{created_by_agent: "Codex"})

      refute pending?(socket)
      refute_push "agents", _payload, 100
    end

    test "a members_changed broadcast for a board the person keeps leaves the subscription in place",
         ctx do
      {organization, lost} = derived_org_board(ctx.user)
      socket = join!(ctx.device)
      assert_push "agents", _payload

      remove_org_admin!(organization, ctx.user)
      assert_agents_until(&("Gemini" not in agent_names(&1)))

      Phoenix.PubSub.broadcast(
        Kanban.PubSub,
        "board:#{ctx.board.id}",
        {Boards, :members_changed, ctx.board.id}
      )

      assert pending?(socket)
      assert_eventually(fn -> not pending?(socket) end)
      assert agents_topics(socket) == ["agents:#{ctx.board.id}"]
      assert board_topics(socket) == ["board:#{ctx.board.id}"]
      refute "agents:#{lost.id}" in agents_topics(socket)
      assert Process.alive?(socket.channel_pid)
    end

    test "losing every board stops the channel", ctx do
      {organization, lost} = derived_org_board(ctx.user)
      enforce_plans()
      socket = join!(ctx.device)
      assert_push "agents", payload
      assert "Gemini" in agent_names(payload)
      assert agents_topics(socket) == ["agents:#{lost.id}"]
      ref = Process.monitor(socket.channel_pid)

      remove_org_admin!(organization, ctx.user)

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

    test "a burst of members_changed broadcasts coalesces into one rebuild", ctx do
      socket = join!(ctx.device)
      assert_push "agents", _payload

      rebuilds =
        count_rebuilds(socket, fn ->
          for _ <- 1..100 do
            send(socket.channel_pid, {Boards, :members_changed, ctx.board.id})
          end
        end)

      assert rebuilds == 1
    end

    test "other messages on the board topic are ignored", ctx do
      socket = join!(ctx.device)
      assert_push "agents", _payload

      send(socket.channel_pid, {Kanban.Tasks, :task_updated, %{id: 0}})

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
      assert "board:#{gained.id}" in board_topics(socket)

      {:ok, _removed} = Boards.remove_user_from_board(gained, ctx.user, owner)

      assert_agents_until(&("Gemini" not in agent_names(&1)))
      refute "agents:#{gained.id}" in agents_topics(socket)
      refute "board:#{gained.id}" in board_topics(socket)
    end
  end

  # D466: gains that send no board_access_changed notification.
  describe "access gained without a notification" do
    setup :with_board

    test "pushes a board gained through a board move", ctx do
      %{owner: owner, workspace: workspace, moved: moved} = org_with_personal_board(ctx.user)
      socket = join!(ctx.device)
      assert_push "agents", payload
      refute "Gemini" in agent_names(payload)
      refute "agents:#{moved.id}" in agents_topics(socket)

      {:ok, _board} = Workspaces.move_board_to_workspace(owner, moved, workspace)

      payload = assert_agents_until(&("Gemini" in agent_names(&1)))
      assert payload == expected(ctx.scope)
      assert "agents:#{moved.id}" in agents_topics(socket)
      assert "board:#{moved.id}" in board_topics(socket)
    end

    test "subscribes to the gained board topic", ctx do
      %{organization: organization, owner: owner, workspace: workspace, moved: moved} =
        org_with_personal_board(ctx.user)

      socket = join!(ctx.device)
      assert_push "agents", _payload

      {:ok, _board} = Workspaces.move_board_to_workspace(owner, moved, workspace)
      assert_agents_until(&("Gemini" in agent_names(&1)))
      assert_eventually(fn -> not pending?(socket) end)

      # A members_changed on the gained board's topic is now heard.
      Phoenix.PubSub.broadcast(
        Kanban.PubSub,
        "board:#{moved.id}",
        {Boards, :members_changed, moved.id}
      )

      assert pending?(socket)

      # So is the loss it signals: removal from the Organization sends no
      # notification, only that broadcast (D460).
      remove_org_admin!(organization, ctx.user)

      assert_agents_until(&("Gemini" not in agent_names(&1)))
      refute "board:#{moved.id}" in board_topics(socket)
    end

    test "pushes the Organization's boards when the person becomes an org-admin", ctx do
      {organization, board} = derived_org_board(user_fixture())
      socket = join!(ctx.device)
      assert_push "agents", payload
      refute "Gemini" in agent_names(payload)

      {:ok, _membership} =
        Organizations.appoint_org_admin(admin_fixture(), organization, ctx.user)

      payload = assert_agents_until(&("Gemini" in agent_names(&1)))
      assert payload == expected(ctx.scope)
      assert "agents:#{board.id}" in agents_topics(socket)
      assert "board:#{board.id}" in board_topics(socket)
    end

    test "subscribes a board another org-admin creates in the Organization", ctx do
      %{owner: owner, workspace: workspace} = org_with_personal_board(ctx.user)
      socket = join!(ctx.device)
      assert_push "agents", _payload

      {:ok, created} = Boards.create_board(owner, %{name: "Shared board"}, workspace: workspace)

      assert created.workspace_id == workspace.id
      assert_eventually(fn -> "agents:#{created.id}" in agents_topics(socket) end)
      assert "board:#{created.id}" in board_topics(socket)
    end

    test "ignores a gain to an already covered board", ctx do
      socket = join!(ctx.device)
      assert_push "agents", _payload

      send(socket.channel_pid, {Boards, :access_gained, [ctx.board.id]})

      refute pending?(socket)
      assert agents_topics(socket) == ["agents:#{ctx.board.id}"]
      assert board_topics(socket) == ["board:#{ctx.board.id}"]
    end

    test "coalesces several gains", ctx do
      socket = join!(ctx.device)
      assert_push "agents", _payload
      uncovered = ai_optimized_board_fixture(user_fixture())

      rebuilds =
        count_rebuilds(socket, fn ->
          for _ <- 1..100 do
            send(socket.channel_pid, {Boards, :access_gained, [uncovered.id]})
          end
        end)

      assert rebuilds == 1
      # The rebuild re-reads access from the context, so a signal naming a
      # board the person cannot see never subscribes it.
      refute "board:#{uncovered.id}" in board_topics(socket)
    end

    test "a gain and a loss in one burst are both picked up", ctx do
      {organization, lost} = derived_org_board(ctx.user)
      gained = ai_optimized_board_fixture(user_fixture())
      agent_task(columns(gained)["Doing"], %{created_by_agent: "Codex"})
      socket = join!(ctx.device)
      assert_push "agents", payload
      assert "Gemini" in agent_names(payload)

      Repo.insert!(%Kanban.Boards.BoardUser{
        board_id: gained.id,
        user_id: ctx.user.id,
        access: :read_only
      })

      send(socket.channel_pid, {Boards, :access_gained, [gained.id]})
      remove_org_admin!(organization, ctx.user)

      payload =
        assert_agents_until(fn payload ->
          names = agent_names(payload)
          "Codex" in names and "Gemini" not in names
        end)

      assert payload == expected(ctx.scope)
      assert "board:#{gained.id}" in board_topics(socket)
      refute "board:#{lost.id}" in board_topics(socket)
    end

    # SCIM and SSO provisioning add the person through this same function
    # (Kanban.SSO.Provisioning), and plain membership grants no board access.
    test "joining an Organization as a plain member gains nothing", ctx do
      {organization, board} = derived_org_board(user_fixture())
      socket = join!(ctx.device)
      assert_push "agents", _payload
      AccessSignal.subscribe(ctx.user)

      assert {:ok, _membership} = Organizations.add_member(organization, ctx.user, :member)

      refute_receive {Boards, :access_gained, _board_ids}, 50
      refute pending?(socket)
      refute "board:#{board.id}" in board_topics(socket)
      assert board_topics(socket) == ["board:#{ctx.board.id}"]
    end

    test "subscribes to the person's board-access topic on join", ctx do
      socket = join!(ctx.device)
      assert_push "agents", _payload

      assert AccessSignal.topic(ctx.user) in Registry.keys(Kanban.PubSub, socket.channel_pid)
    end
  end
end
