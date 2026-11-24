defmodule Kanban.Reviews.Approval do
  @moduledoc """
  The app's signed approval (docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md
  §6.6, §7.5, §9.5, decision 4).

  An approval made in the app is two requests:

    1. `issue_challenge/5` (`POST /api/me/reviews/:task_id/approval_challenge`)
       returns a single-use nonce, valid for 2 minutes, bound to the device,
       the task, the task's `review_requested_at` and a fingerprint of what
       the review screen shows (`Kanban.Reviews.ApprovalChallenge.review_fingerprint/1`),
       so a resubmission inside the same second cannot reuse it. The app
       sends the `review_fingerprint` the review detail returned, and a
       challenge is issued only when it matches the task's now, so an edit
       made after the screen loaded is never signed unseen. Only the
       nonce's hash is stored.
    2. The app unlocks its approval key with a biometric, signs
       `signing_string/3` and sends `approve/5`
       (`POST /api/me/reviews/:task_id/approve`) the `review_requested_at`, the
       nonce and the signature.

  ## The checks, in order

  `approve/6` runs these checks in this order and stops at the first that
  fails; `issue_challenge/5` runs the first four, so a phone learns that a
  change is too large before it asks for a biometric, and then checks the
  `review_fingerprint` it was sent: missing or malformed is
  `{:bad_request, message}`, and one that does not match the task's is
  `{:conflict, :edited, task}`. Checks 1 to 3 are
  `Kanban.Reviews.DecisionChecks.decidable/4`, which the request for changes
  (`Kanban.Reviews.RequestChanges`) runs too:

    1. **Access.** The task exists, is not archived, is on a board the person
       can see and they can write to it (the review write check). Anything
       else is `:not_found`, so no later answer reveals a task the person
       cannot review.
    2. **State.** The review is still pending, and its `review_requested_at`
       matches the one sent: else `{:conflict, :already_decided, task}` or
       `{:conflict, :resubmitted, task}` with the current task.
    3. **Plan.** `:mobile_app`, for the person and then for the task's board:
       `{:plan_required, :mobile_app}`.
    4. **Large-change guard.** `Kanban.Reviews.MobileGuard.check/2` for the
       device's class: `{:too_large_for_phone, size}` for a phone above the
       limit, emitting `[:kanban, :review, :phone_approval_refused]`.
    5. **Signature.** A nonce and a signature are present
       (`:missing`); the nonce was issued to this device for this task, this
       `review_requested_at` and this submission, with the task fields the
       review screen shows, the description and the status of each section
       verdict unchanged since (`:invalid`);
       it is unused
       (`:reused`) and
       unexpired (`:expired`); and the signature verifies against the device's
       approval public key (`:invalid`). A refusal is
       `{:signature_rejected, reason}`, writes `:approval_signature_rejected`
       and emits `[:kanban, :review, :approval_signature_rejected]`, with the
       reason only: never the nonce or the signature. A nonce found used
       because the approval it signed committed after check 2 ran is a retry
       racing that commit, not a rejection: it answers the state check 2
       finds now (`{:conflict, :already_decided, task}`) and records nothing.

  ## Committing

  The commit runs in one transaction: it locks the task row and the device
  row, runs the access check again (a task archived, or a person whose write
  access was removed, since the checks ran is `:not_found`), refuses a device
  revoked since its request was admitted (`:revoked`), checks the state and
  the submission fingerprint again, consumes the nonce with one conditional
  update, and calls
  `Kanban.Reviews.approve_review/3` unchanged with the fresh task, the
  device's platform as `via`, the device and `approval_key: true`. So a
  review resubmitted between the checks and the commit answers 409, a nonce
  is consumed at most once, and a refused approval rolls the nonce back
  unused. Two devices approving at once queue on the row lock: the second
  finds the review decided and answers 409 `already_decided`.

  ## Retries

  A request sent with an `Idempotency-Key` header carries it as
  `opts[:idempotency]` (`Kanban.Devices.IdempotencyKey`). The commit claims
  it before it locks anything (`Kanban.Devices.Nonces.claim/2`) and stores
  the approved result with it in the same transaction
  (`Kanban.Devices.Nonces.record/2`), so a retry with the same key, even one
  sent in parallel, replays the first 200 rather than approving twice or
  answering 409. A refused approval stores nothing.

  `approve_review/3` opens its own transaction, which nests inside this one,
  and everything it causes outside the database waits for this one's commit
  (`Kanban.Telemetry.AfterCommit`): its telemetry, the audit event's telemetry
  and log line, the completer's notification and the webhooks. So an approval
  that rolls back here, after `approve_review/3` returned (an idempotency
  record that fails, or an exception), emits and sends none of them.

  ## The signing string

  The canonical signing string and the signature check live in
  `Kanban.Reviews.ApprovalSignature`; `signing_string/3`, `stamp/1`,
  `signing_version/0` and `verify_signature/3` are delegated to it.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts.Scope
  alias Kanban.Devices.Device
  alias Kanban.Devices.DeviceToken
  alias Kanban.Devices.Nonce
  alias Kanban.Devices.Nonces
  alias Kanban.Repo
  alias Kanban.Reviews
  alias Kanban.Reviews.ApprovalChallenge
  alias Kanban.Reviews.ApprovalSignature
  alias Kanban.Reviews.Audit
  alias Kanban.Reviews.DecisionChecks
  alias Kanban.Reviews.MobileGuard
  alias Kanban.Tasks.Task
  alias Kanban.Telemetry.AfterCommit

  @purge_batch_size 1000

  @fingerprint_message "review_fingerprint is required: the review_fingerprint the review detail returned, 64 lowercase hexadecimal characters."

  @type conflict :: :already_decided | :resubmitted | :edited
  @type rejection :: :missing | :invalid | :expired | :reused
  @type reason ::
          :not_found
          | {:bad_request, String.t()}
          | {:conflict, conflict(), Task.t()}
          | {:plan_required, :mobile_app}
          | {:too_large_for_phone, MobileGuard.size()}
          | {:signature_rejected, rejection()}
          | :revoked
          | {:replay, Nonce.t()}
          | atom()
          | Ecto.Changeset.t()

  @doc "See `Kanban.Reviews.ApprovalSignature.signing_version/0`."
  defdelegate signing_version(), to: ApprovalSignature

  @doc "See `Kanban.Reviews.ApprovalSignature.signing_string/3`."
  defdelegate signing_string(nonce, task_id, review_requested_at), to: ApprovalSignature

  @doc "See `Kanban.Reviews.ApprovalSignature.stamp/1`."
  defdelegate stamp(review_requested_at), to: ApprovalSignature

  @doc "See `Kanban.Reviews.ApprovalSignature.verify_signature/3`."
  defdelegate verify_signature(public_key, message, signature), to: ApprovalSignature

  @doc """
  Issues an approval nonce on `device` for task `task_id`, after checks 1 to
  4. `params` may carry `"review_requested_at"`: when it is present and does
  not match the task's, the answer is `{:conflict, :resubmitted, task}`.

  `params` must carry `"review_fingerprint"`, the value the review detail
  returned: missing or malformed is `{:bad_request, message}`, and one that
  does not match the task's fingerprint now is `{:conflict, :edited, task}`,
  so the nonce is bound to what the reviewer was shown, not to an edit made
  after the screen loaded.

  Returns `{:ok, challenge, task}` with the plain nonce in `challenge.nonce`,
  or `{:error, reason}`.
  """
  @spec issue_challenge(Scope.t(), Device.t(), integer(), map(), DateTime.t()) ::
          {:ok, ApprovalChallenge.t(), Task.t()} | {:error, reason()}
  def issue_challenge(scope, device, task_id, params, now \\ DateTime.utc_now())

  def issue_challenge(%Scope{} = scope, %Device{} = device, task_id, params, now)
      when is_map(params) do
    with {:ok, pending, _requested} <-
           decidable_pending(scope, device, task_id, params, :optional),
         :ok <- check_shown(pending, params),
         {:ok, challenge} <- insert_challenge(device, pending, now) do
      {:ok, challenge, pending}
    end
  end

  # The fingerprint the review screen was rendered with must be the task's
  # now. It is not a secret (the review detail returns it), so a plain
  # comparison is enough.
  defp check_shown(%Task{} = task, %{"review_fingerprint" => shown}) do
    cond do
      not ApprovalChallenge.valid_fingerprint?(shown) ->
        {:error, {:bad_request, @fingerprint_message}}

      shown == ApprovalChallenge.review_fingerprint(task) ->
        :ok

      true ->
        {:error, {:conflict, :edited, task}}
    end
  end

  defp check_shown(_task, _params), do: {:error, {:bad_request, @fingerprint_message}}

  @doc """
  Approves task `task_id` on `device` once all five checks pass (see the
  moduledoc). `params` holds `"review_requested_at"` (required, `nil` for a
  task without one), `"nonce"` and `"signature"`.

  `opts` takes `:idempotency`, the `Kanban.Devices.IdempotencyKey` the
  request carried, or `nil`: the commit claims it first and stores the
  approved result with it, and a key already stored is
  `{:error, {:replay, nonce}}` (see "Retries" in the moduledoc).

  Returns `{:ok, task}`, the approved task, or `{:error, reason}`.
  """
  @spec approve(Scope.t(), Device.t(), integer(), map(), DateTime.t(), keyword()) ::
          {:ok, Task.t()} | {:error, reason()}
  def approve(scope, device, task_id, params, now \\ DateTime.utc_now(), opts \\ [])

  def approve(%Scope{} = scope, %Device{} = device, task_id, params, now, opts)
      when is_map(params) and is_list(opts) do
    idempotency = Keyword.get(opts, :idempotency)

    with {:ok, pending, requested} <- decidable_pending(scope, device, task_id, params, :required) do
      approve_pending(scope, device, pending, requested, params, {now, idempotency})
    end
  end

  @doc """
  Deletes the approval challenges whose 2 minutes ran out before `now`, used
  or not, `batch_size` rows per statement. Returns the number deleted. A used
  challenge is kept until then so that presenting it again is refused as
  `:reused`.
  """
  @spec purge_challenges(DateTime.t(), pos_integer()) :: non_neg_integer()
  def purge_challenges(%DateTime{} = now, batch_size \\ @purge_batch_size)
      when is_integer(batch_size) and batch_size > 0 do
    purge(DateTime.truncate(now, :second), batch_size, 0)
  end

  defp purge(now, batch_size, removed) do
    ids =
      from(c in ApprovalChallenge, where: c.expires_at < ^now, select: c.id, limit: ^batch_size)

    case from(c in ApprovalChallenge, where: c.id in subquery(ids)) |> Repo.delete_all() do
      {count, _rows} when count < batch_size -> removed + count
      {count, _rows} -> purge(now, batch_size, removed + count)
    end
  end

  # Checks 1 to 4, shared by the challenge and the approval: 1 to 3 are
  # Kanban.Reviews.DecisionChecks.decidable/4.
  defp decidable_pending(scope, device, task_id, params, mode) do
    with {:ok, pending, requested} <- DecisionChecks.decidable(scope, task_id, params, mode),
         :ok <- check_guard(pending, device) do
      {:ok, pending, requested}
    end
  end

  # --- 4. Large-change guard -----------------------------------------------------

  defp check_guard(%Task{} = task, %Device{device_class: device_class}) do
    size = MobileGuard.size(task)

    case MobileGuard.check(size, device_class) do
      :ok ->
        :ok

      {:error, :too_large_for_phone} ->
        Kanban.Telemetry.emit(
          [:kanban, :review, :phone_approval_refused],
          %{count: 1, files: size.files, changed_lines: size.changed_lines},
          %{task_id: task.id, board_id: task.column.board_id}
        )

        {:error, {:too_large_for_phone, size}}
    end
  end

  # --- 5. Signature --------------------------------------------------------------

  defp approve_pending(scope, device, pending, requested, params, {now, _idempotency} = at) do
    with {:ok, challenge} <- signed_challenge(scope, device, pending, params, now),
         do: committed(scope, device, pending, challenge, requested, at)
  end

  defp signed_challenge(scope, device, pending, params, now) do
    pending
    |> check_signature(device, params, now)
    |> decided_meanwhile(scope, pending, params)
    |> record_rejection(pending, scope, device)
  end

  # A nonce bound to this device, task and stamp is found used only once the
  # approval it signed has committed: a retry racing that commit. Answer with
  # the state the commit left (409, or the replay of its key) rather than
  # recording a rejected signature for a request that did not fail.
  defp decided_meanwhile({:error, {:signature_rejected, :reused}} = refused, scope, task, params) do
    case DecisionChecks.decidable(scope, task.id, params, :required) do
      {:error, {:conflict, _reason, _task}} = conflict -> conflict
      _still_pending_or_other -> refused
    end
  end

  defp decided_meanwhile(result, _scope, _task, _params), do: result

  defp check_signature(%Task{} = task, %Device{} = device, params, now) do
    with {:error, reason} <- signature_checks(task, device, params, now),
         do: {:error, {:signature_rejected, reason}}
  end

  defp signature_checks(task, device, params, now) do
    with {:ok, nonce, signature} <- signature_params(params),
         {:ok, challenge} <- find_challenge(nonce),
         :ok <- challenge_usable(challenge, device, task, now),
         :ok <- verified(device, nonce, task, signature),
         do: {:ok, challenge}
  end

  # In order: bound to this device, task and stamp; unused; unexpired; and
  # issued for the submission the task carries now.
  defp challenge_usable(challenge, device, task, now) do
    with :ok <- bound(challenge, device, task),
         :ok <- unused(challenge),
         :ok <- unexpired(challenge, now),
         do: submitted(challenge, task)
  end

  defp signature_params(%{"nonce" => nonce, "signature" => signature})
       when is_binary(nonce) and nonce != "" and is_binary(signature) and signature != "",
       do: {:ok, nonce, signature}

  defp signature_params(_params), do: {:error, :missing}

  defp find_challenge(nonce) do
    with true <- ApprovalChallenge.valid_nonce?(nonce),
         %ApprovalChallenge{} = challenge <-
           Repo.get_by(ApprovalChallenge, nonce_hash: DeviceToken.hash_token(nonce)) do
      {:ok, challenge}
    else
      _unknown -> {:error, :invalid}
    end
  end

  # A nonce issued to another device, for another task, or before the review
  # was resubmitted is `:invalid`, and says nothing about its own state.
  defp bound(%ApprovalChallenge{} = challenge, %Device{id: device_id}, %Task{} = task) do
    if challenge.device_id == device_id and challenge.task_id == task.id and
         DecisionChecks.same_stamp?(
           challenge.review_requested_at,
           truncate(task.review_requested_at)
         ),
       do: :ok,
       else: {:error, :invalid}
  end

  # The work resubmitted since the challenge, even inside the same second, or
  # a task field the reviewer was shown edited since.
  defp submitted(challenge, task),
    do: if(same_submission?(challenge, task), do: :ok, else: {:error, :invalid})

  defp same_submission?(%ApprovalChallenge{review_fingerprint: fingerprint}, %Task{} = task),
    do: is_binary(fingerprint) and fingerprint == ApprovalChallenge.review_fingerprint(task)

  defp unused(%ApprovalChallenge{used_at: nil}), do: :ok
  defp unused(%ApprovalChallenge{}), do: {:error, :reused}

  defp unexpired(%ApprovalChallenge{expires_at: expires_at}, now) do
    if DateTime.compare(expires_at, now) == :gt, do: :ok, else: {:error, :expired}
  end

  defp verified(%Device{approval_public_key: key}, nonce, %Task{} = task, signature) do
    message = signing_string(nonce, task.id, task.review_requested_at)
    if verify_signature(key, message, signature), do: :ok, else: {:error, :invalid}
  end

  # --- Issue and commit ------------------------------------------------------------

  defp insert_challenge(device, task, now) do
    device
    |> ApprovalChallenge.create_changeset(task, now)
    |> Repo.insert()
  end

  # A nonce found consumed or expired under the lock is a rejection too.
  defp committed(scope, device, pending, challenge, requested, at) do
    scope
    |> commit(device, pending, challenge, requested, at)
    |> record_rejection(pending, scope, device)
  end

  defp commit(scope, device, task, challenge, requested, at) do
    AfterCommit.after_commit(fn ->
      Repo.transaction(fn -> commit_locked(scope, device, task, challenge, requested, at) end)
    end)
  end

  # The idempotency key is claimed before the row locks, so a parallel retry
  # with the same key waits here and then replays this commit's result.
  defp commit_locked(scope, device, task, challenge, requested, {_now, idempotency} = at) do
    with {:ok, fresh} <- admit_locked(scope, device, task, challenge, requested, at),
         {:ok, approved} <- approve_fresh(scope, fresh, device),
         :ok <- Nonces.record(idempotency, approved) do
      approved
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # Under the locks, in this order: the idempotency key, the access, device,
  # state and plan re-check, the submission, and the nonce.
  defp admit_locked(scope, device, task, challenge, requested, {now, idempotency}) do
    with :ok <- Nonces.claim(idempotency, now),
         {:ok, fresh} <- DecisionChecks.recheck_locked(scope, device, task, requested),
         :ok <- same_locked_submission(challenge, fresh),
         :ok <- consume(challenge, now),
         do: {:ok, fresh}
  end

  defp approve_fresh(scope, fresh, %Device{} = device),
    do:
      Reviews.approve_review(scope, fresh,
        via: device.platform,
        device: device,
        approval_key: true
      )

  defp same_locked_submission(challenge, fresh) do
    with {:error, reason} <- submitted(challenge, fresh),
         do: {:error, {:signature_rejected, reason}}
  end

  # One statement marks the nonce used, so it is consumed at most once even
  # when the same nonce is sent twice at once.
  defp consume(%ApprovalChallenge{id: id}, now) do
    at = truncate(now)

    from(c in ApprovalChallenge,
      where: c.id == ^id and is_nil(c.used_at) and c.expires_at > ^at
    )
    |> Repo.update_all(set: [used_at: at])
    |> case do
      {1, _rows} -> :ok
      {0, _rows} -> {:error, {:signature_rejected, consumed_reason(id, at)}}
    end
  end

  defp consumed_reason(id, at) do
    case Repo.get(ApprovalChallenge, id) do
      %ApprovalChallenge{used_at: nil, expires_at: expires_at} ->
        if DateTime.compare(expires_at, at) == :gt, do: :invalid, else: :expired

      _used_or_gone ->
        :reused
    end
  end

  defp record_rejection(
         {:error, {:signature_rejected, reason}} = refused,
         %Task{} = task,
         %Scope{user: user},
         %Device{} = device
       ) do
    Audit.record_signature_rejected(task, user, device, reason)

    Kanban.Telemetry.emit(
      [:kanban, :review, :approval_signature_rejected],
      %{count: 1},
      %{
        task_id: task.id,
        board_id: task.column.board_id,
        device_class: device.device_class,
        reason: reason
      }
    )

    refused
  end

  defp record_rejection(result, _task, _scope, _device), do: result

  defp truncate(%DateTime{} = at), do: DateTime.truncate(at, :second)
  defp truncate(nil), do: nil
end
