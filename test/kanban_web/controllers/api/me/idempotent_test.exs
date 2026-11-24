defmodule KanbanWeb.API.Me.IdempotentTest do
  @moduledoc """
  `KanbanWeb.API.Me.Idempotent` binds an `Idempotency-Key` to the body fields
  of the decision it was sent with. A multipart body can carry a file part in
  one of those fields, a `%Plug.Upload{}` that cannot be JSON-encoded; with a
  key such a request must be refused as it is without one, never crash.

  An approval's key is bound to a hash of its signature too (W2923): an
  identical retry replays the first 200, and a resend with other signature
  bytes, or none, runs as a new request and is refused.
  """
  # async: false - one test switches the global :plans_enforced application
  # env on, and one approves from two processes at once.
  use KanbanWeb.ConnCase, async: false

  import Ecto.Query
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.DevicesFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.PlansHelpers
  import Kanban.TasksFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.AuditLog
  alias Kanban.Devices.Nonce
  alias Kanban.Repo
  alias Kanban.Reviews.Approval
  alias Kanban.Reviews.ApprovalChallenge
  alias Kanban.Reviews.ApprovalSignature
  alias Kanban.Tasks
  alias Kanban.Tasks.Task

  @requested_at ~U[2026-11-18 09:30:00Z]
  @stamp "2026-11-18T09:30:00Z"
  @key "7d1c2b3a-4e5f-4a6b-8c7d-9e0f1a2b3c4d"

  setup do
    user = user_fixture()
    approval_key = approval_keypair_fixture()

    {_device, tokens} =
      device_with_tokens_fixture(Scope.for_user(user), %{
        approval_public_key: approval_key.public_key
      })

    board = board_fixture(user)
    review = column_fixture(board, %{name: "Review", position: 1})
    _done = column_fixture(board, %{name: "Done", position: 2})

    {:ok, task} =
      review
      |> task_fixture(%{title: "Show the member list"})
      |> Tasks.update_task(%{needs_review: true, completed_by_agent: "Claude"})

    task =
      task
      |> Ecto.Changeset.change(%{review_requested_at: @requested_at})
      |> Repo.update!()

    upload = %Plug.Upload{
      path: Path.join(System.tmp_dir!(), "notes.txt"),
      filename: "notes.txt",
      content_type: "text/plain"
    }

    %{
      user: user,
      token: tokens.access_token,
      approval_key: approval_key,
      task: task,
      upload: upload
    }
  end

  # A Plug.Test map body is the parsed multipart body: an upload stays a
  # %Plug.Upload{} in body_params, as Plug.Parsers.MULTIPART leaves it.
  defp post_multipart(ctx, action, params, key) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> ctx.token)
    |> put_req_header("accept", "application/json")
    |> then(&if(key, do: put_req_header(&1, "idempotency-key", key), else: &1))
    |> post("/api/me/reviews/#{ctx.task.id}/#{action}", params)
  end

  defp post_json(ctx, path, body, key) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> ctx.token)
    |> put_req_header("content-type", "application/json")
    |> then(&if(key, do: put_req_header(&1, "idempotency-key", key), else: &1))
    |> post(path, Jason.encode!(body))
  end

  defp approve(ctx, body, key),
    do: post_json(ctx, "/api/me/reviews/#{ctx.task.id}/approve", body, key)

  # What the app does: take a challenge for the review it showed, then sign
  # the canonical string built from it.
  defp signed_approval(ctx) do
    shown = %{"review_fingerprint" => ApprovalChallenge.review_fingerprint(ctx.task)}

    %{"data" => %{"nonce" => nonce}} =
      ctx
      |> post_json("/api/me/reviews/#{ctx.task.id}/approval_challenge", shown, nil)
      |> json_response(201)

    message = Approval.signing_string(nonce, ctx.task.id, @requested_at)

    %{
      "review_requested_at" => @stamp,
      "nonce" => nonce,
      "signature" => sign_approval(ctx.approval_key.private_key, message),
      "message" => message
    }
  end

  defp body(signed), do: Map.delete(signed, "message")

  defp approvals, do: AuditLog.list_events([action: :review_approved], order: :asc)
  defp nonce_count, do: Repo.aggregate(Nonce, :count)
  defp undecided?(task), do: Repo.get!(Task, task.id).review_status in [nil, :pending]

  test "a file part as notes is the same 422 with a key as without one", ctx do
    for notes <- [ctx.upload, %{"part" => ctx.upload}, [ctx.upload]] do
      params = %{"review_requested_at" => @stamp, "notes" => notes}

      without_key = ctx |> post_multipart("request_changes", params, nil) |> json_response(422)
      with_key = ctx |> post_multipart("request_changes", params, @key) |> json_response(422)

      assert with_key == without_key
      assert with_key == %{"errors" => %{"notes" => ["can't be blank"]}}
    end

    assert undecided?(ctx.task)
    assert Repo.aggregate(Nonce, :count) == 0

    # The refused requests stored nothing, so the same key with real notes acts.
    params = %{"review_requested_at" => @stamp, "notes" => "Handle the empty list."}
    assert ctx |> post_multipart("request_changes", params, @key) |> json_response(200)
    assert Repo.aggregate(Nonce, :count) == 1
  end

  test "a file part as review_requested_at is refused alike with or without a key", ctx do
    params = %{"review_requested_at" => ctx.upload, "notes" => "Handle the empty list."}

    without_key = post_multipart(ctx, "request_changes", params, nil)
    with_key = post_multipart(ctx, "request_changes", params, @key)

    assert with_key.status == without_key.status
    assert with_key.status in 400..499
    assert with_key.resp_body == without_key.resp_body

    approve = post_multipart(ctx, "approve", %{"review_requested_at" => ctx.upload}, @key)
    assert approve.status in 400..499

    assert undecided?(ctx.task)
    assert Repo.aggregate(Nonce, :count) == 0
  end

  describe "an approval's key is bound to its signature" do
    test "replays an identical approve", ctx do
      signed = signed_approval(ctx)

      first = ctx |> approve(body(signed), @key) |> json_response(200)
      assert first["data"]["review_status"] == "approved"

      # The response was lost: the app resends the same request.
      assert ctx |> approve(body(signed), @key) |> json_response(200) == first
      assert [_one] = approvals()
      assert nonce_count() == 1
    end

    test "treats a signature twin as a new request", ctx do
      signed = signed_approval(ctx)
      twin = signature_twin(signed["signature"])

      # The twin is a valid signature of the same message, in other bytes.
      refute twin == signed["signature"]

      assert ApprovalSignature.verify_signature(
               ctx.approval_key.public_key,
               signed["message"],
               twin
             )

      first = ctx |> approve(body(signed), @key) |> json_response(200)

      # Other signature bytes are another request: it runs, and is refused,
      # rather than being answered with the first 200 unchecked.
      assert %{"error" => "already_decided"} =
               ctx |> approve(%{body(signed) | "signature" => twin}, @key) |> json_response(409)

      # The first request is still replayed.
      assert ctx |> approve(body(signed), @key) |> json_response(200) == first
      assert [_one] = approvals()
      assert nonce_count() == 1
    end

    test "missing signature is a new request", ctx do
      signed = signed_approval(ctx)
      assert ctx |> approve(body(signed), @key) |> json_response(200)

      sent = body(signed)

      for resend <- [Map.delete(sent, "signature"), %{sent | "signature" => nil}] do
        assert %{"error" => "already_decided"} =
                 ctx |> approve(resend, @key) |> json_response(409)
      end

      assert [_one] = approvals()
      assert nonce_count() == 1
    end

    test "parallel identical retries approve once", ctx do
      signed = signed_approval(ctx)

      responses =
        1..2
        |> Enum.map(fn _n ->
          Elixir.Task.async(fn ->
            response = approve(ctx, body(signed), @key)
            {response.status, Jason.decode!(response.resp_body)}
          end)
        end)
        |> Enum.map(&Elixir.Task.await(&1, 10_000))

      assert [{200, first}, {200, first}] = responses
      assert first["data"]["review_status"] == "approved"
      assert [_one] = approvals()
      assert nonce_count() == 1
    end

    test "replay re-checks access", ctx do
      signed = signed_approval(ctx)
      assert ctx |> approve(body(signed), @key) |> json_response(200)

      # An identical retry is a replay, and the replay re-checks the plan: a
      # person whose Organization no longer includes the app is refused.
      organization = organization_fixture()
      organization_member_fixture(organization, ctx.user)
      enforce_plans()

      assert %{"error" => "plan_required"} =
               ctx |> approve(body(signed), @key) |> json_response(403)

      # And access: a task archived since is not found.
      from(t in Task, where: t.id == ^ctx.task.id)
      |> Repo.update_all(set: [archived_at: DateTime.utc_now(:second)])

      assert ctx |> approve(body(signed), @key) |> json_response(404)
      assert [_one] = approvals()
    end

    test "an identical approve past the key's 24 hours is not replayed", ctx do
      signed = signed_approval(ctx)
      assert ctx |> approve(body(signed), @key) |> json_response(200)

      Repo.update_all(Nonce, set: [expires_at: DateTime.add(DateTime.utc_now(:second), -1)])

      assert %{"error" => "already_decided"} =
               ctx |> approve(body(signed), @key) |> json_response(409)
    end
  end
end
