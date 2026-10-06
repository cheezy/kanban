defmodule KanbanWeb.MCP.SchemaValidatorTest do
  use ExUnit.Case, async: true

  alias KanbanWeb.MCP.SchemaValidator

  @schema %{
    "type" => "object",
    "properties" => %{
      "id" => %{"type" => ["string", "integer"]},
      "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 5},
      "status" => %{"type" => "string", "enum" => ["open", "done"]},
      "content" => %{"type" => "string", "minLength" => 1, "maxLength" => 3},
      "flag" => %{"type" => "boolean"},
      "items" => %{"type" => "array"},
      "nested" => %{
        "type" => "object",
        "properties" => %{"n" => %{"type" => "number"}},
        "required" => ["n"]
      }
    },
    "required" => ["id"],
    "additionalProperties" => false
  }

  test "accepts valid input" do
    assert SchemaValidator.validate(
             %{
               "id" => 1,
               "limit" => 5,
               "status" => "open",
               "content" => "abc",
               "flag" => true,
               "items" => [],
               "nested" => %{"n" => 1.5}
             },
             @schema
           ) == :ok

    assert SchemaValidator.validate(%{"id" => "W1"}, @schema) == :ok
  end

  test "reports a non-object top level" do
    assert SchemaValidator.validate([1], @schema) ==
             {:error, ["arguments must be of type object"]}
  end

  test "reports required, type, enum, range, length and unknown keys by path" do
    assert {:error, messages} =
             SchemaValidator.validate(
               %{
                 "limit" => 0,
                 "status" => "nope",
                 "content" => "abcd",
                 "flag" => "yes",
                 "nested" => %{},
                 "extra" => 1
               },
               @schema
             )

    assert "arguments.id is required" in messages
    assert "arguments.limit must be at least 1" in messages
    assert "arguments.status must be one of open, done" in messages
    assert "arguments.content must be at most 3 characters" in messages
    assert "arguments.flag must be of type boolean" in messages
    assert "arguments.nested.n is required" in messages
    assert ~s(arguments has an unknown property "extra") in messages
  end

  test "a float is not an integer, an empty string is below minLength, a high value above maximum" do
    assert {:error, messages} =
             SchemaValidator.validate(%{"id" => 1.5, "content" => "", "limit" => 9}, @schema)

    assert "arguments.id must be of type string or integer" in messages
    assert "arguments.content must be at least 1 characters" in messages
    assert "arguments.limit must be at most 5" in messages
  end

  test "error messages never echo a rejected value" do
    assert {:error, messages} =
             SchemaValidator.validate(%{"id" => 1, "status" => "<script>secret"}, @schema)

    refute Enum.any?(messages, &(&1 =~ "secret"))
  end

  test "caps the number of messages" do
    args = Map.new(1..50, &{"k#{&1}", 1}) |> Map.put("id", 1)
    assert {:error, messages} = SchemaValidator.validate(args, @schema)
    assert length(messages) == 10
  end

  test "an integral float counts as an integer, a fractional one does not" do
    assert SchemaValidator.validate(%{"id" => 1, "limit" => 5.0}, @schema) == :ok

    assert {:error, ["arguments.limit must be of type integer"]} =
             SchemaValidator.validate(%{"id" => 1, "limit" => 2.5}, @schema)

    assert SchemaValidator.integral_float?(5.0)
    refute SchemaValidator.integral_float?(5.5)
    refute SchemaValidator.integral_float?(5)
  end

  test "an open schema allows unknown keys" do
    schema = Map.put(@schema, "additionalProperties", true)
    assert SchemaValidator.validate(%{"id" => 1, "anything" => 1}, schema) == :ok
  end
end
