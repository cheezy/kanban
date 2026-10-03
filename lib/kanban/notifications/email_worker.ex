defmodule Kanban.Notifications.EmailWorker do
  @moduledoc """
  Delivers the email for one notification.

  `Kanban.Notifications.notify/3` calls `enqueue/1` inside its insert
  transaction, passing only the rows whose recipient wants email, so a
  rolled-back notification never leaves a job behind. Jobs are unique per
  `notification_id` for as long as Oban keeps them, and `emailed_at` is the
  durable guard: once it is set, a later perform sends nothing.

  `perform/1` re-reads the notification and the recipient's current user row
  and returns `:ok` without sending when the notification is gone or already
  emailed, the user is disabled or unconfirmed, or the user no longer
  belongs to the notification's board.

  Delivery is at-least-once: the email is sent before `emailed_at` is
  stamped, so a crash between the two can resend on retry (the stable
  `Message-ID` lets mail clients collapse the duplicate). Stamping first
  would instead drop emails whenever SMTP fails.

  Failures are logged — and returned to Oban — as a bounded failure kind
  (`:permanent_failure`, `:temporary_failure`, `:retries_exceeded` or
  `:delivery_failed`) plus the notification id. The raw adapter reason is
  never logged: SMTP replies often echo the recipient address.
  """

  use Oban.Worker,
    queue: :notifications,
    max_attempts: 5,
    unique: [period: :infinity, fields: [:worker, :args], keys: [:notification_id]]

  import Ecto.Query, warn: false

  alias Kanban.Accounts.User
  alias Kanban.Boards.BoardUser
  alias Kanban.Mailer
  alias Kanban.Notifications.Notification
  alias Kanban.Repo
  alias KanbanWeb.Emails.NotificationEmail

  require Logger

  @doc """
  Enqueues one delivery job per notification.

  Returns `:ok`, or `{:error, changeset}` for the first job that could not be
  inserted so the caller can roll back.
  """
  @spec enqueue([Notification.t()]) :: :ok | {:error, Ecto.Changeset.t()}
  def enqueue(notifications) when is_list(notifications) do
    Enum.reduce_while(notifications, :ok, &insert_job/2)
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
    with {:ok, notification} <- fetch_pending(id),
         :ok <- check_recipient(notification.user),
         :ok <- check_membership(notification, notification.user) do
      deliver(notification, notification.user)
    else
      {:skip, reason} ->
        Logger.info("notification email #{id} skipped: #{reason}")
        :ok
    end
  end

  # The user is preloaded fresh with the notification, so a changed address is
  # honoured. user_id is a non-null cascading foreign key, so it is always
  # present.
  defp fetch_pending(id) do
    case Repo.get(Notification, id) do
      nil -> {:skip, :not_found}
      %Notification{emailed_at: %DateTime{}} -> {:skip, :already_emailed}
      notification -> {:ok, Repo.preload(notification, [:board, :user])}
    end
  end

  defp check_recipient(%User{disabled_at: %DateTime{}}), do: {:skip, :user_disabled}
  defp check_recipient(%User{confirmed_at: nil}), do: {:skip, :user_unconfirmed}
  defp check_recipient(%User{}), do: :ok

  defp check_membership(%Notification{board_id: nil}, _user), do: :ok

  defp check_membership(%Notification{board_id: board_id}, %User{id: user_id}) do
    if BoardUser |> where(board_id: ^board_id, user_id: ^user_id) |> Repo.exists?() do
      :ok
    else
      {:skip, :not_a_member}
    end
  end

  defp deliver(notification, user) do
    case notification |> NotificationEmail.build(user) |> Mailer.deliver() do
      {:ok, _metadata} ->
        stamp_emailed(notification)
        :ok

      {:error, reason} ->
        kind = failure_kind(reason)

        Logger.warning(
          "notification email delivery failed (notification_id=#{notification.id}): #{kind}"
        )

        {:error, kind}
    end
  end

  defp failure_kind({:permanent_failure, _host, _reply}), do: :permanent_failure
  defp failure_kind({:temporary_failure, _host, _reply}), do: :temporary_failure
  defp failure_kind({:retries_exceeded, _detail}), do: :retries_exceeded
  defp failure_kind(_reason), do: :delivery_failed

  defp stamp_emailed(%Notification{id: id}) do
    Notification
    |> where([n], n.id == ^id and is_nil(n.emailed_at))
    |> Repo.update_all(set: [emailed_at: DateTime.utc_now()])
  end
end
