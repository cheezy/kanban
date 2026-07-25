defmodule KanbanWeb.TaskLive.Form.TechnicalDetails do
  @moduledoc """
  JSON encoding/decoding for the task form's `technical_details` textarea,
  extracted from `KanbanWeb.TaskLive.FormComponent` (which was well over the
  module-size guidance in `AGENTS.md`).

  The column stores a map, but the form edits it as free text, so this module
  owns the round trip in both directions and turns malformed input into a
  friendly changeset error rather than a crash.
  """

  @doc """
  Renders the current `technical_details` map as the textarea's initial value:
  an empty map shows an empty textarea; any populated map is pretty-printed.
  """
  def encode(%Ecto.Changeset{} = changeset) do
    case Ecto.Changeset.get_field(changeset, :technical_details) do
      map when map == %{} -> ""
      map when is_map(map) -> Jason.encode!(map, pretty: true)
      _ -> ""
    end
  end

  @doc """
  Converts the textarea string into a map for the changeset.

    * key absent (field hidden) or already a map (API path): passthrough
    * empty / whitespace-only string: `%{}`
    * valid JSON object: the decoded map
    * valid JSON non-object (array/scalar) or invalid JSON: `{:error, raw}`

  `Jason.decode/1` returns `{:error, _}` on garbage and never raises, so a
  malformed entry becomes a friendly changeset error rather than a crash.
  """
  def decode(task_params) do
    case Map.fetch(task_params, "technical_details") do
      :error -> {:ok, task_params}
      {:ok, value} when is_map(value) -> {:ok, task_params}
      {:ok, value} when is_binary(value) -> decode_string(task_params, value)
    end
  end

  defp decode_string(task_params, raw) do
    case String.trim(raw) do
      "" ->
        {:ok, Map.put(task_params, "technical_details", %{})}

      trimmed ->
        case Jason.decode(trimmed) do
          {:ok, decoded} when is_map(decoded) ->
            {:ok, Map.put(task_params, "technical_details", decoded)}

          _ ->
            {:error, raw}
        end
    end
  end

  @doc """
  Variant for the validate path: on error, drops the uncastable string from the
  params (so Ecto does not emit a generic "is invalid" cast error) and signals
  `:error` so the caller can attach the friendly message.
  """
  def decode_for_changeset(task_params) do
    case decode(task_params) do
      {:ok, params} -> {params, nil}
      {:error, _raw} -> {Map.delete(task_params, "technical_details"), :error}
    end
  end

  @doc "Attaches the friendly error when `decode_for_changeset/1` signalled `:error`."
  def maybe_add_error(changeset, nil), do: changeset

  def maybe_add_error(changeset, :error) do
    Ecto.Changeset.add_error(changeset, :technical_details, "must be a JSON object")
  end
end
