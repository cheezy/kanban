defmodule KanbanWeb.MCP.SchemaValidator do
  @moduledoc """
  Validates tool arguments against the subset of JSON Schema the MCP tool
  definitions use (W2231): `type` (one type or a list), `required`,
  `properties`, `additionalProperties: false`, `enum`, `minimum`, `maximum`,
  `minLength` and `maxLength`.

  Error messages name the offending path only and never echo a value, so a
  rejected argument is never reflected back to the caller. At most
  `@max_errors` messages are returned.
  """

  @max_errors 10

  @doc """
  Returns `:ok` or `{:error, messages}`.
  """
  def validate(value, schema) do
    case value |> errors(schema, "arguments") |> Enum.take(@max_errors) do
      [] -> :ok
      messages -> {:error, messages}
    end
  end

  defp errors(value, schema, path) do
    case type_errors(value, schema, path) do
      [] -> constraint_errors(value, schema, path)
      type_errors -> type_errors
    end
  end

  defp type_errors(value, %{"type" => types}, path) do
    if types |> List.wrap() |> Enum.any?(&type?(value, &1)),
      do: [],
      else: ["#{path} must be of type #{types |> List.wrap() |> Enum.join(" or ")}"]
  end

  defp type_errors(_value, _schema, _path), do: []

  defp type?(value, "object"), do: is_map(value)
  defp type?(value, "string"), do: is_binary(value)
  # JSON Schema counts a number with a zero fractional part (5.0) as an
  # integer; KanbanWeb.MCP.Tools turns it into one before it is used.
  defp type?(value, "integer"), do: is_integer(value) or integral_float?(value)
  defp type?(value, "number"), do: is_number(value)
  defp type?(value, "boolean"), do: is_boolean(value)
  defp type?(value, "array"), do: is_list(value)
  defp type?(value, "null"), do: is_nil(value)

  @doc false
  def integral_float?(value), do: is_float(value) and value == Float.round(value)

  defp constraint_errors(value, schema, path) when is_map(value) do
    required_errors(value, schema, path) ++
      unknown_key_errors(value, schema, path) ++ property_errors(value, schema, path)
  end

  defp constraint_errors(value, schema, path) do
    enum_errors(value, schema, path) ++
      range_errors(value, schema, path) ++ length_errors(value, schema, path)
  end

  defp required_errors(value, schema, path) do
    for key <- Map.get(schema, "required", []), not Map.has_key?(value, key) do
      "#{path}.#{key} is required"
    end
  end

  defp unknown_key_errors(value, %{"additionalProperties" => false} = schema, path) do
    known = Map.get(schema, "properties", %{})

    for key <- Map.keys(value), not Map.has_key?(known, key) do
      "#{path} has an unknown property #{inspect(String.slice(key, 0, 64))}"
    end
  end

  defp unknown_key_errors(_value, _schema, _path), do: []

  defp property_errors(value, schema, path) do
    schema
    |> Map.get("properties", %{})
    |> Enum.flat_map(fn {key, property_schema} ->
      case Map.fetch(value, key) do
        {:ok, property} -> errors(property, property_schema, "#{path}.#{key}")
        :error -> []
      end
    end)
  end

  defp enum_errors(value, %{"enum" => allowed}, path) do
    if value in allowed, do: [], else: ["#{path} must be one of #{Enum.join(allowed, ", ")}"]
  end

  defp enum_errors(_value, _schema, _path), do: []

  defp range_errors(value, schema, path) when is_number(value),
    do: bound_errors(value, schema, path, {"minimum", "maximum"}, "")

  defp range_errors(_value, _schema, _path), do: []

  defp length_errors(value, schema, path) when is_binary(value) do
    value
    |> String.length()
    |> bound_errors(schema, path, {"minLength", "maxLength"}, " characters")
  end

  defp length_errors(_value, _schema, _path), do: []

  defp bound_errors(measure, schema, path, {min_key, max_key}, unit) do
    below(measure, schema[min_key], path, unit) ++ above(measure, schema[max_key], path, unit)
  end

  defp below(measure, min, path, unit) when is_number(min) and measure < min,
    do: ["#{path} must be at least #{min}#{unit}"]

  defp below(_measure, _min, _path, _unit), do: []

  defp above(measure, max, path, unit) when is_number(max) and measure > max,
    do: ["#{path} must be at most #{max}#{unit}"]

  defp above(_measure, _max, _path, _unit), do: []
end
