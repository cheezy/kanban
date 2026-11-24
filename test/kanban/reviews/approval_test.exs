defmodule Kanban.Reviews.ApprovalTest do
  # async: false - one test switches the global :plans_enforced application env on.
  use Kanban.DataCase, async: false
  use Oban.Testing, repo: Kanban.Repo

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
  alias Kanban.Boards
  alias Kanban.Reviews.Approval
  alias Kanban.Reviews.ApprovalChallenge
  alias Kanban.Reviews.ApprovalChallengePurgeWorker
  alias Kanban.Tasks

  @requested_at ~U[2026-11-18 09:30:00Z]
  @requested_param "2026-11-18T09:30:00Z"

  setup do
    user = user_fixture()
    scope = Scope.for_user(user)
    board = board_fixture(user)
    review = column_fixture(board, %{name: "Review", position: 1})
    _done = column_fixture(board, %{name: "Done", position: 2})
    key = approval_keypair_fixture()
    phone = device_fixture(scope, %{device_class: :phone, approval_public_key: key.public_key})

    %{user: user, scope: scope, board: board, review: review, key: key, phone: phone}
  end

  defp pending_task!(column, attrs \\ %{}) do
    {:ok, task} =
      column
      |> task_fixture(%{title: "Approve me"})
      |> Tasks.update_task(%{needs_review: true, completed_by_agent: "Claude"})

    task
    |> Ecto.Changeset.change(Map.merge(%{review_requested_at: @requested_at}, attrs))
    |> Repo.update!()
  end

  defp large_change, do: %{actual_files_changed: Enum.map_join(1..11, ", ", &"lib/f#{&1}.ex")}

  defp signed_params(key, nonce, task_id, requested_at \\ @requested_at) do
    message = Approval.signing_string(nonce, task_id, requested_at)

    %{
      "review_requested_at" => Approval.stamp(requested_at),
      "nonce" => nonce,
      "signature" => sign_approval(key.private_key, message)
    }
  end

  # The review_fingerprint the review screen would return for the task now.
  defp shown(task),
    do: %{
      "review_fingerprint" => task |> Repo.reload!() |> ApprovalChallenge.review_fingerprint()
    }

  defp challenge!(ctx, task, now \\ DateTime.utc_now()) do
    {:ok, challenge, _task} =
      Approval.issue_challenge(ctx.scope, ctx.phone, task.id, shown(task), now)

    challenge
  end

  defp rejected_rows,
    do: AuditLog.list_events([action: :approval_signature_rejected], order: :asc)

  defp challenge_ids, do: ApprovalChallenge |> select([c], c.id) |> Repo.all()

  describe "signing_string/3 and verify_signature/3" do
    test "verifies a P-256 signature over the canonical string", %{key: key} do
      nonce = "sdan_" <> String.duplicate("A", 43)
      message = Approval.signing_string(nonce, 8597, @requested_at)

      assert message ==
               "stride-approval-v1\n#{nonce}\n8597\n2026-11-18T09:30:00Z\napprove"

      assert Approval.signing_string(nonce, 1, nil) ==
               "stride-approval-v1\n#{nonce}\n1\n\napprove"

      signature = sign_approval(key.private_key, message)
      assert Approval.verify_signature(key.public_key, message, signature)

      other = approval_keypair_fixture()
      refute Approval.verify_signature(other.public_key, message, signature)

      for tampered <- [
            Approval.signing_string(nonce, 8598, @requested_at),
            Approval.signing_string(nonce, 8597, ~U[2026-11-18 09:30:01Z]),
            String.replace(message, "approve", "request_changes")
          ] do
        refute Approval.verify_signature(key.public_key, tampered, signature)
      end

      # A raw r||s signature (64 bytes) is not DER, so it is refused.
      raw = :crypto.strong_rand_bytes(64) |> Base.url_encode64(padding: false)

      for bad <- [raw, "not base64!", "", String.duplicate("A", 300)] do
        refute Approval.verify_signature(key.public_key, message, bad)
      end

      # Only the canonical unpadded spelling verifies, for the signature and
      # for the key: padding, or stray low bits in the last character, is refused.
      padded = signature |> Base.url_decode64!(padding: false) |> Base.url_encode64()

      if padded != signature do
        refute Approval.verify_signature(key.public_key, message, padded)
      end

      refute Approval.verify_signature(key.public_key <> "=", message, signature)

      flipped = low_bits(key.public_key)

      assert Base.url_decode64!(flipped, padding: false) ==
               Base.url_decode64!(key.public_key, padding: false)

      refute Approval.verify_signature(flipped, message, signature)

      refute Approval.verify_signature("not-a-key", message, signature)
      refute Approval.verify_signature(nil, message, signature)
      refute Approval.verify_signature(key.public_key, message, nil)
    end
  end

  # A P-256 key is 65 bytes, so its last base64 character has two unused
  # bits; setting the lowest one keeps the bytes a lenient decoder returns.
  defp low_bits(encoded) do
    {head, last} = String.split_at(encoded, -1)
    alphabet = ~c"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
    index = Enum.find_index(alphabet, &(&1 == :binary.first(last)))
    head <> <<Enum.at(alphabet, Bitwise.bor(index, 1))>>
  end

  describe "issue_challenge/5 and approve/5" do
    test "a device revoked while its approval is in flight does not approve", ctx do
      task = pending_task!(ctx.review)
      challenge = challenge!(ctx, task)
      params = signed_params(ctx.key, challenge.nonce, task.id)

      # The request was admitted with the device as it was; the row is revoked now.
      ctx.phone |> Ecto.Changeset.change(revoked_at: ~U[2026-11-18 09:40:00Z]) |> Repo.update!()

      assert {:error, :revoked} = Approval.approve(ctx.scope, ctx.phone, task.id, params)
      assert Repo.get!(Kanban.Tasks.Task, task.id).review_status in [nil, :pending]
      assert Repo.get!(ApprovalChallenge, challenge.id).used_at == nil
    end

    test "a challenge is single-use and expires after 2 minutes", ctx do
      task = pending_task!(ctx.review)
      now = ~U[2026-11-19 10:00:00Z]

      assert {:ok, challenge, _task} =
               Approval.issue_challenge(ctx.scope, ctx.phone, task.id, shown(task), now)

      assert challenge.nonce =~ ~r/\Asdan_[A-Za-z0-9_-]{43}\z/
      assert challenge.expires_at == ~U[2026-11-19 10:02:00Z]
      assert challenge.review_requested_at == @requested_at

      stored = Repo.get!(ApprovalChallenge, challenge.id)
      assert stored.nonce == nil
      refute stored.nonce_hash == challenge.nonce

      params = signed_params(ctx.key, challenge.nonce, task.id)

      assert {:error, {:signature_rejected, :expired}} =
               Approval.approve(ctx.scope, ctx.phone, task.id, params, ~U[2026-11-19 10:02:00Z])

      fresh = challenge!(ctx, task)
      params = signed_params(ctx.key, fresh.nonce, task.id)

      assert {:ok, %{review_status: :approved}} =
               Approval.approve(ctx.scope, ctx.phone, task.id, params)

      assert Repo.get!(ApprovalChallenge, fresh.id).used_at

      # The same review back in Review with the same stamp: the used nonce is refused.
      task
      |> Repo.reload!()
      |> Ecto.Changeset.change(review_status: nil, column_id: ctx.review.id)
      |> Repo.update!()

      assert {:error, {:signature_rejected, :reused}} =
               Approval.approve(ctx.scope, ctx.phone, task.id, params)

      assert Enum.map(rejected_rows(), & &1.metadata["reason"]) == ["expired", "reused"]
    end

    test "checks run in the documented order", ctx do
      owner = user_fixture()
      shared = board_fixture(owner)
      shared_review = column_fixture(shared, %{name: "Review"})
      {:ok, _} = Boards.add_user_to_board(shared, ctx.user, :read_only, owner)
      read_only = pending_task!(shared_review, large_change())

      decided =
        ctx.review
        |> pending_task!(large_change())
        |> Ecto.Changeset.change(review_status: :approved)
        |> Repo.update!()

      large = pending_task!(ctx.review, large_change())
      small = pending_task!(ctx.review)
      no_signature = %{"review_requested_at" => @requested_param}

      organization = organization_fixture()
      organization_member_fixture(organization, ctx.user)
      enforce_plans()

      # 1. Access beats every later check.
      assert {:error, :not_found} =
               Approval.approve(ctx.scope, ctx.phone, read_only.id, no_signature)

      # 2. State beats the plan, the guard and the signature.
      assert {:error, {:conflict, :already_decided, %{id: id}}} =
               Approval.approve(ctx.scope, ctx.phone, decided.id, no_signature)

      assert id == decided.id

      assert {:error, {:conflict, :resubmitted, _task}} =
               Approval.approve(ctx.scope, ctx.phone, large.id, %{
                 "review_requested_at" => "2026-11-18T09:31:00Z"
               })

      # A missing or malformed review_requested_at is a bad request after access.
      for bad <- [%{}, %{"review_requested_at" => "yesterday"}, %{"review_requested_at" => 5}] do
        assert {:error, {:bad_request, _message}} =
                 Approval.approve(ctx.scope, ctx.phone, large.id, bad)
      end

      # 3. The plan beats the guard and the signature.
      assert {:error, {:plan_required, :mobile_app}} =
               Approval.approve(ctx.scope, ctx.phone, large.id, no_signature)

      workspace = org_workspace_fixture(organization)
      ctx.board |> Ecto.Changeset.change(workspace_id: workspace.id) |> Repo.update!()

      # 4. The guard beats the signature.
      assert {:error, {:too_large_for_phone, %{files: 11}}} =
               Approval.approve(ctx.scope, ctx.phone, large.id, no_signature)

      # Only now is the signature checked, and only its refusal is audited.
      assert rejected_rows() == []

      assert {:error, {:signature_rejected, :missing}} =
               Approval.approve(ctx.scope, ctx.phone, small.id, no_signature)

      assert [%{metadata: %{"reason" => "missing"}}] = rejected_rows()
    end

    test "a challenge runs checks 1 to 4 and binds the task's own stamp", ctx do
      large = pending_task!(ctx.review, large_change())

      assert {:error, {:too_large_for_phone, _size}} =
               Approval.issue_challenge(ctx.scope, ctx.phone, large.id, %{})

      assert {:error, {:conflict, :resubmitted, _task}} =
               Approval.issue_challenge(ctx.scope, ctx.phone, large.id, %{
                 "review_requested_at" => "2026-11-18T09:31:00Z"
               })

      assert {:error, :not_found} = Approval.issue_challenge(ctx.scope, ctx.phone, -1, %{})
      assert Repo.aggregate(ApprovalChallenge, :count) == 0
    end
  end

  # The task fields the review screen shows (design §6.4, §7.5), and the
  # description, which decision 17 binds too: an edit to any of them after
  # the challenge must refuse the approval.
  @shown_edits [
    title: "Approve me, edited",
    description: "Edited after the challenge",
    priority: :critical,
    time_spent_minutes: 999,
    acceptance_criteria: "A criterion the reviewer never saw",
    security_considerations: ["A consideration the reviewer never saw"]
  ]

  defp edit!(task, attrs) do
    task |> Repo.reload!() |> Ecto.Changeset.change(attrs) |> Repo.update!()
  end

  defp approve_with(ctx, task, challenge) do
    Approval.approve(
      ctx.scope,
      ctx.phone,
      task.id,
      signed_params(ctx.key, challenge.nonce, task.id)
    )
  end

  defp assert_refused(ctx, task, challenge) do
    assert {:error, {:signature_rejected, :invalid}} = approve_with(ctx, task, challenge)
    assert Repo.get!(Kanban.Tasks.Task, task.id).review_status in [nil, :pending]
    assert Repo.get!(ApprovalChallenge, challenge.id).used_at == nil
  end

  describe "review_fingerprint/1 and an edit after the challenge" do
    test "approves an unedited task", ctx do
      task = pending_task!(ctx.review, %{acceptance_criteria: "It works", description: "Why"})
      challenge = challenge!(ctx, task)

      assert {:ok, %{review_status: :approved}} = approve_with(ctx, task, challenge)
    end

    test "refuses after acceptance criteria change", ctx do
      task = pending_task!(ctx.review, %{acceptance_criteria: "It works"})
      challenge = challenge!(ctx, task)
      edit!(task, acceptance_criteria: "It works\nAnd it ships without review")

      assert_refused(ctx, task, challenge)
      assert [%{metadata: %{"reason" => "invalid"}}] = rejected_rows()

      # A fresh challenge binds the criteria as they are now.
      assert {:ok, %{review_status: :approved}} = approve_with(ctx, task, challenge!(ctx, task))
    end

    test "refuses after any task field the review screen shows changes", ctx do
      for {field, value} <- @shown_edits do
        task = pending_task!(ctx.review, %{description: "Why", acceptance_criteria: "It works"})
        challenge = challenge!(ctx, task)
        edit!(task, [{field, value}])

        assert {:error, {:signature_rejected, :invalid}} = approve_with(ctx, task, challenge),
               "an edit to #{field} after the challenge was approved"
      end
    end

    test "refuses after a whitespace-only edit", ctx do
      task = pending_task!(ctx.review, %{acceptance_criteria: "It works"})
      challenge = challenge!(ctx, task)
      edit!(task, acceptance_criteria: "It works ")

      assert_refused(ctx, task, challenge)
    end

    test "approves after an edit is reverted", ctx do
      task = pending_task!(ctx.review, %{acceptance_criteria: "It works"})
      challenge = challenge!(ctx, task)
      edit!(task, acceptance_criteria: "Something else", title: "Another title")
      edit!(task, acceptance_criteria: "It works", title: "Approve me")

      assert {:ok, %{review_status: :approved}} = approve_with(ctx, task, challenge)
    end

    test "approves after an edit to fields the review screen does not show", ctx do
      task = pending_task!(ctx.review)
      challenge = challenge!(ctx, task)

      edit!(task,
        why: "Edited after the challenge",
        complexity: :large,
        position: 42,
        updated_at: ~N[2030-01-01 00:00:00]
      )

      assert {:ok, %{review_status: :approved}} = approve_with(ctx, task, challenge)
    end

    test "fingerprints a nil description", ctx do
      task = pending_task!(ctx.review, %{description: nil, acceptance_criteria: nil})

      assert ApprovalChallenge.review_fingerprint(task) =~ ~r/\A[0-9a-f]{64}\z/

      challenge = challenge!(ctx, task)
      assert {:ok, %{review_status: :approved}} = approve_with(ctx, task, challenge)
    end

    test "fingerprint is deterministic", ctx do
      task = pending_task!(ctx.review, %{description: "Why", acceptance_criteria: "It works"})
      fingerprint = ApprovalChallenge.review_fingerprint(task)

      assert fingerprint =~ ~r/\A[0-9a-f]{64}\z/
      assert ApprovalChallenge.review_fingerprint(task) == fingerprint
      assert task |> Repo.reload!() |> ApprovalChallenge.review_fingerprint() == fingerprint

      # Preloads and fields outside the fingerprint leave it unchanged.
      assert task
             |> Repo.reload!()
             |> Repo.preload(column: :board)
             |> Map.merge(%{position: 7, why: "Other"})
             |> ApprovalChallenge.review_fingerprint() == fingerprint

      refute ApprovalChallenge.review_fingerprint(%{task | title: "Other"}) == fingerprint
    end

    test "covers every task field the review read renders", ctx do
      task = pending_task!(ctx.review, %{description: "Why", acceptance_criteria: "It works"})
      fingerprint = ApprovalChallenge.review_fingerprint(task)

      # Not edited in place: ids and the identifier never change, board and
      # goal are other records, and completed_by_agent is a completion field.
      not_task_fields = [:id, :identifier, :board, :goal]

      rendered =
        task
        |> Repo.preload([:parent, column: :board])
        |> KanbanWeb.API.Me.ReviewJSON.task()
        |> Map.keys()
        |> Kernel.--(not_task_fields)

      edits = Keyword.put(@shown_edits, :completed_by_agent, "Another agent")

      for field <- rendered do
        assert Keyword.has_key?(edits, field), "the review read renders #{field}, untested here"
        changed = Map.put(task, field, Keyword.fetch!(edits, field))

        refute ApprovalChallenge.review_fingerprint(changed) == fingerprint,
               "the review read renders #{field}, but the fingerprint ignores it"
      end
    end
  end

  describe "issue_challenge/5 and the review_fingerprint the screen sent" do
    test "refuses a missing review_fingerprint", ctx do
      task = pending_task!(ctx.review)

      for params <- [%{}, %{"review_requested_at" => @requested_param}] do
        assert {:error, {:bad_request, message}} =
                 Approval.issue_challenge(ctx.scope, ctx.phone, task.id, params)

        assert message =~ "review_fingerprint is required"
      end

      assert challenge_ids() == []
    end

    test "refuses a malformed review_fingerprint", ctx do
      task = pending_task!(ctx.review)
      fingerprint = ApprovalChallenge.review_fingerprint(task)

      malformed = [
        nil,
        "",
        42,
        ["#{fingerprint}"],
        %{"value" => fingerprint},
        String.upcase(fingerprint),
        String.slice(fingerprint, 0, 63),
        fingerprint <> "0",
        fingerprint <> "\n",
        " " <> String.slice(fingerprint, 1, 63),
        String.duplicate("g", 64)
      ]

      for value <- malformed do
        assert {:error, {:bad_request, _message}} =
                 Approval.issue_challenge(ctx.scope, ctx.phone, task.id, %{
                   "review_fingerprint" => value
                 }),
               "#{inspect(value)} was accepted as a review_fingerprint"
      end

      assert challenge_ids() == []
    end

    test "refuses a fingerprint the task no longer has", ctx do
      task = pending_task!(ctx.review, %{acceptance_criteria: "It works"})
      loaded = shown(task)
      edit!(task, acceptance_criteria: "It works\nAnd it ships without review")

      assert {:error, {:conflict, :edited, current}} =
               Approval.issue_challenge(ctx.scope, ctx.phone, task.id, loaded)

      assert current.acceptance_criteria == "It works\nAnd it ships without review"
      assert challenge_ids() == []

      # Reloading the screen gives the fingerprint a challenge accepts.
      assert {:ok, %{review_status: :approved}} = approve_with(ctx, task, challenge!(ctx, task))
    end

    test "refuses after any task field the review screen shows changes", ctx do
      for {field, value} <- @shown_edits do
        task = pending_task!(ctx.review, %{description: "Why", acceptance_criteria: "It works"})
        loaded = shown(task)
        edit!(task, [{field, value}])

        assert {:error, {:conflict, :edited, _task}} =
                 Approval.issue_challenge(ctx.scope, ctx.phone, task.id, loaded),
               "an edit to #{field} after the screen loaded was issued a challenge"
      end
    end

    test "a valid but unrelated fingerprint is an edit, not a bad request", ctx do
      task = pending_task!(ctx.review)
      other = String.duplicate("0", 64)

      assert {:error, {:conflict, :edited, _task}} =
               Approval.issue_challenge(ctx.scope, ctx.phone, task.id, %{
                 "review_fingerprint" => other
               })
    end

    test "binds the section verdicts the screen shows", ctx do
      task =
        pending_task!(ctx.review, %{
          patterns_to_follow: "Follow the sibling module",
          reviewer_result: %{"status" => "approved", "issues" => []}
        })

      verdict = fn task ->
        task
        |> Repo.reload!()
        |> Kanban.Reviews.MobileReview.verdicts()
        |> Enum.find(&(&1.section == :patterns))
        |> Map.fetch!(:status)
      end

      assert verdict.(task) == "passed"
      loaded = shown(task)

      # Clearing a field the screen does not show flips the verdict it does.
      edit!(task, patterns_to_follow: nil)
      assert verdict.(task) == "not_assessed"
      refute shown(task) == loaded

      assert {:error, {:conflict, :edited, _task}} =
               Approval.issue_challenge(ctx.scope, ctx.phone, task.id, loaded)
    end
  end

  describe "purge_challenges/2 and ApprovalChallengePurgeWorker" do
    test "deletes expired challenges, used or not, and keeps live ones", ctx do
      task = pending_task!(ctx.review)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      expired = challenge!(ctx, task, DateTime.add(now, -300, :second))
      used = challenge!(ctx, task, DateTime.add(now, -200, :second))

      ApprovalChallenge
      |> where([c], c.id == ^used.id)
      |> Repo.update_all(set: [used_at: now])

      live = challenge!(ctx, task, now)

      assert Approval.purge_challenges(now, 1) == 2
      assert challenge_ids() == [live.id]
      refute Repo.get(ApprovalChallenge, expired.id)

      assert :ok = perform_job(ApprovalChallengePurgeWorker, %{})
      assert challenge_ids() == [live.id]
      assert ApprovalChallengePurgeWorker.__opts__()[:queue] == :maintenance
    end

    test "is scheduled daily in the Oban crontab" do
      crontab =
        Application.fetch_env!(:kanban, Oban)
        |> Keyword.fetch!(:plugins)
        |> Enum.find_value(fn
          {Oban.Plugins.Cron, opts} -> Keyword.fetch!(opts, :crontab)
          _plugin -> nil
        end)

      assert {"53 3 * * *", ApprovalChallengePurgeWorker} in crontab
    end
  end
end
