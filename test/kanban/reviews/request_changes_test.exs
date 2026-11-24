defmodule Kanban.Reviews.RequestChangesTest do
  # async: false - the plan tests switch the global :plans_enforced application env on.
  use Kanban.DataCase, async: false

  import Ecto.Query

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.DevicesFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.PlansHelpers
  import Kanban.TasksFixtures
  import Kanban.WorkspacesFixtures

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

    %{user: user, scope: scope, phone: phone, review: review}
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

  # Reviews.request_changes_review/3 refuses notes that String.trim/1 empties,
  # so these cases are ones only RequestChanges' own check refuses: a
  # zero-width space and a combining mark survive String.trim/1, and with a
  # revoked device a check made at the commit would answer :revoked first.
  # Either way the answer proves the notes were refused before the commit.
  test "blank or invisible notes are :review_notes_required before the commit and store nothing",
       ctx do
    task = pending_task!(ctx.review)
    key = key(ctx.phone, task)

    for notes <- [" ", "\u200B", "\u200B \u2060", "\u0301"] do
      assert {:error, :review_notes_required} =
               RequestChanges.request_changes(
                 ctx.scope,
                 ctx.phone,
                 task.id,
                 %{@params | "notes" => notes},
                 idempotency: key
               ),
             "notes #{inspect(notes)}"
    end

    assert Nonces.find_replay(key) == :none
    assert rows() == []
    assert Repo.get!(Task, task.id).review_status in [nil, :pending]

    ctx.phone |> Ecto.Changeset.change(revoked_at: DateTime.utc_now(:second)) |> Repo.update!()

    assert {:error, :review_notes_required} =
             RequestChanges.request_changes(
               ctx.scope,
               ctx.phone,
               task.id,
               %{@params | "notes" => " "},
               idempotency: key
             )
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

  # Grants the person and the review column's board the plan, with plans
  # enforced, and returns a scope carrying the membership the way the device
  # plug builds it, so the plan check before the lock makes no query.
  defp paid_scope!(ctx) do
    organization = organization_fixture()
    member = organization_member_fixture(organization, ctx.user)
    enforce_plans()

    Kanban.Boards.Board
    |> where([b], b.id == ^ctx.review.board_id)
    |> Repo.update_all(set: [workspace_id: org_workspace_fixture(organization).id])

    {Scope.put_organization_membership(ctx.scope, member), member}
  end

  describe "the :mobile_app plan under the lock" do
    test "refuses after a plan downgrade", ctx do
      {scope, member} = paid_scope!(ctx)
      task = pending_task!(ctx.review)
      key = key(ctx.phone, task)

      # Committed after the request was admitted, so only the check under the
      # lock sees it.
      Repo.delete!(member)

      assert {:error, {:plan_required, :mobile_app}} =
               RequestChanges.request_changes(scope, ctx.phone, task.id, @params,
                 idempotency: key
               )

      assert Nonces.find_replay(key) == :none
      assert rows() == []
      assert Repo.get!(Task, task.id).review_status in [nil, :pending]
    end

    test "plan refusal shape", ctx do
      {scope, member} = paid_scope!(ctx)
      task = pending_task!(ctx.review)
      Repo.delete!(member)

      # The same refusal before the lock (a scope with no membership) and under
      # it (a scope still carrying the removed one).
      before_lock = RequestChanges.request_changes(ctx.scope, ctx.phone, task.id, @params)
      under_lock = RequestChanges.request_changes(scope, ctx.phone, task.id, @params)

      assert before_lock == {:error, {:plan_required, :mobile_app}}
      assert under_lock == before_lock
      assert Repo.get!(Task, task.id).review_status in [nil, :pending]
    end

    test "a current plan still requests changes", ctx do
      {scope, _member} = paid_scope!(ctx)
      task = pending_task!(ctx.review)

      assert {:ok, %Task{review_status: :changes_requested}} =
               RequestChanges.request_changes(scope, ctx.phone, task.id, @params)
    end
  end
end
