defmodule Kanban.Mobile.SwiftContract do
  @moduledoc """
  Derives the OpenAPI document StrideKit generates its Swift client from
  (W2783). `mix mobile.api` writes it to
  `mobile/ios/StrideKit/Sources/StrideKit/openapi.json`, where the Swift OpenAPI
  Generator plugin reads it at build time.

  The contract itself stays strict, because the server's tests check responses
  against it. This copy only loosens what an app reads, where the generator
  would otherwise drop a value or refuse a whole response. `derive!/1`
  makes six changes, and leaves everything else and the key order as they are:

    * **A nullable reference** (`anyOf` of a schema and `null`) becomes the plain
      schema on a property that is not required. The generator skips a property
      whose schema mentions `null`, so the app would never see the value.
    * **A type list with several types besides `null`** loses its `type` and
      `items`, so any JSON value decodes. The generator keeps only the first
      type and throws on the others.
    * **`null` in an enum's values** is removed. The type already says it.
    * **A text enum with several values, in a schema a response can return,** is
      opened: `anyOf` of the enum and a plain string. The API only adds values,
      and an app must ignore one it does not know, but a closed Swift enum throws.
      An enum with one value stays closed: it tells two schemas apart, or names a
      version the app must not guess at. So do the enums in requests. An opened
      enum that may be null loses its `null`, and its property is no longer
      required, as with a nullable reference.
    * **`oneOf` in those same schemas** becomes `anyOf`. The generator decodes the
      first case that fits, and a case whose keys may all be null fits anything,
      so the right case's values were lost.
    * **An enum on a response header** is removed. The client throws on a header
      value outside it, so a new `cache-control` policy would break every app.

  A schema that is both sent and returned would lose its closed enums in the
  request, so `derive!/1` raises for one. Split it in the contract.

  The enum and `oneOf` changes apply to the schemas under `components` a response
  reaches. A union written directly in a response body stays `oneOf`, and an enum
  there would stay closed, so give such a body a named schema.
  """

  alias Jason.OrderedObject

  @output_path "mobile/ios/StrideKit/Sources/StrideKit/openapi.json"
  # Values under these keys are data, not schemas.
  @data_keys ~w(const default enum example examples)

  @doc "The document StrideKit's build reads, relative to the project root."
  @spec output_path() :: String.t()
  def output_path, do: @output_path

  @doc """
  Derives the document from the contract's JSON, in the contract's key order.
  Raises `ArgumentError` when a schema is both sent and returned.
  """
  @spec derive!(String.t()) :: String.t()
  def derive!(json) when is_binary(json) do
    contract = Jason.decode!(json)
    readable = contract |> response_schemas() |> refuse_shared!(request_schemas(contract))

    derived =
      json
      |> Jason.decode!(objects: :ordered_objects)
      |> put_schemas(fn name, schema -> rewrite(schema, name in readable) end)
      |> rewrite_paths()
      |> open_headers()

    Jason.encode!(derived, pretty: true) <> "\n"
  end

  # The names of the schemas any response can return, however deep.
  defp response_schemas(contract), do: reachable(contract, "responses")
  defp request_schemas(contract), do: reachable(contract, "requestBody")

  defp reachable(contract, part) do
    closed =
      contract
      |> operation_refs(part)
      |> close(Map.get(contract, "components", %{}), MapSet.new())

    for {"schemas", name} <- closed, into: MapSet.new(), do: name
  end

  defp operation_refs(contract, part) do
    for {_path, item} <- Map.get(contract, "paths", %{}),
        %{"operationId" => _id, ^part => value} <- Map.values(item),
        ref <- refs(value),
        do: ref
  end

  defp refuse_shared!(responses, requests) do
    case responses |> MapSet.intersection(requests) |> Enum.sort() do
      [] ->
        responses

      shared ->
        raise ArgumentError,
              "mobile.api: the contract both sends and returns #{Enum.join(shared, ", ")}. " <>
                "Give the request a schema of its own."
    end
  end

  defp close([], _components, seen), do: seen

  defp close([{kind, name} = ref | rest], components, seen) do
    if MapSet.member?(seen, ref),
      do: close(rest, components, seen),
      else: close(refs(components[kind][name]) ++ rest, components, MapSet.put(seen, ref))
  end

  defp refs(%{"$ref" => "#/components/" <> pointer}) do
    [kind, name] = String.split(pointer, "/", parts: 2)
    [{kind, name}]
  end

  defp refs(map) when is_map(map), do: map |> Map.values() |> refs()
  defp refs(list) when is_list(list), do: Enum.flat_map(list, &refs/1)
  defp refs(_value), do: []

  defp put_schemas(contract, fun) do
    update(contract, "components", fn components ->
      update(components, "schemas", fn %OrderedObject{values: schemas} ->
        %OrderedObject{
          values: Enum.map(schemas, fn {name, value} -> {name, fun.(name, value)} end)
        }
      end)
    end)
  end

  defp rewrite_paths(contract), do: update(contract, "paths", &rewrite(&1, false))

  defp open_headers(contract) do
    update(contract, "components", fn components ->
      update(components, "headers", &without_enums/1)
    end)
  end

  defp without_enums(%OrderedObject{values: values} = object) do
    kept = for {key, value} <- values, key != "enum", do: {key, without_enums(value)}
    %{object | values: kept}
  end

  defp without_enums(value), do: value

  defp update(%OrderedObject{values: values}, key, fun) do
    %OrderedObject{
      values: Enum.map(values, fn {k, v} -> {k, if(k == key, do: fun.(v), else: v)} end)
    }
  end

  defp rewrite(%OrderedObject{values: values} = object, readable?) do
    optional = values |> List.keyfind("properties", 0) |> dropped_from_required(readable?)

    values
    |> Enum.map(fn {key, value} -> {key, rewrite_value(key, value, readable?, optional)} end)
    |> rewrite_schema(readable?)
    |> then(&%{object | values: &1})
  end

  defp rewrite(list, readable?) when is_list(list), do: Enum.map(list, &rewrite(&1, readable?))
  defp rewrite(value, _readable?), do: value

  defp rewrite_value("required", names, _readable?, optional) when is_list(names),
    do: names -- optional

  defp rewrite_value(key, value, _readable?, _optional) when key in @data_keys, do: value

  defp rewrite_value(_key, value, readable?, _optional), do: rewrite(value, readable?)

  # A property that may be null and loses its `null` can no longer be required.
  defp dropped_from_required({"properties", %OrderedObject{values: properties}}, readable?) do
    for {name, %OrderedObject{values: schema}} <- properties,
        null_union?(schema) or (nullable?(schema) and opens?(schema, readable?)),
        do: name
  end

  defp dropped_from_required(_properties, _readable?), do: []

  # `rewrite_schema/2` gets one object's pairs, with every value under it
  # already rewritten.
  defp rewrite_schema(values, readable?) do
    cond do
      null_union?(values) -> without_null(values)
      several_types?(values) -> Enum.reject(values, fn {key, _} -> key in ~w(type items) end)
      opens?(values, readable?) -> open(values)
      readable? -> values |> drop_null_value() |> one_of_to_any_of()
      true -> drop_null_value(values)
    end
  end

  defp null_union?(values) do
    case List.keyfind(values, "anyOf", 0) do
      {"anyOf", [_, _] = options} -> Enum.any?(options, &null_schema?/1)
      _ -> false
    end
  end

  defp null_schema?(%OrderedObject{values: [{"type", "null"}]}), do: true
  defp null_schema?(_schema), do: false

  defp without_null(values) do
    Enum.flat_map(values, fn
      {"anyOf", options} ->
        [%OrderedObject{values: schema}] = Enum.reject(options, &null_schema?/1)
        schema

      pair ->
        [pair]
    end)
  end

  defp several_types?(values) do
    case types(values) do
      types when is_list(types) -> length(types -- ["null"]) > 1
      _ -> false
    end
  end

  defp types(values), do: values |> List.keyfind("type", 0, {"type", nil}) |> elem(1)

  defp nullable?(values), do: values |> types() |> List.wrap() |> Enum.member?("null")

  defp opens?(_values, false), do: false

  defp opens?(values, true) do
    case List.keyfind(values, "enum", 0) do
      {"enum", [_, _ | _]} ->
        types = values |> types() |> List.wrap()
        types -- ["null"] == ["string"]

      _ ->
        false
    end
  end

  defp open(values) do
    {"enum", options} = List.keyfind(values, "enum", 0)
    kept = Enum.reject(values, fn {key, _} -> key in ~w(type enum) end)

    known = OrderedObject.new([{"type", "string"}, {"enum", options -- [nil]}])
    [{"anyOf", [known, OrderedObject.new([{"type", "string"}])]} | kept]
  end

  defp drop_null_value(values) do
    Enum.map(values, fn
      {"enum", options} when is_list(options) -> {"enum", options -- [nil]}
      pair -> pair
    end)
  end

  defp one_of_to_any_of(values) do
    Enum.map(values, fn
      {"oneOf", options} when is_list(options) -> {"anyOf", options}
      pair -> pair
    end)
  end
end
