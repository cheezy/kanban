defmodule Kanban.Push.PushWorker do
  @moduledoc """
  Delivers the push for one notification to each of its recipient's devices
  (docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §7.8, §9.4, §10).

  ## Enqueueing

  `Kanban.Notifications.notify/3` calls `recipient_ids/2` and `enqueue/2`
  inside its insert transaction, so a rolled-back notification never leaves a
  job behind, and `notify/3` itself never sends. A job is enqueued only for a
  recipient who:

    * has push on for the event type (the saved switch, else the default;
      the four never-push event types never push),
    * has at least one active device with a push token
      (`Kanban.Devices.PushTokens`), and
    * has paid access (`Kanban.Plans.unlocked_user_ids/1`).

  Jobs run on the `:push` queue, are unique per `notification_id` for as long
  as Oban keeps them and are tried 5 times with Oban's backoff.

  ## Sending

  `perform/1` re-reads everything, because any of it can change between the
  enqueue and the send, and goes through §7.8's steps in order:

    1. **the plan**, as `Kanban.Notifications.EmailWorker` checks it: the
       recipient always, and the board when there is one;
    2. **the push switch** for the event type. A switch turned off since the
       enqueue holds the push (`reason: :mode`). Quiet hours come next, in a
       later task;
    3. **the decision**, for the four decision events only: one that is no
       longer open (a review approved in the meantime, a released card that
       cleared) holds the push (`reason: :resolved`);
    4. **the payload**, built per device locale by `Kanban.Push.PayloadBuilder`;
    5. **the send**, to each device that is still active with a push token,
       each device read again just before its own send
       (`Kanban.Devices.PushTokens.current/1`), so one revoked while the job
       runs gets nothing.

  The notification and recipient checks `EmailWorker` makes come first: a
  missing notification, a disabled or unconfirmed user, or a user no longer
  on the notification's board sends nothing. Each of these, a lost plan, or
  no device left is logged with the notification id and its reason and ends
  the job with `:ok`. The device list is read right after the plan, so a job
  with no device left ends there and never emits `held`.

  The decision check reads `Kanban.Decisions.build_with_summary/2` once per
  job, which also gives the badge (the decisions waiting, counted before the
  100-item cap). That list reads only in-app rows, so a released or
  expired-claim decision missing from it is checked on its own row
  (`Kanban.Decisions.Sources.notification_open?/2`), whatever its `in_app`
  flag. A review or a failed hook missing from a list cut at 100 items is
  sent without its counts; missing from a list that was not cut, it is
  resolved.

  ## Results

    * `:ok` from the adapter emits `[:kanban, :push, :sent]`;
    * `:unregistered` clears that device's push token and emits
      `[:kanban, :push, :failed]` with `reason: :unregistered`;
    * any other error emits `failed` with a bounded reason (`failure_reason/1`).
      When a device was rate limited or the push service was unavailable, the
      job returns `{:error, reason}` so Oban retries it; every other result
      ends the job with `:ok`.

  Delivery is at least once: a retry sends again to the devices that already
  got the push, and the collapse id lets the device replace the duplicate.

  No push token, title, body or target name is ever logged or put in
  telemetry; logs carry the notification id, a device id and a reason, and
  telemetry carries the platform, the event type and the reason.
  """

  use Oban.Worker,
    queue: :push,
    max_attempts: 5,
    unique: [period: :infinity, fields: [:worker, :args], keys: [:notification_id]]

  import Ecto.Query, warn: false

  alias Kanban.Accounts.Scope
  alias Kanban.Accounts.User
  alias Kanban.Boards.BoardUser
  alias Kanban.Decisions
  alias Kanban.Decisions.Sources
  alias Kanban.Devices.Device
  alias Kanban.Devices.PushTokens
  alias Kanban.Notifications
  alias Kanban.Notifications.Notification
  alias Kanban.Notifications.Preference
  alias Kanban.Notifications.PushSettings
  alias Kanban.Organizations
  alias Kanban.Plans
  alias Kanban.Push
  alias Kanban.Push.PayloadBuilder
  alias Kanban.Repo
  alias Kanban.Tasks.Task

  require Logger

  @passed_through [
    :unregistered,
    :rate_limited,
    :not_configured,
    :no_push_token,
    :no_push_environment,
    :unsupported_platform
  ]
  @unavailable [
    :timeout,
    :service_unavailable,
    :internal_server_error,
    :unavailable,
    :internal,
    :unknown_error
  ]
  @retried [:rate_limited, :unavailable]

  @doc """
  Returns the ids of the recipients in `deliveries` who get a push for
  `event_type`: push on, an active device with a push token, and paid access.
  """
  @spec recipient_ids(atom(), [map()]) :: MapSet.t(pos_integer())
  def recipient_ids(event_type, deliveries) do
    if event_type in PushSettings.push_events() do
      for(%{push: true, user_id: id} <- deliveries, do: id)
      |> PushTokens.user_ids_with_device()
      |> MapSet.to_list()
      |> Plans.unlocked_user_ids()
    else
      MapSet.new()
    end
  end

  @doc """
  Enqueues one push job for each of `notifications` whose recipient is in
  `user_ids`.

  Returns `:ok`, or `{:error, changeset}` for the first job that could not be
  inserted so the caller can roll back.
  """
  @spec enqueue([Notification.t()], MapSet.t(pos_integer())) ::
          :ok | {:error, Ecto.Changeset.t()}
  def enqueue(notifications, user_ids) when is_list(notifications) do
    notifications
    |> Enum.filter(&MapSet.member?(user_ids, &1.user_id))
    |> Enum.reduce_while(:ok, &insert_job/2)
  end

  # Oban.insert_all ignores `unique` on the Basic engine, so insert one by one.
  defp insert_job(%Notification{id: id}, :ok) do
    case %{notification_id: id} |> new() |> Oban.insert() do
      {:ok, _job} -> {:cont, :ok}
      {:error, changeset} -> {:halt, {:error, changeset}}
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"notification_id" => id}}) do
    case prepare(id) do
      {:ok, notification, context, devices} ->
        deliver(notification, context, devices)

      {:held, notification, reason} ->
        Kanban.Telemetry.emit([:kanban, :push, :held], %{count: 1}, %{
          event_type: notification.event_type,
          reason: reason
        })

        :ok

      {:skip, reason} ->
        Logger.info("notification push #{id} skipped: #{reason}")
        :ok
    end
  end

  # §7.8's steps 1-3, then what step 4 builds from.
  defp prepare(id) do
    with {:ok, n} <- fetch(id),
         :ok <- check_access(n),
         {:ok, devices} <- check_delivery(n),
         {:ok, context} <- build_context(n) do
      {:ok, n, context, devices}
    end
  end

  # The devices first, so a job with no device left ends before the switch
  # could hold it; then the push switch.
  defp check_delivery(n) do
    with {:ok, devices} <- fetch_devices(n),
         :ok <- check_settings(n) do
      {:ok, devices}
    end
  end

  # The recipient, their board membership and the plan, in that order.
  defp check_access(%Notification{user: user} = n) do
    with :ok <- check_recipient(user),
         :ok <- check_membership(n) do
      check_plan(n)
    end
  end

  defp build_context(%Notification{user: user} = n) do
    decisions = load_decisions(user)

    with {:ok, decision} <- check_open(n, decisions),
         {:ok, subject} <- fetch_subject(n) do
      {:ok,
       %{
         hide_titles: Organizations.hide_titles?(user),
         badge: decisions.summary.waiting,
         subject: subject,
         decision: decision
       }}
    end
  end

  defp fetch(id) do
    case Repo.get(Notification, id) do
      nil -> {:skip, :not_found}
      notification -> {:ok, Repo.preload(notification, :user)}
    end
  end

  defp check_recipient(%User{disabled_at: %DateTime{}}), do: {:skip, :user_disabled}
  defp check_recipient(%User{confirmed_at: nil}), do: {:skip, :user_unconfirmed}
  defp check_recipient(%User{}), do: :ok

  defp check_membership(%Notification{board_id: nil}), do: :ok

  defp check_membership(%Notification{board_id: board_id, user_id: user_id}) do
    if BoardUser |> where(board_id: ^board_id, user_id: ^user_id) |> Repo.exists?(),
      do: :ok,
      else: {:skip, :not_a_member}
  end

  # Step 1: the recipient first, then the board, read fresh by id.
  defp check_plan(%Notification{board_id: nil, user: user}),
    do: plan_verdict(Plans.user_unlocked?(user))

  defp check_plan(%Notification{board_id: board_id, user: user}),
    do: plan_verdict(Plans.user_unlocked?(user) and Plans.board_unlocked?(board_id))

  defp plan_verdict(true), do: :ok
  defp plan_verdict(false), do: {:skip, :plan_locked}

  # Step 2: the switch the person set, read again. Quiet hours (the next
  # task) are checked here too, holding the push with reason :quiet_hours.
  defp check_settings(%Notification{event_type: type} = n) do
    cond do
      type not in PushSettings.push_events() -> {:skip, :not_pushable}
      push_on?(n) -> :ok
      true -> {:held, n, :mode}
    end
  end

  defp push_on?(%Notification{user_id: user_id, event_type: type}) do
    preference =
      Repo.get_by(Preference, user_id: user_id, event_type: type) ||
        Notifications.default_preference(type)

    preference.push
  end

  defp load_decisions(user),
    do: user |> Scope.for_user() |> Decisions.build_with_summary(source: :push)

  # Step 3: decision events only.
  defp check_open(%Notification{} = n, decisions),
    do: n |> PayloadBuilder.decision_id() |> open_item(n, decisions)

  defp open_item(nil, _n, _decisions), do: {:ok, nil}

  defp open_item(decision_id, n, %{items: items} = decisions) do
    case Enum.find(items, &(&1.id == decision_id)) do
      nil -> open_beyond_list(n, decisions)
      item -> {:ok, item}
    end
  end

  # The list reads only in-app rows and stops at 100 items. A released or
  # expired-claim decision missing from it is checked on its own row, so a
  # push-only (hidden) row is judged like a visible one. A review or a
  # failed hook missing from a full list may rank below the cap, so it is
  # sent without the counts the item would have given.
  defp open_beyond_list(%Notification{event_type: type} = n, _decisions)
       when type in [:task_unclaimed, :claim_expired] do
    n = Repo.preload(n, task: :column)

    if Sources.notification_open?(n, DateTime.utc_now()),
      do: {:ok, nil},
      else: {:held, n, :resolved}
  end

  defp open_beyond_list(_n, %{items: items, summary: %{waiting: waiting}})
       when waiting > length(items),
       do: {:ok, nil}

  defp open_beyond_list(n, _decisions), do: {:held, n, :resolved}

  defp fetch_subject(%Notification{event_type: :target_status_changed, title: name}),
    do: {:ok, %{name: name}}

  defp fetch_subject(%Notification{task_id: nil}), do: {:skip, :subject_gone}

  defp fetch_subject(%Notification{task_id: task_id}) do
    Task
    |> where([t], t.id == ^task_id)
    |> select([t], %{identifier: t.identifier, title: t.title})
    |> Repo.one()
    |> case do
      nil -> {:skip, :subject_gone}
      subject -> {:ok, subject}
    end
  end

  defp fetch_devices(%Notification{user_id: user_id}) do
    case PushTokens.list_for_user(user_id) do
      [] -> {:skip, :no_device}
      devices -> {:ok, devices}
    end
  end

  # Steps 4 and 5: one payload per device locale, one send per device.
  defp deliver(notification, context, devices) do
    {results, _payloads} =
      Enum.map_reduce(devices, %{}, fn device, payloads ->
        deliver_one(notification, context, PushTokens.current(device), payloads)
      end)

    case Enum.find(results, &(&1 in @retried)) do
      nil -> :ok
      reason -> {:error, reason}
    end
  end

  # The device is read again just before its send: one revoked, or whose
  # token moved, since the job listed the devices gets nothing.
  defp deliver_one(_notification, _context, nil, payloads), do: {:gone, payloads}

  defp deliver_one(notification, context, %Device{} = device, payloads) do
    {payload, payloads} = payload_for(notification, context, device, payloads)
    {send_one(notification, device, payload), payloads}
  end

  defp payload_for(notification, context, device, payloads) do
    locale = PayloadBuilder.locale(device)

    case Map.fetch(payloads, locale) do
      {:ok, payload} ->
        {payload, payloads}

      :error ->
        payload = PayloadBuilder.build(notification, Map.put(context, :locale, locale))
        {payload, Map.put(payloads, locale, payload)}
    end
  end

  defp send_one(notification, %Device{} = device, payload) do
    case Push.send(device, payload) do
      :ok ->
        Kanban.Telemetry.emit([:kanban, :push, :sent], %{count: 1}, %{
          platform: device.platform,
          event_type: notification.event_type
        })

        :ok

      :unregistered ->
        PushTokens.clear(device)
        failed(notification, device, :unregistered)

      {:error, reason} ->
        failed(notification, device, failure_reason(reason))
    end
  end

  defp failed(notification, device, reason) do
    Logger.warning(
      "notification push failed (notification_id=#{notification.id}, device_id=#{device.id}): #{reason}"
    )

    Kanban.Telemetry.emit([:kanban, :push, :failed], %{count: 1}, %{
      platform: device.platform,
      event_type: notification.event_type,
      reason: reason
    })

    reason
  end

  @doc """
  Maps an adapter error to a bounded reason that is safe to log, to put in
  telemetry and to return to Oban: the known reasons pass through, the push
  service being down or erroring is `:unavailable`, and anything else is
  `:rejected`.
  """
  @spec failure_reason(term()) :: atom()
  def failure_reason(reason) when reason in @passed_through, do: reason
  def failure_reason(reason) when reason in @unavailable, do: :unavailable
  def failure_reason(_reason), do: :rejected
end
