defmodule KanbanWeb.API.Me.FallbackController do
  @moduledoc """
  The error responses of the person API (`/api/me/*`, W2748), in the shapes
  `priv/openapi/stride-api.json` documents for it:

    * a changeset is `422 {"errors": {field: [message]}}` (`ValidationError`),
      with the messages only, never the values sent;
    * `:not_found` is `404 {"error": "Not Found"}` (`Error`), whether the
      record is missing or belongs to someone else;
    * `:revoked`, a device revoked while its request was in flight, is the
      `401 {"error": "Invalid access token"}` that
      `KanbanWeb.Plugs.AuthenticateDeviceToken` answers for a revoked device,
      with the same `www-authenticate: Bearer error="invalid_token"`
      challenge, so the app handles both the same way;
    * `{:plan_required, feature}`, a route the person's plan or the board's
      does not unlock (design §10), is `403 {"error": "plan_required",
      "feature": feature, "message": message}` (`PlanRequired`), the shape
      the agent API answers for a locked feature, so the app can show its
      locked panel without matching message text;
    * the app approval's refusals (W2754): `{:bad_request, message}` is
      `400 {"error": "Bad Request", "message": message}`;
      `{:conflict, kind, task}`, a review decided, resubmitted or (for the
      challenge) edited since the app loaded it, is `409 {"error":
      "already_decided" | "resubmitted" | "edited", "message", "review"}` (`ReviewConflict`) with the review's current
      state; `{:too_large_for_phone, size}` is `422 {"error":
      "too_large_for_phone", "message", "size", "limits"}`
      (`TooLargeForPhone`); `{:signature_rejected, reason}` is `422
      {"error": "signature_rejected", "reason", "message"}`
      (`SignatureRejected`), with the reason only; and a refusal from
      `Kanban.Reviews.approve_review/3` itself is `422 {"error":
      "approval_failed", "reason"}` (`ApprovalFailed`). `:not_authorized` is
      the 404 above, so a refusal never reveals the task.
    * `{:files_changed, files_version}`, a file's diff asked for with a
      `files_version` the task's file list no longer has (W2753), is `409
      {"error": "files_changed", "message", "files_version"}`
      (`FilesChanged`) with the current version.
    * the app's request for changes (W2755): `:review_notes_required`, notes
      that are missing or blank, is `422 {"errors": {"notes": ["can't be
      blank"]}}` (`ValidationError`), with the message only, never the notes
      sent; `:review_notes_invalid`, notes with a NUL byte, is `422
      {"errors": {"notes": ["contains characters that are not allowed"]}}`.
    * the app's promote to Ready (W2759, `Kanban.Tasks.Promote`):
      `:forbidden`, a person who can see the board but not write to it, is
      `403 {"error": "Forbidden", "message": message}` (`Error`);
      `:empty_selection` and `:too_many_tasks` are `422 {"errors":
      {"task_ids": [message]}}` (`ValidationError`); `{:not_promotable, ids}`
      is `422 {"error": "not_promotable", "message", "task_ids"}` and
      `:wip_limit_reached`, `:no_ready_column` and `:update_failed` are `422
      {"error": reason, "message"}` (`PromoteRefusal`); and `:conflict`, a
      task moved by someone else in the middle of the promote, is `409
      {"error": "conflict", "message"}` (`Error`).
    * the app's task actions (W2760, `KanbanWeb.API.Me.TaskController`):
      `{:in_device_locale, changeset}` is the changeset's `422 {"errors":
      {field: [message]}}` above, with each message translated into the
      device's language (its `locale`, resolved by `Kanban.Locales.resolve/1`;
      English without a device); `:not_movable`, `:no_backlog_column` and
      `:move_failed` are `422 {"error": reason, "message"}`
      (`MeTaskRefusal`); and `:backlog_wip_limit_reached` is `422 {"error":
      "wip_limit_reached", "message"}` with a message about Backlog.
    * `{:rate_limited, retry_after_ms}`, the app approval's per-device limit,
      is `429 {"error": "rate_limited", "message": message}` (`Error`) with a
      `retry-after` header in seconds.

  The agent API's `KanbanWeb.API.FallbackController` attaches task
  documentation links and a different 404 body, which is why the person API
  has its own.
  """
  use KanbanWeb, :controller

  alias Kanban.Locales
  alias Kanban.Reviews.MobileGuard
  alias Kanban.Tasks.Promote
  alias Kanban.Tasks.Task
  alias KanbanWeb.API.Me.ReviewJSON
  alias KanbanWeb.CoreComponents
  alias KanbanWeb.Plugs.BearerChallenge

  # The refusals Kanban.Reviews.approve_review/3 can return once the approval
  # checks have passed: the board has no Done column to move the task to, or
  # the task left the state an approval needs.
  @approval_failures [
    :column_not_found,
    :review_not_performed,
    :invalid_column,
    :invalid_review_status
  ]

  # The promote refusals that carry only a reason and a message.
  @promote_refusals [:wip_limit_reached, :no_ready_column, :update_failed]

  # The app's task-action refusals that carry only a reason and a message.
  @task_refusals [:not_movable, :no_backlog_column, :move_failed]

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: Ecto.Changeset.traverse_errors(changeset, &interpolate/1)})
  end

  def call(conn, {:error, {:in_device_locale, %Ecto.Changeset{} = changeset}}) do
    locale = conn.assigns |> Map.get(:current_device) |> device_locale() |> Locales.resolve()

    errors =
      Gettext.with_locale(KanbanWeb.Gettext, locale, fn ->
        Ecto.Changeset.traverse_errors(changeset, &CoreComponents.translate_error/1)
      end)

    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: errors})
  end

  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "Not Found"})
  end

  def call(conn, {:error, {:plan_required, feature}}) do
    conn
    |> put_status(:forbidden)
    |> json(%{
      error: "plan_required",
      feature: to_string(feature),
      message: plan_message(feature)
    })
  end

  def call(conn, {:error, :not_authorized}), do: call(conn, {:error, :not_found})

  def call(conn, {:error, {:bad_request, message}}) when is_binary(message) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Bad Request", message: message})
  end

  def call(conn, {:error, {:conflict, kind, %Task{} = task}})
      when kind in [:already_decided, :resubmitted, :edited] do
    conn
    |> put_status(:conflict)
    |> json(%{
      error: Atom.to_string(kind),
      message: conflict_message(kind),
      review: ReviewJSON.review_state(task)
    })
  end

  def call(conn, {:error, {:files_changed, files_version}}) when is_binary(files_version) do
    conn
    |> put_status(:conflict)
    |> json(%{
      error: "files_changed",
      message:
        "This task's changed files changed since the review was loaded. Reload the review.",
      files_version: files_version
    })
  end

  def call(conn, {:error, {:too_large_for_phone, size}}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: "too_large_for_phone",
      message:
        "This change is too large to approve on a phone. Approve it on a tablet or on the web.",
      size: %{
        files: size.files,
        files_unknown: Map.get(size, :files_unknown, false),
        changed_lines: size.changed_lines,
        truncated: size.truncated
      },
      limits: MobileGuard.limits()
    })
  end

  def call(conn, {:error, {:signature_rejected, reason}}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: "signature_rejected",
      reason: Atom.to_string(reason),
      message: signature_message(reason)
    })
  end

  def call(conn, {:error, reason}) when reason in @approval_failures do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "approval_failed", reason: Atom.to_string(reason)})
  end

  def call(conn, {:error, :review_notes_required}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: %{notes: ["can't be blank"]}})
  end

  def call(conn, {:error, :review_notes_invalid}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: %{notes: ["contains characters that are not allowed"]}})
  end

  def call(conn, {:error, :forbidden}) do
    conn
    |> put_status(:forbidden)
    |> json(%{error: "Forbidden", message: "This needs write access to the board."})
  end

  def call(conn, {:error, :empty_selection}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: %{task_ids: ["can't be blank"]}})
  end

  def call(conn, {:error, :too_many_tasks}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: %{task_ids: ["should have at most #{Promote.max_tasks()} item(s)"]}})
  end

  def call(conn, {:error, {:not_promotable, task_ids}}) when is_list(task_ids) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: "not_promotable",
      message: "Only work and defect tasks in Backlog can be promoted to Ready.",
      task_ids: task_ids
    })
  end

  def call(conn, {:error, reason}) when reason in @promote_refusals do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: Atom.to_string(reason), message: promote_message(reason)})
  end

  def call(conn, {:error, reason}) when reason in @task_refusals do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: Atom.to_string(reason), message: task_message(reason)})
  end

  def call(conn, {:error, :backlog_wip_limit_reached}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: "wip_limit_reached",
      message: "Backlog has no room for this task under its WIP limit."
    })
  end

  def call(conn, {:error, :conflict}) do
    conn
    |> put_status(:conflict)
    |> json(%{
      error: "conflict",
      message: "A task was moved by someone else at the same time. Try again."
    })
  end

  def call(conn, {:error, {:rate_limited, retry_after_ms}}) when is_integer(retry_after_ms) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(div(retry_after_ms, 1000) + 1))
    |> put_status(:too_many_requests)
    |> json(%{error: "rate_limited", message: "Too many requests. Try again later."})
  end

  def call(conn, {:error, :revoked}) do
    conn
    |> BearerChallenge.put_challenge(:invalid_token)
    |> put_status(:unauthorized)
    |> json(%{error: "Invalid access token"})
  end

  defp conflict_message(:already_decided), do: "This review has already been decided."

  defp conflict_message(:resubmitted),
    do: "This task was sent for review again since it was loaded. Review it again."

  defp conflict_message(:edited),
    do: "This task was edited since the review was loaded. Reload the review."

  defp signature_message(:missing), do: "The approval needs a nonce and a signature."

  defp signature_message(:invalid),
    do: "The approval signature or nonce is not valid for this device and review."

  defp signature_message(:expired), do: "The approval nonce has expired. Request a new one."

  defp signature_message(:reused),
    do: "The approval nonce has already been used. Request a new one."

  defp promote_message(:wip_limit_reached),
    do: "Ready has no room for these tasks under its WIP limit."

  defp promote_message(:no_ready_column), do: "This board has no Ready column."

  defp promote_message(:update_failed), do: "The tasks could not be promoted. Try again."

  defp task_message(:not_movable),
    do:
      "Only work and defect tasks in Ready, or in Doing with an expired claim, can be moved to Backlog."

  defp task_message(:no_backlog_column), do: "This board has no Backlog column."
  defp task_message(:move_failed), do: "The task could not be moved. Try again."

  defp device_locale(%{locale: locale}), do: locale
  defp device_locale(_device), do: nil

  defp plan_message(:mobile_app), do: "The Stride app is available to boards in an Organization."
  defp plan_message(_feature), do: "This feature is available to boards in an Organization."

  defp interpolate({message, opts}) do
    Enum.reduce(opts, message, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", stringify(value))
    end)
  end

  defp stringify(value) when is_binary(value) or is_number(value) or is_atom(value),
    do: to_string(value)

  defp stringify(value), do: inspect(value)
end
