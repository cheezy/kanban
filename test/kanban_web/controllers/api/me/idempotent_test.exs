defmodule KanbanWeb.API.Me.IdempotentTest do
  @moduledoc """
  `KanbanWeb.API.Me.Idempotent` binds an `Idempotency-Key` to the body fields
  of the decision it was sent with. A multipart body can carry a file part in
  one of those fields, a `%Plug.Upload{}` that cannot be JSON-encoded; with a
  key such a request must be refused as it is without one, never crash.
  """
  use KanbanWeb.ConnCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.DevicesFixtures
  import Kanban.TasksFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.Devices.Nonce
  alias Kanban.Repo
  alias Kanban.Tasks
  alias Kanban.Tasks.Task

  @requested_at ~U[2026-11-18 09:30:00Z]
  @stamp "2026-11-18T09:30:00Z"
  @key "7d1c2b3a-4e5f-4a6b-8c7d-9e0f1a2b3c4d"

  setup do
    user = user_fixture()
    {_device, tokens} = device_with_tokens_fixture(Scope.for_user(user))
    review = user |> board_fixture() |> column_fixture(%{name: "Review", position: 1})

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

    %{token: tokens.access_token, task: task, upload: upload}
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
end
