defmodule Kanban.Webhooks.PlanEnforcementTest do
  @moduledoc """
  Webhooks while paid plans are enforced: a free board's endpoints are
  paused (no new endpoints, no edits, no queued or delivered events) without
  being disabled or deleted, and they resume as soon as the board is paid.
  """
  # async: false - these tests switch the global :plans_enforced application
  # env on through Kanban.PlansHelpers.
  use Kanban.DataCase, async: false
  use Oban.Testing, repo: Kanban.Repo

  import Ecto.Query
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.PlansHelpers
  import Kanban.TasksFixtures
  import Kanban.TelemetryHelpers
  import Kanban.WebhooksFixtures
  import Kanban.WorkspacesFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.Boards
  alias Kanban.Boards.Board
  alias Kanban.Columns
  alias Kanban.Repo
  alias Kanban.Webhooks
  alias Kanban.Webhooks.Delivery
  alias Kanban.Webhooks.DeliveryWorker
  alias Kanban.Webhooks.Endpoint
  alias Kanban.Webhooks.Events
  alias Kanban.Webhooks.Payload
  alias Kanban.Webhooks.Transport

  @refused [:kanban, :plan, :feature_refused]
  @locked {:error, {:plan_required, :integrations}}
  @opts [resolver: &__MODULE__.public_resolver/1, allow_http: false]
  @valid %{"url" => "https://hooks.example.com/stride", "event_types" => ["task.created"]}

  def public_resolver(_host), do: {:ok, [{93, 184, 216, 34}]}

  setup do
    owner = user_fixture()
    board = ai_optimized_board_fixture(owner)
    column = board |> Columns.list_columns() |> Enum.find(&(&1.name == "Doing"))
    task = task_fixture(column, %{title: "Paused delivery"})

    endpoint =
      webhook_endpoint_fixture(board,
        url: "https://hooks.example.com/stride",
        event_types: ["task.created", "task.moved"]
      )

    Repo.delete_all(Oban.Job)

    %{
      owner: owner,
      scope: Scope.for_user(owner),
      board: board,
      task: task,
      endpoint: endpoint
    }
  end

  defp make_paid(%Board{id: id}) do
    workspace = org_workspace_fixture(organization_fixture())

    {1, _} =
      Board |> where([b], b.id == ^id) |> Repo.update_all(set: [workspace_id: workspace.id])

    :ok
  end

  defp job_args(endpoint, task) do
    {:ok, payload} = Payload.build("task.moved", task)

    %{
      "endpoint_id" => endpoint.id,
      "delivery_id" => "dlv-paused",
      "event" => "task.moved",
      "payload" => payload |> Jason.encode!() |> Jason.decode!()
    }
  end

  # Replies 200, reporting each request to the test process.
  defp stub_transport do
    test = self()

    Req.Test.stub(Transport, fn conn ->
      send(test, {:request, conn})
      Plug.Conn.send_resp(conn, 200, "ok")
    end)
  end

  defp queued_endpoint_ids do
    [worker: DeliveryWorker] |> all_enqueued() |> Enum.map(& &1.args["endpoint_id"])
  end

  defp deliveries(endpoint), do: Delivery |> where(endpoint_id: ^endpoint.id) |> Repo.all()

  describe "endpoint management on a free board under enforcement" do
    setup :enforce_plans

    test "create_endpoint refuses, writes nothing and emits feature_refused", ctx do
      attach_telemetry(@refused)

      assert Webhooks.create_endpoint(ctx.scope, ctx.board, @valid, @opts) == @locked

      assert_received {:telemetry_event, @refused, %{count: 1},
                       %{feature: :integrations, surface: :context}}

      assert [%Endpoint{id: id}] = Webhooks.list_endpoints(ctx.scope, ctx.board)
      assert id == ctx.endpoint.id
    end

    test "update_endpoint refuses and leaves the endpoint unchanged", ctx do
      attach_telemetry(@refused)

      assert Webhooks.update_endpoint(ctx.scope, ctx.endpoint, %{"enabled" => false}, @opts) ==
               @locked

      assert_received {:telemetry_event, @refused, _,
                       %{feature: :integrations, surface: :context}}

      assert Repo.get!(Endpoint, ctx.endpoint.id).enabled
    end

    test "rotate_secret refuses and keeps the current secret", ctx do
      attach_telemetry(@refused)
      before = Webhooks.signing_secret(ctx.endpoint)

      assert Webhooks.rotate_secret(ctx.scope, ctx.endpoint) == @locked

      assert_received {:telemetry_event, @refused, _,
                       %{feature: :integrations, surface: :context}}

      assert Endpoint |> Repo.get!(ctx.endpoint.id) |> Webhooks.signing_secret() == before
    end

    test "send_test_event refuses and queues nothing", ctx do
      attach_telemetry(@refused)

      assert Webhooks.send_test_event(ctx.scope, ctx.endpoint) == @locked

      assert_received {:telemetry_event, @refused, _,
                       %{feature: :integrations, surface: :context}}

      assert queued_endpoint_ids() == []
    end

    test "send_test_event on a disabled endpoint still reports the plan first", ctx do
      disabled = webhook_endpoint_fixture(ctx.board, enabled: false)

      assert Webhooks.send_test_event(ctx.scope, disabled) == @locked
    end

    test "delete_endpoint is still allowed", ctx do
      assert {:ok, %Endpoint{}} = Webhooks.delete_endpoint(ctx.scope, ctx.endpoint)
      assert Repo.get(Endpoint, ctx.endpoint.id) == nil
    end

    test "listing endpoints and deliveries is still allowed", ctx do
      delivery_fixture(ctx.endpoint)

      assert [%Endpoint{}] = Webhooks.list_endpoints(ctx.scope, ctx.board)
      assert [%Delivery{}] = Webhooks.list_deliveries(ctx.scope, ctx.endpoint)
    end

    test "a non-owner gets :unauthorized, not the plan refusal", ctx do
      modifier = user_fixture()
      {:ok, _} = Boards.add_user_to_board(ctx.board, modifier, :modify, ctx.owner)
      attach_telemetry(@refused)
      scope = Scope.for_user(modifier)

      assert Webhooks.create_endpoint(scope, ctx.board, @valid, @opts) == {:error, :unauthorized}
      assert Webhooks.rotate_secret(scope, ctx.endpoint) == {:error, :unauthorized}
      assert Webhooks.send_test_event(scope, ctx.endpoint) == {:error, :unauthorized}
      refute_received {:telemetry_event, @refused, _, _}
    end
  end

  describe "endpoint management on a paid board or without enforcement" do
    test "a paid board under enforcement manages endpoints normally", ctx do
      enforce_plans()
      :ok = make_paid(ctx.board)

      assert {:ok, {%Endpoint{}, _secret}} =
               Webhooks.create_endpoint(ctx.scope, ctx.board, @valid, @opts)

      assert {:ok, {%Endpoint{}, _secret}} = Webhooks.rotate_secret(ctx.scope, ctx.endpoint)
      assert {:ok, %Oban.Job{}} = Webhooks.send_test_event(ctx.scope, ctx.endpoint)
    end

    test "a free board is unchanged while enforcement is off", ctx do
      assert {:ok, {%Endpoint{}, _secret}} =
               Webhooks.create_endpoint(ctx.scope, ctx.board, @valid, @opts)

      assert {:ok, %Endpoint{enabled: false}} =
               Webhooks.update_endpoint(ctx.scope, ctx.endpoint, %{"enabled" => false}, @opts)
    end
  end

  describe "Events.emit/3" do
    test "queues no delivery for a free board under enforcement", ctx do
      enforce_plans()

      assert :ok = Events.emit(ctx.board.id, :task_moved, ctx.task)
      assert queued_endpoint_ids() == []
    end

    test "queues the delivery for a paid board under enforcement", ctx do
      enforce_plans()
      :ok = make_paid(ctx.board)

      assert :ok = Events.emit(ctx.board.id, :task_moved, ctx.task)
      assert queued_endpoint_ids() == [ctx.endpoint.id]
    end

    test "queues the delivery for a free board while enforcement is off", ctx do
      assert :ok = Events.emit(ctx.board.id, :task_moved, ctx.task)
      assert queued_endpoint_ids() == [ctx.endpoint.id]
    end
  end

  describe "DeliveryWorker.perform/1" do
    test "a job queued before the lock delivers nothing and emits feature_refused", ctx do
      stub_transport()
      enforce_plans()
      attach_telemetry(@refused)

      assert :ok = perform_job(DeliveryWorker, job_args(ctx.endpoint, ctx.task))

      refute_received {:request, _}

      assert_received {:telemetry_event, @refused, %{count: 1},
                       %{feature: :integrations, surface: :oban}}

      assert deliveries(ctx.endpoint) == []
    end

    test "a retry after the board loses paid access stops without another attempt", ctx do
      stub_transport()
      enforce_plans()

      assert :ok = perform_job(DeliveryWorker, job_args(ctx.endpoint, ctx.task), attempt: 2)

      refute_received {:request, _}
      assert deliveries(ctx.endpoint) == []
    end

    test "pausing leaves the endpoint enabled with its configuration", ctx do
      stub_transport()
      enforce_plans()

      perform_job(DeliveryWorker, job_args(ctx.endpoint, ctx.task))

      reloaded = Repo.get!(Endpoint, ctx.endpoint.id)
      assert reloaded.enabled
      assert reloaded.event_types == ctx.endpoint.event_types
      assert reloaded.updated_at == ctx.endpoint.updated_at
    end

    test "a paid board under enforcement delivers", ctx do
      stub_transport()
      enforce_plans()
      :ok = make_paid(ctx.board)

      assert :ok = perform_job(DeliveryWorker, job_args(ctx.endpoint, ctx.task))

      assert_received {:request, _}
      assert [%Delivery{}] = deliveries(ctx.endpoint)
    end
  end

  describe "resuming after the board becomes paid" do
    test "the next event queues and delivers to the paused endpoint", ctx do
      stub_transport()
      enforce_plans()
      Events.emit(ctx.board.id, :task_moved, ctx.task)
      assert queued_endpoint_ids() == []

      :ok = make_paid(ctx.board)
      Events.emit(ctx.board.id, :task_moved, ctx.task)

      assert [%Oban.Job{args: args}] = all_enqueued(worker: DeliveryWorker)
      assert :ok = perform_job(DeliveryWorker, args)
      assert_received {:request, _}
    end

    test "an endpoint the owner disabled stays disabled", ctx do
      {:ok, _} =
        Webhooks.update_endpoint(ctx.scope, ctx.endpoint, %{"enabled" => false}, @opts)

      enforce_plans()
      :ok = make_paid(ctx.board)
      Events.emit(ctx.board.id, :task_moved, ctx.task)

      assert queued_endpoint_ids() == []
      refute Repo.get!(Endpoint, ctx.endpoint.id).enabled
    end
  end
end
