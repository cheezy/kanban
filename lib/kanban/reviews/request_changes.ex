defmodule Kanban.Reviews.RequestChanges do
  @moduledoc """
  A request for changes made in the app
  (docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §7.5):
  `POST /api/me/reviews/:task_id/request_changes`.

  It runs checks 1 to 3 of the approval, in the same order
  (`Kanban.Reviews.DecisionChecks.decidable/4`: access, the review still
  pending with the `review_requested_at` sent, and the `:mobile_app` plan),
  and then calls `Kanban.Reviews.request_changes_review/3` with the notes,
  the device's platform as `via` and the device, which writes the
  `:review_changes_requested` audit event. There is no signature and no
  large-change guard: asking for changes leaves the task in Review, so a
  phone may ask for changes on a change of any size.

  Missing or non-string notes, and notes with nothing visible in them (only
  whitespace, invisible format characters such as a zero-width space, or
  combining marks), are `:review_notes_required`; notes with a NUL byte are
  `:review_notes_invalid`. Both are answered only once the checks have
  passed, so a 422 never reveals a task the person cannot review.

  ## Committing

  The commit runs in one transaction, as an approval's does: it claims the
  request's idempotency key first (`Kanban.Devices.Nonces.claim/2`), locks
  the task row and the device row, runs the access and state checks again
  (`Kanban.Reviews.DecisionChecks.recheck_locked/4`), records the request,
  and stores its result with the key (`Kanban.Devices.Nonces.record/2`). So
  a review decided or resubmitted since the checks ran answers 409, a device
  revoked since is `:revoked`, and a retry with the same key replays the
  first result rather than requesting changes twice.
  """

  alias Kanban.Accounts.Scope
  alias Kanban.Devices.Device
  alias Kanban.Devices.Nonce
  alias Kanban.Devices.Nonces
  alias Kanban.Repo
  alias Kanban.Reviews
  alias Kanban.Reviews.DecisionChecks
  alias Kanban.Tasks.Task
  alias Kanban.Telemetry.AfterCommit

  @type reason ::
          :not_found
          | {:bad_request, String.t()}
          | {:conflict, :already_decided | :resubmitted, Task.t()}
          | {:plan_required, :mobile_app}
          | :review_notes_required
          | :review_notes_invalid
          | :revoked
          | {:replay, Nonce.t()}
          | atom()
          | Ecto.Changeset.t()

  @doc """
  Requests changes on task `task_id` from `device`. `params` holds
  `"review_requested_at"` (required, `nil` for a task without one) and
  `"notes"`, the feedback for the agent (required).

  `opts` takes `:idempotency`, the `Kanban.Devices.IdempotencyKey` the
  request carried, or `nil`, and `:now`; a key already stored is
  `{:error, {:replay, nonce}}`.

  Returns `{:ok, task}`, the task with `review_status: :changes_requested`,
  or `{:error, reason}`.
  """
  @spec request_changes(Scope.t(), Device.t(), integer(), map(), keyword()) ::
          {:ok, Task.t()} | {:error, reason()}
  def request_changes(scope, device, task_id, params, opts \\ [])

  def request_changes(%Scope{} = scope, %Device{} = device, task_id, params, opts)
      when is_map(params) and is_list(opts) do
    notes = Map.get(params, "notes")

    with {:ok, pending, requested} <- DecisionChecks.decidable(scope, task_id, params, :required),
         :ok <- check_notes(notes) do
      commit(scope, device, pending, requested, notes, opts)
    end
  end

  # Nothing left once whitespace, control and format characters and
  # combining marks are taken out means nothing the agent could read.
  @invisible ~r/[\s\p{Z}\p{Cc}\p{Cf}\p{M}]/u

  defp check_notes(notes) when is_binary(notes) do
    cond do
      String.contains?(notes, <<0>>) -> {:error, :review_notes_invalid}
      not String.valid?(notes) -> {:error, :review_notes_invalid}
      String.replace(notes, @invisible, "") == "" -> {:error, :review_notes_required}
      true -> :ok
    end
  end

  defp check_notes(_notes), do: {:error, :review_notes_required}

  defp commit(scope, device, task, requested, notes, opts) do
    AfterCommit.after_commit(fn ->
      Repo.transaction(fn -> commit_locked(scope, device, task, requested, notes, opts) end)
    end)
  end

  defp commit_locked(scope, device, task, requested, notes, opts) do
    idempotency = Keyword.get(opts, :idempotency)

    with {:ok, fresh} <- admit_locked(scope, device, task, requested, idempotency, opts),
         {:ok, decided} <- request_fresh(scope, fresh, device, notes),
         :ok <- Nonces.record(idempotency, decided) do
      decided
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # Under the locks: the idempotency key first, then the access, device and
  # state re-check.
  defp admit_locked(scope, device, task, requested, idempotency, opts) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    with :ok <- Nonces.claim(idempotency, now),
         do: DecisionChecks.recheck_locked(scope, device, task, requested)
  end

  defp request_fresh(scope, fresh, %Device{} = device, notes),
    do:
      Reviews.request_changes_review(scope, fresh,
        review_notes: notes,
        via: device.platform,
        device: device
      )
end
