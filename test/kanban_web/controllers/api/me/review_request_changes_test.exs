defmodule KanbanWeb.API.Me.ReviewRequestChangesTest do
  # async: false - some tests switch the global :plans_enforced application env
  # on, and some send requests from two processes at once.
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
  alias Kanban.Tasks
  alias Kanban.Tasks.Task
  alias KanbanWeb.API.Me.Idempotent

  @requested_at ~U[2026-11-18 09:30:00Z]
  @stamp "2026-11-18T09:30:00Z"
  @notes "Handle the empty member list before showing the table."
  @key "4f8e2a6c-1b3d-4e5f-8a7b-9c0d1e2f3a4b"

  setup do
    user = user_fixture()
    scope = Scope.for_user(user)
    phone_key = approval_keypair_fixture()

    {phone, phone_tokens} =
      device_with_tokens_fixture(scope, %{
        device_class: :phone,
        approval_public_key: phone_key.public_key
      })

    {tablet, tablet_tokens} =
      device_with_tokens_fixture(scope, %{
        platform: :android,
        client_id: "stride-android",
        device_class: :tablet
      })

    board = board_fixture(user)
    review = column_fixture(board, %{name: "Review", position: 1})
    _done = column_fixture(board, %{name: "Done", position: 2})

    %{
      user: user,
      board: board,
      review: review,
      phone: %{device: phone, token: phone_tokens.access_token, key: phone_key},
      tablet: %{device: tablet, token: tablet_tokens.access_token}
    }
  end

  defp pending_task!(column, attrs \\ %{}) do
    {:ok, task} =
      column
      |> task_fixture(%{title: "Show the member list"})
      |> Tasks.update_task(%{needs_review: true, completed_by_agent: "Claude"})

    task
    |> Ecto.Changeset.change(Map.merge(%{review_requested_at: @requested_at}, attrs))
    |> Repo.update!()
  end

  defp entry(path, lines),
    do: %{"path" => path, "diff" => Enum.map_join(1..lines//1, "\n", &"+line #{&1}")}

  # `files` files sharing `lines` added lines between them.
  defp change_of(files, lines) do
    per_file = div(lines, files)
    extra = lines - per_file * files

    %{
      changed_files:
        Enum.map(1..files, fn n ->
          entry("lib/f#{n}.ex", per_file + if(n == 1, do: extra, else: 0))
        end)
    }
  end

  defp post_json(token, path, body, key) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
    |> with_key(key)
    |> post(path, Jason.encode!(body))
  end

  defp with_key(conn, nil), do: conn

  defp with_key(conn, keys) when is_list(keys),
    do: %{conn | req_headers: idem(keys) ++ conn.req_headers}

  defp with_key(conn, key), do: put_req_header(conn, "idempotency-key", key)

  defp idem(keys), do: Enum.map(keys, &{"idempotency-key", &1})

  defp request_changes(device, task_id, body, key \\ nil),
    do: post_json(device.token, "/api/me/reviews/#{task_id}/request_changes", body, key)

  defp body(notes \\ @notes), do: %{"review_requested_at" => @stamp, "notes" => notes}

  defp approve(device, task_id, body, key),
    do: post_json(device.token, "/api/me/reviews/#{task_id}/approve", body, key)

  defp signed_approval(device, task_id) do
    %{"data" => %{"nonce" => nonce}} =
      device.token
      |> post_json("/api/me/reviews/#{task_id}/approval_challenge", %{}, nil)
      |> json_response(201)

    message = Approval.signing_string(nonce, task_id, @requested_at)

    %{
      "review_requested_at" => @stamp,
      "nonce" => nonce,
      "signature" => sign_approval(device.key.private_key, message)
    }
  end

  # Runs `fun` once, in the test process, right after its second query on
  # `tasks`: the approve request has read the pending task and not yet the
  # approval challenge.
  defp on_second_tasks_query(fun) do
    test_pid = self()
    handler_id = "second-tasks-query-#{System.unique_integer([:positive])}"
    seen = :counters.new(1, [])

    :telemetry.attach(
      handler_id,
      [:kanban, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        if self() == test_pid and metadata[:source] == "tasks" do
          :counters.add(seen, 1, 1)

          if :counters.get(seen, 1) == 2 do
            :telemetry.detach(handler_id)
            fun.()
          end
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp rows(action), do: AuditLog.list_events([action: action], order: :asc)
  defp nonce_count, do: Repo.aggregate(Nonce, :count)
  defp undecided?(task), do: Repo.get!(Task, task.id).review_status in [nil, :pending]

  describe "POST /api/me/reviews/:task_id/request_changes" do
    test "requests changes and leaves the task in Review", ctx do
      # A phone may ask for changes on a change too large for it to approve.
      task = pending_task!(ctx.review, change_of(14, 652))

      assert %{"data" => data} =
               ctx.phone |> request_changes(task.id, body()) |> json_response(200)

      assert data["task_id"] == task.id
      assert data["identifier"] == task.identifier
      assert data["review_status"] == "changes_requested"
      assert {:ok, _at, 0} = DateTime.from_iso8601(data["reviewed_at"])
      refute Map.has_key?(data, "notes")

      stored = Repo.get!(Task, task.id)
      assert stored.review_status == :changes_requested
      assert stored.review_notes == @notes
      assert stored.reviewed_by_id == ctx.user.id
      assert stored.column_id == ctx.review.id

      # Without a key nothing is stored.
      assert nonce_count() == 0
    end

    test "blank notes answer 422", ctx do
      task = pending_task!(ctx.review)

      for sent <- [body(""), body("   \n "), body(nil), body(42), Map.delete(body(), "notes")] do
        assert ctx.phone |> request_changes(task.id, sent, @key) |> json_response(422) ==
                 %{"errors" => %{"notes" => ["can't be blank"]}}
      end

      assert undecided?(task)
      assert rows(:review_changes_requested) == []
      assert nonce_count() == 0

      # A refused request stores nothing, so its retry with notes acts.
      assert ctx.phone |> request_changes(task.id, body(), @key) |> json_response(200)
    end

    test "notes with nothing visible in them answer 422, and a NUL byte is refused as notes",
         ctx do
      task = pending_task!(ctx.review)

      for invisible <- [
            "\u200B",
            "\u200C\u200D",
            "\uFEFF",
            "\u180E",
            "\u2060",
            "\u0301",
            " \u200B\n"
          ] do
        assert ctx.phone |> request_changes(task.id, body(invisible)) |> json_response(422) ==
                 %{"errors" => %{"notes" => ["can't be blank"]}}
      end

      assert ctx.phone |> request_changes(task.id, body("Fix\u0000 it")) |> json_response(422) ==
               %{"errors" => %{"notes" => ["contains characters that are not allowed"]}}

      assert undecided?(task)
      assert ctx.phone |> request_changes(task.id, body("Fix it \u{1F44D}")) |> json_response(200)
    end

    test "very long notes are accepted and never echoed or stored with the key", ctx do
      task = pending_task!(ctx.review)
      notes = String.duplicate("Explain the change. ", 5_000)

      response = ctx.phone |> request_changes(task.id, body(notes), @key)
      assert %{"data" => %{"review_status" => "changes_requested"}} = json_response(response, 200)
      refute response.resp_body =~ "Explain the change."

      assert Repo.get!(Task, task.id).review_notes == notes
      assert [%Nonce{response_body: stored}] = Repo.all(Nonce)
      refute Jason.encode!(stored) =~ "Explain the change."
    end

    test "409 resubmitted when review_requested_at differs", ctx do
      task = pending_task!(ctx.review)
      stale = %{body() | "review_requested_at" => "2026-11-18T09:00:00Z"}

      assert %{"error" => "resubmitted", "review" => %{"review_requested_at" => @stamp}} =
               ctx.phone |> request_changes(task.id, stale, @key) |> json_response(409)

      assert undecided?(task)
      assert nonce_count() == 0
    end

    test "409 already_decided once the review is decided", ctx do
      task = pending_task!(ctx.review)
      assert ctx.tablet |> request_changes(task.id, body()) |> json_response(200)

      assert %{"error" => "already_decided", "review" => %{"review_status" => status}} =
               ctx.phone |> request_changes(task.id, body()) |> json_response(409)

      assert status == "changes_requested"
      assert [_one] = rows(:review_changes_requested)
    end

    test "writes review_changes_requested with via and device_class", ctx do
      task = pending_task!(ctx.review)
      assert ctx.phone |> request_changes(task.id, body(), @key) |> json_response(200)

      assert [%{metadata: metadata} = row] = rows(:review_changes_requested)

      assert %{"via" => "ios", "device_class" => "phone", "device_id" => device_id} = metadata
      assert device_id == ctx.phone.device.id

      # Neither the notes nor the key reach the audit row.
      encoded = row |> Map.take([:metadata, :target_label]) |> Jason.encode!()
      refute encoded =~ @notes
      refute encoded =~ @key

      assert ctx.tablet
             |> request_changes(pending_task!(ctx.review).id, body())
             |> json_response(200)

      assert [_phone, %{metadata: %{"via" => "android", "device_class" => "tablet"}}] =
               rows(:review_changes_requested)
    end

    test "a missing review_requested_at is a 400", ctx do
      task = pending_task!(ctx.review)

      assert %{"error" => "Bad Request"} =
               ctx.phone
               |> request_changes(task.id, %{"notes" => @notes})
               |> json_response(400)

      assert undecided?(task)
    end

    test "a task the person cannot see, an archived task and ids that are not one are 404",
         ctx do
      hidden = pending_task!(column_fixture(board_fixture(user_fixture()), %{name: "Review"}))

      archived = pending_task!(ctx.review)
      archived |> Ecto.Changeset.change(archived_at: DateTime.utc_now(:second)) |> Repo.update!()

      for id <- [hidden.id, archived.id, "abc", "0"] do
        # 404 wins over the blank notes: a 422 never reveals the task.
        assert ctx.phone |> request_changes(id, body("")) |> json_response(404) ==
                 %{"error" => "Not Found"}
      end

      assert undecided?(hidden)
    end

    test "plan_required on a free board", ctx do
      task = pending_task!(ctx.review)
      organization = organization_fixture()
      organization_member_fixture(organization, ctx.user)
      enforce_plans()

      assert ctx.phone |> request_changes(task.id, body()) |> json_response(403) == %{
               "error" => "plan_required",
               "feature" => "mobile_app",
               "message" => "The Stride app is available to boards in an Organization."
             }

      assert undecided?(task)
    end
  end

  describe "Idempotency-Key" do
    test "a retried approve with the same key returns the first 200, not 409", ctx do
      task = pending_task!(ctx.review)
      signed = signed_approval(ctx.phone, task.id)

      first = ctx.phone |> approve(task.id, signed, @key) |> json_response(200)
      assert first["data"]["review_status"] == "approved"

      # The response was lost: the app retries the same request.
      assert ctx.phone |> approve(task.id, signed, @key) |> json_response(200) == first
      assert [_one] = rows(:review_approved)
      assert nonce_count() == 1

      # Without the key, or with another, the retry is the 409 it always was.
      assert %{"error" => "already_decided"} =
               ctx.phone |> approve(task.id, signed, nil) |> json_response(409)

      assert %{"error" => "already_decided"} =
               ctx.phone |> approve(task.id, signed, "another-key") |> json_response(409)
    end

    test "a retried request for changes with the same key returns the first 200", ctx do
      task = pending_task!(ctx.review)
      first = ctx.phone |> request_changes(task.id, body(), @key) |> json_response(200)

      assert ctx.phone |> request_changes(task.id, body(), @key) |> json_response(200) == first

      # The key is bound to the notes it was sent with: other notes are a new
      # request, refused as already decided rather than answered with the
      # first 200 while they are dropped.
      assert %{"error" => "already_decided"} =
               ctx.phone
               |> request_changes(task.id, body("Other notes"), @key)
               |> json_response(409)

      assert Repo.get!(Task, task.id).review_notes == @notes
      assert [_one] = rows(:review_changes_requested)
    end

    test "a stored result is not replayed to a person who lost access or the plan", ctx do
      task = pending_task!(ctx.review)
      ctx.phone |> request_changes(task.id, body(), @key) |> json_response(200)

      organization = organization_fixture()
      organization_member_fixture(organization, ctx.user)
      enforce_plans()

      assert %{"error" => "plan_required"} =
               ctx.phone |> request_changes(task.id, body(), @key) |> json_response(403)

      from(t in Task, where: t.id == ^task.id)
      |> Repo.update_all(set: [archived_at: DateTime.utc_now(:second)])

      assert ctx.phone |> request_changes(task.id, body(), @key) |> json_response(404)
    end

    test "two parallel requests with one key run the action once", ctx do
      task = pending_task!(ctx.review)

      bodies =
        1..2
        |> Enum.map(fn _n ->
          Elixir.Task.async(fn ->
            response = request_changes(ctx.phone, task.id, body(), @key)
            {response.status, Jason.decode!(response.resp_body)}
          end)
        end)
        |> Enum.map(&Elixir.Task.await(&1, 10_000))

      assert [{200, first}, {200, first}] = bodies
      assert first["data"]["review_status"] == "changes_requested"
      assert [_one] = rows(:review_changes_requested)
      assert nonce_count() == 1
    end

    test "an approve retry racing the first commit is a replay or a 409, never a rejected signature",
         ctx do
      for {key, expected} <- [{@key, :replay}, {nil, :conflict}] do
        task = pending_task!(ctx.review)
        signed = signed_approval(ctx.phone, task.id)
        first = make_ref()

        # The first request commits after the retry has read the pending task
        # and before it reads the nonce.
        on_second_tasks_query(fn ->
          response =
            fn -> approve(ctx.phone, task.id, signed, key) end
            |> Elixir.Task.async()
            |> Elixir.Task.await()

          send(self(), {first, json_response(response, 200)})
        end)

        retry = approve(ctx.phone, task.id, signed, key)
        assert_received {^first, approved}

        case expected do
          :replay -> assert json_response(retry, 200) == approved
          :conflict -> assert %{"error" => "already_decided"} = json_response(retry, 409)
        end

        assert rows(:approval_signature_rejected) == []
      end

      assert length(rows(:review_approved)) == 2
    end

    test "a key reused for another task acts anew and never returns the other result", ctx do
      first_task = pending_task!(ctx.review)
      second_task = pending_task!(ctx.review)

      first = ctx.phone |> request_changes(first_task.id, body(), @key) |> json_response(200)
      second = ctx.phone |> request_changes(second_task.id, body(), @key) |> json_response(200)

      assert first["data"]["task_id"] == first_task.id
      assert second["data"]["task_id"] == second_task.id
      assert length(rows(:review_changes_requested)) == 2

      # The same key for the other decision on a decided task is not a replay.
      assert %{"error" => "already_decided"} =
               ctx.phone
               |> approve(first_task.id, %{"review_requested_at" => @stamp}, @key)
               |> json_response(409)
    end

    test "the same key from another device is not a replay", ctx do
      task = pending_task!(ctx.review)
      assert ctx.phone |> request_changes(task.id, body(), @key) |> json_response(200)

      assert %{"error" => "already_decided"} =
               ctx.tablet |> request_changes(task.id, body(), @key) |> json_response(409)
    end

    test "a stored result past its 24 hours is not replayed", ctx do
      task = pending_task!(ctx.review)
      assert ctx.phone |> request_changes(task.id, body(), @key) |> json_response(200)

      Repo.update_all(Nonce, set: [expires_at: DateTime.add(DateTime.utc_now(:second), -1)])

      assert %{"error" => "already_decided"} =
               ctx.phone |> request_changes(task.id, body(), @key) |> json_response(409)
    end

    test "an empty, malformed or repeated key is a 400 and nothing runs", ctx do
      task = pending_task!(ctx.review)

      for key <- ["", String.duplicate("k", 256), "has space", ["one", "two"]] do
        assert ctx.phone |> request_changes(task.id, body(), key) |> json_response(400) ==
                 %{"error" => "Bad Request", "message" => Idempotent.bad_key_message()}

        assert ctx.phone |> approve(task.id, %{}, key) |> json_response(400) ==
                 %{"error" => "Bad Request", "message" => Idempotent.bad_key_message()}
      end

      assert undecided?(task)
      assert nonce_count() == 0
    end
  end
end

defmodule KanbanWeb.API.Me.ReviewRequestChangesRateLimitTest do
  # Not async: it turns the global rate limiter on with a small limit.
  use KanbanWeb.ConnCase, async: false

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.DevicesFixtures
  import Kanban.TasksFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.Devices.Nonce
  alias Kanban.Repo

  setup do
    original = Application.get_env(:kanban, Kanban.RateLimit)

    Application.put_env(:kanban, Kanban.RateLimit,
      enabled: true,
      review_approval: %{scale_ms: 60_000, id_limit: 1}
    )

    on_exit(fn -> Application.put_env(:kanban, Kanban.RateLimit, original) end)

    scope = Scope.for_user(user_fixture())
    board = board_fixture(scope.user)
    task = column_fixture(board, %{name: "Review"}) |> task_fixture(%{title: "Limit me"})
    {_phone, phone} = device_with_tokens_fixture(scope, %{device_class: :phone})

    %{task: task, phone: phone.access_token}
  end

  test "request changes shares the approval's per-device limit and a 429 is not stored", ctx do
    path = "/api/me/reviews/#{ctx.task.id}/request_changes"

    post = fn ->
      build_conn()
      |> put_req_header("authorization", "Bearer " <> ctx.phone)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("idempotency-key", "limit-key")
      |> post(path, Jason.encode!(%{"review_requested_at" => nil, "notes" => "Fix it"}))
    end

    # The task is not pending review, so the first is refused without acting.
    assert post.() |> json_response(409)
    limited = post.()
    assert json_response(limited, 429)["error"] == "rate_limited"
    assert [_seconds] = get_resp_header(limited, "retry-after")
    assert Repo.aggregate(Nonce, :count) == 0
  end
end
