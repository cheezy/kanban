defmodule KanbanWeb.API.ChangedFilesTransportTest do
  @moduledoc """
  Unit tests for the extracted changed_files transport decoder (W1443). These
  pin the exact decode error messages and the decompression-bomb / size bounds —
  the controller request tests only assert the 422 status + top-level key, so
  this suite is what locks the security-control behavior byte-identical.
  """
  use ExUnit.Case, async: true

  alias KanbanWeb.API.ChangedFilesTransport

  @valid_entries [
    %{"path" => "lib/kanban/tasks/goals.ex", "diff" => "@@ -1 +1 @@\n-old\n+new a == b"}
  ]

  defp decode(payload), do: ChangedFilesTransport.decode_and_validate_changed_files(payload)

  defp base64_envelope(term),
    do: %{"encoding" => "base64", "data" => term |> Jason.encode!() |> Base.encode64()}

  defp gzip_envelope(term),
    do: %{
      "encoding" => "gzip+base64",
      "data" => term |> Jason.encode!() |> :zlib.gzip() |> Base.encode64()
    }

  # Extract the single decode-error message from the failure body.
  defp error_message({:error, {:completion_validation_failed, body}}) do
    [%{errors: [%{message: message}]}] = body.failures
    message
  end

  describe "happy paths" do
    test "decodes a base64-encoded envelope to the validated array" do
      assert {:ok, entries} = decode(base64_envelope(@valid_entries))
      assert [%{"path" => "lib/kanban/tasks/goals.ex"}] = entries
    end

    test "decodes a gzip+base64-encoded envelope to the validated array" do
      assert {:ok, entries} = decode(gzip_envelope(@valid_entries))
      assert [%{"path" => "lib/kanban/tasks/goals.ex"}] = entries
    end

    test "a raw (non-envelope) list passes straight through to validation" do
      assert {:ok, entries} = decode(@valid_entries)
      assert [%{"path" => "lib/kanban/tasks/goals.ex"}] = entries
    end
  end

  describe "transport decode errors (exact messages preserved)" do
    test "malformed base64" do
      result = decode(%{"encoding" => "base64", "data" => "not valid base64 !!!"})
      assert error_message(result) == "data is not valid base64"
    end

    test "unsupported encoding" do
      result = decode(%{"encoding" => "rot13", "data" => "whatever"})

      assert error_message(result) ==
               "unsupported changed_files encoding (use base64 or gzip+base64)"
    end

    test "valid gzip+base64 wrapping non-gzip bytes" do
      result = decode(%{"encoding" => "gzip+base64", "data" => Base.encode64("plain, not gzip")})
      assert error_message(result) == "data is not valid gzip"
    end

    test "decoded payload is a JSON object, not an array" do
      result = decode(base64_envelope(%{"not" => "an array"}))
      assert error_message(result) == "decoded payload is not a JSON array"
    end

    test "decoded payload is not valid JSON" do
      result = decode(%{"encoding" => "base64", "data" => Base.encode64("{not json")})
      assert error_message(result) == "decoded payload is not valid JSON"
    end
  end

  describe "size bounds (security controls)" do
    test "encoded data exceeding the 10 MB input cap is rejected before decoding" do
      oversized = %{"encoding" => "base64", "data" => String.duplicate("A", 10_000_001)}
      assert error_message(decode(oversized)) == "encoded data exceeds the maximum allowed size"
    end

    test "a gzip bomb is aborted at the 5 MB decoded cap during streaming inflate" do
      # ~6 MB of a single byte gzips to a few KB (well under the 10 MB encoded
      # cap) but inflates past the 5 MB decoded cap — the streaming loop must
      # abort mid-inflate rather than allocate the whole thing.
      bomb = %{
        "encoding" => "gzip+base64",
        "data" => "A" |> String.duplicate(6_000_000) |> :zlib.gzip() |> Base.encode64()
      }

      assert error_message(decode(bomb)) == "decoded payload exceeds the maximum allowed size"
    end
  end
end
