defmodule Kanban.Reviews.Approval do
  @moduledoc """
  The app's signed approval (docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md
  §6.6, §7.5, §9.5, decision 4).

  An approval made in the app is two requests:

    1. `issue_challenge/5` (`POST /api/me/reviews/:task_id/approval_challenge`)
       returns a single-use nonce, valid for 2 minutes, bound to the device,
       the task, the task's `review_requested_at` and a fingerprint of the
       work under review (`Kanban.Reviews.ApprovalChallenge.review_fingerprint/1`),
       so a resubmission inside the same second cannot reuse it. Only its
       hash is stored.
    2. The app unlocks its approval key with a biometric, signs
       `signing_string/3` and sends `approve/5`
       (`POST /api/me/reviews/:task_id/approve`) the `review_requested_at`, the
       nonce and the signature.

  ## The checks, in order

  `approve/5` runs these checks in this order and stops at the first that
  fails; `issue_challenge/5` runs the first four, so a phone learns that a
  change is too large before it asks for a biometric:

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
       `review_requested_at` and this submission (`:invalid`); it is unused
       (`:reused`) and
       unexpired (`:expired`); and the signature verifies against the device's
       approval public key (`:invalid`). A refusal is
       `{:signature_rejected, reason}`, writes `:approval_signature_rejected`
       and emits `[:kanban, :review, :approval_signature_rejected]`, with the
       reason only: never the nonce or the signature.

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

  `approve_review/3` opens its own transaction, which nests inside this one,
  and its telemetry waits for this one's commit (`Kanban.Telemetry.AfterCommit`).
  Its PubSub and webhook notifications run once its own transaction returns,
  which is the last statement before this one commits.

  ## The signing string

  The canonical signing string and the signature check live in
  `Kanban.Reviews.ApprovalSignature`; `signing_string/3`, `stamp/1`,
  `signing_version/0` and `verify_signature/3` are delegated to it.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts.Scope
  alias Kanban.Devices.Device
  alias Kanban.Devices.DeviceToken
  alias Kanban.Plans
  alias Kanban.Queries.BoardScope
  alias Kanban.Repo
  alias Kanban.Reviews
  alias Kanban.Reviews.ApprovalChallenge
  alias Kanban.Reviews.ApprovalSignature
  alias Kanban.Reviews.Audit
  alias Kanban.Reviews.MobileGuard
  alias Kanban.Tasks.AgentWorkflow
  alias Kanban.Tasks.Task
  alias Kanban.Telemetry.AfterCommit

  @purge_batch_size 1000
  @requested_at_message "review_requested_at is required: the ISO 8601 extended-format timestamp the challenge returned, such as 2026-11-18T09:30:00Z, or null or an empty string for a task that has none."

  @type conflict :: :already_decided | :resubmitted
  @type rejection :: :missing | :invalid | :expired | :reused
  @type reason ::
          :not_found
          | {:bad_request, String.t()}
          | {:conflict, conflict(), Task.t()}
          | {:plan_required, :mobile_app}
          | {:too_large_for_phone, MobileGuard.size()}
          | {:signature_rejected, rejection()}
          | :revoked
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
         {:ok, challenge} <- insert_challenge(device, pending, now) do
      {:ok, challenge, pending}
    end
  end

  @doc """
  Approves task `task_id` on `device` once all five checks pass (see the
  moduledoc). `params` holds `"review_requested_at"` (required, `nil` for a
  task without one), `"nonce"` and `"signature"`.

  Returns `{:ok, task}`, the approved task, or `{:error, reason}`.
  """
  @spec approve(Scope.t(), Device.t(), integer(), map(), DateTime.t()) ::
          {:ok, Task.t()} | {:error, reason()}
  def approve(scope, device, task_id, params, now \\ DateTime.utc_now())

  def approve(%Scope{} = scope, %Device{} = device, task_id, params, now) when is_map(params) do
    with {:ok, pending, requested} <- decidable_pending(scope, device, task_id, params, :required) do
      approve_pending(scope, device, pending, requested, params, now)
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

  # Checks 1 to 4, shared by the challenge and the approval.
  defp decidable_pending(scope, device, task_id, params, mode) do
    with {:ok, task} <- fetch_decidable(scope, task_id),
         {:ok, requested} <- requested_at(params, mode),
         {:ok, pending} <- check_state(scope, task, requested),
         :ok <- check_plan(scope, pending),
         :ok <- check_guard(pending, device) do
      {:ok, pending, requested}
    end
  end

  # --- 1. Access ---------------------------------------------------------------

  defp fetch_decidable(%Scope{user: %{id: _} = user} = scope, task_id)
       when is_integer(task_id) do
    Task
    |> where([t], t.id == ^task_id and is_nil(t.archived_at))
    |> BoardScope.apply_board_scope_with_column_join(scope)
    |> preload([t], [:completed_by, :reviewed_by, column: :board])
    |> Repo.one()
    |> authorize(user)
  end

  defp fetch_decidable(_scope, _task_id), do: {:error, :not_found}

  defp authorize(%Task{column: %{board_id: board_id}} = task, user) do
    if AgentWorkflow.authorized_reviewer?(board_id, user),
      do: {:ok, task},
      else: {:error, :not_found}
  end

  defp authorize(_task, _user), do: {:error, :not_found}

  # --- 2. State ------------------------------------------------------------------

  # `:any` means the caller sent none, so the challenge binds the task's own.
  defp requested_at(params, mode) do
    case Map.fetch(params, "review_requested_at") do
      :error when mode == :optional -> {:ok, :any}
      :error -> {:error, {:bad_request, @requested_at_message}}
      {:ok, empty} when empty in [nil, ""] -> {:ok, nil}
      {:ok, value} when is_binary(value) -> parse_requested_at(value)
      {:ok, _other} -> {:error, {:bad_request, @requested_at_message}}
    end
  end

  defp parse_requested_at(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> {:ok, DateTime.truncate(at, :second)}
      {:error, _reason} -> {:error, {:bad_request, @requested_at_message}}
    end
  end

  defp check_state(scope, %Task{} = task, requested) do
    case Reviews.get_pending_review(scope, task.id) do
      {:ok, pending} -> match_requested(Repo.preload(pending, :reviewed_by), requested)
      {:error, :not_found} -> {:error, {:conflict, :already_decided, task}}
    end
  end

  defp match_requested(pending, :any), do: {:ok, pending}

  defp match_requested(%Task{review_requested_at: stored} = pending, requested) do
    if same_stamp?(stored, requested),
      do: {:ok, pending},
      else: {:error, {:conflict, :resubmitted, pending}}
  end

  defp same_stamp?(nil, nil), do: true

  defp same_stamp?(%DateTime{} = stored, %DateTime{} = requested),
    do: stored |> DateTime.truncate(:second) |> DateTime.compare(requested) == :eq

  defp same_stamp?(_stored, _requested), do: false

  # --- 3. Plan -------------------------------------------------------------------

  defp check_plan(scope, %Task{column: %{board: board}}) do
    with :ok <- Plans.check_user(scope, :mobile_app, surface: :controller) do
      Plans.check_board(board, :mobile_app, surface: :controller)
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

  defp approve_pending(scope, device, pending, requested, params, now) do
    with {:ok, challenge} <- signed_challenge(scope, device, pending, params, now),
         do: committed(scope, device, pending, challenge, requested, now)
  end

  defp signed_challenge(scope, device, pending, params, now) do
    pending
    |> check_signature(device, params, now)
    |> record_rejection(pending, scope, device)
  end

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
         same_stamp?(challenge.review_requested_at, truncate(task.review_requested_at)),
       do: :ok,
       else: {:error, :invalid}
  end

  # The work resubmitted since the challenge, even inside the same second.
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
  defp committed(scope, device, pending, challenge, requested, now) do
    scope
    |> commit(device, pending, challenge, requested, now)
    |> record_rejection(pending, scope, device)
  end

  defp commit(scope, device, task, challenge, requested, now) do
    AfterCommit.after_commit(fn ->
      Repo.transaction(fn -> commit_locked(scope, device, task, challenge, requested, now) end)
    end)
  end

  defp commit_locked(scope, device, task, challenge, requested, now) do
    with {:ok, fresh} <- recheck_locked(scope, device, task, requested),
         :ok <- same_locked_submission(challenge, fresh),
         :ok <- consume(challenge, now),
         {:ok, approved} <- approve_fresh(scope, fresh, device) do
      approved
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # Under the task row lock: still visible and decidable, the device still
  # active, and the review still pending with the stamp the app signed.
  defp recheck_locked(scope, device, task, requested) do
    with :ok <- lock_task_row(task.id),
         {:ok, _current} <- fetch_decidable(scope, task.id),
         :ok <- lock_active_device(device),
         do: locked_state(scope, task, requested)
  end

  defp approve_fresh(scope, fresh, %Device{} = device),
    do:
      Reviews.approve_review(scope, fresh,
        via: device.platform,
        device: device,
        approval_key: true
      )

  defp lock_task_row(task_id) do
    query = from(t in Task, where: t.id == ^task_id, lock: "FOR UPDATE", select: t.id)
    if Repo.one(query), do: :ok, else: {:error, :not_found}
  end

  # FOR SHARE: a revoke waits for this commit, and one made before it is seen.
  defp lock_active_device(%Device{id: device_id}) do
    query =
      from(d in Device,
        where: d.id == ^device_id and is_nil(d.revoked_at),
        lock: "FOR SHARE",
        select: d.id
      )

    if Repo.one(query), do: :ok, else: {:error, :revoked}
  end

  defp same_locked_submission(challenge, fresh) do
    with {:error, reason} <- submitted(challenge, fresh),
         do: {:error, {:signature_rejected, reason}}
  end

  # Under the row lock, a review decided or resubmitted since the checks ran
  # is a conflict with the task as it is now.
  defp locked_state(scope, %Task{} = task, requested) do
    case check_state(scope, task, requested) do
      {:error, {:conflict, :already_decided, _stale}} ->
        current = Task |> Repo.get!(task.id) |> Repo.preload([:reviewed_by, column: :board])
        {:error, {:conflict, :already_decided, current}}

      result ->
        result
    end
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
