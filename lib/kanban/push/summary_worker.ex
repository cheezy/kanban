defmodule Kanban.Push.SummaryWorker do
  @moduledoc """
  Sends the one summary push that follows a person's quiet hours
  (docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §7.9, decision 5).

  `Kanban.Push.PushWorker` holds every push due inside quiet hours
  (`reason: :quiet_hours`) and never sends it later, so the end of a quiet
  period is not a burst of held pushes. Instead, when the period ends and
  decisions are still waiting, this worker sends one push with their count,
  such as "3 things waited overnight", that opens Now.

  ## When it runs

    * **Every 15 minutes**, from the Oban crontab, with no arguments. It looks
      at everyone with quiet hours on (`PushSettingsStore.summary_candidates/1`)
      and takes the latest quiet period that has ended
      (`Kanban.Push.QuietHours.last_ended/2`) when it ended less than two hours
      ago and no summary was taken since. The two-hour bound lets a few missed
      runs catch up without sending a summary hours after the person woke,
      and keeps a `nil` `last_summary_at` from reaching an old period.
    * **Once for one person** (`enqueue_ended/2`), when a settings change ends
      quiet hours while they hold, such as turning them off at night or moving
      to a time zone where they are over. The period ends at the change. A
      change made while a period's summary is due enqueues one too, so the
      change never cancels it. A change made while a one-person job is
      queued, retrying or running (`pending?/1`) enqueues nothing and leaves
      `last_summary_at` alone, so that job sends the summary once.

  A quiet period followed less than 30 minutes later by the next one may
  have no run in the gap, so its summary goes at the first run after it,
  inside the next period.

  ## Exactly once

  A period's summary is taken before it is sent, with a conditional update
  of `last_summary_at` that only one run can win (`claim_summary/3`,
  `claim_ended_summary/3`), so two runs at once send one summary and no lock
  is held while a push service answers. When no device got the summary
  because a device was rate limited or the service was unavailable, the
  summary is given back (`release_summary/3`): the next run sends it, or Oban
  retries a one-person job. A run that stops between taking and sending
  loses that summary rather than sending it twice; the decisions are still
  in Now and on the badge.

  ## What it checks before sending

  The same things `PushWorker` checks, read again after the period is taken:
  an enabled, confirmed user with paid access (`Kanban.Plans.user_unlocked?/1`),
  at least one decision event's push switch on, a device with a push token,
  and decisions waiting (`Kanban.Decisions.build_with_summary/2`, counted
  before the 100-item cap). Each device is read again just before its own
  send (`Kanban.Devices.PushTokens.current/1`), so one revoked meanwhile gets
  nothing. A period with nothing to send is still taken, so it never gets a
  late summary.

  The summary carries only the count (`Kanban.Push.PayloadBuilder.summary/2`),
  in each device's locale. Each run emits `[:kanban, :push, :summarized]` once per
  period it took, with its `outcome`, and `sent` and `failed` per device with
  `event_type: :quiet_hours_summary`. Logs and telemetry never carry a user, a
  device token or the text.
  """

  use Oban.Worker, queue: :push, max_attempts: 3

  import Ecto.Query, warn: false

  alias Kanban.Accounts.Scope
  alias Kanban.Accounts.User
  alias Kanban.Decisions
  alias Kanban.Devices.Device
  alias Kanban.Devices.PushTokens
  alias Kanban.Notifications.Digest
  alias Kanban.Notifications.PushSettings
  alias Kanban.Notifications.PushSettingsStore
  alias Kanban.Plans
  alias Kanban.Push
  alias Kanban.Push.PayloadBuilder
  alias Kanban.Push.PushWorker
  alias Kanban.Push.QuietHours
  alias Kanban.Repo

  require Logger

  @event_type :quiet_hours_summary
  @lookback_seconds 2 * 60 * 60
  # A gap between two periods shorter than this may hold no cron tick.
  @short_gap_seconds 30 * 60
  @pending_states ~w(available scheduled executing retryable)
  @retried [:rate_limited, :unavailable]

  @doc """
  Enqueues the summary for the quiet period a settings change ended at
  `ended_at` for `user_id`. Called inside the change's transaction.
  """
  @spec enqueue_ended(pos_integer(), DateTime.t()) ::
          {:ok, Oban.Job.t()} | {:error, Ecto.Changeset.t()}
  def enqueue_ended(user_id, %DateTime{} = ended_at) when is_integer(user_id) do
    %{user_id: user_id, ended_at: DateTime.to_iso8601(ended_at)}
    |> new()
    |> Oban.insert()
  end

  @doc """
  True when a one-person summary job for `user_id` is queued, scheduled,
  waiting to retry or running. A running job counts: it may not have taken
  its period yet, and once it has, the summary it sends is the one owed.
  """
  @spec pending?(pos_integer()) :: boolean()
  def pending?(user_id) when is_integer(user_id) do
    worker = inspect(__MODULE__)

    Oban.Job
    |> where([j], j.worker == ^worker and j.state in @pending_states)
    |> where([j], fragment("(?->>'user_id')::bigint", j.args) == ^user_id)
    |> Repo.exists?()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id, "ended_at" => ended} = args})
      when is_integer(user_id) and is_binary(ended) do
    now = Digest.parse_now(args)

    case DateTime.from_iso8601(ended) do
      {:ok, ended_at, _offset} -> summarize_ended(user_id, ended_at, now)
      {:error, _reason} -> :ok
    end
  end

  def perform(%Oban.Job{args: args}) do
    now = Digest.parse_now(args)

    for settings <- PushSettingsStore.summary_candidates(now),
        {:due, period_end} <- [due(settings, now)] do
      if PushSettingsStore.claim_summary(settings, period_end, now) == :claimed,
        do: deliver(settings.user_id, settings.last_summary_at, now)
    end

    :ok
  end

  @doc """
  `{:due, period_end}` when the quiet period `settings` give that ended
  latest, at `period_end`, needs a summary at `now`: it ended less than two
  hours ago, no summary was taken since, and no new period has begun, or
  the next one began less than 30 minutes after it ended, a gap the
  15-minute cron may have no run in. Otherwise `:not_due`.
  """
  @spec due(PushSettings.t(), DateTime.t()) :: {:due, DateTime.t()} | :not_due
  def due(%PushSettings{} = settings, %DateTime{} = now) do
    with %DateTime{} = period_end <- QuietHours.last_ended(settings, now),
         true <- owed?(settings, period_end, now) do
      {:due, period_end}
    else
      _not_due -> :not_due
    end
  end

  defp owed?(settings, period_end, now) do
    recent?(period_end, now) and taken_before?(settings.last_summary_at, period_end) and
      reachable?(settings, period_end, now)
  end

  defp recent?(period_end, now), do: DateTime.diff(now, period_end) < @lookback_seconds

  defp reachable?(settings, period_end, now),
    do: settings |> QuietHours.current_start(now) |> reachable?(period_end)

  defp reachable?(nil, _period_end), do: true

  defp reachable?(started_at, period_end),
    do: DateTime.diff(started_at, period_end) < @short_gap_seconds

  defp taken_before?(nil, _period_end), do: true
  defp taken_before?(taken_at, period_end), do: DateTime.compare(taken_at, period_end) == :lt

  # A one-person summary is sent only while quiet hours, as they are now, do
  # not hold: a change that started a new period leaves it to that period.
  defp summarize_ended(user_id, ended_at, now) do
    settings = Repo.get(PushSettings, user_id)

    with false <- QuietHours.inside?(settings, now),
         :claimed <- PushSettingsStore.claim_ended_summary(user_id, ended_at, now) do
      deliver(user_id, settings && settings.last_summary_at, now)
    else
      _not_sent -> :ok
    end
  end

  defp deliver(user_id, previous, now) do
    case prepare(user_id) do
      {:ok, waiting, devices} ->
        devices
        |> send_all(waiting)
        |> finish(user_id, previous, now)

      {:skip, outcome} ->
        emit_summary(outcome)
        :ok
    end
  end

  defp prepare(user_id) do
    with {:ok, user} <- fetch_user(user_id),
         :ok <- check_plan(user),
         :ok <- check_switches(user),
         {:ok, devices} <- fetch_devices(user_id),
         {:ok, waiting} <- count_waiting(user) do
      {:ok, waiting, devices}
    end
  end

  defp fetch_user(user_id) do
    case Repo.get(User, user_id) do
      %User{disabled_at: nil, confirmed_at: %DateTime{}} = user -> {:ok, user}
      _gone_or_inactive -> {:skip, :user_inactive}
    end
  end

  defp check_plan(user),
    do: if(Plans.user_unlocked?(user), do: :ok, else: {:skip, :plan_locked})

  defp check_switches(user) do
    %{switches: switches} = user |> Scope.for_user() |> PushSettingsStore.get()

    if Enum.any?(PushSettings.decision_events(), &Map.fetch!(switches, &1)),
      do: :ok,
      else: {:skip, :switched_off}
  end

  defp fetch_devices(user_id) do
    case PushTokens.list_for_user(user_id) do
      [] -> {:skip, :no_device}
      devices -> {:ok, devices}
    end
  end

  defp count_waiting(user) do
    %{summary: %{waiting: waiting}} =
      user |> Scope.for_user() |> Decisions.build_with_summary(source: :push)

    if waiting > 0, do: {:ok, waiting}, else: {:skip, :nothing_waiting}
  end

  # One payload per locale, one send per device, each device read again
  # just before its send.
  defp send_all(devices, waiting) do
    {results, _payloads} =
      Enum.map_reduce(devices, %{}, fn device, payloads ->
        send_current(PushTokens.current(device), waiting, payloads)
      end)

    results
  end

  defp send_current(nil, _waiting, payloads), do: {:gone, payloads}

  defp send_current(%Device{} = device, waiting, payloads) do
    locale = PayloadBuilder.locale(device)
    payload = Map.get_lazy(payloads, locale, fn -> PayloadBuilder.summary(waiting, locale) end)
    {send_one(device, payload), Map.put(payloads, locale, payload)}
  end

  defp send_one(device, payload) do
    case Push.send(device, payload) do
      :ok ->
        Kanban.Telemetry.emit([:kanban, :push, :sent], %{count: 1}, %{
          platform: device.platform,
          event_type: @event_type
        })

        :ok

      :unregistered ->
        PushTokens.clear(device)
        failed(device, :unregistered)

      {:error, reason} ->
        failed(device, PushWorker.failure_reason(reason))
    end
  end

  defp failed(device, reason) do
    Logger.warning("quiet hours summary push failed (device_id=#{device.id}): #{reason}")

    Kanban.Telemetry.emit([:kanban, :push, :failed], %{count: 1}, %{
      platform: device.platform,
      event_type: @event_type,
      reason: reason
    })

    reason
  end

  # Sent to one device or more: done. Sent to none because of a passing
  # failure: given back for the next run. Otherwise the period stays taken.
  defp finish(results, user_id, previous, now) do
    cond do
      :ok in results ->
        emit_summary(:sent)
        :ok

      Enum.all?(results, &(&1 == :gone)) ->
        emit_summary(:no_device)
        :ok

      reason = Enum.find(results, &(&1 in @retried)) ->
        PushSettingsStore.release_summary(user_id, previous, now)
        emit_summary(:failed)
        {:error, reason}

      true ->
        emit_summary(:failed)
        :ok
    end
  end

  defp emit_summary(outcome),
    do: Kanban.Telemetry.emit([:kanban, :push, :summarized], %{count: 1}, %{outcome: outcome})
end
