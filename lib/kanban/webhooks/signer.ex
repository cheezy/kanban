defmodule Kanban.Webhooks.Signer do
  @moduledoc """
  Builds and checks the `X-Stride-Signature` header on generic webhook
  deliveries (W2226).

  The header is `t=<unix seconds>,v1=<hex HMAC-SHA256>`, where the HMAC is
  keyed with the endpoint's signing secret over `"<t>.<body>"`. Signing the
  timestamp with the body lets a receiver reject replays: `verify/4` refuses
  a timestamp more than five minutes from now. A header may carry several
  `v1` values (one per secret during a rotation); any one matching is enough.
  """

  @tolerance_seconds 300

  @doc """
  Returns the signature header value for `body`, signed with `secret` at
  unix time `timestamp`.
  """
  def sign(body, secret, timestamp \\ System.system_time(:second))
      when is_binary(body) and is_binary(secret) and is_integer(timestamp) do
    "t=#{timestamp},v1=#{digest(body, secret, timestamp)}"
  end

  @doc """
  Returns a signature header value for `body` carrying one `v1` per secret in
  `secrets`, in the order given, all signed at unix time `timestamp`.

  Audit streaming (`Kanban.AuditStream.Adapters.Https`) uses it during a
  rotation, passing the old secret first, so a receiver still holding either
  secret verifies with `verify/4`. With one secret it returns exactly what
  `sign/3` does. Webhook deliveries keep using `sign/3`.
  """
  @spec sign_all(binary(), [binary(), ...], integer()) :: String.t()
  def sign_all(body, [_ | _] = secrets, timestamp \\ System.system_time(:second))
      when is_binary(body) and is_integer(timestamp) do
    signatures = Enum.map_join(secrets, ",", &"v1=#{digest_secret(body, &1, timestamp)}")
    "t=#{timestamp},#{signatures}"
  end

  defp digest_secret(body, secret, timestamp) when is_binary(secret),
    do: digest(body, secret, timestamp)

  @doc """
  Checks a signature header against `body` and `secret`.

  Options: `:now` (unix seconds, defaults to the system clock) and
  `:tolerance` (seconds, defaults to 300). Returns `:ok` or
  `{:error, :malformed_header | :stale_timestamp | :invalid_signature}`.
  """
  def verify(header, body, secret, opts \\ [])
      when is_binary(body) and is_binary(secret) do
    with {:ok, timestamp, signatures} <- parse(header),
         :ok <- check_fresh(timestamp, opts) do
      check_signatures(signatures, digest(body, secret, timestamp))
    end
  end

  defp check_signatures(signatures, expected) do
    if Enum.any?(signatures, &Plug.Crypto.secure_compare(&1, expected)),
      do: :ok,
      else: {:error, :invalid_signature}
  end

  defp digest(body, secret, timestamp) do
    :hmac
    |> :crypto.mac(:sha256, secret, "#{timestamp}.#{body}")
    |> Base.encode16(case: :lower)
  end

  defp check_fresh(timestamp, opts) do
    now = Keyword.get_lazy(opts, :now, fn -> System.system_time(:second) end)
    tolerance = Keyword.get(opts, :tolerance, @tolerance_seconds)

    if abs(now - timestamp) > tolerance, do: {:error, :stale_timestamp}, else: :ok
  end

  defp parse(header) when is_binary(header) do
    pairs = header |> String.split(",") |> Enum.map(&String.split(&1, "=", parts: 2))

    with {:ok, timestamp} <- timestamp(pairs),
         {:ok, signatures} <- signatures(pairs) do
      {:ok, timestamp, signatures}
    else
      _ -> {:error, :malformed_header}
    end
  end

  defp parse(_header), do: {:error, :malformed_header}

  defp signatures(pairs) do
    case for [key, value] <- pairs, key == "v1", do: value do
      [] -> :error
      signatures -> {:ok, signatures}
    end
  end

  defp timestamp(pairs) do
    case for [key, value] <- pairs, key == "t", do: Integer.parse(value) do
      [{timestamp, ""}] -> {:ok, timestamp}
      _ -> :error
    end
  end
end
