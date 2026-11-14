defmodule Kanban.Notifications.AuditStreamEmailWorker do
  @moduledoc """
  Sends one org-admin one audit stream security email
  (`docs/plans/AUDIT-LOG-STREAMING-DESIGN.md` §13.3), enqueued by
  `Kanban.Notifications.AuditStreamAlerts.enqueue/4`.

  Each job is one occurrence for one recipient: its `ref` is shared by the
  occurrence's jobs and names the email's Message-ID. The job is not unique,
  so a second Failing email for the same destination an hour later is its
  own job.

  `perform/1` re-checks that the recipient is still an enabled org-admin of
  the Organization, so an org-admin removed, demoted or disabled after the
  change is skipped. The email is built from the job's snapshot alone, never
  from the destination, which may be gone. It renders in the recipient's
  stored locale, or English (`Kanban.Notifications.AnnouncementWorker.locale_for/1`).
  It is a security email: no preference gates it and it has no unsubscribe
  link.

  Failures are logged — and returned to Oban, which retries — as a bounded
  failure kind plus the user id, never the address or the raw adapter reason.
  No telemetry event is emitted (§13.1).
  """

  use Oban.Worker, queue: :notifications, max_attempts: 3

  alias Kanban.Accounts
  alias Kanban.Accounts.User
  alias Kanban.AuditStream.Destination
  alias Kanban.AuditStream.Gap
  alias Kanban.Mailer
  alias Kanban.Notifications.AnnouncementWorker
  alias Kanban.Notifications.AuditStreamAlerts
  alias Kanban.Notifications.EmailWorker
  alias Kanban.Organizations
  alias KanbanWeb.Emails.AuditStreamEmail

  require Logger

  @failing_reasons [
    :unauthorized,
    :config_error,
    :no_success,
    :rejected_batch,
    :blocked_address,
    :credentials_unreadable
  ]

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"user_id" => user_id, "organization_id" => organization_id} = args
      })
      when is_integer(user_id) and is_integer(organization_id) do
    with {:ok, alert} <- parse(args),
         {:ok, user} <- fetch_recipient(user_id, organization_id) do
      deliver(user, %{alert | actor: actor(args["actor_id"])})
    else
      {:skip, reason} ->
        Logger.info("audit stream email for user_id=#{user_id} skipped: #{reason}")
        :ok
    end
  end

  defp fetch_recipient(user_id, organization_id) do
    with %User{} = user <- Accounts.get_user(user_id),
         true <- Organizations.org_admin?(user, organization_id) do
      {:ok, user}
    else
      _not_a_recipient -> {:skip, :not_a_recipient}
    end
  end

  defp actor(nil), do: :stride

  defp actor(id) when is_integer(id) do
    case Accounts.get_user(id) do
      %User{email: email} -> {:user, email}
      nil -> :deleted_account
    end
  end

  # Never Stride: an id that is not one could only have named a person.
  defp actor(_invalid), do: :deleted_account

  defp deliver(user, alert) do
    email =
      Gettext.with_locale(KanbanWeb.Gettext, AnnouncementWorker.locale_for(user), fn ->
        AuditStreamEmail.build(user, alert)
      end)

    case Mailer.deliver(email) do
      {:ok, _metadata} ->
        :ok

      {:error, reason} ->
        kind = EmailWorker.failure_kind(reason)

        Logger.warning(
          "audit stream #{alert.kind} email delivery failed (user_id=#{user.id}): #{kind}"
        )

        {:error, kind}
    end
  end

  # --- args -------------------------------------------------------------------

  # Every string that becomes an atom is matched against a known list, so a
  # job's args never create one.
  defp parse(%{"alert" => alert, "ref" => ref, "destination" => destination} = args)
       when is_binary(ref) do
    with {:ok, kind} <- parse_kind(alert),
         {:ok, destination} <- parse_destination(destination),
         {:ok, details} <- parse_details(kind, details_arg(args)) do
      {:ok, alert(kind, ref, destination, details)}
    end
  end

  defp parse(_args), do: {:skip, :invalid_args}

  defp parse_kind(alert), do: known(alert, AuditStreamAlerts.kinds(), :unknown_alert)

  defp details_arg(%{"details" => details}) when is_map(details), do: details
  defp details_arg(_args), do: %{}

  defp alert(kind, ref, destination, details),
    do: Map.merge(%{kind: kind, ref: ref, destination: destination, actor: :stride}, details)

  defp parse_destination(%{"id" => id, "kind" => kind, "name" => name} = destination)
       when is_integer(id) and is_binary(name) do
    with {:ok, kind} <- known(kind, Destination.kinds(), :unknown_destination_kind) do
      {:ok,
       %{
         id: id,
         kind: kind,
         name: name,
         url_host: destination["url_host"],
         url_hint: destination["url_hint"],
         credential_hint: destination["credential_hint"],
         site: destination["site"]
       }}
    end
  end

  defp parse_destination(_destination), do: {:skip, :invalid_args}

  defp parse_details(:created, details),
    do: {:ok, %{start_from: string(details["start_from"], "now")}}

  defp parse_details(:updated, details),
    do: {:ok, %{changed: details["changed"] |> List.wrap() |> Enum.filter(&is_binary/1)}}

  defp parse_details(:failing, details) do
    case known(details["reason"], @failing_reasons, :unknown_reason) do
      {:ok, reason} -> {:ok, %{reason: reason}}
      {:skip, _unknown} -> {:ok, %{reason: :unknown}}
    end
  end

  defp parse_details(:gap, %{"gap" => gap}), do: parse_gap(gap)
  defp parse_details(:gap, _details), do: {:skip, :invalid_args}
  defp parse_details(_kind, _details), do: {:ok, %{}}

  defp parse_gap(%{"reason" => reason, "events" => events} = gap) when is_integer(events) do
    with {:ok, reason} <- known(reason, Gap.reasons(), :unknown_gap_reason),
         {:ok, span} <- parse_span(gap) do
      {:ok, %{gap: Map.merge(%{reason: reason, events: events}, span)}}
    end
  end

  defp parse_gap(_gap), do: {:skip, :invalid_args}

  defp parse_span(gap) do
    with {:ok, first_at} <- parse_time(gap["first_at"]),
         {:ok, last_at} <- parse_time(gap["last_at"]) do
      {:ok, %{first_at: first_at, last_at: last_at, opened: gap["opened"] == true}}
    end
  end

  defp parse_time(value) do
    case value |> to_string() |> DateTime.from_iso8601() do
      {:ok, at, _offset} -> {:ok, at}
      {:error, _invalid_date} -> {:skip, :invalid_args}
    end
  end

  defp known(value, atoms, error) when is_binary(value) do
    case Enum.find(atoms, &(Atom.to_string(&1) == value)) do
      nil -> {:skip, error}
      atom -> {:ok, atom}
    end
  end

  defp known(_value, _atoms, error), do: {:skip, error}

  defp string(value, _default) when is_binary(value), do: value
  defp string(_value, default), do: default
end
