defmodule Kanban.Notifications do
  @moduledoc """
  The Notifications context: durable per-user notifications, delivery
  preferences and live updates over PubSub.

  `notify/3` is the single entry point every event source uses (task
  lifecycle hooks, sweepers, the comment goal). It resolves each recipient's
  in-app and email preferences (`Kanban.Notifications.Recipients`), inserts
  at most one row per `(user, dedupe_key)` and broadcasts each new in-app row
  on that user's own topic. In the same transaction it enqueues a
  `Kanban.Notifications.EmailWorker` job for each new row whose recipient
  wants email for the event type (saved preference, else the default below),
  and a `Kanban.Push.PushWorker` job for each new row whose recipient has push
  on for it, an active device with a push token and paid access. A recipient
  with push on but in-app and email off gets a hidden row only when a push
  can reach them.

  ## Module layout

  This module is the public API. Every function delegates to the module that
  owns its concern, so callers only ever use `Kanban.Notifications`:

    * `Kanban.Notifications.Delivery` - `notify/3`: recipient resolution,
      row inserts, email and push enqueueing, and the plan gate
    * `Kanban.Notifications.Inbox` - `list_notifications/2`,
      `unread_count/1`, `mark_read/2` and `mark_all_read/1`
    * `Kanban.Notifications.Preferences` - `event_types/0`,
      `default_preference/1`, `get_preferences/1`, `update_preference/3`
      and `unsubscribe/2`
    * `Kanban.Notifications.Broadcaster` - `topic/1`, `subscribe/1` and the
      broadcasts `Delivery` and `Inbox` send
    * `Kanban.Notifications.Visibility` - the visibility rule `Inbox` reads
      through, and `list_task_notifications/4`
    * `Kanban.Notifications.ExpiredClaims` - `list_recently_expired_claims/2`
    * `Kanban.Notifications.PushSettingsStore`,
      `Kanban.Notifications.DigestRecipients` and
      `Kanban.Notifications.AuditStreamAlerts` - push settings, digest
      recipients and audit stream security emails

  `Delivery` uses `Preferences` for event types and defaults,
  `Kanban.Notifications.Recipients` for who hears about an event and
  `Broadcaster` for live updates; `Inbox` uses `Visibility` and
  `Broadcaster`. None of them calls back into this module.

  ## Visibility

  Read and mark functions take a `%Kanban.Accounts.Scope{}` and only ever
  touch the scoped user's in-app rows (rows stored for email-only delivery,
  with `in_app: false`, never appear in the inbox or the unread count).
  `notify/3` applies the same membership rule at write time: when an event
  names a board, recipients who do not belong to that board are dropped
  before anything is inserted or broadcast. A notification tied to a board
  is hidden once the user no longer belongs to that board; a notification
  with a nil `board_id` (an account-level event such as being removed from a
  board) is always visible to its user.

  ## Paid plans

  While paid plans are enforced, `notify/3` drops every event on a board that
  is not paid (`Kanban.Plans.board_unlocked?/1`): nothing is inserted,
  broadcast or emailed, and it returns `{:ok, []}`. Board-less events are
  gated by their producers. A recipient without paid access gets no email
  job, even on a paid board, and `Kanban.Notifications.EmailWorker` checks
  both the recipient and the board again before it sends. The inbox and the unread count show only
  paid boards' rows and board-less rows, and `update_preference/3` refuses
  users without paid access.

  ## Default preferences

  Preferences are stored only when a user changes them; `default_preference/1`
  supplies the rest, so existing users need no backfill. In-app delivery is on
  for every event type. Email is on for events that ask the user to act or
  that change their access:

  | Event type              | Email by default |
  |-------------------------|------------------|
  | `review_requested`      | yes              |
  | `task_reviewed`         | yes              |
  | `task_assigned`         | yes              |
  | `task_unclaimed`        | yes              |
  | `claim_expired`         | yes              |
  | `after_goal_failed`     | yes              |
  | `board_access_changed`  | yes              |
  | `target_status_changed` | yes              |
  | `mentioned`             | yes              |
  | `weekly_digest`         | yes              |
  | `goal_completed`        | no               |
  | `comment_added`         | no               |

  Push is on by default for the four decision events (`review_requested`,
  `task_unclaimed`, `claim_expired` and `after_goal_failed`) and off for
  everything else; `task_assigned`, `board_access_changed`, `weekly_digest`
  and `comment_added` never push.

  ## Push settings

  `get_push_settings/1`, `update_push_settings/3` and
  `ensure_push_settings_for_device/1` read and write the person's push mode,
  the eight push switches, quiet hours and time zone; see
  `Kanban.Notifications.PushSettings` and
  `Kanban.Notifications.PushSettingsStore`.

  ## PubSub messages

  Subscribers to `topic/1` receive:

    * `{:notification_created, %Notification{}}` for every newly inserted row
    * `{:notifications_read, unread_count}` after `mark_read/2` or
      `mark_all_read/1`

  ## Audit streaming security emails

  `enqueue_audit_stream_email/4` emails every enabled org-admin of an
  Organization about its audit stream destinations
  (`Kanban.Notifications.AuditStreamAlerts`). They are security emails, so
  they bypass `notify/3`: no in-app row, no preference, no plan gate and no
  unsubscribe link.
  """

  alias Kanban.Accounts.Scope
  alias Kanban.Accounts.User
  alias Kanban.Notifications.AuditStreamAlerts
  alias Kanban.Notifications.Broadcaster
  alias Kanban.Notifications.Delivery
  alias Kanban.Notifications.DigestRecipients
  alias Kanban.Notifications.ExpiredClaims
  alias Kanban.Notifications.Inbox
  alias Kanban.Notifications.Notification
  alias Kanban.Notifications.Preference
  alias Kanban.Notifications.Preferences
  alias Kanban.Notifications.PushSettings
  alias Kanban.Notifications.PushSettingsStore
  alias Kanban.Notifications.Visibility
  alias Kanban.Tasks.Task

  @type event_type :: Preferences.event_type()
  @type notify_attrs :: Delivery.notify_attrs()

  # -- preferences: Kanban.Notifications.Preferences -------------------------

  @doc """
  Returns every notification event type, including the reserved
  `:comment_added` and `:mentioned` types.
  """
  @spec event_types() :: [event_type()]
  defdelegate event_types(), to: Preferences

  @doc """
  Returns the in-code default preference for an event type, as an unsaved
  `%Preference{}` with no user. Accepts the atom or string form and raises
  `ArgumentError` for an unknown event type; see
  `Kanban.Notifications.Preferences.default_preference/1`.
  """
  @spec default_preference(event_type() | String.t()) :: Preference.t()
  defdelegate default_preference(event_type), to: Preferences

  @doc """
  Returns the scoped user's preference for every event type, in
  `event_types/0` order. Types without a saved row use
  `default_preference/1`.
  """
  @spec get_preferences(Scope.t()) :: [Preference.t()]
  defdelegate get_preferences(scope), to: Preferences

  @doc """
  Creates or updates the scoped user's preference for one event type,
  refusing a user without paid access while plans are enforced; see
  `Kanban.Notifications.Preferences.update_preference/3`.
  """
  @spec update_preference(Scope.t(), event_type() | String.t(), map()) ::
          {:ok, Preference.t()}
          | {:error, :invalid_event_type | {:plan_required, :notifications} | Ecto.Changeset.t()}
  defdelegate update_preference(scope, event_type, attrs), to: Preferences

  @doc """
  Turns email off for one user and one event type, leaving in-app delivery
  as it was, for the signed unsubscribe links. Never a paid action; see
  `Kanban.Notifications.Preferences.unsubscribe/2`.
  """
  @spec unsubscribe(pos_integer(), event_type() | String.t()) ::
          :ok | {:error, :not_found | :invalid_event_type | Ecto.Changeset.t()}
  defdelegate unsubscribe(user_id, event_type), to: Preferences

  # -- PubSub: Kanban.Notifications.Broadcaster ------------------------------

  @doc """
  Returns the PubSub topic carrying one user's notification events.
  """
  @spec topic(Scope.t() | User.t() | pos_integer()) :: String.t()
  defdelegate topic(scope_or_user), to: Broadcaster

  @doc """
  Subscribes the calling process to a user's notification topic.
  """
  @spec subscribe(Scope.t() | User.t() | pos_integer()) :: :ok | {:error, term()}
  defdelegate subscribe(scope_or_user), to: Broadcaster

  # -- delivery: Kanban.Notifications.Delivery -------------------------------

  @doc """
  Records an event for a list of recipients: at most one row per recipient
  and `dedupe_key`, their email and push jobs enqueued in the same
  transaction, and each new in-app row broadcast as
  `{:notification_created, notification}` after it commits.

  Returns `{:ok, inserted}`, `{:error, :invalid_event_type}` or
  `{:error, changeset}` (nothing is inserted for anyone). See
  `Kanban.Notifications.Delivery.notify/3` for the attributes and rules.
  """
  @spec notify(event_type() | String.t(), [User.t() | nil], notify_attrs() | map()) ::
          {:ok, [Notification.t()]} | {:error, :invalid_event_type | Ecto.Changeset.t()}
  defdelegate notify(event_type, recipients, attrs), to: Delivery

  # -- inbox: Kanban.Notifications.Inbox -------------------------------------

  @doc """
  Lists the scoped user's visible notifications, newest first; see
  `Kanban.Notifications.Inbox.list_notifications/2` for the `:unread_only`,
  `:limit` and `:before` options.
  """
  @spec list_notifications(Scope.t(), keyword()) :: [Notification.t()]
  defdelegate list_notifications(scope, opts \\ []), to: Inbox

  @doc """
  Counts the scoped user's visible unread notifications.
  """
  @spec unread_count(Scope.t()) :: non_neg_integer()
  defdelegate unread_count(scope), to: Inbox

  @doc """
  Marks one of the scoped user's notifications read and broadcasts the new
  unread count. Returns `{:error, :not_found}` for an id the user cannot
  see; see `Kanban.Notifications.Inbox.mark_read/2`.
  """
  @spec mark_read(Scope.t(), integer() | String.t()) ::
          {:ok, Notification.t()} | {:error, :not_found}
  defdelegate mark_read(scope, id), to: Inbox

  @doc """
  Marks every visible unread notification of the scoped user read and
  broadcasts the new unread count. Returns `{:ok, updated_count}`; see
  `Kanban.Notifications.Inbox.mark_all_read/1`.
  """
  @spec mark_all_read(Scope.t()) :: {:ok, non_neg_integer()}
  defdelegate mark_all_read(scope), to: Inbox

  # -- other reads and stores ------------------------------------------------

  @doc """
  Lists tasks whose agent claim expired in `[now - lookback_seconds, now)`
  and that are still in Doing; see
  `Kanban.Notifications.ExpiredClaims.list_recently_expired_claims/2`.
  Read-only; never unclaims anything.
  """
  @spec list_recently_expired_claims(DateTime.t(), pos_integer()) :: [Task.t()]
  defdelegate list_recently_expired_claims(now, lookback_seconds), to: ExpiredClaims

  @doc """
  Lists the scoped user's visible notifications of `event_types` on tasks on
  `board_ids`, newest first, with each task and its column preloaded; see
  `Kanban.Notifications.Visibility.list_task_notifications/4`.
  """
  @spec list_task_notifications(Scope.t(), [event_type()], [integer()], keyword()) ::
          [Notification.t()]
  defdelegate list_task_notifications(scope, event_types, board_ids, opts \\ []),
    to: Visibility

  @doc "The scoped user's push settings; see `PushSettingsStore.get/1`."
  @spec get_push_settings(Scope.t()) :: PushSettings.view()
  defdelegate get_push_settings(scope), to: PushSettingsStore, as: :get

  @doc "Changes the scoped user's push settings; see `PushSettingsStore.update/3`."
  @spec update_push_settings(Scope.t(), map(), keyword()) ::
          {:ok, PushSettings.view()} | {:error, Ecto.Changeset.t() | {:plan_required, atom()}}
  defdelegate update_push_settings(scope, attrs, opts), to: PushSettingsStore, as: :update

  @doc """
  Creates a device user's push settings row on their first device; see
  `PushSettingsStore.ensure_for_device/1`.
  """
  defdelegate ensure_push_settings_for_device(insert_result),
    to: PushSettingsStore,
    as: :ensure_for_device

  @doc "Ids of the users who should receive the weekly digest; see `DigestRecipients`."
  defdelegate list_digest_recipients(), to: DigestRecipients

  @doc """
  Enqueues the audit stream security email `kind` about `destination` for
  every enabled org-admin of its Organization; see `AuditStreamAlerts`. Call it
  inside the transaction that makes the change. These emails skip `notify/3`:
  no preference or plan gates them. `actor` is `nil` when Stride recorded it.
  """
  @spec enqueue_audit_stream_email(
          atom(),
          AuditStreamAlerts.destination_ref(),
          User.t() | nil,
          map()
        ) ::
          :ok | {:error, Ecto.Changeset.t()}
  defdelegate enqueue_audit_stream_email(kind, destination, actor, details \\ %{}),
    to: AuditStreamAlerts,
    as: :enqueue
end
