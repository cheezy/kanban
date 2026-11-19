defmodule Kanban.Reviews.ApprovalSignature do
  @moduledoc """
  The string the app signs to approve a review, and the check of its
  signature (docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §6.6, §7.5).
  `Kanban.Reviews.Approval` runs the approval and delegates its
  `signing_string/3`, `stamp/1` and `verify_signature/3` here.

  ## The signing string

  The app signs these five lines joined by a line feed (`\\n`), in UTF-8,
  with no trailing line feed:

      stride-approval-v1
      <nonce>
      <task id, in decimal>
      <review_requested_at>
      approve

  `<review_requested_at>` is the value the challenge response returned, an
  ISO 8601 UTC timestamp such as `2026-11-18T09:30:00Z`, or the empty string
  when the task has none. The signature is ECDSA P-256 with SHA-256 over
  those bytes, as a DER `ECDSA-Sig-Value` in unpadded URL-safe base64.

  Both the signature and the device's approval public key must be in that
  canonical encoding: padded base64, or a last character whose unused bits
  are set, is refused rather than decoded leniently.
  """

  @signing_version "stride-approval-v1"
  @decision "approve"
  # A P-256 key is 87 characters and a DER signature at most 96; anything far
  # longer is refused before it is decoded.
  @max_encoded_length 256

  @doc "The first line of the signing string: `#{@signing_version}`."
  @spec signing_version() :: String.t()
  def signing_version, do: @signing_version

  @doc """
  The string the app signs to approve task `task_id` with `nonce`, for a task
  whose `review_requested_at` is `review_requested_at` (see the moduledoc).
  """
  @spec signing_string(String.t(), integer(), DateTime.t() | nil) :: String.t()
  def signing_string(nonce, task_id, review_requested_at)
      when is_binary(nonce) and is_integer(task_id) do
    Enum.join(
      [
        @signing_version,
        nonce,
        Integer.to_string(task_id),
        stamp(review_requested_at),
        @decision
      ],
      "\n"
    )
  end

  @doc """
  `review_requested_at` as the signing string and the challenge response
  carry it: ISO 8601 UTC, or `""` when there is none.
  """
  @spec stamp(DateTime.t() | nil) :: String.t()
  def stamp(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  def stamp(nil), do: ""

  @doc """
  Whether `signature`, a DER ECDSA signature in unpadded URL-safe base64,
  verifies `message` against `public_key`, an uncompressed P-256 point in
  unpadded URL-safe base64 (the device's `approval_public_key`). Anything
  that is not in that canonical encoding, or cannot be decoded, is `false`.
  """
  @spec verify_signature(term(), binary(), term()) :: boolean()
  def verify_signature(public_key, message, signature)
      when is_binary(public_key) and is_binary(message) and is_binary(signature) do
    with {:ok, point} <- decode(public_key),
         {:ok, der} <- decode(signature) do
      :crypto.verify(:ecdsa, :sha256, message, der, [point, :secp256r1])
    else
      _undecodable -> false
    end
  rescue
    _error in [ArgumentError, ErlangError] -> false
  end

  def verify_signature(_public_key, _message, _signature), do: false

  # Only the canonical unpadded spelling decodes: the decoder alone would also
  # take padding and stray low bits in the last character.
  defp decode(value) when byte_size(value) <= @max_encoded_length do
    with {:ok, bytes} <- Base.url_decode64(value, padding: false),
         ^value <- Base.url_encode64(bytes, padding: false) do
      {:ok, bytes}
    else
      _not_canonical -> :error
    end
  end

  defp decode(_value), do: :error
end
