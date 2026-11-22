defmodule Kanban.Mobile.ApiContractTest do
  @moduledoc """
  The API contract copy both native apps build their clients from (W2779).
  """
  use ExUnit.Case, async: true

  alias Kanban.Mobile.ApiContract

  @root Path.expand("../../..", __DIR__)
  @refresh_hint "mobile/shared/openapi.json is stale. Refresh it with: MIX_ENV=test mix mobile.api"

  defp source, do: @root |> Path.join(ApiContract.source_path()) |> File.read!()

  defp committed, do: @root |> Path.join(ApiContract.output_path()) |> File.read!()

  defp json_response(schema),
    do: %{"description" => "OK", "content" => %{"application/json" => %{"schema" => schema}}}

  defp me_operation(id, responses \\ nil) do
    %{
      "operationId" => id,
      "security" => [%{"deviceAuth" => []}],
      "responses" =>
        responses || %{"200" => json_response(%{"$ref" => "#/components/schemas/Me"})}
    }
  end

  # The smallest contract that passes: one /api/me operation and one other.
  defp contract(paths \\ %{}) do
    %{
      "openapi" => "3.1.0",
      "components" => %{
        "securitySchemes" => %{
          "bearerAuth" => %{"type" => "http", "scheme" => "bearer"},
          "deviceAuth" => %{"type" => "http", "scheme" => "bearer"}
        },
        "schemas" => %{"Me" => %{"type" => "object"}}
      },
      "paths" =>
        Map.merge(
          %{
            "/api/me" => %{"get" => me_operation("getMe")},
            "/oauth/token" => %{
              "post" => %{
                "operationId" => "oauthToken",
                "security" => [],
                "responses" => %{"200" => json_response(%{"type" => "object"})}
              }
            }
          },
          paths
        )
    }
  end

  defp problems(contract) do
    assert {:error, problems} = ApiContract.validate(contract)
    problems
  end

  describe "the committed copy" do
    test "the committed copy matches the contract" do
      assert committed() == source(), @refresh_hint
    end

    test "the real contract passes validation" do
      assert source() |> Jason.decode!() |> ApiContract.validate() == :ok
    end

    test "the mobile/shared README names the task, its copy and its staleness test" do
      readme = @root |> Path.join("mobile/shared/README.md") |> File.read!()

      for text <- [
            "mix mobile.api",
            "[openapi.json](openapi.json)",
            "test/kanban/mobile/api_contract_test.exs"
          ] do
        assert readme =~ text, "mobile/shared/README.md does not mention #{text}"
      end
    end

    test "the copy is the contract's exact bytes, ending in a newline" do
      assert ApiContract.validate_source!(source()) == source()
      assert String.ends_with?(committed(), "}\n")
    end
  end

  describe "validate/1" do
    test "a minimal contract passes" do
      assert ApiContract.validate(contract()) == :ok
    end

    test "an /api/me operation without deviceAuth fails validation" do
      op = "listMyAgents" |> me_operation() |> Map.put("security", [%{"bearerAuth" => []}])

      assert problems(contract(%{"/api/me/agents" => %{"get" => op}})) == [
               "GET /api/me/agents does not require deviceAuth"
             ]
    end

    test "an /api/me operation with no security at all fails" do
      op = "listMyAgents" |> me_operation() |> Map.delete("security")

      assert problems(contract(%{"/api/me/agents" => %{"get" => op}})) == [
               "GET /api/me/agents does not require deviceAuth"
             ]
    end

    test "a non-/api/me operation needs no deviceAuth" do
      assert ApiContract.validate(contract()) == :ok
      assert get_in(contract(), ["paths", "/oauth/token", "post", "security"]) == []
    end

    test "a contract that does not define the deviceAuth scheme fails" do
      contract =
        update_in(contract(), ["components", "securitySchemes"], &Map.delete(&1, "deviceAuth"))

      assert problems(contract) == ["components.securitySchemes does not define deviceAuth"]
    end

    test "an operation with no operationId fails" do
      op = "unused" |> me_operation() |> Map.delete("operationId")

      assert problems(contract(%{"/api/me/boards" => %{"get" => op}})) == [
               "GET /api/me/boards has no operationId"
             ]
    end

    test "an operation outside /api/me with an empty operationId fails" do
      contract = put_in(contract(), ["paths", "/oauth/token", "post", "operationId"], "")

      assert problems(contract) == ["POST /oauth/token has no operationId"]
    end

    test "two operations sharing an operationId fail" do
      contract = contract(%{"/api/me/agents" => %{"get" => me_operation("getMe")}})

      assert problems(contract) == ["operationId getMe is used by 2 operations"]
    end

    test "a contract with no /api/me paths fails" do
      contract = update_in(contract(), ["paths"], &Map.delete(&1, "/api/me"))

      assert problems(contract) == ["the contract has no /api/me operations"]
    end

    test "a contract with no paths at all fails" do
      assert problems(Map.delete(contract(), "paths")) == [
               "the contract has no /api/me operations"
             ]
    end

    test "a path's parameters and extension keys are not read as operations" do
      item = %{
        "parameters" => [%{"name" => "id"}],
        "x-internal" => %{"note" => "not an operation"},
        "get" => me_operation("getMyBoard")
      }

      assert %{"/api/me/boards/{id}" => item} |> contract() |> ApiContract.validate() == :ok
    end

    test "an /api/me operation with no 2xx response fails" do
      op = me_operation("getMyBoard", %{"404" => %{"description" => "Not found"}})

      assert problems(contract(%{"/api/me/boards/{id}" => %{"get" => op}})) == [
               "GET /api/me/boards/{id} has no 2xx response"
             ]
    end

    test "an /api/me 200 with no content, or content without a schema, fails" do
      no_content = me_operation("getMyBoard", %{"200" => %{"description" => "OK"}})

      no_schema =
        me_operation("listMyBoards", %{
          "200" => %{"description" => "OK", "content" => %{"application/json" => %{}}}
        })

      contract =
        contract(%{
          "/api/me/boards/{id}" => %{"get" => no_content},
          "/api/me/boards" => %{"get" => no_schema}
        })

      assert problems(contract) == [
               "GET /api/me/boards 200 application/json has no response schema",
               "GET /api/me/boards/{id} 200 has no response schema"
             ]
    end

    test "an /api/me 204 needs no schema" do
      op = me_operation("revokeMyDevice", %{"204" => %{"description" => "Revoked"}})

      assert %{"/api/me/devices/{id}" => %{"delete" => op}}
             |> contract()
             |> ApiContract.validate() == :ok
    end

    test "oneOf and anyOf response schemas count as schemas" do
      one_of = me_operation("getMyTask", %{"200" => json_response(%{"oneOf" => [%{}, %{}]})})
      any_of = me_operation("listMyTasks", %{"201" => json_response(%{"anyOf" => [%{}]})})

      contract =
        contract(%{
          "/api/me/tasks/{id}" => %{"get" => one_of},
          "/api/me/tasks" => %{"post" => any_of}
        })

      assert ApiContract.validate(contract) == :ok
    end

    test "a document that is not OpenAPI 3 fails" do
      assert problems(Map.put(contract(), "openapi", "2.0")) == [
               ~s(openapi is "2.0", expected 3.x)
             ]
    end

    test "reports every problem, not just the first" do
      op = %{"responses" => %{}}

      assert problems(contract(%{"/api/me/agents" => %{"get" => op}})) == [
               "GET /api/me/agents has no operationId",
               "GET /api/me/agents does not require deviceAuth",
               "GET /api/me/agents has no 2xx response"
             ]
    end

    test "a value that is not a JSON object fails" do
      assert ApiContract.validate([]) == {:error, ["the contract is not a JSON object"]}
    end
  end

  describe "validate_source!/1" do
    test "returns the source unchanged when it is valid" do
      json = Jason.encode!(contract(), pretty: true) <> "\n"

      assert ApiContract.validate_source!(json) == json
    end

    test "raises naming every problem when the contract is invalid" do
      json = contract() |> update_in(["paths"], &Map.delete(&1, "/api/me")) |> Jason.encode!()

      assert_raise ArgumentError,
                   ~r/contract is invalid:\n  \* the contract has no \/api\/me/,
                   fn ->
                     ApiContract.validate_source!(json)
                   end
    end

    test "raises when the JSON does not parse" do
      assert_raise ArgumentError, ~r/the contract does not parse/, fn ->
        ApiContract.validate_source!("{\"openapi\": ")
      end
    end
  end
end
