defmodule Kanban.Webhooks.CreatorDisabledTest do
  @moduledoc """
  An endpoint sends nothing while the account that created it is disabled,
  and sends again once the account is enabled (decided 2026-10-21):
  `Kanban.Webhooks.Endpoint.sendable/1`, read by `Kanban.Webhooks.Events`,
  `Kanban.Webhooks.DeliveryWorker` and `Kanban.Webhooks.send_test_event/2`.
  Also the stored reason an endpoint was switched off, and the creator
  `Kanban.Webhooks.list_endpoints/2` preloads for the Integrations tab.
  """
  use Kanban.DataCase, async: true
  use Oban.Testing, repo: Kanban.Repo

  import Ecto.Query, only: [where: 3]
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures
  import Kanban.WebhooksFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.Accounts.User
  alias Kanban.Repo
  alias Kanban.Webhooks
  alias Kanban.Webhooks.Delivery
  alias Kanban.Webhooks.DeliveryWorker
  alias Kanban.Webhooks.Endpoint
  alias Kanban.Webhooks.Events

  setup do
    Repo.delete_all(Oban.Job)
    owner = user_fixture()
    board = board_fixture(owner)
    creator = user_fixture()
    %{owner: owner, scope: Scope.for_user(owner), board: board, creator: creator}
  end

  defp set_disabled(user, at), do: user |> User.disabled_changeset(at) |> Repo.update!()

  defp disable(user), do: set_disabled(user, DateTime.utc_now(:second))

  defp sendable_ids do
    Endpoint.sendable() |> Repo.all() |> Enum.map(& &1.id) |> MapSet.new()
  end

  describe "Endpoint.sendable/1" do
    test "keeps enabled endpoints of active or deleted creators, and drops the rest", ctx do
      active = webhook_endpoint_fixture(ctx.board, %{created_by_id: ctx.owner.id})
      orphaned = webhook_endpoint_fixture(ctx.board, %{created_by_id: nil})

      switched_off =
        webhook_endpoint_fixture(ctx.board, %{created_by_id: ctx.owner.id, enabled: false})

      blocked = webhook_endpoint_fixture(ctx.board, %{created_by_id: ctx.creator.id})
      disable(ctx.creator)

      ids = sendable_ids()

      assert active.id in ids
      assert orphaned.id in ids
      refute switched_off.id in ids
      refute blocked.id in ids
    end

    test "narrows a query it is given", ctx do
      kept = webhook_endpoint_fixture(ctx.board, %{created_by_id: ctx.owner.id})
      _other = webhook_endpoint_fixture(board_fixture(ctx.owner), %{created_by_id: ctx.owner.id})

      query = where(Endpoint, [e], e.id == ^kept.id)
      assert [%Endpoint{id: id}] = query |> Endpoint.sendable() |> Repo.all()
      assert id == kept.id
    end
  end

  describe "event fan-out" do
    setup ctx do
      task = ctx.board |> column_fixture() |> task_fixture()
      endpoint = webhook_endpoint_fixture(ctx.board, %{created_by_id: ctx.creator.id})
      Repo.delete_all(Oban.Job)
      Map.merge(ctx, %{task: task, endpoint: endpoint})
    end

    test "queues nothing while the creator is disabled, and resumes once they are enabled", ctx do
      creator = disable(ctx.creator)

      Events.emit(ctx.board.id, :task_created, ctx.task)
      refute_enqueued(worker: DeliveryWorker)

      set_disabled(creator, nil)

      Events.emit(ctx.board.id, :task_created, ctx.task)
      assert_enqueued(worker: DeliveryWorker, args: %{endpoint_id: ctx.endpoint.id})
    end

    test "another creator's endpoint on the board keeps sending", ctx do
      owners = webhook_endpoint_fixture(ctx.board, %{created_by_id: ctx.owner.id})
      disable(ctx.creator)

      Events.emit(ctx.board.id, :task_created, ctx.task)

      assert [job] = all_enqueued(worker: DeliveryWorker)
      assert job.args["endpoint_id"] == owners.id
    end
  end

  describe "DeliveryWorker" do
    test "drops a job queued before the creator was disabled, sending and recording nothing",
         ctx do
      endpoint = webhook_endpoint_fixture(ctx.board, %{created_by_id: ctx.creator.id})
      disable(ctx.creator)

      args = %{
        "endpoint_id" => endpoint.id,
        "delivery_id" => "dlv-1",
        "event" => "task.created",
        "payload" => %{"id" => "evt"}
      }

      assert perform_job(DeliveryWorker, args) == :ok
      deliveries = Delivery |> where([d], d.endpoint_id == ^endpoint.id) |> Repo.all()
      assert deliveries == []
    end
  end

  describe "send_test_event/2" do
    test "is refused while the creator is disabled", ctx do
      endpoint = webhook_endpoint_fixture(ctx.board, %{created_by_id: ctx.creator.id})
      disable(ctx.creator)

      assert Webhooks.send_test_event(ctx.scope, endpoint) ==
               {:error, :creator_disabled}

      refute_enqueued(worker: DeliveryWorker)
    end

    test "is queued for an endpoint whose creator was deleted", ctx do
      endpoint = webhook_endpoint_fixture(ctx.board, %{created_by_id: nil})

      assert {:ok, _job} = Webhooks.send_test_event(ctx.scope, endpoint)
    end

    test "taking the endpoint over by disabling and enabling it lets it send again", ctx do
      endpoint = webhook_endpoint_fixture(ctx.board, %{created_by_id: ctx.creator.id})
      disable(ctx.creator)
      scope = ctx.scope

      {:ok, off} = Webhooks.update_endpoint(scope, endpoint, %{"enabled" => false})
      {:ok, on} = Webhooks.update_endpoint(scope, off, %{"enabled" => true})

      assert on.created_by_id == ctx.owner.id
      assert {:ok, _job} = Webhooks.send_test_event(scope, on)
    end
  end

  describe "disabled_reason" do
    test "a pause stores the reason, and re-enabling clears it", ctx do
      endpoint = webhook_endpoint_fixture(ctx.board, %{created_by_id: ctx.creator.id})

      assert Webhooks.pause_creator_endpoints(ctx.creator.id, :all) == 1
      paused = Repo.get!(Endpoint, endpoint.id)
      assert paused.disabled_reason == :creator_lost_access

      {:ok, enabled} =
        Webhooks.update_endpoint(ctx.scope, paused, %{"enabled" => true})

      assert enabled.disabled_reason == nil
      assert Repo.get!(Endpoint, endpoint.id).disabled_reason == nil
    end

    test "the changeset clears it on any change to enabled, and keeps it otherwise", ctx do
      paused = %Endpoint{
        board_id: ctx.board.id,
        kind: :generic,
        url: "https://hooks.example.com/x",
        event_types: ["task.created"],
        enabled: false,
        disabled_reason: :creator_lost_access
      }

      kept = Endpoint.changeset(paused, %{"event_types" => ["task.moved"]})
      refute Ecto.Changeset.changed?(kept, :disabled_reason)

      cleared = Endpoint.changeset(paused, %{"enabled" => true})
      assert Ecto.Changeset.get_change(cleared, :disabled_reason, :unset) == nil

      by_hand = Endpoint.changeset(%{paused | enabled: true}, %{"enabled" => false})
      assert Ecto.Changeset.fetch_field!(by_hand, :disabled_reason) == nil
    end

    test "it cannot be cast from params", ctx do
      endpoint = webhook_endpoint_fixture(ctx.board, %{created_by_id: ctx.owner.id})

      changeset = Endpoint.changeset(endpoint, %{"disabled_reason" => "creator_lost_access"})
      refute Ecto.Changeset.changed?(changeset, :disabled_reason)
    end
  end

  describe "list_endpoints/2" do
    test "preloads only the creator's id, name, email and disabled_at", ctx do
      webhook_endpoint_fixture(ctx.board, %{created_by_id: ctx.creator.id})
      webhook_endpoint_fixture(ctx.board, %{created_by_id: nil})

      assert [with_creator, orphaned] =
               Webhooks.list_endpoints(ctx.scope, ctx.board)

      assert %User{id: id, email: email, hashed_password: nil} = with_creator.created_by
      assert id == ctx.creator.id
      assert email == ctx.creator.email
      assert orphaned.created_by == nil
    end
  end
end
