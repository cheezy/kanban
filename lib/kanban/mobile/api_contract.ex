defmodule Kanban.Mobile.ApiContract do
  @moduledoc """
  Checks the OpenAPI contract the native apps build their API clients from
  (W2779), before `mix mobile.api` copies it to `mobile/shared/openapi.json`.

  The copy is byte-for-byte the same as `priv/openapi/stride-api.json`, so
  the Android app builds against exactly the contract the server tests. The iOS app
  builds from a second document `Kanban.Mobile.SwiftContract` derives from it,
  which loosens only what the Swift generator cannot read. Generating
  the Swift and Kotlin clients belongs to each app's own build, never to the
  Elixir build. `test/kanban/mobile/api_contract_test.exs` fails when the
  committed copy is stale. Refresh it with `MIX_ENV=test mix mobile.api`, and
  never edit it by hand.

  ## Rules

  `validate/1` takes the decoded contract and reports every problem it finds:

    * the document is OpenAPI 3 and defines the `deviceAuth` security scheme
    * it has at least one `/api/me` path
    * every operation, on any path, has a non-empty `operationId`, and no two
      operations share one, because the client generators name methods after it
    * every `/api/me` operation lists `deviceAuth` in its `security`
    * every `/api/me` operation has a 2xx response, and each 2xx response
      gives a `schema` for every media type it returns. A `204` has no body,
      so it needs no schema. A `$ref`, `oneOf` or `anyOf` schema counts.
  """

  @source_path "priv/openapi/stride-api.json"
  @output_path "mobile/shared/openapi.json"
  @device_scheme "deviceAuth"
  @methods ~w(get put post patch delete head options trace)

  @doc "The contract the copy comes from, relative to the project root."
  @spec source_path() :: String.t()
  def source_path, do: @source_path

  @doc "The exact copy, relative to the project root."
  @spec output_path() :: String.t()
  def output_path, do: @output_path

  @doc """
  Checks a decoded contract. Returns `:ok`, or `{:error, problems}` with one
  readable line per problem, in path order.
  """
  @spec validate(map()) :: :ok | {:error, [String.t()]}
  def validate(contract) when is_map(contract) do
    operations = operations(contract)

    problems =
      document_problems(contract) ++
        me_paths_problems(operations) ++
        Enum.flat_map(operations, &operation_problems/1) ++
        duplicate_id_problems(operations)

    case problems do
      [] -> :ok
      problems -> {:error, problems}
    end
  end

  def validate(_contract), do: {:error, ["the contract is not a JSON object"]}

  @doc """
  Parses the contract's JSON and checks it, returning the source unchanged so
  the caller can copy its exact bytes. Raises `ArgumentError` listing every
  problem when the JSON does not parse or the contract breaks a rule.
  """
  @spec validate_source!(String.t()) :: String.t()
  def validate_source!(json) when is_binary(json) do
    with {:ok, contract} <- decode(json),
         :ok <- validate(contract) do
      json
    else
      {:error, problems} ->
        raise ArgumentError,
              "mobile.api: the contract is invalid:\n" <>
                Enum.map_join(problems, "\n", &("  * " <> &1))
    end
  end

  defp decode(json) do
    case Jason.decode(json) do
      {:ok, contract} -> {:ok, contract}
      {:error, error} -> {:error, ["the contract does not parse: " <> Exception.message(error)]}
    end
  end

  defp document_problems(contract) do
    version_problems(contract["openapi"]) ++ scheme_problems(contract)
  end

  defp version_problems("3." <> _rest), do: []
  defp version_problems(version), do: ["openapi is #{inspect(version)}, expected 3.x"]

  defp scheme_problems(%{"components" => %{"securitySchemes" => %{@device_scheme => _}}}), do: []

  defp scheme_problems(_contract),
    do: ["components.securitySchemes does not define #{@device_scheme}"]

  defp me_paths_problems(operations) do
    if Enum.any?(operations, &me_operation?/1),
      do: [],
      else: ["the contract has no /api/me operations"]
  end

  defp operation_problems({path, method, operation} = entry) do
    label = "#{String.upcase(method)} #{path}"
    id_problems(label, operation) ++ me_problems(entry, label)
  end

  defp id_problems(_label, %{"operationId" => id}) when is_binary(id) and id != "", do: []
  defp id_problems(label, _operation), do: ["#{label} has no operationId"]

  defp me_problems({path, _method, operation}, label) do
    if me_path?(path),
      do: security_problems(label, operation) ++ response_problems(label, operation),
      else: []
  end

  defp security_problems(label, operation) do
    requirements = List.wrap(operation["security"])

    if Enum.any?(requirements, &(is_map(&1) and Map.has_key?(&1, @device_scheme))),
      do: [],
      else: ["#{label} does not require #{@device_scheme}"]
  end

  defp response_problems(label, operation) do
    case success_responses(operation) do
      [] -> ["#{label} has no 2xx response"]
      responses -> Enum.flat_map(responses, &success_problems(label, &1))
    end
  end

  defp success_responses(%{"responses" => responses}) when is_map(responses) do
    responses
    |> Enum.filter(fn {status, _response} -> String.starts_with?(status, "2") end)
    |> Enum.sort()
  end

  defp success_responses(_operation), do: []

  defp success_problems(_label, {"204", _response}), do: []

  defp success_problems(label, {status, %{"content" => content}})
       when is_map(content) and map_size(content) > 0 do
    content
    |> Enum.sort()
    |> Enum.reject(fn {_type, media} -> schema?(media) end)
    |> Enum.map(fn {type, _media} -> "#{label} #{status} #{type} has no response schema" end)
  end

  defp success_problems(label, {status, _response}),
    do: ["#{label} #{status} has no response schema"]

  defp schema?(%{"schema" => schema}) when is_map(schema) and map_size(schema) > 0, do: true
  defp schema?(_media), do: false

  defp duplicate_id_problems(operations) do
    operations
    |> Enum.flat_map(&operation_id/1)
    |> Enum.frequencies()
    |> Enum.filter(fn {_id, count} -> count > 1 end)
    |> Enum.sort()
    |> Enum.map(fn {id, count} -> "operationId #{id} is used by #{count} operations" end)
  end

  defp operation_id({_path, _method, %{"operationId" => id}}) when is_binary(id) and id != "",
    do: [id]

  defp operation_id(_entry), do: []

  defp operations(%{"paths" => paths}) when is_map(paths) do
    for {path, item} <- Enum.sort(paths),
        is_map(item),
        {method, operation} <- Enum.sort(item),
        method in @methods,
        is_map(operation),
        do: {path, method, operation}
  end

  defp operations(_contract), do: []

  defp me_operation?({path, _method, _operation}), do: me_path?(path)

  defp me_path?(path), do: path == "/api/me" or String.starts_with?(path, "/api/me/")
end
