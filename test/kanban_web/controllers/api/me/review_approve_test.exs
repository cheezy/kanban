defmodule KanbanWeb.API.Me.ReviewApproveTest do
  # async: false - some tests switch the global :plans_enforced application env
  # on, and one approves from two processes at once.
  use KanbanWeb.ConnCase, async: false

  import Ecto.Query
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.DevicesFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.PlansHelpers
  import Kanban.TasksFixtures
  import Kanban.TelemetryHelpers

  alias Kanban.Accounts.Scope
  alias Kanban.AuditLog
  alias Kanban.Boards
  alias Kanban.Repo
  alias Kanban.Reviews.Approval
  alias Kanban.Reviews.ApprovalChallenge
  alias Kanban.Tasks
  alias Kanban.Tasks.Task

  @requested_at ~U[2026-11-18 09:30:00Z]

  setup do
    user = user_fixture()
    scope = Scope.for_user(user)
    phone_key = approval_keypair_fixture()
    tablet_key = approval_keypair_fixture()

    {phone, phone_tokens} =
      device_with_tokens_fixture(scope, %{
        device_class: :phone,
        approval_public_key: phone_key.public_key
      })

    {tablet, tablet_tokens} =
      device_with_tokens_fixture(scope, %{
        platform: :android,
        client_id: "stride-android",
        device_class: :tablet,
        approval_public_key: tablet_key.public_key
      })

    board = board_fixture(user)
    review = column_fixture(board, %{name: "Review", position: 1})
    done = column_fixture(board, %{name: "Done", position: 2})

    %{
      user: user,
      board: board,
      review: review,
      done: done,
      phone: %{device: phone, token: phone_tokens.access_token, key: phone_key},
      tablet: %{device: tablet, token: tablet_tokens.access_token, key: tablet_key}
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

  defp post_json(token, path, body) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
  end

  defp challenge(device, task_id, body \\ %{}),
    do: post_json(device.token, "/api/me/reviews/#{task_id}/approval_challenge", body)

  defp approve(device, task_id, body),
    do: post_json(device.token, "/api/me/reviews/#{task_id}/approve", body)

  defp challenge!(device, task_id) do
    device |> challenge(task_id) |> json_response(201) |> Map.fetch!("data")
  end

  # What the app does: sign the canonical string built from the challenge.
  defp signed(device, %{"nonce" => nonce, "task_id" => task_id} = data) do
    message = Approval.signing_string(nonce, task_id, parse(data["review_requested_at"]))

    %{
      "review_requested_at" => data["review_requested_at"],
      "nonce" => nonce,
      "signature" => sign_approval(device.key.private_key, message)
    }
  end

  defp parse(""), do: nil

  defp parse(value) do
    {:ok, at, 0} = DateTime.from_iso8601(value)
    at
  end

  defp rows(action), do: AuditLog.list_events([action: action], order: :asc)

  defp into_org_workspace!(user, board) do
    organization = organization_fixture()
    organization_member_fixture(organization, user)
    workspace = Kanban.WorkspacesFixtures.org_workspace_fixture(organization)
    board |> Ecto.Changeset.change(workspace_id: workspace.id) |> Repo.update!()
  end

  describe "POST /api/me/reviews/:task_id/approval_challenge and /approve" do
    test "approves with a valid signature and moves the task to Done", ctx do
      task = pending_task!(ctx.review)
      data = challenge!(ctx.phone, task.id)

      assert data["nonce"] =~ ~r/\Asdan_[A-Za-z0-9_-]{43}\z/
      assert data["task_id"] == task.id
      assert data["review_requested_at"] == "2026-11-18T09:30:00Z"
      assert data["decision"] == "approve"
      assert data["signing_version"] == "stride-approval-v1"
      assert {:ok, _expires, 0} = DateTime.from_iso8601(data["expires_at"])

      assert %{"data" => approved} =
               ctx.phone |> approve(task.id, signed(ctx.phone, data)) |> json_response(200)

      assert approved["task_id"] == task.id
      assert approved["identifier"] == task.identifier
      assert approved["review_status"] == "approved"
      assert approved["reviewed_at"]

      stored = Repo.get!(Task, task.id)
      assert stored.review_status == :approved
      assert stored.column_id == ctx.done.id

      # Only the nonce's hash is stored.
      refute ApprovalChallenge |> where([c], c.nonce_hash == ^data["nonce"]) |> Repo.exists?()
    end

    test "answers 409 already_decided and 409 resubmitted", ctx do
      ctx.user |> Ecto.Changeset.change(name: "Sam Rivera") |> Repo.update!()
      task = pending_task!(ctx.review)
      first = challenge!(ctx.phone, task.id)
      second = challenge!(ctx.tablet, task.id)

      assert ctx.phone |> approve(task.id, signed(ctx.phone, first)) |> json_response(200)

      assert %{
               "error" => "already_decided",
               "message" => _,
               "review" => %{
                 "task_id" => task_id,
                 "review_status" => "approved",
                 "reviewed_by" => reviewer,
                 "reviewed_at" => reviewed_at
               }
             } = ctx.tablet |> approve(task.id, signed(ctx.tablet, second)) |> json_response(409)

      assert task_id == task.id
      assert reviewer == "Sam Rivera"
      assert reviewed_at

      # Challenge requested, the task resubmitted, then approve.
      resubmitted = pending_task!(ctx.review)
      data = challenge!(ctx.phone, resubmitted.id)

      resubmitted
      |> Ecto.Changeset.change(review_requested_at: ~U[2026-11-18 10:00:00Z])
      |> Repo.update!()

      assert %{"error" => "resubmitted", "review" => %{"review_requested_at" => stamp}} =
               ctx.phone |> approve(resubmitted.id, signed(ctx.phone, data)) |> json_response(409)

      assert stamp == "2026-11-18T10:00:00Z"

      # Signing the new stamp with the old nonce does not help: the nonce was
      # bound to the old one.
      new_stamp = %{data | "review_requested_at" => "2026-11-18T10:00:00Z"}

      assert %{"error" => "signature_rejected", "reason" => "invalid"} =
               ctx.phone
               |> approve(resubmitted.id, signed(ctx.phone, new_stamp))
               |> json_response(422)

      assert Repo.get!(Task, resubmitted.id).review_status in [nil, :pending]
    end

    test "a phone gets 422 too_large_for_phone at 11 files and a tablet approves", ctx do
      attach_telemetry([:kanban, :review, :phone_approval_refused])
      large = pending_task!(ctx.review, change_of(11, 11))

      assert %{
               "error" => "too_large_for_phone",
               "size" => %{"files" => 11, "changed_lines" => 11, "truncated" => false},
               "limits" => %{"max_files" => 10, "max_changed_lines" => 500}
             } = ctx.phone |> challenge(large.id) |> json_response(422)

      assert_received {:telemetry_event, [:kanban, :review, :phone_approval_refused],
                       %{count: 1, files: 11, changed_lines: 11}, metadata}

      assert metadata == %{task_id: large.id, board_id: ctx.board.id}

      # A modified app that skips the challenge is refused at approve too.
      assert %{"error" => "too_large_for_phone"} =
               ctx.phone
               |> approve(large.id, %{"review_requested_at" => "2026-11-18T09:30:00Z"})
               |> json_response(422)

      data = challenge!(ctx.tablet, large.id)
      assert ctx.tablet |> approve(large.id, signed(ctx.tablet, data)) |> json_response(200)

      # Exactly 10 files and 500 lines is within a phone's limit.
      at_limit = pending_task!(ctx.review, change_of(10, 500))
      data = challenge!(ctx.phone, at_limit.id)
      assert ctx.phone |> approve(at_limit.id, signed(ctx.phone, data)) |> json_response(200)
    end

    test "a missing, wrong, reused or expired signature is refused with an audit row each",
         ctx do
      attach_telemetry([:kanban, :review, :approval_signature_rejected])
      task = pending_task!(ctx.review)
      data = challenge!(ctx.phone, task.id)
      good = signed(ctx.phone, data)

      # Missing.
      for body <- [
            Map.delete(good, "signature"),
            Map.delete(good, "nonce"),
            %{good | "signature" => ""}
          ] do
        assert %{"error" => "signature_rejected", "reason" => "missing"} =
                 ctx.phone |> approve(task.id, body) |> json_response(422)
      end

      # Wrong: another key, a tampered signature, an unknown nonce.
      other = approval_keypair_fixture()
      message = Approval.signing_string(data["nonce"], task.id, @requested_at)

      for body <- [
            %{good | "signature" => sign_approval(other.private_key, message)},
            %{good | "signature" => "AAAA"},
            %{good | "nonce" => "sdan_" <> String.duplicate("x", 43)}
          ] do
        assert %{"error" => "signature_rejected", "reason" => "invalid"} =
                 ctx.phone |> approve(task.id, body) |> json_response(422)
      end

      # Expired.
      expired_data = challenge!(ctx.phone, task.id)

      ApprovalChallenge
      |> where([c], c.expires_at > ^DateTime.utc_now())
      |> Repo.update_all(set: [expires_at: ~U[2026-01-01 00:00:00Z]])

      assert %{"reason" => "expired"} =
               ctx.phone
               |> approve(task.id, signed(ctx.phone, expired_data))
               |> json_response(422)

      # Reused: a nonce consumed by an approval is refused once the same
      # review is back in Review.
      fresh = challenge!(ctx.phone, task.id)
      fresh_body = signed(ctx.phone, fresh)
      assert ctx.phone |> approve(task.id, fresh_body) |> json_response(200)

      task
      |> Repo.reload!()
      |> Ecto.Changeset.change(review_status: nil, column_id: ctx.review.id)
      |> Repo.update!()

      assert %{"reason" => "reused"} =
               ctx.phone |> approve(task.id, fresh_body) |> json_response(422)

      reasons = :approval_signature_rejected |> rows() |> Enum.map(& &1.metadata["reason"])

      assert reasons ==
               List.duplicate("missing", 3) ++
                 List.duplicate("invalid", 3) ++ ["expired", "reused"]

      [row | _] = rows(:approval_signature_rejected)

      assert row.metadata == %{
               "user_id" => ctx.user.id,
               "task_id" => task.id,
               "board_id" => ctx.board.id,
               "device_id" => ctx.phone.device.id,
               "device_class" => "phone",
               "reason" => "missing"
             }

      for row <- rows(:approval_signature_rejected) do
        refute inspect(row) =~ data["nonce"]
        refute inspect(row) =~ good["signature"]
      end

      assert_received {:telemetry_event, [:kanban, :review, :approval_signature_rejected],
                       %{count: 1}, metadata}

      assert metadata == %{
               task_id: task.id,
               board_id: ctx.board.id,
               device_class: :phone,
               reason: :missing
             }
    end

    test "two devices approving at once: one succeeds, one gets 409", ctx do
      task = pending_task!(ctx.review)
      phone_body = signed(ctx.phone, challenge!(ctx.phone, task.id))
      tablet_body = signed(ctx.tablet, challenge!(ctx.tablet, task.id))

      statuses =
        [{ctx.phone, phone_body}, {ctx.tablet, tablet_body}]
        |> Enum.map(fn {device, body} ->
          Elixir.Task.async(fn -> approve(device, task.id, body).status end)
        end)
        |> Enum.map(&Elixir.Task.await(&1, 10_000))
        |> Enum.sort()

      assert statuses == [200, 409]
      assert [_one] = rows(:review_approved)
    end

    test "the audit row has via, device_class and approval_key true", ctx do
      task = pending_task!(ctx.review)
      data = challenge!(ctx.tablet, task.id)
      assert ctx.tablet |> approve(task.id, signed(ctx.tablet, data)) |> json_response(200)

      assert [%{metadata: metadata}] = rows(:review_approved)

      assert %{
               "via" => "android",
               "device_class" => "tablet",
               "device_id" => device_id,
               "approval_key" => true
             } = metadata

      assert device_id == ctx.tablet.device.id
    end

    test "a nonce issued for another task or device is refused", ctx do
      task = pending_task!(ctx.review)
      other_task = pending_task!(ctx.review)

      # The tablet's nonce, signed with the phone's key, sent by the phone.
      tablet_nonce = challenge!(ctx.tablet, task.id)

      assert %{"reason" => "invalid"} =
               ctx.phone
               |> approve(task.id, signed(ctx.phone, tablet_nonce))
               |> json_response(422)

      # A nonce for another task, re-signed for this one.
      other_nonce = challenge!(ctx.phone, other_task.id)

      assert %{"reason" => "invalid"} =
               ctx.phone
               |> approve(task.id, signed(ctx.phone, %{other_nonce | "task_id" => task.id}))
               |> json_response(422)

      assert Repo.get!(Task, task.id).review_status in [nil, :pending]
      assert Repo.get!(ApprovalChallenge, tablet_nonce_id(tablet_nonce)).used_at == nil
    end

    test "work resubmitted inside the same second is not approved with the earlier nonce", ctx do
      task = pending_task!(ctx.review, %{completion_summary: "first submission"})
      data = challenge!(ctx.phone, task.id)

      # The same review_requested_at, different work: what a second complete in
      # the same second leaves behind.
      task |> Ecto.Changeset.change(completion_summary: "second submission") |> Repo.update!()

      assert %{"error" => "signature_rejected", "reason" => "invalid"} =
               ctx.phone |> approve(task.id, signed(ctx.phone, data)) |> json_response(422)

      assert Repo.get!(Task, task.id).review_status in [nil, :pending]
      assert [%{metadata: %{"reason" => "invalid"}}] = rows(:approval_signature_rejected)

      # A fresh challenge for the work as it is now approves it.
      fresh = challenge!(ctx.phone, task.id)
      assert ctx.phone |> approve(task.id, signed(ctx.phone, fresh)) |> json_response(200)
    end

    test "a task with no review_requested_at takes it back as null or an empty string", ctx do
      for sent <- [nil, ""] do
        task = pending_task!(ctx.review, %{review_requested_at: nil})

        assert %{"review_requested_at" => ""} =
                 data =
                 ctx.phone
                 |> challenge(task.id, %{"review_requested_at" => sent})
                 |> json_response(201)
                 |> Map.fetch!("data")

        body = %{signed(ctx.phone, data) | "review_requested_at" => sent}
        assert ctx.phone |> approve(task.id, body) |> json_response(200)
      end
    end

    test "a task archived after the challenge answers 404 and stays unapproved", ctx do
      task = pending_task!(ctx.review)
      data = challenge!(ctx.phone, task.id)
      task |> Ecto.Changeset.change(archived_at: ~U[2026-11-18 09:40:00Z]) |> Repo.update!()

      assert ctx.phone |> approve(task.id, signed(ctx.phone, data)) |> json_response(404) ==
               %{"error" => "Not Found"}

      assert Repo.get!(Task, task.id).review_status in [nil, :pending]
    end

    test "plan_required on a free board", ctx do
      task = pending_task!(ctx.review)
      organization = organization_fixture()
      organization_member_fixture(organization, ctx.user)
      enforce_plans()

      for response <- [
            challenge(ctx.phone, task.id),
            approve(ctx.phone, task.id, %{"review_requested_at" => "2026-11-18T09:30:00Z"})
          ] do
        assert json_response(response, 403) == %{
                 "error" => "plan_required",
                 "feature" => "mobile_app",
                 "message" => "The Stride app is available to boards in an Organization."
               }
      end

      assert Repo.aggregate(ApprovalChallenge, :count) == 0
    end

    test "under enforcement, a board in the person's Organization approves", ctx do
      task = pending_task!(ctx.review)
      into_org_workspace!(ctx.user, ctx.board)
      enforce_plans()

      data = challenge!(ctx.phone, task.id)
      assert ctx.phone |> approve(task.id, signed(ctx.phone, data)) |> json_response(200)
    end

    test "write access removed between challenge and approve answers 404 with no review state",
         ctx do
      owner = user_fixture()
      shared = board_fixture(owner)
      shared_review = column_fixture(shared, %{name: "Review"})
      {:ok, _} = Boards.add_user_to_board(shared, ctx.user, :modify, owner)
      task = pending_task!(shared_review)
      data = challenge!(ctx.phone, task.id)

      {:ok, _} = Boards.update_user_access(shared, ctx.user, :read_only, owner)

      for response <- [
            approve(ctx.phone, task.id, signed(ctx.phone, data)),
            challenge(ctx.phone, task.id)
          ] do
        assert json_response(response, 404) == %{"error" => "Not Found"}
      end
    end

    test "rights lost between challenge and approve: removed from the board or the task moved",
         ctx do
      owner = user_fixture()
      shared = board_fixture(owner)
      shared_review = column_fixture(shared, %{name: "Review", position: 1})
      _shared_done = column_fixture(shared, %{name: "Done", position: 2})
      {:ok, _} = Boards.add_user_to_board(shared, ctx.user, :modify, owner)
      removed = pending_task!(shared_review)
      removed_data = challenge!(ctx.phone, removed.id)
      {:ok, _} = Boards.remove_user_from_board(shared, ctx.user, owner)

      doing = column_fixture(ctx.board, %{name: "Doing", position: 3})
      moved = pending_task!(ctx.review)
      moved_data = challenge!(ctx.phone, moved.id)
      moved |> Ecto.Changeset.change(column_id: doing.id) |> Repo.update!()

      # Removed from the board: the task is no longer theirs to see.
      assert ctx.phone
             |> approve(removed.id, signed(ctx.phone, removed_data))
             |> json_response(404) == %{"error" => "Not Found"}

      # Pulled out of Review: still visible, no longer pending, so the state
      # check answers 409 with the task as it is now.
      assert %{"error" => "already_decided", "review" => %{"review_status" => nil}} =
               ctx.phone |> approve(moved.id, signed(ctx.phone, moved_data)) |> json_response(409)

      for task <- [removed, moved] do
        stored = Repo.get!(Task, task.id)
        assert stored.review_status in [nil, :pending]
        assert stored.reviewed_at == nil
      end

      assert Repo.get!(Task, moved.id).column_id == doing.id
      assert rows(:review_approved) == []
    end

    test "a board with no Done column answers 422 approval_failed column_not_found", ctx do
      bare = board_fixture(ctx.user)
      bare_review = column_fixture(bare, %{name: "Review", position: 1})
      task = pending_task!(bare_review)
      data = challenge!(ctx.phone, task.id)

      assert ctx.phone |> approve(task.id, signed(ctx.phone, data)) |> json_response(422) == %{
               "error" => "approval_failed",
               "reason" => "column_not_found"
             }

      stored = Repo.get!(Task, task.id)
      assert stored.review_status in [nil, :pending]
      assert stored.column_id == bare_review.id
      assert rows(:review_approved) == []

      # A Done column spelled another way is found.
      done = column_fixture(bare, %{name: " DONE", position: 2})
      data = challenge!(ctx.phone, task.id)
      assert ctx.phone |> approve(task.id, signed(ctx.phone, data)) |> json_response(200)
      assert Repo.get!(Task, task.id).column_id == done.id
    end

    test "a phone is refused a change it cannot count or that is over 10 files (D454)", ctx do
      eleven = Enum.map_join(1..11, "\n", &"lib/f#{&1}.ex")

      for listed <- [
            eleven,
            "lib/a.ex; lib/b.ex lib/c.ex\nlib/d.ex lib/e.ex lib/f.ex lib/g.ex lib/h.ex lib/i.ex lib/j.ex lib/k.ex",
            "14 files"
          ] do
        task = pending_task!(ctx.review, %{actual_files_changed: listed})

        detail =
          build_conn()
          |> put_req_header("authorization", "Bearer " <> ctx.phone.token)
          |> get("/api/me/reviews/#{task.id}")
          |> json_response(200)
          |> Map.fetch!("data")

        assert detail["approvable_here"] == false, "expected #{inspect(listed)} not approvable"

        assert %{"error" => "too_large_for_phone"} =
                 ctx.phone |> challenge(task.id) |> json_response(422)

        assert %{"error" => "too_large_for_phone"} =
                 ctx.phone
                 |> approve(task.id, %{"review_requested_at" => "2026-11-18T09:30:00Z"})
                 |> json_response(422)
      end

      # Ten files, one of them listed twice under another spelling, is ten.
      ten = Enum.map_join(1..10, "\n", &"lib/f#{&1}.ex") <> "\n./lib/f1.ex"
      task = pending_task!(ctx.review, %{actual_files_changed: ten})
      data = challenge!(ctx.phone, task.id)
      assert ctx.phone |> approve(task.id, signed(ctx.phone, data)) |> json_response(200)
    end

    test "a task the person cannot see and ids that are not one are 404", ctx do
      owner = user_fixture()
      hidden_board = board_fixture(owner)
      hidden = pending_task!(column_fixture(hidden_board, %{name: "Review"}))

      for id <- [hidden.id, "abc", "0", "99999999999999999999"] do
        assert ctx.phone |> challenge(id) |> json_response(404) == %{"error" => "Not Found"}

        assert ctx.phone
               |> approve(id, %{"review_requested_at" => "2026-11-18T09:30:00Z"})
               |> json_response(404) == %{"error" => "Not Found"}
      end
    end

    test "a missing review_requested_at is a 400", ctx do
      task = pending_task!(ctx.review)

      assert %{"error" => "Bad Request"} =
               ctx.phone |> approve(task.id, %{"nonce" => "x"}) |> json_response(400)
    end
  end

  defp tablet_nonce_id(%{"nonce" => nonce}) do
    hash = Kanban.Devices.DeviceToken.hash_token(nonce)

    ApprovalChallenge
    |> where([c], c.nonce_hash == ^hash)
    |> select([c], c.id)
    |> Repo.one!()
  end
end

defmodule KanbanWeb.API.Me.ReviewApproveRateLimitTest do
  # Not async: it turns the global rate limiter on with a small limit.
  use KanbanWeb.ConnCase, async: false

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.DevicesFixtures
  import Kanban.TasksFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.Repo
  alias Kanban.Reviews.ApprovalChallenge

  setup do
    original = Application.get_env(:kanban, Kanban.RateLimit)

    Application.put_env(:kanban, Kanban.RateLimit,
      enabled: true,
      review_approval: %{scale_ms: 60_000, id_limit: 2}
    )

    on_exit(fn -> Application.put_env(:kanban, Kanban.RateLimit, original) end)

    scope = Scope.for_user(user_fixture())
    board = board_fixture(scope.user)
    task = column_fixture(board, %{name: "Review"}) |> task_fixture(%{title: "Limit me"})
    {_phone, phone} = device_with_tokens_fixture(scope, %{device_class: :phone})
    {_tablet, tablet} = device_with_tokens_fixture(scope, %{device_class: :tablet})

    %{task: task, phone: phone.access_token, tablet: tablet.access_token}
  end

  defp post_json(token, path, body \\ %{}) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
  end

  test "the challenge and the approval share a per-device limit and answer 429", ctx do
    challenge = "/api/me/reviews/#{ctx.task.id}/approval_challenge"
    approve = "/api/me/reviews/#{ctx.task.id}/approve"

    # Two requests of either kind use the device's limit; the task is not
    # pending review, so each is refused without a challenge being issued.
    assert ctx.phone |> post_json(challenge) |> json_response(409)
    assert ctx.phone |> post_json(approve, %{"review_requested_at" => nil}) |> json_response(409)

    for path <- [challenge, approve] do
      conn = post_json(ctx.phone, path)

      assert json_response(conn, 429) == %{
               "error" => "rate_limited",
               "message" => "Too many requests. Try again later."
             }

      assert [retry_after] = get_resp_header(conn, "retry-after")
      assert String.to_integer(retry_after) > 0
    end

    # Another device of the same person is not affected.
    assert ctx.tablet |> post_json(challenge) |> json_response(409)
    assert Repo.aggregate(ApprovalChallenge, :count) == 0
  end
end
