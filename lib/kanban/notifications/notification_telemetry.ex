defmodule Kanban.Notifications.NotificationTelemetry do
  @moduledoc """
  Emits the notification, email delivery and weekly digest telemetry events
  through `Kanban.Telemetry`.

  Every event is emitted only after the change it reports has been saved, or
  after the mailer has answered, so a refused or invalid change emits
  nothing. The functions that take a result return it unchanged, so they can
  sit at the end of a pipe without changing what the caller sees; the
  worker functions return `:ok`. A change that saves nothing new (marking a
  read notification read again, or saving the same preference flags) emits
  nothing either.

  `created/1` runs after `Kanban.Notifications.notify/3` has committed its
  own transaction. `notify/3` is meant to be called once the triggering
  write has committed; a caller that runs it inside an outer transaction
  that later rolls back will already have emitted `created`.

  Metadata carries ids, event types, reason atoms and counts only. Email
  addresses, notification titles and bodies, and raw mailer errors never
  appear in it, because telemetry handlers may forward events to tools
  outside the app.
  """

  alias Kanban.Notifications.Notification
  alias Kanban.Notifications.Preference

  @doc """
  Emits `[:kanban, :notification, :created]` once for each saved
  notification in an `{:ok, notifications}` result. Returns `result`.
  """
  @spec created(result) :: result when result: term()
  def created({:ok, notifications} = result) when is_list(notifications) do
    Enum.each(notifications, fn %Notification{} = notification ->
      Kanban.Telemetry.emit([:kanban, :notification, :created], %{count: 1}, %{
        notification_id: notification.id,
        user_id: notification.user_id,
        event_type: notification.event_type,
        board_id: notification.board_id,
        in_app: notification.in_app
      })
    end)

    result
  end

  def created(result), do: result

  @doc """
  Emits `[:kanban, :notification, :read]` when `result` is a notification
  that was just marked read. Call it only on the unread path. Returns
  `result`.
  """
  @spec read(result) :: result when result: term()
  def read({:ok, %Notification{} = notification} = result) do
    Kanban.Telemetry.emit([:kanban, :notification, :read], %{count: 1}, %{
      notification_id: notification.id,
      user_id: notification.user_id,
      event_type: notification.event_type
    })

    result
  end

  def read(result), do: result

  @doc """
  Emits `[:kanban, :notification, :all_read]` for `user_id` with the number
  of notifications marked read, which may be 0. Returns `result`.
  """
  @spec all_read({:ok, non_neg_integer()}, integer()) :: {:ok, non_neg_integer()}
  def all_read({:ok, count} = result, user_id) when is_integer(count) do
    Kanban.Telemetry.emit([:kanban, :notification, :all_read], %{count: count}, %{
      user_id: user_id
    })

    result
  end

  @doc """
  Emits `[:kanban, :notification, :preference_updated]` when `result` is a
  saved preference whose flags differ from `previous`, the preference as it
  was. Returns `result`.
  """
  @spec preference_updated(result, Preference.t()) :: result when result: term()
  def preference_updated(
        {:ok, %Preference{in_app: in_app, email: email}} = result,
        %Preference{in_app: in_app, email: email}
      ),
      do: result

  def preference_updated({:ok, %Preference{} = preference} = result, %Preference{}) do
    Kanban.Telemetry.emit([:kanban, :notification, :preference_updated], %{count: 1}, %{
      user_id: preference.user_id,
      event_type: preference.event_type,
      in_app: preference.in_app,
      mail: preference.email
    })

    result
  end

  def preference_updated(result, _previous), do: result

  @doc """
  Emits `[:kanban, :notification, :unsubscribed]` when `result` is the saved
  preference of an unsubscribe link. The event type is the saved atom, never
  the string the link carried. Returns `result`.
  """
  @spec unsubscribed(result) :: result when result: term()
  def unsubscribed({:ok, %Preference{} = preference} = result) do
    Kanban.Telemetry.emit([:kanban, :notification, :unsubscribed], %{count: 1}, %{
      user_id: preference.user_id,
      event_type: preference.event_type
    })

    result
  end

  def unsubscribed(result), do: result

  @doc """
  Emits `[:kanban, :notification, :email_sent]` for `notification`. Call it
  only once the mailer has accepted the email. Returns `:ok`.
  """
  @spec email_sent(Notification.t()) :: :ok
  def email_sent(%Notification{} = notification) do
    Kanban.Telemetry.emit([:kanban, :notification, :email_sent], %{count: 1}, %{
      notification_id: notification.id,
      user_id: notification.user_id,
      event_type: notification.event_type
    })
  end

  @doc """
  Emits `[:kanban, :notification, :email_skipped]` for the job's
  `notification_id`, which may no longer exist, and the skip `reason` atom.
  Returns `:ok`.
  """
  @spec email_skipped(term(), atom()) :: :ok
  def email_skipped(notification_id, reason) when is_atom(reason) do
    Kanban.Telemetry.emit([:kanban, :notification, :email_skipped], %{count: 1}, %{
      notification_id: notification_id,
      reason: reason
    })
  end

  @doc """
  Emits `[:kanban, :notification, :email_failed]` for `notification`.
  `error` must already be a bounded failure kind from
  `Kanban.Notifications.EmailWorker.failure_kind/1`, never the raw mailer
  reason, which can echo the recipient address. Returns `:ok`.
  """
  @spec email_failed(Notification.t(), atom()) :: :ok
  def email_failed(%Notification{} = notification, error) when is_atom(error) do
    Kanban.Telemetry.emit([:kanban, :notification, :email_failed], %{count: 1}, %{
      notification_id: notification.id,
      user_id: notification.user_id,
      event_type: notification.event_type,
      error: error
    })
  end

  @doc """
  Emits `[:kanban, :digest, :sent]` for `user_id` and the ISO `week`. Call it
  only once the mailer has accepted the digest. Returns `:ok`.
  """
  @spec digest_sent(integer(), String.t()) :: :ok
  def digest_sent(user_id, week) do
    Kanban.Telemetry.emit([:kanban, :digest, :sent], %{count: 1}, %{
      user_id: user_id,
      week: week
    })
  end

  @doc """
  Emits `[:kanban, :digest, :fanout_completed]` with the number of digest
  jobs the fan-out enqueued for the ISO `week`. Returns `:ok`.
  """
  @spec digest_fanout_completed(non_neg_integer(), String.t()) :: :ok
  def digest_fanout_completed(count, week) when is_integer(count) do
    Kanban.Telemetry.emit([:kanban, :digest, :fanout_completed], %{count: count}, %{
      week: week
    })
  end
end
