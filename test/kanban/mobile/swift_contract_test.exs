defmodule Kanban.Mobile.SwiftContractTest do
  use ExUnit.Case, async: true

  alias Kanban.Mobile.ApiContract
  alias Kanban.Mobile.SwiftContract

  @root Path.expand("../../..", __DIR__)
  @refresh_hint "run MIX_ENV=test mix mobile.api and commit the result"

  describe "the committed document" do
    test "matches the contract" do
      assert committed() == SwiftContract.derive!(source()), @refresh_hint
    end

    test "names the same operations and schemas as the contract" do
      contract = Jason.decode!(source())
      derived = Jason.decode!(committed())

      assert operations(derived) == operations(contract)
      assert schema_names(derived) == schema_names(contract)

      assert Map.drop(derived, ["components", "paths"]) ==
               Map.drop(contract, ["components", "paths"])
    end

    test "leaves no schema the Swift generator skips or misreads, though the contract has some" do
      contract = Jason.decode!(source())
      derived = Jason.decode!(committed())

      for misread? <- [&null_union?/1, &several_types?/1, &null_in_enum?/1] do
        assert find(schemas(contract), misread?) != []
        assert find(schemas(derived), misread?) == []
      end

      assert find(contract["components"]["headers"], &is_map_key(&1, "enum")) != []
      assert find(derived["components"]["headers"], &is_map_key(&1, "enum")) == []
    end

    test "opens the decisions enums the API adds values to" do
      item = schemas(Jason.decode!(committed()))["DecisionItem"]["properties"]

      for schema <- [item["kind"], item["actions"]["items"]] do
        assert [%{"type" => "string", "enum" => [_ | _]}, %{"type" => "string"}] = schema["anyOf"]
      end
    end

    test "has no enum written directly in a response body, where it would stay closed" do
      paths = Jason.decode!(source())["paths"]

      bodies =
        for {_path, item} <- paths, %{"responses" => responses} <- Map.values(item) do
          responses
        end

      assert find(bodies, &is_map_key(&1, "oneOf")) != []
      assert find(bodies, &is_map_key(&1, "enum")) == []
    end

    test "keeps a request's enum closed" do
      request = schemas(Jason.decode!(committed()))["OAuthTokenRequest"]["properties"]

      assert request["platform"]["enum"] == ["ios", "android"]
    end
  end

  describe "derive!/1" do
    test "keeps the key order and ends in a newline" do
      json =
        ~s({"paths": {}, "openapi": "3.1.0", "components": {"schemas": {}}, "info": {"b": 1, "a": 2}})

      derived = SwiftContract.derive!(json)

      assert String.ends_with?(derived, "}\n")

      assert derived
             |> Jason.decode!(objects: :ordered_objects)
             |> Map.get(:values)
             |> Enum.map(&elem(&1, 0)) ==
               ["paths", "openapi", "components", "info"]

      assert derived =~ ~r/"b": 1,\s+"a": 2/
    end

    test "a nullable reference becomes the reference and is no longer required" do
      reference = %{"anyOf" => [ref("Label"), %{"type" => "null"}], "description" => "the label"}

      derived =
        derive_response(%{
          "type" => "object",
          "required" => ["id", "label"],
          "properties" => %{"id" => %{"type" => "integer"}, "label" => reference}
        })

      assert derived["required"] == ["id"]

      assert derived["properties"]["label"] ==
               "Label" |> ref() |> Map.put("description", "the label")
    end

    test "a nullable reference in a request changes the same way" do
      schema = %{
        "type" => "object",
        "required" => ["label"],
        "properties" => %{"label" => %{"anyOf" => [%{"type" => "null"}, ref("Label")]}}
      }

      derived = derive_schemas(%{"Request" => schema})["Request"]

      assert derived["required"] == []
      assert derived["properties"]["label"] == ref("Label")
    end

    test "an anyOf with more than one real schema is left alone" do
      schema = %{"anyOf" => [ref("A"), ref("B"), %{"type" => "null"}]}

      assert derive_response(schema) == schema
    end

    test "a schema with several types accepts any value" do
      derived =
        derive_response(%{
          "type" => "object",
          "properties" => %{
            "documentation" => %{
              "type" => ["string", "array", "object"],
              "items" => %{"type" => "string"},
              "description" => "where to read more"
            },
            "name" => %{"type" => ["string", "null"]}
          }
        })

      assert derived["properties"]["documentation"] == %{"description" => "where to read more"}
      assert derived["properties"]["name"] == %{"type" => ["string", "null"]}
    end

    test "a text enum in a response is opened" do
      schema = %{"type" => "string", "enum" => ["a", "b"], "description" => "kind"}

      assert derive_response(schema) == %{
               "anyOf" => [%{"type" => "string", "enum" => ["a", "b"]}, %{"type" => "string"}],
               "description" => "kind"
             }
    end

    test "a text enum two references below a response is opened" do
      schemas = %{
        "Outer" => %{"type" => "array", "items" => ref("Inner")},
        "Inner" => %{"type" => "string", "enum" => ["a", "b"]}
      }

      derived = derive_schemas(schemas, ref("Outer"))

      assert [%{"enum" => ["a", "b"]}, %{"type" => "string"}] = derived["Inner"]["anyOf"]
    end

    test "a nullable text enum in a response is opened and no longer required" do
      derived =
        derive_response(%{
          "type" => "object",
          "required" => ["status"],
          "properties" => %{
            "status" => %{"type" => ["string", "null"], "enum" => ["open", nil]}
          }
        })

      assert derived["required"] == []

      assert derived["properties"]["status"]["anyOf"] == [
               %{"type" => "string", "enum" => ["open"]},
               %{"type" => "string"}
             ]
    end

    test "a text enum in an error response given by reference is opened" do
      schemas = %{"Problem" => %{"type" => "string", "enum" => ["bad", "worse"]}}

      contract =
        schemas
        |> contract(%{"type" => "object"})
        |> put_in(["components", "responses"], %{"Refused" => content(ref("Problem"))})
        |> put_in(["paths", "/api/me", "get", "responses", "422"], %{
          "$ref" => "#/components/responses/Refused"
        })

      assert [%{"enum" => ["bad", "worse"]}, _string] = derive(contract)["Problem"]["anyOf"]
    end

    test "a text enum with one value stays closed in a response" do
      schema = %{"type" => "string", "enum" => ["stride-approval-v1"]}

      assert derive_response(schema) == schema
    end

    test "an enum in a request stays closed and loses its null" do
      schemas = %{"Request" => %{"type" => ["string", "null"], "enum" => ["a", "b", nil]}}

      derived = schemas |> contract(%{"type" => "object"}) |> with_request("Request") |> derive()

      assert derived["Request"] == %{"type" => ["string", "null"], "enum" => ["a", "b"]}
    end

    test "a schema that is both sent and returned is refused" do
      contract = with_request(contract(%{"Both" => %{"type" => "object"}}, ref("Both")), "Both")

      assert_raise ArgumentError, ~r/both sends and returns Both/, fn -> derive(contract) end
    end

    test "a response header loses its enum" do
      header = %{"required" => true, "schema" => %{"type" => "string", "enum" => ["no-store"]}}

      derived =
        %{}
        |> contract(%{"type" => "object"})
        |> put_in(["components", "headers"], %{"NoStore" => header})
        |> Jason.encode!()
        |> SwiftContract.derive!()
        |> Jason.decode!()

      assert derived["components"]["headers"]["NoStore"] ==
               %{"required" => true, "schema" => %{"type" => "string"}}
    end

    test "a number enum in a response stays closed" do
      schema = %{"type" => "integer", "enum" => [60, 120]}

      assert derive_response(schema) == schema
    end

    test "oneOf becomes anyOf in a response only" do
      union = %{"oneOf" => [ref("A"), ref("B")]}
      derived = derive_schemas(%{"Body" => union, "Request" => union}, ref("Body"))

      assert derived["Body"] == %{"anyOf" => [ref("A"), ref("B")]}
      assert derived["Request"] == union
    end

    test "a schema that refers to itself is read once" do
      schema = %{"type" => "object", "properties" => %{"parent" => ref("Body")}}

      assert derive_schemas(%{"Body" => schema}, ref("Body"))["Body"] == schema
    end

    test "examples and defaults are data and stay as they are" do
      schema = %{
        "type" => "object",
        "example" => %{"type" => ["string", "array"], "enum" => [nil], "required" => ["x"]},
        "default" => %{"oneOf" => [1]}
      }

      assert derive_response(schema) == schema
    end
  end

  defp source, do: @root |> Path.join(ApiContract.source_path()) |> File.read!()
  defp committed, do: @root |> Path.join(SwiftContract.output_path()) |> File.read!()
  defp schemas(contract), do: contract["components"]["schemas"]
  defp schema_names(contract), do: contract |> schemas() |> Map.keys()

  defp operations(contract) do
    for {path, item} <- contract["paths"], {method, %{"operationId" => id}} <- item do
      {path, method, id}
    end
  end

  # The "Body" schema after deriving a contract whose one response is it.
  defp derive_response(schema), do: derive_schemas(%{"Body" => schema}, ref("Body"))["Body"]

  defp derive_schemas(schemas, response \\ %{"type" => "object"}) do
    schemas |> contract(response) |> derive()
  end

  defp derive(contract) do
    contract |> Jason.encode!() |> SwiftContract.derive!() |> Jason.decode!() |> schemas()
  end

  defp with_request(contract, name) do
    put_in(contract, ["paths", "/api/me", "get", "requestBody"], content(ref(name)))
  end

  defp contract(schemas, response) do
    %{
      "openapi" => "3.1.0",
      "paths" => %{
        "/api/me" => %{
          "get" => %{"operationId" => "getMe", "responses" => %{"200" => content(response)}}
        }
      },
      "components" => %{"schemas" => schemas}
    }
  end

  defp content(schema), do: %{"content" => %{"application/json" => %{"schema" => schema}}}
  defp ref(name), do: %{"$ref" => "#/components/schemas/" <> name}

  # Every map in the document the predicate accepts.
  defp find(map, predicate) when is_map(map) do
    here = if predicate.(map), do: [map], else: []
    nested = map |> Map.values() |> Enum.flat_map(&find(&1, predicate))
    here ++ nested
  end

  defp find(list, predicate) when is_list(list), do: Enum.flat_map(list, &find(&1, predicate))
  defp find(_value, _predicate), do: []

  defp null_union?(%{"anyOf" => [_, _] = options}), do: %{"type" => "null"} in options
  defp null_union?(_map), do: false

  defp several_types?(%{"type" => types}) when is_list(types),
    do: length(types -- ["null"]) > 1

  defp several_types?(_map), do: false

  defp null_in_enum?(%{"enum" => values}) when is_list(values), do: nil in values
  defp null_in_enum?(_map), do: false
end
