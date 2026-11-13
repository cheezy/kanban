defmodule Kanban.AuditStream.TestEvent do
  @moduledoc """
  **Send test event**: one synthetic event sent to a destination to check it
  can be reached, with its result reduced to a coarse class
  (`docs/plans/AUDIT-LOG-STREAMING-DESIGN.md` §10.3, §12.5).

  The event has the `stride.audit.v1` shape (`Kanban.AuditStream.Payload`)
  and the action `audit_stream_test_sent`, and carries no real audit data:
  id `0`, which no stored event has, empty metadata and no actor. The
  destination's own adapter builds the request, under a new batch id, and it
  is sent exactly as a batch is: the URL checked again with
  `Kanban.Webhooks.UrlGuard` through `Kanban.AuditStream.Reachability`, and
  POSTed through `Kanban.Webhooks.Transport` to the approved address. It
  never touches the cursor, the destination's state or its attempts.

  ## Classes

    * `:delivered` - the adapter accepted the answer (a 2xx);
    * `:could_not_connect` - a refused connection, a timeout, a host that
      does not resolve, an address `UrlGuard` refuses, and every other
      transport failure, including a connection closed before an answer;
    * `:certificate_invalid` - the TLS handshake failed on the server's
      certificate: expired, revoked, from an unknown CA, issued for another
      host, or failing any other check of its path;
    * `:credentials_refused` - the adapter classified the answer as
      unauthorized (401, 403, and Splunk codes 21 and 22);
    * `{:http_error, status}` - any other answer.

  Nothing more is returned or recorded: no response body, no transport reason,
  no address. The classes still say whether something answered, whether it
  speaks TLS or HTTP and, for an HTTP error, its status:
  `:certificate_invalid` shows that a TLS server is listening, and
  `:delivered`, `:credentials_refused` or `{:http_error, status}` shows that
  an HTTP server answered. Only `:could_not_connect` merges several failures,
  every one its bullet above names. The classes stay, because they tell an
  org-admin how to fix a destination; §12.5 of
  `docs/plans/AUDIT-LOG-STREAMING-DESIGN.md` accepts what they reveal.

  ## Limit and record

  `send_test/3` authorizes, refuses a destination whose URL, credential or
  signing secret can't be read (`{:error, :credentials_unreadable}`), then
  counts the test
  against the `:audit_stream_test` surface of `Kanban.RateLimit`: 10 an hour
  per Organization, keyed on the Organization so deleting and re-creating a
  destination does not reset it. The 11th gets `{:error, {:rate_limited,
  retry_after_ms}}` and sends nothing. The window is a fixed clock hour, not
  a sliding one, so up to 20 can go out in a burst across an hour boundary,
  which §12.5 accepts. The counter is per node and kept in memory, so an
  instance running several nodes allows 10 an hour on each, and a node that
  restarts starts its count again at zero. Every test sent
  records `audit_stream_test_sent` with its outcome, after the send, even
  when the destination was deleted while it was in flight.

  The caller's rights are read again after the URL check, the last step
  before the POST and the one that can wait on DNS, so a caller demoted,
  removed or disabled since `authorize/1` gets `{:error, :unauthorized}`:
  nothing is sent or recorded, though the test still counts against the
  limit. A revocation that commits during the POST itself is recorded as
  sent by that caller.
  """

  import Ecto.Query, only: [from: 2]

  alias Kanban.Accounts.Scope
  alias Kanban.AuditLog.AuditEvent
  alias Kanban.AuditStream.Adapter
  alias Kanban.AuditStream.Destination
  alias Kanban.AuditStream.DestinationEvents
  alias Kanban.AuditStream.Destinations
  alias Kanban.AuditStream.Payload
  alias Kanban.AuditStream.Reachability
  alias Kanban.Organizations
  alias Kanban.Organizations.Organization
  alias Kanban.RateLimit
  alias Kanban.Repo
  alias Kanban.Webhooks.Transport

  @action "audit_stream_test_sent"
  @request_timeout_ms 10_000
  @deadline_ms 15_000

  # The TLS alerts a client raises when it can't verify the server's
  # certificate. Every other alert, such as one raised because the port does
  # not speak TLS at all, is a failed connection, so the class never tells a
  # port that does not speak TLS from a closed one.
  @certificate_alerts [
    :bad_certificate,
    :unsupported_certificate,
    :certificate_revoked,
    :certificate_expired,
    :certificate_unknown,
    :unknown_ca
  ]

  @type class ::
          :delivered
          | :could_not_connect
          | :certificate_invalid
          | :credentials_refused
          | {:http_error, integer()}

  @doc """
  Sends a test event to the Organization's destination and records it. See
  the moduledoc. `opts` are passed to `Reachability.check_url/2` (`:resolver`
  only).
  """
  @spec send_test(Scope.t() | nil, Destination.t(), keyword()) ::
          {:ok, class()}
          | {:error,
             :unauthorized
             | :not_found
             | :credentials_unreadable
             | {:rate_limited, non_neg_integer()}}
  def send_test(scope, %Destination{id: id}, opts \\ []) do
    with {:ok, actor, destination} <- sendable(scope, id),
         {:ok, class} <- send_as(actor, destination, opts) do
      DestinationEvents.test_sent(destination, actor, outcome(class))
      {:ok, class}
    end
  end

  # Sends only while `actor` is still an org-admin, read again just before
  # the POST (see the moduledoc).
  defp send_as(actor, %Destination{organization_id: organization_id} = destination, opts) do
    adapter = Adapter.module_for(destination.kind)
    still_org_admin = fn -> still_org_admin(actor, organization_id) end

    case send_request(adapter, destination, organization(organization_id), opts, still_org_admin) do
      {:error, :unauthorized} = refused -> refused
      sent -> {:ok, classify(sent, adapter)}
    end
  end

  defp still_org_admin(actor, organization_id) do
    if Organizations.org_admin?(actor, organization_id), do: :ok, else: {:error, :unauthorized}
  end

  defp sendable(scope, id) do
    with {:ok, actor, organization_id} <- Destinations.authorize(scope),
         {:ok, destination} <- Destinations.fetch(organization_id, id),
         :ok <- require_readable(destination),
         :ok <- count(organization_id),
         do: {:ok, actor, destination}
  end

  @doc """
  Builds the test request with `destination`'s adapter, sends it and returns
  its class. Records nothing.
  """
  @spec deliver(Destination.t(), Payload.organization(), keyword()) :: class()
  def deliver(%Destination{} = destination, organization, opts \\ []),
    do: destination.kind |> Adapter.module_for() |> deliver(destination, organization, opts)

  # Every kind has an adapter.
  defp deliver(adapter, destination, organization, opts) when is_atom(adapter) do
    adapter
    |> send_request(destination, organization, opts, fn -> :ok end)
    |> classify(adapter)
  end

  # Builds and POSTs the request once `before_send` allows it, after the URL
  # check; returns what the send returned, or `before_send`'s refusal.
  defp send_request(adapter, destination, organization, opts, before_send) do
    {url, headers, body} =
      adapter.build_request(destination, %{
        batch_id: Ecto.UUID.generate(),
        events: [Payload.build(event(), organization)],
        organization: organization
      })

    post(url, body, headers, opts, before_send)
  end

  @doc "The synthetic event: no real audit data."
  @spec event(DateTime.t()) :: AuditEvent.t()
  def event(now \\ DateTime.utc_now()) do
    %AuditEvent{id: 0, action: @action, inserted_at: now, metadata: %{}, actor_redacted: true}
  end

  @doc """
  The class of what a send returned: `{:response, %{status: _, body: _}}`,
  `{:transport_error, error}` or `{:guard_error, reason}`, classified by
  `adapter` when the destination answered.
  """
  @spec classify(term(), module()) :: class()
  def classify({:response, %{status: status, body: body}}, adapter) do
    case adapter.classify(status, body) do
      :ok -> :delivered
      :unauthorized -> :credentials_refused
      _refused -> {:http_error, status}
    end
  end

  def classify({:transport_error, %{reason: {:tls_alert, {alert, description}}}}, _adapter) do
    if certificate_alert?(alert, description), do: :certificate_invalid, else: :could_not_connect
  end

  def classify({:transport_error, _error}, _adapter), do: :could_not_connect
  def classify({:guard_error, _reason}, _adapter), do: :could_not_connect

  # OTP's ssl sends one of @certificate_alerts for the certificate failures
  # it names (a host name mismatch is `bad_certificate`), and falls back to
  # `handshake_failure` for any other path-validation failure, whose
  # description then carries the `bad_cert` reason.
  defp certificate_alert?(alert, _description) when alert in @certificate_alerts, do: true

  defp certificate_alert?(:handshake_failure, description)
       when is_list(description) or is_binary(description),
       do: description |> to_string() |> String.contains?("bad_cert")

  defp certificate_alert?(_alert, _description), do: false

  @doc """
  The `outcome` recorded on `audit_stream_test_sent`: the class without the
  status, from a fixed set of atoms.
  """
  @spec outcome(class()) :: atom()
  def outcome({:http_error, _status}), do: :http_error
  def outcome(class) when is_atom(class), do: class

  # A URL, credential or current signing secret that can't be read can't be
  # sent with (D17), and the adapters raise on one; an unreadable previous
  # signing secret is never needed.
  defp require_readable(destination) do
    case Destination.unreadable_secrets(destination) -- [:previous_signing_secret] do
      [] -> :ok
      _unreadable -> {:error, :credentials_unreadable}
    end
  end

  # Keyed on the Organization, never the destination or the org-admin.
  defp count(organization_id),
    do: RateLimit.check(:audit_stream_test, identity: "organization:#{organization_id}")

  defp organization(organization_id) do
    query =
      from(o in Organization, where: o.id == ^organization_id, select: %{id: o.id, name: o.name})

    Repo.one!(query)
  end

  # `before_send` runs after the URL check whatever it returned, so a caller
  # revoked during the DNS lookup is refused even when the lookup fails.
  defp post(url, body, headers, opts, before_send) do
    checked = Reachability.check_url(url, Keyword.take(opts, [:resolver]))

    with :ok <- before_send.() do
      case checked do
        {:ok, resolved} ->
          within_deadline(fn ->
            Transport.post(resolved, body, headers, request_timeout: @request_timeout_ms)
          end)

        {:error, reason} ->
          {:guard_error, reason}
      end
    end
  end

  # As the dispatch worker sends: unlinked, so a crash is a failed
  # connection, and stopped at the deadline, which is a timeout.
  defp within_deadline(post) do
    task = Task.Supervisor.async_nolink(Kanban.TaskSupervisor, post)

    case Task.yield(task, @deadline_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, response}} -> {:response, response}
      {:ok, {:error, error}} -> {:transport_error, error}
      {:exit, _reason} -> {:transport_error, :crashed}
      nil -> {:transport_error, :timeout}
    end
  end
end
