defmodule KanbanWeb.API.MobileFixturesTest do
  @moduledoc """
  Keeps the example API responses in `mobile/shared/fixtures/` true to the
  contract in `priv/openapi/stride-api.json` (W2778, design section 7.11).

  Every `/api/me` and `/oauth` operation whose success response has a JSON
  body needs a fixture named `<operationId>.json`, holding that whole body.
  Each fixture must validate against the operation's response schema, with
  no key the schema does not declare. A `204` response has no body, so it
  needs no fixture.

  When this test fails after a contract change, update the fixtures it names
  in the same task — see mobile/shared/fixtures/README.md.
  """
  use ExUnit.Case, async: true

  alias KanbanWeb.API.OpenApiSpec
  alias KanbanWeb.OpenApiSchemaValidator

  # A path only: the files are read when the test runs, never at compile time.
  @fixtures_dir Path.expand("../../../../mobile/shared/fixtures", __DIR__)
  @http_methods ~w(get put post delete patch)
  @validation_line ~r/^\S+\.json(:| is not valid JSON| cannot be read)/

  setup_all do
    %{spec: OpenApiSpec.path() |> File.read!() |> Jason.decode!()}
  end

  # The /api/me and /oauth operations, grouped into those whose success
  # response has a JSON body (they need a fixture), those that answer 204
  # with no body, and anything else, which the contract must settle first.
  defp fixture_operations(spec) do
    groups = spec |> api_operations() |> Enum.group_by(&classify/1)
    Map.new([:required, :exempt, :undocumented], &{&1, Map.get(groups, &1, [])})
  end

  defp api_operations(spec) do
    for {path, item} <- spec["paths"],
        String.starts_with?(path, ["/api/me", "/oauth/"]),
        {method, op} <- item,
        method in @http_methods,
        do: operation(spec, method, path, op)
  end

  defp operation(spec, method, path, op) do
    {status, response} = success_response(spec, op)

    %{
      id: op["operationId"],
      label: "#{String.upcase(method)} #{path}",
      status: status,
      schema: get_in(response, ["content", "application/json", "schema"]),
      content: response["content"]
    }
  end

  defp classify(%{schema: schema}) when is_map(schema), do: :required
  defp classify(%{status: "204", content: nil}), do: :exempt
  defp classify(_op), do: :undocumented

  defp success_response(spec, op) do
    case Enum.filter(op["responses"], fn {status, _} -> status =~ ~r/^2\d\d$/ end) do
      [{status, response}] -> {status, resolve_response(spec, response)}
      _none_or_many -> {nil, %{}}
    end
  end

  defp resolve_response(spec, %{"$ref" => "#/components/responses/" <> name}),
    do: get_in(spec, ["components", "responses", name])

  defp resolve_response(_spec, response), do: response

  defp fixture_files(dir) do
    dir |> File.ls!() |> Enum.filter(&String.ends_with?(&1, ".json")) |> Enum.sort()
  end

  # The decisions' web_url values use the configured Stride host, because the
  # iOS app opens no other (mobile/shared/fixtures/README.md).
  defp stride_web_link?("listMyDecisions.json", "www.stridelikeaboss.com"), do: true
  defp stride_web_link?(_file, _host), do: false

  # Every problem with the fixtures in `dir`, one line each. Taking the
  # folder as an argument is what lets the tests below point it at a
  # temporary folder.
  defp fixture_failures(spec, dir) do
    %{required: required, undocumented: undocumented} = fixture_operations(spec)
    files = fixture_files(dir)
    by_file = Map.new(required, &{"#{&1.id}.json", &1})

    Enum.concat([
      empty_lines(dir, files),
      missing_lines(required, files),
      stray_lines(by_file, files),
      no_body_lines(undocumented),
      invalid_lines(spec, dir, files, by_file)
    ])
  end

  defp empty_lines(dir, []), do: ["#{dir} holds no fixtures"]
  defp empty_lines(_dir, _files), do: []

  defp missing_lines(required, files) do
    for op <- required, "#{op.id}.json" not in files do
      "#{op.id} (#{op.label}) has no fixture: add mobile/shared/fixtures/#{op.id}.json"
    end
  end

  defp stray_lines(by_file, files) do
    for file <- files,
        not Map.has_key?(by_file, file),
        do: "#{file} names no operation with a JSON response body"
  end

  defp no_body_lines(undocumented) do
    for op <- undocumented,
        do: "#{op.id} (#{op.label}) needs a JSON success body or a 204 with no content"
  end

  defp invalid_lines(spec, dir, files, by_file),
    do: Enum.flat_map(files, &file_lines(spec, dir, &1, by_file[&1]))

  defp file_lines(_spec, _dir, _file, nil), do: []

  defp file_lines(spec, dir, file, op) do
    with {:ok, value} <- read_fixture(dir, file),
         :ok <- OpenApiSchemaValidator.validate(value, op.schema, spec, strict: true) do
      []
    else
      {:error, errors} when is_list(errors) ->
        for {path, message} <- errors, do: "#{file}: #{path}: #{message}"

      {:error, line} ->
        [line]
    end
  end

  defp read_fixture(dir, file) do
    path = Path.join(dir, file)

    case File.read(path) do
      {:ok, raw} -> decode_fixture(raw, file)
      {:error, reason} -> {:error, "#{file} cannot be read: #{inspect(reason)}"}
    end
  end

  defp decode_fixture(raw, file) do
    case Jason.decode(raw) do
      {:ok, value} -> {:ok, value}
      {:error, error} -> {:error, "#{file} is not valid JSON: #{Exception.message(error)}"}
    end
  end

  defp fixture(name), do: @fixtures_dir |> Path.join(name) |> File.read!() |> Jason.decode!()

  defp schema_for(spec, id) do
    spec
    |> fixture_operations()
    |> Map.fetch!(:required)
    |> Enum.find(&(&1.id == id))
    |> Map.fetch!(:schema)
  end

  defp validate(value, schema, spec, opts \\ []),
    do: OpenApiSchemaValidator.validate(value, schema, spec, opts)

  defp write_fixtures(dir, fixtures) do
    for {name, value} <- fixtures do
      dir |> Path.join(name) |> File.write!(Jason.encode!(value))
    end
  end

  defp validation_lines(spec, dir),
    do: spec |> fixture_failures(dir) |> Enum.filter(&(&1 =~ @validation_line))

  defp coverage_lines(spec, dir),
    do: spec |> fixture_failures(dir) |> Enum.reject(&(&1 =~ @validation_line))

  describe "the fixtures" do
    test "every fixture validates against its schema", %{spec: spec} do
      failures = validation_lines(spec, @fixtures_dir)

      assert failures == [],
             "Fixtures that do not match the contract (fix the fixture, never the schema):\n" <>
               Enum.join(failures, "\n")
    end

    test "every fixture's schema names only keywords the validator checks", %{spec: spec} do
      problems =
        for %{id: id, schema: schema} <- fixture_operations(spec).required,
            {path, message} <- OpenApiSchemaValidator.schema_problems(schema, spec),
            uniq: true,
            do: "#{id}: #{path}: #{message}"

      assert problems == [],
             "Teach test/support/open_api_schema_validator.ex these keywords:\n" <>
               Enum.join(problems, "\n")
    end

    test "every /api/me operation has a fixture", %{spec: spec} do
      %{required: required, exempt: exempt, undocumented: undocumented} =
        fixture_operations(spec)

      ids = Enum.map(required, & &1.id)
      me_ops = Enum.filter(required, &String.contains?(&1.label, " /api/me"))

      # The list comes from the spec, so it must not come back empty.
      assert "getMe" in ids and "oauthToken" in ids and "oauthRevoke" in ids
      assert length(me_ops) >= 20
      assert undocumented == [], inspect(undocumented)
      assert Enum.all?(exempt, &(&1.status == "204")), inspect(exempt)

      failures = coverage_lines(spec, @fixtures_dir)

      assert failures == [], Enum.join(failures, "\n")
      assert @fixtures_dir |> fixture_files() |> length() == length(required)
    end

    @tag :tmp_dir
    test "a 204 operation needs no fixture and a fixture for one is stray", %{
      spec: spec,
      tmp_dir: dir
    } do
      %{exempt: exempt} = fixture_operations(spec)
      exempt_ids = Enum.map(exempt, & &1.id)

      assert "signOutCurrentDevice" in exempt_ids and "revokeMyDevice" in exempt_ids

      File.cp_r!(@fixtures_dir, dir)
      write_fixtures(dir, [{"signOutCurrentDevice.json", %{}}])

      assert fixture_failures(spec, dir) == [
               "signOutCurrentDevice.json names no operation with a JSON response body"
             ]
    end

    @tag :tmp_dir
    test "a fixture with a missing required field fails with its path", %{
      spec: spec,
      tmp_dir: dir
    } do
      {_, broken} = "getMe.json" |> fixture() |> pop_in(["data", "user", "display_name"])

      assert {:error, [{"$.data.user.display_name", "is required"}]} =
               validate(broken, schema_for(spec, "getMe"), spec, strict: true)

      File.cp_r!(@fixtures_dir, dir)
      write_fixtures(dir, [{"getMe.json", broken}])

      assert fixture_failures(spec, dir) == ["getMe.json: $.data.user.display_name: is required"]
    end

    @tag :tmp_dir
    test "an empty fixtures folder fails", %{spec: spec, tmp_dir: dir} do
      dir |> Path.join("README.md") |> File.write!("# API fixtures\n")
      %{required: required} = fixture_operations(spec)

      failures = fixture_failures(spec, dir)

      assert "#{dir} holds no fixtures" in failures
      assert length(failures) == length(required) + 1
      assert Enum.any?(failures, &(&1 =~ "getMe (GET /api/me) has no fixture"))
    end

    @tag :tmp_dir
    test "a stray, unparsable or extra-key fixture fails", %{spec: spec, tmp_dir: dir} do
      File.cp_r!(@fixtures_dir, dir)
      dir |> Path.join("getMee.json") |> File.write!("{}")
      dir |> Path.join("oauthToken.json") |> File.write!("{not json")
      write_fixtures(dir, [{"oauthRevoke.json", %{"revoked" => true}}])

      failures = fixture_failures(spec, dir)

      assert "getMee.json names no operation with a JSON response body" in failures
      assert Enum.any?(failures, &(&1 =~ "oauthToken.json is not valid JSON"))
      assert "oauthRevoke.json: $.revoked: is not allowed" in failures
    end

    test "nullable fields present as null pass and non-nullable nulls fail", %{spec: spec} do
      schema = schema_for(spec, "listMyDevices")
      %{"data" => [device | _]} = devices = fixture("listMyDevices.json")

      nulls = %{device | "model" => nil, "last_seen_at" => nil, "push_environment" => nil}
      assert :ok = validate(%{devices | "data" => [nulls]}, schema, spec, strict: true)

      not_nullable = %{device | "signed_in_at" => nil}

      assert {:error, [{"$.data[0].signed_in_at", "is null, expected string"}]} =
               validate(%{"data" => [not_nullable]}, schema, spec, strict: true)

      no_organization = "getMe.json" |> fixture() |> put_in(["data", "organization"], nil)
      assert :ok = validate(no_organization, schema_for(spec, "getMe"), spec)
    end

    test "an enum value outside the schema fails with its path", %{spec: spec} do
      %{"data" => [device | _]} = fixture("listMyDevices.json")

      assert {:error, [{"$.data[0].platform", message}]} =
               validate(
                 %{"data" => [%{device | "platform" => "windows"}]},
                 schema_for(spec, "listMyDevices"),
                 spec
               )

      assert message =~ ~s("windows" is not one of)

      token = %{fixture("oauthToken.json") | "token_type" => "bearer"}

      assert {:error, [{"$.token_type", _}]} =
               validate(token, schema_for(spec, "oauthToken"), spec)
    end

    test "fixtures hold made-up data only" do
      for file <- fixture_files(@fixtures_dir) do
        raw = @fixtures_dir |> Path.join(file) |> File.read!()

        refute raw =~ ~r/\b(stride|sdat|sdrt|sdac|sdan)_[A-Za-z0-9]/,
               "#{file} holds a token-shaped value"

        refute raw =~ "SFMyNTY.", "#{file} holds a signed Phoenix token"
        refute raw =~ ~r/eyJ[A-Za-z0-9_-]{10,}/, "#{file} holds a JWT"

        refute raw =~ ~r/localhost|127\.0\.0\.1|\.internal\b|fly\.dev/,
               "#{file} names a real host"

        refute raw =~ ~r/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+/, "#{file} holds an email address"

        for [host] <- Regex.scan(~r{https?://([^/"\s]+)}, raw, capture: :all_but_first) do
          assert String.ends_with?(host, ".example") or stride_web_link?(file, host),
                 "#{file} links to #{host}, not a .example host"
        end
      end
    end
  end

  describe "the schema validator" do
    test "a oneOf value must match exactly one branch", %{spec: spec} do
      schema = %{"$ref" => "#/components/schemas/DecisionItem"}
      %{"data" => %{"items" => [item | _]}} = fixture("listMyDecisions.json")
      assert :ok = validate(item, schema, spec, strict: true)

      # Both a released and a claim-expired detail: two branches match.
      both = %{
        "reason" => nil,
        "notification_id" => 1,
        "claimed_at" => nil,
        "expired_at" => nil
      }

      assert {:error, [{"$.details", "matches 2 of the 5 oneOf schemas, expected exactly 1"}]} =
               validate(%{item | "details" => both}, schema, spec)

      assert {:error,
              [{"$.details", "matches 0 of the 5 oneOf schemas, expected exactly 1"} | branches]} =
               validate(%{item | "details" => %{}}, schema, spec)

      assert {"$.details.reason", "oneOf branch 2: is required"} in branches
    end

    test "an anyOf value must match a branch" do
      schema = %{"anyOf" => [%{"type" => "string"}, %{"type" => "null"}]}

      assert :ok = validate(nil, schema, %{})

      assert {:error,
              [
                {"$", "matches none of the 2 anyOf schemas"},
                {"$", "anyOf branch 1: is integer, expected string"},
                {"$", "anyOf branch 2: is integer, expected null"}
              ]} = validate(1, schema, %{})
    end

    test "an unsupported keyword in a branch is reported, never read as a non-match" do
      one_of = %{"oneOf" => [%{"type" => "string"}, %{"type" => "string", "allOf" => []}]}

      assert {:error, [{"$", "schema keyword \"allOf\" is not supported"}]} =
               validate("x", one_of, %{})

      any_of = %{"anyOf" => [%{"type" => "integer"}, %{"type" => "string", "allOf" => []}]}

      assert {:error, [{"$", "schema keyword \"allOf\" is not supported"}]} =
               validate("x", any_of, %{})
    end

    test "schema_problems finds an unsupported keyword no value reaches" do
      spec = %{"components" => %{"schemas" => %{"A" => %{"maxProperties" => 1}}}}

      schema = %{
        "type" => "object",
        "properties" => %{
          "list" => %{"type" => "array", "items" => %{"allOf" => []}},
          "pick" => %{"anyOf" => [%{"type" => "null"}, %{"$ref" => "#/components/schemas/A"}]},
          "id" => %{"type" => "integer", "format" => "int64"}
        }
      }

      assert :ok = validate(%{"list" => []}, schema, spec)

      assert [
               {"#/components/schemas/A", "schema keyword \"maxProperties\" is not supported"},
               {"#/properties/id", "format \"int64\" is not supported"},
               {"#/properties/list/items", "schema keyword \"allOf\" is not supported"}
             ] = schema |> OpenApiSchemaValidator.schema_problems(spec) |> Enum.sort()

      assert [{"#/components/schemas/B", "$ref does not resolve"}] =
               OpenApiSchemaValidator.schema_problems(%{"$ref" => "#/components/schemas/B"}, %{})
    end

    test "const and maximum are checked, and an integer enum prints as a list" do
      assert :ok = validate("x", %{"const" => "x"}, %{})
      assert {:error, [{"$", "\"y\" is not \"x\""}]} = validate("y", %{"const" => "x"}, %{})
      assert :ok = validate(5, %{"maximum" => 5}, %{})
      assert {:error, [{"$", "is 6, more than 5"}]} = validate(6, %{"maximum" => 5}, %{})
      assert {:error, [{"$", "1 is not one of [100]"}]} = validate(1, %{"enum" => [100]}, %{})
    end

    test "strict mode refuses an undeclared key that plain mode allows" do
      schema = %{"type" => "object", "properties" => %{"a" => %{"type" => "integer"}}}

      assert :ok = validate(%{"a" => 1, "b" => 2}, schema, %{})

      assert {:error, [{"$.b", "is not declared in the schema"}]} =
               validate(%{"a" => 1, "b" => 2}, schema, %{}, strict: true)

      open = Map.put(schema, "additionalProperties", %{"type" => "string"})
      assert :ok = validate(%{"a" => 1, "b" => "x"}, open, %{}, strict: true)

      assert {:error, [{"$.b", "is integer, expected string"}]} =
               validate(%{"b" => 2}, open, %{})

      anything = Map.put(schema, "additionalProperties", true)
      assert :ok = validate(%{"b" => 2}, anything, %{}, strict: true)
    end

    test "an unsupported keyword or format is an error, never skipped" do
      assert {:error, [{"$", "schema keyword \"allOf\" is not supported"}]} =
               validate(1, %{"allOf" => []}, %{})

      assert {:error, [{"$", "format \"uuid\" is not supported"}]} =
               validate("x", %{"type" => "string", "format" => "uuid"}, %{})

      assert {:error, [{"$", "schema true is not an object"}]} = validate(1, true, %{})
    end

    test "date-time and date formats are checked" do
      assert :ok = validate("2026-11-20T09:28:00Z", %{"format" => "date-time"}, %{})
      assert :ok = validate("2026-11-20", %{"format" => "date"}, %{})

      assert {:error, [{"$", "\"2026-11-20\" is not an RFC 3339 date-time"}]} =
               validate("2026-11-20", %{"format" => "date-time"}, %{})

      assert {:error, [{"$", "\"20 Nov\" is not an ISO 8601 date"}]} =
               validate("20 Nov", %{"format" => "date"}, %{})

      # A format applies only to strings, but an unknown one is refused on any value.
      assert :ok = validate(nil, %{"format" => "date"}, %{})

      assert {:error, [{"$", "format \"int64\" is not supported"}]} =
               validate(5, %{"type" => "integer", "format" => "int64"}, %{})
    end

    test "pattern, minimum, maxLength, minItems and maxItems are checked", %{spec: spec} do
      settings = fixture("getMyNotificationSettings.json")
      schema = schema_for(spec, "getMyNotificationSettings")

      bad_time = put_in(settings, ["data", "quiet_start"], "25:00")
      assert {:error, [{"$.data.quiet_start", message}]} = validate(bad_time, schema, spec)

      assert message =~ "does not match"

      assert {:error, [{"$", "is -1, less than 0"}]} =
               validate(-1, %{"minimum" => 0}, %{})

      assert {:error, [{"$", "is longer than 2 characters"}]} =
               validate("abc", %{"maxLength" => 2}, %{})

      assert {:error, [{"$", "has 0 items, fewer than 1"}]} =
               validate([], %{"minItems" => 1}, %{})

      assert {:error, [{"$", "has 2 items, more than 1"}]} =
               validate([1, 2], %{"maxItems" => 1}, %{})
    end

    test "an integer is not a float and a number accepts both" do
      assert {:error, [{"$", "is number, expected integer"}]} =
               validate(1.5, %{"type" => "integer"}, %{})

      assert :ok = validate(1, %{"type" => "number"}, %{})
      assert :ok = validate(1.5, %{"type" => ["number", "null"]}, %{})

      assert {:error, [{"$", "is boolean, expected string or null"}]} =
               validate(true, %{"type" => ["string", "null"]}, %{})
    end

    test "a $ref must be local and resolve" do
      assert {:error,
              [{"$", "$ref \"other.json#/x\" is not a local #/components/schemas/ reference"}]} =
               validate(1, %{"$ref" => "other.json#/x"}, %{})

      assert {:error, [{"$", "$ref #/components/schemas/Nope does not resolve"}]} =
               validate(1, %{"$ref" => "#/components/schemas/Nope"}, %{})
    end

    test "a key that is not a plain name is quoted in the path" do
      schema = %{"type" => "object", "required" => ["odd key"]}

      assert {:error, [{~s($["odd key"]), "is required"}]} = validate(%{}, schema, %{})
      assert OpenApiSchemaValidator.key_path("$.data", "user") == "$.data.user"

      assert OpenApiSchemaValidator.format_errors([{"$.a", "is required"}, {"$.b", "x"}]) ==
               "$.a: is required\n$.b: x"
    end
  end
end
