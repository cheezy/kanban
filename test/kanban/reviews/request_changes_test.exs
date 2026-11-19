defmodule Kanban.Reviews.RequestChangesTest do
  use Kanban.DataCase, async: true

  import Ecto.Query

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.DevicesFixtures
  import Kanban.TasksFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.AuditLog
  alias Kanban.Devices.Nonce
  alias Kanban.Devices.Nonces
  alias Kanban.Reviews.RequestChanges
  alias Kanban.Tasks
  alias Kanban.Tasks.Task

  @requested_at ~U[2026-11-18 09:30:00Z]
  @params %{"review_requested_at" => "2026-11-18T09:30:00Z", "notes" => "Cover the empty list."}

  setup do
    user = user_fixture()
    scope = Scope.for_user(user)
    phone = device_fixture(scope, %{device_class: :phone})
    review = user |> board_fixture() |> column_fixture(%{name: "Review"})

    %{scope: scope, phone: phone, review: review}
  end

  defp pending_task!(column) do
    {:ok, task} =
      column
      |> task_fixture(%{title: "Show the member list"})
      |> Tasks.update_task(%{needs_review: true, completed_by_agent: "Claude"})

    task |> Ecto.Changeset.change(review_requested_at: @requested_at) |> Repo.update!()
  end

  defp key(device, task),
    do: Nonces.idempotency_key(device, :request_changes, task.id, "retry-1", &%{id: &1.id})

  defp rows, do: AuditLog.list_events([action: :review_changes_requested], order: :asc)

  test "requests changes and stores the result with the key", ctx do
    task = pending_task!(ctx.review)
    key = key(ctx.phone, task)

    assert {:ok, %Task{review_status: :changes_requested, review_notes: "Cover the empty list."}} =
             RequestChanges.request_changes(ctx.scope, ctx.phone, task.id, @params,
               idempotency: key
             )

    assert {:ok, %Nonce{response_status: 200, response_body: %{"id" => id}}} =
             Nonces.find_replay(key)

    assert id == task.id
  end

  test "a key already stored is a replay and requests nothing again", ctx do
    task = pending_task!(ctx.review)
    key = key(ctx.phone, task)

    assert {:ok, _task} =
             RequestChanges.request_changes(ctx.scope, ctx.phone, task.id, @params,
               idempotency: key
             )

    # Reopen the review so only the stored key can stop a second request.
    Task
    |> where([t], t.id == ^task.id)
    |> Repo.update_all(set: [review_status: nil, reviewed_at: nil, reviewed_by_id: nil])

    assert {:error, {:replay, %Nonce{response_status: 200}}} =
             RequestChanges.request_changes(ctx.scope, ctx.phone, task.id, @params,
               idempotency: key
             )

    assert [_one] = rows()
  end

  test "blank notes are :review_notes_required and store nothing", ctx do
    task = pending_task!(ctx.review)
    key = key(ctx.phone, task)

    assert {:error, :review_notes_required} =
             RequestChanges.request_changes(
               ctx.scope,
               ctx.phone,
               task.id,
               %{@params | "notes" => " "},
               idempotency: key
             )

    assert Nonces.find_replay(key) == :none
    assert rows() == []
  end

  test "a device revoked before the commit is :revoked and stores nothing", ctx do
    task = pending_task!(ctx.review)
    key = key(ctx.phone, task)
    ctx.phone |> Ecto.Changeset.change(revoked_at: DateTime.utc_now(:second)) |> Repo.update!()

    assert {:error, :revoked} =
             RequestChanges.request_changes(ctx.scope, ctx.phone, task.id, @params,
               idempotency: key
             )

    assert Nonces.find_replay(key) == :none
    assert Repo.get!(Task, task.id).review_status in [nil, :pending]
  end

  test "without a key it requests changes and stores nothing", ctx do
    task = pending_task!(ctx.review)

    assert {:ok, %Task{review_status: :changes_requested}} =
             RequestChanges.request_changes(ctx.scope, ctx.phone, task.id, @params)

    assert Repo.aggregate(Nonce, :count) == 0
  end
end
