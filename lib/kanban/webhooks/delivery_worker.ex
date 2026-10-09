defmodule Kanban.Webhooks.DeliveryWorker do
  @moduledoc """
  Delivers one webhook event to one endpoint (W2227), recording a
  `Kanban.Webhooks.Delivery` row for every attempt.

  Job args (string keys once stored): `endpoint_id`, `delivery_id` (a UUID
  that stays the same across retries and is sent as `X-Stride-Delivery`, so
  a receiver can de-duplicate), `event`, and `payload`, the envelope built by
  `Kanban.Webhooks.Payload` when the event happened. The worker never reads
  the task again.

  Each attempt:

    1. A deleted or disabled endpoint ends the job with `:ok`, sending
       nothing and recording nothing.
    2. `UrlGuard.check/2` runs again, because DNS may have changed since the
       endpoint was saved. A blocked or invalid target records a failed
       delivery and cancels the job; a host that does not resolve records a
       failure and retries. A `:slack` endpoint whose stored URL is not a
       Slack incoming webhook is cancelled the same way.
    3. A generic endpoint gets the JSON envelope with the `X-Stride-Event`,
       `X-Stride-Delivery` and `X-Stride-Signature` headers; a Slack
       endpoint gets a `Kanban.Webhooks.SlackFormatter` message and none of
       those headers.
    4. `Kanban.Webhooks.Transport` sends it to the approved address. A 2xx
       is a success; anything else (redirects included, which are never
       followed) or a transport error is recorded and retried with
       exponential backoff, up to 8 attempts.

  Errors returned to Oban (and so stored in `oban_jobs.errors`) are bounded
  terms such as `{:http_status, 500}`; the URL, which for Slack is a
  credential, never appears in them or in the log.
  """
  use Oban.Worker, queue: :webhooks, max_attempts: 8

  alias Kanban.Repo
  alias Kanban.Webhooks
  alias Kanban.Webhooks.Delivery
  alias Kanban.Webhooks.Endpoint
  alias Kanban.Webhooks.Signer
  alias Kanban.Webhooks.SlackFormatter
  alias Kanban.Webhooks.Transport
  alias Kanban.Webhooks.UrlGuard

  require Logger

  @max_backoff 3_600

  @doc "Queues one delivery of `payload` for `event` to the endpoint."
  @spec enqueue(integer(), String.t(), map()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(endpoint_id, event, payload) do
    endpoint_id |> new_job(event, payload) |> Oban.insert()
  end

  @doc "Queues one delivery of the same `payload` to each endpoint."
  @spec enqueue_all([integer()], String.t(), map()) :: :ok
  def enqueue_all(endpoint_ids, event, payload) do
    endpoint_ids
    |> Enum.map(&new_job(&1, event, payload))
    |> Oban.insert_all()

    :ok
  end

  defp new_job(endpoint_id, event, payload) do
    new(%{
      endpoint_id: endpoint_id,
      delivery_id: Ecto.UUID.generate(),
      event: event,
      payload: payload
    })
  end

  @doc """
  Seconds to wait before the next attempt: 15 × 2^attempt with up to 20%
  jitter added, capped at an hour.
  """
  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) do
    attempt
    |> Oban.Backoff.exponential(mult: 15, max_pow: 8)
    |> Oban.Backoff.jitter(mode: :inc, mult: 0.2)
    |> min(@max_backoff)
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"endpoint_id" => endpoint_id} = args, attempt: attempt}) do
    case Repo.get(Endpoint, endpoint_id) do
      %Endpoint{enabled: true} = endpoint -> deliver(endpoint, args, attempt)
      _deleted_or_disabled -> :ok
    end
  end

  defp deliver(endpoint, args, attempt) do
    with {:ok, resolved} <- check_target(endpoint),
         {:ok, body, headers} <- build_request(endpoint, args) do
      resolved
      |> Transport.post(body, headers)
      |> record_outcome(endpoint, args, attempt)
    else
      {:error, reason} -> refuse(endpoint, args, attempt, reason)
    end
  end

  defp check_target(%Endpoint{kind: kind, url: url}) do
    with {:ok, resolved} <- UrlGuard.check(url, resolver_opts()),
         :ok <- check_kind(kind, url) do
      {:ok, resolved}
    end
  end

  defp check_kind(:slack, url),
    do: if(Endpoint.slack_url?(url), do: :ok, else: {:error, :not_slack_url})

  defp check_kind(_kind, _url), do: :ok

  defp build_request(%Endpoint{kind: :slack}, %{"payload" => payload}) do
    body = payload |> SlackFormatter.format() |> Jason.encode!()
    {:ok, body, [{"content-type", "application/json"}]}
  end

  defp build_request(endpoint, %{"payload" => payload} = args) do
    with {:ok, secret} <- secret(endpoint) do
      body = Jason.encode!(payload)

      {:ok, body,
       [
         {"content-type", "application/json"},
         {"user-agent", "Stride-Webhooks/1"},
         {"x-stride-event", args["event"]},
         {"x-stride-delivery", args["delivery_id"]},
         {"x-stride-signature", Signer.sign(body, secret)}
       ]}
    end
  end

  defp secret(endpoint) do
    case Webhooks.signing_secret(endpoint) do
      {:ok, secret} -> {:ok, secret}
      {:error, :invalid} -> {:error, :signing_secret_unavailable}
    end
  end

  # :unresolvable is often a passing DNS problem, so it is retried; every
  # other refusal is permanent until the owner changes the endpoint.
  defp refuse(endpoint, args, attempt, reason) do
    record(endpoint, args, attempt, %{status: :failed, error: to_string(reason)})

    if reason == :unresolvable, do: {:error, reason}, else: {:cancel, reason}
  end

  defp record_outcome({:ok, %{status: status}}, endpoint, args, attempt)
       when status in 200..299 do
    record(endpoint, args, attempt, %{
      status: :succeeded,
      response_status: status,
      delivered_at: DateTime.utc_now()
    })

    :ok
  end

  defp record_outcome({:ok, %{status: status, body: body}}, endpoint, args, attempt) do
    record(endpoint, args, attempt, %{
      status: :failed,
      response_status: status,
      error: "HTTP #{status}: " <> Transport.sanitize(body)
    })

    {:error, {:http_status, status}}
  end

  defp record_outcome({:error, exception}, endpoint, args, attempt) do
    reason = transport_reason(exception)
    record(endpoint, args, attempt, %{status: :failed, error: "transport: #{inspect(reason)}"})
    {:error, {:transport, reason}}
  end

  defp transport_reason(%{reason: reason}) when is_atom(reason), do: reason
  defp transport_reason(%{__struct__: struct}), do: struct

  defp record(endpoint, args, attempt, attrs) do
    attrs = Map.merge(attrs, %{event: args["event"], payload: args["payload"], attempt: attempt})

    case insert_delivery(endpoint.id, attrs) do
      {:ok, _delivery} ->
        :ok

      # The endpoint was deleted while the request was in flight.
      {:error, _changeset} ->
        Logger.warning("webhook delivery for endpoint #{endpoint.id} could not be recorded")
    end
  end

  defp insert_delivery(endpoint_id, attrs) do
    %Delivery{endpoint_id: endpoint_id}
    |> Delivery.changeset(attrs)
    |> Repo.insert()
  end

  defp resolver_opts do
    case Application.get_env(:kanban, __MODULE__, [])[:resolver] do
      {module, function} -> [resolver: &apply(module, function, [&1])]
      nil -> []
    end
  end
end
