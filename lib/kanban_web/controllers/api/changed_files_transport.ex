defmodule KanbanWeb.API.ChangedFilesTransport do
  @moduledoc """
  Decodes and validates the `changed_files` diff snapshot for the
  `PUT /api/tasks/:id/changed_files` endpoint.

  Extracted from `KanbanWeb.API.TaskController` (W1443). The snapshot may arrive
  raw, base64-encoded, or gzip+base64-encoded — an edge request filter can
  misread a unified code diff as an attack and drop a raw upload, so an encoded
  envelope is offered as a purely additive alternative:

      {"changed_files": {"encoding": "base64", "data": "<base64 of the array>"}}

  This module decodes the transport envelope, guards against oversized and
  decompression-bomb uploads with bounded streaming inflate (see the caps
  below), and validates the decoded JSON array through
  `Kanban.Tasks.CompletionValidation`. It is pure: `decode_and_validate_changed_files/1`
  returns `{:ok, list}` or `{:error, {:completion_validation_failed, body}}` for
  the controller to render (as `422 Unprocessable Entity`).
  """

  alias Kanban.Tasks.CompletionValidation

  # Caps guarding against an oversized or decompression-bomb upload before it
  # reaches the validator. The downstream 500-line-per-file rule bounds content
  # further; these bound the raw transport bytes.
  @max_decoded_changed_files_bytes 5_000_000
  @max_encoded_changed_files_bytes 10_000_000

  @doc """
  Decodes the (optionally transport-encoded) `changed_files` payload and
  validates it. A raw list, `nil`, or any non-envelope shape passes straight
  through to the validator exactly as before.
  """
  def decode_and_validate_changed_files(payload) do
    with {:ok, decoded} <- decode_changed_files_payload(payload) do
      validate_changed_files_payload(decoded)
    end
  end

  defp validate_changed_files_payload(payload) do
    case CompletionValidation.validate_changed_files(payload) do
      {:ok, value} ->
        {:ok, value}

      {:error, errors} ->
        {:error, {:completion_validation_failed, build_changed_files_failure_body(errors)}}
    end
  end

  defp build_changed_files_failure_body(errors) do
    %{
      error: "completion validation failed",
      failures: [
        %{
          field: "changed_files",
          errors:
            Enum.map(errors, fn {field, message} ->
              %{field: to_string(field), message: message}
            end)
        }
      ],
      required_format: %{
        "changed_files" => [
          %{
            "path" => "lib/foo.ex",
            "diff" => "Unified-patch text — see docs/diff-contract.md (≤ 500 lines per file)"
          },
          %{"path" => "assets/logo.png", "diff" => "[binary file — no diff captured]"}
        ]
      }
    }
  end

  defp decode_changed_files_payload(%{"encoding" => encoding, "data" => data})
       when is_binary(encoding) and is_binary(data) do
    with {:ok, raw} <- decode_transport(encoding, data) do
      decode_json_array(raw)
    end
  end

  defp decode_changed_files_payload(payload), do: {:ok, payload}

  defp decode_transport(_encoding, data)
       when byte_size(data) > @max_encoded_changed_files_bytes,
       do: changed_files_decode_error("encoded data exceeds the maximum allowed size")

  defp decode_transport("base64", data) do
    case Base.decode64(data) do
      {:ok, bin} -> {:ok, bin}
      :error -> changed_files_decode_error("data is not valid base64")
    end
  end

  defp decode_transport("gzip+base64", data) do
    case Base.decode64(data) do
      {:ok, gzipped} -> gunzip_changed_files(gzipped)
      :error -> changed_files_decode_error("data is not valid base64")
    end
  end

  defp decode_transport(_encoding, _data),
    do:
      changed_files_decode_error("unsupported changed_files encoding (use base64 or gzip+base64)")

  # Inflate gzip data incrementally, aborting as soon as the cumulative
  # decompressed size exceeds the cap. A one-shot :zlib.gunzip/1 would inflate
  # the entire payload into memory first, so a small high-ratio "bomb" could
  # allocate gigabytes before the downstream size guard ever ran. The streaming
  # loop bounds peak memory to the cap.
  defp gunzip_changed_files(gzipped) do
    z = :zlib.open()

    try do
      :zlib.inflateInit(z, 31)
      bounded_inflate(z, :zlib.safeInflate(z, gzipped), [], 0)
    rescue
      _ -> changed_files_decode_error("data is not valid gzip")
    catch
      _, _ -> changed_files_decode_error("data is not valid gzip")
    after
      :zlib.close(z)
    end
  end

  defp bounded_inflate(z, {status, output}, acc, size) do
    size = size + IO.iodata_length(output)

    cond do
      size > @max_decoded_changed_files_bytes ->
        changed_files_decode_error("decoded payload exceeds the maximum allowed size")

      status == :continue ->
        bounded_inflate(z, :zlib.safeInflate(z, []), [acc | [output]], size)

      true ->
        {:ok, IO.iodata_to_binary([acc | [output]])}
    end
  end

  defp decode_json_array(raw)
       when byte_size(raw) > @max_decoded_changed_files_bytes,
       do: changed_files_decode_error("decoded payload exceeds the maximum allowed size")

  defp decode_json_array(raw) do
    case Jason.decode(raw) do
      {:ok, list} when is_list(list) -> {:ok, list}
      {:ok, _other} -> changed_files_decode_error("decoded payload is not a JSON array")
      {:error, _} -> changed_files_decode_error("decoded payload is not valid JSON")
    end
  end

  defp changed_files_decode_error(message) do
    {:error,
     {:completion_validation_failed,
      build_changed_files_failure_body([{:changed_files, message}])}}
  end
end
