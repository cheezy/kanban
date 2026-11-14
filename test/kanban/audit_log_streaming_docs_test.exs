defmodule Kanban.AuditLogStreamingDocsTest do
  @moduledoc """
  Keeps the receiver examples in `docs/audit-log-streaming.md` able to verify a
  batch signed during a signing-secret rotation (W2720).

  For the 24 hours after a rotation, `x-stride-signature` carries two `v1`
  values, the old secret's first. A receiver that reads only the first `v1`, or
  only the last, refuses every batch signed for the secret it does not hold.
  These tests check that the Python and Node.js examples collect every `v1`
  value and accept a match against any of them, and that the split rule the
  guide describes verifies the header Stride really sends.
  """
  use ExUnit.Case, async: true

  alias Kanban.Webhooks.Signer

  @doc_path Path.expand("../../docs/audit-log-streaming.md", __DIR__)

  setup_all do
    %{doc: File.read!(@doc_path)}
  end

  describe "the Python example" do
    test "collects every v1 value and accepts a match against any of them", %{doc: doc} do
      code = example(doc, "### Python", "python")

      assert code =~ ~s|return [value for key, value in parts if key == name]|
      assert code =~ ~s|signatures = header_values(header, "v1")|

      assert code =~ "return any(\n"
      assert code =~ "hmac.compare_digest(expected.encode(), signature.encode())\n"
      assert code =~ "for signature in signatures\n"
    end
  end

  describe "the Node.js example" do
    test "collects every v1 value and accepts a match against any of them", %{doc: doc} do
      code = example(doc, "### Node.js", "javascript")

      assert code =~ ~s|.filter(([key]) => key === name)|
      assert code =~ ~s|const signatures = headerValues(header, "v1");|
      assert code =~ ~s|return signatures.some((signature) => {|
      assert code =~ ~s|crypto.timingSafeEqual(given, expected)|
    end
  end

  describe "the rotation header" do
    test "the guide shows two v1 values, the old secret's first", %{doc: doc} do
      assert doc =~ "`t=<t>,v1=<old>,v1=<new>`"
    end

    test "the guide's split rule verifies Stride's two-v1 header with either secret" do
      body = ~s|{"version":1,"events":[]}|
      timestamp = 1_794_600_000

      header =
        Signer.sign_all(body, ["old-placeholder-secret", "new-placeholder-secret"], timestamp)

      assert [_, _] = values(header, "v1")
      assert guide_verifies?(header, body, "old-placeholder-secret")
      assert guide_verifies?(header, body, "new-placeholder-secret")
      refute guide_verifies?(header, body, "other-placeholder-secret")
    end
  end

  # D443: the HTTPS header_name setting is the authorization header's name,
  # sent with the credential; Stride's signature headers can't be configured.
  describe "the HTTPS header_name setting" do
    test "the field table and the email table call it the authorization header name",
         %{doc: doc} do
      assert doc =~ "| **Authorization header name (optional)** |"
      assert doc =~ "or the HTTPS authorization header name changes."
      refute doc =~ ~r/HTTPS signature header/i
    end
  end

  # The fenced block of `language` that follows `heading`.
  defp example(doc, heading, language) do
    [_, after_heading] = String.split(doc, "\n" <> heading <> "\n", parts: 2)
    [_, block] = String.split(after_heading, "```" <> language <> "\n", parts: 2)
    [code, _] = String.split(block, "\n```\n", parts: 2)
    code
  end

  # The guide's rule: split on "," and each part on its first "=" only.
  defp values(header, name) do
    header
    |> String.split(",")
    |> Enum.flat_map(fn part ->
      case String.split(part, "=", parts: 2) do
        [^name, value] -> [value]
        _ -> []
      end
    end)
  end

  defp guide_verifies?(header, body, secret) do
    [timestamp] = values(header, "t")

    expected =
      :crypto.mac(:hmac, :sha256, secret, timestamp <> "." <> body)
      |> Base.encode16(case: :lower)

    header
    |> values("v1")
    |> Enum.any?(&Plug.Crypto.secure_compare(&1, expected))
  end
end
