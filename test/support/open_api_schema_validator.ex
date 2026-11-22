defmodule KanbanWeb.OpenApiSchemaValidator do
  @moduledoc """
  Test-only check of a decoded JSON value against a schema in
  `priv/openapi/stride-api.json` (W2778).

  `KanbanWeb.API.MobileFixturesTest` uses it to keep the example responses in
  `mobile/shared/fixtures/` from drifting away from the API contract. The
  project carries no JSON Schema library, so this module covers exactly the
  keywords the contract's response schemas use: `type`, `enum`, `required`,
  `properties`, `additionalProperties`, `items`, `minItems`, `maxItems`,
  `minimum`, `maximum`, `maxLength`, `pattern`, `const`, `format`
  (`date-time` and `date`), `anyOf`, `oneOf` and local `$ref`s into
  `#/components/schemas/`.

  Annotations such as `description` and `example` are ignored. **Any other
  keyword is reported as an error rather than skipped**, so a spec change that
  starts using `allOf`, `const` or a new `format` fails until this module
  learns it, instead of passing because nothing checked it. `validate/4`
  sees only the nodes a value reaches, so `schema_problems/2` walks a whole
  schema, `$ref`s included, and reports every unsupported keyword or format
  it holds, even in an optional property, an array's items or an `anyOf`
  branch no fixture takes.

  When no `anyOf` or `oneOf` branch matches, each branch's own errors follow
  the summary error, prefixed with the branch number, so the field at fault
  is still named.

  Errors are `{json_path, message}` pairs. A path starts at `$`, names keys as
  `.key` (or `["odd key"]`) and indexes as `[0]`; a missing required key is
  reported at the path the key would have, so
  `{"$.data.user.display_name", "is required"}`.

  With `strict: true`, an object whose schema declares `properties` and says
  nothing about `additionalProperties` may not carry an undeclared key. JSON
  Schema would allow one; fixtures may not, because an app built against them
  would read a field the API never promised.
  """

  @annotations ~w(description title example examples default deprecated readOnly writeOnly)
  @keywords ~w(type enum const required properties additionalProperties items minItems
               maxItems minimum maximum maxLength pattern format anyOf oneOf $ref)
  @formats ~w(date-time date)
  @schema_ref "#/components/schemas/"
  @plain_key ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/

  @type error :: {String.t(), String.t()}

  @doc """
  Validates `value` against `schema`, resolving `$ref`s in `spec`.

  Returns `:ok` or `{:error, errors}`. Options: `strict:` (default `false`).
  """
  @spec validate(term(), map(), map(), keyword()) :: :ok | {:error, [error()]}
  def validate(value, schema, spec, opts \\ []) do
    ctx = %{spec: spec, strict: Keyword.get(opts, :strict, false)}

    case check(value, schema, "$", ctx) do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  @doc """
  Lists every unsupported keyword or format anywhere in `schema`, following
  local `$ref`s into `spec` once each. Returns `{schema_path, message}` pairs;
  an empty list means `validate/4` can check every node of the schema.
  """
  @spec schema_problems(map(), map()) :: [error()]
  def schema_problems(schema, spec) do
    {problems, _seen} = walk(schema, "#", spec, MapSet.new())
    Enum.reverse(problems)
  end

  @doc "Formats errors one per line, as `path: message`."
  @spec format_errors([error()]) :: String.t()
  def format_errors(errors),
    do: Enum.map_join(errors, "\n", fn {path, msg} -> "#{path}: #{msg}" end)

  @doc "Appends an object key to a JSON path."
  @spec key_path(String.t(), String.t()) :: String.t()
  def key_path(path, key) do
    if Regex.match?(@plain_key, key), do: "#{path}.#{key}", else: "#{path}[#{Jason.encode!(key)}]"
  end

  defp check(value, schema, path, ctx) when is_map(schema) do
    case unsupported(schema) do
      [] -> check_supported(value, schema, path, ctx)
      messages -> Enum.map(messages, &{path, &1})
    end
  end

  defp check(_value, schema, path, _ctx),
    do: [{path, "schema #{inspect(schema)} is not an object"}]

  # Messages for every keyword or format validate/4 cannot check.
  defp unsupported(schema) do
    keywords =
      schema
      |> Map.keys()
      |> Enum.reject(&(&1 in @keywords or &1 in @annotations))
      |> Enum.sort()
      |> Enum.map(&"schema keyword #{inspect(&1)} is not supported")

    case schema do
      %{"format" => format} when format not in @formats ->
        keywords ++ ["format #{inspect(format)} is not supported"]

      _schema ->
        keywords
    end
  end

  defp walk(schema, path, spec, seen) when is_map(schema) do
    own = schema |> unsupported() |> Enum.map(&{path, &1})
    {from_ref, seen} = walk_ref(schema["$ref"], spec, seen)
    schema |> subschemas(path) |> walk_all(spec, {from_ref ++ Enum.reverse(own), seen})
  end

  defp walk(_schema, _path, _spec, seen), do: {[], seen}

  defp walk_all(subschemas, spec, acc) do
    Enum.reduce(subschemas, acc, fn {sub, sub_path}, {problems, seen} ->
      {found, seen} = walk(sub, sub_path, spec, seen)
      {found ++ problems, seen}
    end)
  end

  defp walk_ref(@schema_ref <> name = ref, spec, seen) do
    case {MapSet.member?(seen, ref), get_in(spec, ["components", "schemas", name])} do
      {true, _schema} -> {[], seen}
      {false, nil} -> {[{ref, "$ref does not resolve"}], MapSet.put(seen, ref)}
      {false, schema} -> walk(schema, ref, spec, MapSet.put(seen, ref))
    end
  end

  defp walk_ref(nil, _spec, seen), do: {[], seen}
  defp walk_ref(ref, _spec, seen), do: {[{"#", "$ref #{inspect(ref)} is not local"}], seen}

  defp subschemas(schema, path),
    do: properties_of(schema, path) ++ branches_of(schema, path) ++ singles_of(schema, path)

  defp properties_of(schema, path) do
    for {key, sub} <- Map.get(schema, "properties", %{}), do: {sub, "#{path}/properties/#{key}"}
  end

  defp branches_of(schema, path) do
    for keyword <- ["anyOf", "oneOf"],
        {sub, index} <- schema |> Map.get(keyword, []) |> Enum.with_index(),
        do: {sub, "#{path}/#{keyword}/#{index}"}
  end

  defp singles_of(schema, path) do
    for keyword <- ["items", "additionalProperties"],
        is_map(schema[keyword]),
        do: {schema[keyword], "#{path}/#{keyword}"}
  end

  # A $ref is checked together with its sibling keywords (JSON Schema
  # 2020-12). A type mismatch stops the checks below this node, so one wrong
  # type is one error, not a cascade.
  defp check_supported(value, schema, path, ctx) do
    ref_errors = ref(value, schema["$ref"], path, ctx)

    case type(value, schema["type"], path) do
      [] ->
        ref_errors ++ keyword_errors(value, schema, path, ctx) ++ strict(value, schema, path, ctx)

      type_errors ->
        ref_errors ++ type_errors
    end
  end

  defp strict(value, %{"properties" => _} = schema, path, %{strict: true})
       when is_map(value) and not is_map_key(schema, "additionalProperties") do
    for key <- undeclared_keys(value, schema),
        do: {key_path(path, key), "is not declared in the schema"}
  end

  defp strict(_value, _schema, _path, _ctx), do: []

  defp keyword_errors(value, schema, path, ctx) do
    Enum.flat_map(@keywords -- ["type", "$ref"], fn keyword ->
      if Map.has_key?(schema, keyword),
        do: keyword(keyword, schema[keyword], value, path, schema, ctx),
        else: []
    end)
  end

  defp ref(_value, nil, _path, _ctx), do: []

  defp ref(value, @schema_ref <> name = ref, path, ctx) do
    case get_in(ctx.spec, ["components", "schemas", name]) do
      nil -> [{path, "$ref #{ref} does not resolve"}]
      schema -> check(value, schema, path, ctx)
    end
  end

  defp ref(_value, ref, path, _ctx),
    do: [{path, "$ref #{inspect(ref)} is not a local #{@schema_ref} reference"}]

  defp type(_value, nil, _path), do: []

  defp type(value, types, path) do
    actual = json_type(value)
    types = List.wrap(types)

    if Enum.any?(types, &type_matches?(&1, actual)),
      do: [],
      else: [{path, "is #{actual}, expected #{Enum.join(types, " or ")}"}]
  end

  defp type_matches?("number", "integer"), do: true
  defp type_matches?(expected, actual), do: expected == actual

  defp json_type(nil), do: "null"
  defp json_type(value) when is_boolean(value), do: "boolean"
  defp json_type(value) when is_integer(value), do: "integer"
  defp json_type(value) when is_float(value), do: "number"
  defp json_type(value) when is_binary(value), do: "string"
  defp json_type(value) when is_list(value), do: "array"
  defp json_type(value) when is_map(value), do: "object"

  defp keyword("enum", allowed, value, path, _schema, _ctx) do
    if value in allowed,
      do: [],
      else: [{path, "#{show(value)} is not one of #{show(allowed)}"}]
  end

  defp keyword("const", expected, value, path, _schema, _ctx) do
    if value == expected, do: [], else: [{path, "#{show(value)} is not #{show(expected)}"}]
  end

  defp keyword("required", required, value, path, _schema, _ctx) when is_map(value) do
    for key <- required, not Map.has_key?(value, key), do: {key_path(path, key), "is required"}
  end

  defp keyword("properties", properties, value, path, _schema, ctx) when is_map(value) do
    Enum.flat_map(properties, fn {key, property} ->
      if Map.has_key?(value, key),
        do: check(value[key], property, key_path(path, key), ctx),
        else: []
    end)
  end

  defp keyword("additionalProperties", additional, value, path, schema, ctx) when is_map(value) do
    value
    |> undeclared_keys(schema)
    |> Enum.flat_map(&additional_property(additional, value[&1], key_path(path, &1), ctx))
  end

  defp keyword("items", items, value, path, _schema, ctx) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, index} -> check(item, items, "#{path}[#{index}]", ctx) end)
  end

  defp keyword("minItems", min, value, path, _schema, _ctx)
       when is_list(value) and length(value) < min,
       do: [{path, "has #{length(value)} items, fewer than #{min}"}]

  defp keyword("maxItems", max, value, path, _schema, _ctx)
       when is_list(value) and length(value) > max,
       do: [{path, "has #{length(value)} items, more than #{max}"}]

  defp keyword("minimum", min, value, path, _schema, _ctx) when is_number(value) and value < min,
    do: [{path, "is #{value}, less than #{min}"}]

  defp keyword("maximum", max, value, path, _schema, _ctx) when is_number(value) and value > max,
    do: [{path, "is #{value}, more than #{max}"}]

  defp keyword("maxLength", max, value, path, _schema, _ctx) when is_binary(value) do
    if String.length(value) > max, do: [{path, "is longer than #{max} characters"}], else: []
  end

  defp keyword("pattern", pattern, value, path, _schema, _ctx) when is_binary(value) do
    regex = Regex.compile!(pattern, "u")

    if Regex.match?(regex, value),
      do: [],
      else: [{path, "#{inspect(value)} does not match #{inspect(pattern)}"}]
  end

  defp keyword("format", format, value, path, _schema, _ctx) when is_binary(value),
    do: format(format, value, path)

  defp keyword("anyOf", branches, value, path, _schema, ctx) do
    branches |> Enum.map(&check(value, &1, path, ctx)) |> any_of(path, length(branches))
  end

  defp keyword("oneOf", branches, value, path, _schema, ctx) do
    branches |> Enum.map(&check(value, &1, path, ctx)) |> one_of(path, length(branches))
  end

  # A keyword that does not apply to this value's type, or that it satisfies.
  defp keyword(_keyword, _arg, _value, _path, _schema, _ctx), do: []

  # A branch that fails only because it holds a keyword this module cannot
  # check is not a non-matching branch: that would let a value pass (or fail)
  # on a check that never ran, so the unsupported error is reported instead.
  defp any_of(results, path, count) do
    cond do
      (unchecked = unchecked(results)) != [] ->
        unchecked

      Enum.any?(results, &(&1 == [])) ->
        []

      true ->
        [{path, "matches none of the #{count} anyOf schemas"} | branch_errors(results, "anyOf")]
    end
  end

  defp one_of(results, path, count) do
    case {unchecked(results), Enum.count(results, &(&1 == []))} do
      {[_ | _] = unchecked, _matches} ->
        unchecked

      {[], 1} ->
        []

      {[], 0} ->
        [
          {path, "matches 0 of the #{count} oneOf schemas, expected exactly 1"}
          | branch_errors(results, "oneOf")
        ]

      {[], n} ->
        [{path, "matches #{n} of the #{count} oneOf schemas, expected exactly 1"}]
    end
  end

  defp unchecked(results) do
    for errors <- results,
        {_path, message} = error <- errors,
        String.ends_with?(message, "is not supported"),
        do: error
  end

  defp branch_errors(results, keyword) do
    for {errors, index} <- Enum.with_index(results, 1),
        {path, message} <- errors,
        do: {path, "#{keyword} branch #{index}: #{message}"}
  end

  defp show(value), do: inspect(value, charlists: :as_lists)

  # The strict rule applies only where additionalProperties is absent; when it
  # is present, keyword("additionalProperties", ...) handles the keys.
  defp undeclared_keys(value, schema) do
    declared = Map.get(schema, "properties", %{})
    value |> Map.keys() |> Enum.reject(&Map.has_key?(declared, &1)) |> Enum.sort()
  end

  defp additional_property(true, _value, _path, _ctx), do: []
  defp additional_property(false, _value, path, _ctx), do: [{path, "is not allowed"}]
  defp additional_property(schema, value, path, ctx), do: check(value, schema, path, ctx)

  defp format("date-time", value, path) do
    case DateTime.from_iso8601(value) do
      {:ok, _datetime, _offset} -> []
      {:error, _} -> [{path, "#{inspect(value)} is not an RFC 3339 date-time"}]
    end
  end

  defp format("date", value, path) do
    case Date.from_iso8601(value) do
      {:ok, _date} -> []
      {:error, _} -> [{path, "#{inspect(value)} is not an ISO 8601 date"}]
    end
  end

  # unsupported/1 reports any other format before a value is checked.
end
