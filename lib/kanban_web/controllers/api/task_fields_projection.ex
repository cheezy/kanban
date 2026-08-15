defmodule KanbanWeb.API.TaskFieldsProjection do
  @moduledoc """
  Resolution of the `fields` projection parameter on `GET /api/tasks/:id`
  (W2076).

  Conn-free on the `TaskParamFilter` precedent (W1443): the pure
  parse/validate logic and the rejection message text live here, while the
  controller keeps HTTP status codes, `ErrorDocs` wiring, and rendering.

  Two deliberate decisions are encoded here rather than left to callers:

    * **Mutual exclusion is presence-based.** `fields` and `response_view`
      on one request is a 422 whenever both keys are present — before any
      parsing, so `?fields=title&response_view=full` and even
      `?fields=&response_view=slim` are rejected. A value-sensitive
      carve-out would need a precedence rule, which is exactly the
      ambiguity mutual exclusion exists to avoid, and presence is the only
      reading a client can predict without knowing `view_for/1`'s fallback
      internals.

    * **Validation stays in string space.** Requested names are split,
      trimmed, deduplicated, and compared as strings against
      `KanbanWeb.API.TaskJSON.projectable_field_names/0`. The parameter is
      attacker-controllable, so nothing here ever calls `String.to_atom/1`
      — the same atom-exhaustion stance `view_for/1` takes for
      `response_view`.
  """

  alias KanbanWeb.API.TaskJSON

  @always_present ~w(id identifier)

  @doc """
  Resolves the `fields` parameter from the raw params map.

  Returns:

    * `{:ok, nil}` — no projection requested (absent or blank `fields`);
      the caller falls through to `view_for/1` resolution.
    * `{:ok, fields}` — a validated list of field names to project,
      always led by `id` and `identifier` so responses stay
      self-describing.
    * `{:error, :mutually_exclusive}` — both `fields` and `response_view`
      were sent.
    * `{:error, :invalid_shape}` — `fields` was present but not a scalar
      string (`?fields[]=x`, `?fields[key]=x`).
    * `{:error, {:unknown_fields, names}}` — every requested name not on
      the allow-list, in request order.
  """
  @spec resolve(map()) ::
          {:ok, [String.t()] | nil}
          | {:error, :mutually_exclusive}
          | {:error, :invalid_shape}
          | {:error, {:unknown_fields, [String.t()]}}
  def resolve(params) do
    cond do
      Map.has_key?(params, "fields") and Map.has_key?(params, "response_view") ->
        {:error, :mutually_exclusive}

      not Map.has_key?(params, "fields") ->
        {:ok, nil}

      not is_binary(params["fields"]) ->
        # (W2094) A present-but-non-scalar shape such as ?fields[]=x or
        # ?fields[key]=x is a malformed projection request, not the absence
        # of one. It used to fall back to the FULL body — a client-side
        # encoding bug then yields maximum data, inverting the projection's
        # data-minimization intent — so it now rejects like unknown names do.
        {:error, :invalid_shape}

      true ->
        params["fields"]
        |> parse_names()
        |> validate_names()
    end
  end

  @doc """
  The rejection message for a non-scalar `fields` shape (W2094).
  """
  @spec invalid_shape_message() :: String.t()
  def invalid_shape_message do
    "fields must be a single comma-separated string (for example fields=status,needs_review) — array or map shapes like fields[]=x are not accepted"
  end

  @doc """
  The rejection message for one unknown field name — kept beside the
  validation it explains, on the `TaskParamFilter.forbidden_update_message/1`
  convention.
  """
  @spec unknown_field_message(String.t()) :: String.t()
  def unknown_field_message(name) do
    "#{name} is not in the allow-listed fields for GET /api/tasks/:id"
  end

  defp parse_names(raw) do
    raw
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp validate_names([]), do: {:ok, nil}

  defp validate_names(names) do
    allowed = TaskJSON.projectable_field_names()

    case Enum.reject(names, &(&1 in allowed)) do
      [] -> {:ok, @always_present ++ (names -- @always_present)}
      unknown -> {:error, {:unknown_fields, unknown}}
    end
  end
end
