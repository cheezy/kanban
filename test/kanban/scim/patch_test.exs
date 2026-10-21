defmodule Kanban.SCIM.PatchTest do
  use ExUnit.Case, async: true

  alias Kanban.SCIM.Patch

  defp ops(operations), do: %{"Operations" => operations}

  defp user_changes(operations), do: operations |> ops() |> Patch.user_changes()
  defp group_ops(operations), do: operations |> ops() |> Patch.group_ops()

  describe "user_changes/1" do
    test "reads Okta's value-map form" do
      assert user_changes([%{"op" => "replace", "value" => %{"active" => false}}]) ==
               {:ok, %{active: false}}
    end

    test "reads Entra ID's path form with string booleans" do
      assert user_changes([%{"op" => "Replace", "path" => "active", "value" => "False"}]) ==
               {:ok, %{active: false}}

      assert user_changes([%{"op" => "Add", "path" => "active", "value" => "TRUE"}]) ==
               {:ok, %{active: true}}
    end

    test "reads name parts, externalId and userName" do
      body =
        ops([
          %{
            "op" => "replace",
            "value" => %{
              "name" => %{"givenName" => "Ada", "familyName" => "Lovelace"},
              "externalId" => "00u1",
              "userName" => "ada@example.com",
              "id" => "ignored"
            }
          }
        ])

      assert Patch.user_changes(body) ==
               {:ok,
                %{
                  name: "Ada Lovelace",
                  name_parts: %{given: "Ada", family: "Lovelace"},
                  external_id: "00u1",
                  user_name: "ada@example.com"
                }}
    end

    test "the formatted name wins over parts and the display name" do
      body =
        ops([
          %{"op" => "replace", "path" => "name.givenName", "value" => "Ada"},
          %{"op" => "replace", "path" => "displayName", "value" => "Countess"},
          %{"op" => "replace", "path" => "name.formatted", "value" => "Ada King"}
        ])

      assert Patch.user_changes(body) ==
               {:ok,
                %{
                  name: "Ada King",
                  name_parts: %{given: "Ada", display: "Countess", formatted: "Ada King"}
                }}
    end

    test "the display name is used when no other name is sent" do
      assert user_changes([%{"op" => "replace", "path" => "displayName", "value" => "Ada"}]) ==
               {:ok, %{name: "Ada", name_parts: %{display: "Ada"}}}
    end

    test "removing externalId clears it; removing other attributes is ignored" do
      assert user_changes([%{"op" => "remove", "path" => "externalId"}]) ==
               {:ok, %{external_id: nil}}

      assert user_changes([%{"op" => "remove", "path" => "title"}]) == {:ok, %{}}
    end

    test "ignores attributes Stride does not store, and nulls" do
      body =
        ops([
          %{
            "op" => "replace",
            "value" => %{
              "urn:ietf:params:scim:schemas:extension:enterprise:2.0:User:department" => "R&D",
              "emails" => [%{"value" => "x@example.com"}],
              "displayName" => nil
            }
          }
        ])

      assert Patch.user_changes(body) == {:ok, %{}}
    end

    test "refuses malformed bodies and values" do
      assert Patch.user_changes(%{}) == {:error, :invalid_syntax}
      assert user_changes([]) == {:error, :invalid_syntax}

      assert user_changes([%{"op" => "move", "path" => "active"}]) ==
               {:error, :invalid_syntax}

      assert user_changes([%{"path" => "active"}]) == {:error, :invalid_syntax}
      assert user_changes([%{"op" => "remove"}]) == {:error, :invalid_syntax}

      assert user_changes([%{"op" => "replace", "path" => "active", "value" => "maybe"}]) ==
               {:error, :invalid_value}

      assert user_changes([%{"op" => "replace", "path" => "userName", "value" => 5}]) ==
               {:error, :invalid_value}

      assert user_changes([%{"op" => "replace", "value" => "active"}]) ==
               {:error, :invalid_value}

      assert user_changes([%{"op" => "replace", "value" => %{"name" => %{"givenName" => 1}}}]) ==
               {:error, :invalid_value}
    end
  end

  describe "group_ops/1" do
    test "reads member adds" do
      body =
        ops([
          %{"op" => "add", "path" => "members", "value" => [%{"value" => "1"}, %{"value" => 2}]}
        ])

      assert Patch.group_ops(body) == {:ok, [{:add, ["1", "2"]}]}
    end

    test "reads Okta's remove by path filter" do
      body = ops([%{"op" => "remove", "path" => ~s(members[value eq "7"])}])
      assert Patch.group_ops(body) == {:ok, [{:remove, ["7"]}]}
    end

    test "reads Entra ID's remove by value list and remove all" do
      assert group_ops([%{"op" => "Remove", "path" => "members", "value" => [%{"value" => "3"}]}]) ==
               {:ok, [{:remove, ["3"]}]}

      assert group_ops([%{"op" => "remove", "path" => "members"}]) ==
               {:ok, [:remove_all]}
    end

    test "reads replace, by path and by value map" do
      assert group_ops([
               %{"op" => "replace", "path" => "members", "value" => [%{"value" => "4"}]}
             ]) == {:ok, [{:replace, ["4"]}]}

      body =
        ops([
          %{
            "op" => "replace",
            "value" => %{
              "id" => "9",
              "displayName" => "Engineering",
              "members" => [%{"value" => "5"}]
            }
          }
        ])

      assert {:ok, parsed} = Patch.group_ops(body)
      assert Enum.sort(parsed) == Enum.sort([{:display_name, "Engineering"}, {:replace, ["5"]}])
    end

    test "reads a displayName path" do
      assert group_ops([%{"op" => "replace", "path" => "displayName", "value" => "X"}]) ==
               {:ok, [{:display_name, "X"}]}
    end

    test "refuses unknown paths and malformed members" do
      assert group_ops([%{"op" => "replace", "path" => "owner", "value" => "x"}]) ==
               {:error, :invalid_path}

      assert group_ops([%{"op" => "add", "path" => ~s(members[value eq "1"])}]) ==
               {:error, :invalid_path}

      assert group_ops([%{"op" => "replace", "value" => %{"owner" => "x"}}]) ==
               {:error, :invalid_path}

      assert group_ops([%{"op" => "add", "path" => "members", "value" => [%{}]}]) ==
               {:error, :invalid_syntax}

      assert group_ops([%{"op" => "add", "path" => "members", "value" => "x"}]) ==
               {:error, :invalid_syntax}

      assert group_ops([%{"op" => "replace", "path" => "displayName", "value" => 1}]) ==
               {:error, :invalid_syntax}

      assert group_ops([%{"op" => "jump"}]) == {:error, :invalid_syntax}
      assert group_ops(["x"]) == {:error, :invalid_syntax}
      assert Patch.group_ops(%{}) == {:error, :invalid_syntax}
    end

    test "a single member object is read as a list" do
      body = ops([%{"op" => "add", "path" => "members", "value" => %{"value" => "8"}}])
      assert Patch.group_ops(body) == {:ok, [{:add, ["8"]}]}
    end

    test "keeps the operations in the order they were sent" do
      assert group_ops([
               %{"op" => "add", "path" => "members", "value" => [%{"value" => "1"}]},
               %{"op" => "remove", "path" => ~s(members[value eq "1"])},
               %{"op" => "replace", "path" => "members", "value" => [%{"value" => "2"}]},
               %{"op" => "remove", "path" => "members"}
             ]) == {:ok, [{:add, ["1"]}, {:remove, ["1"]}, {:replace, ["2"]}, :remove_all]}
    end

    # Each operation used to be appended to the list read so far, so this
    # took about 16 seconds; read in one pass it takes milliseconds.
    test "reads a body of 100,000 operations in linear time" do
      operation = %{"op" => "remove", "path" => "members", "value" => [%{"value" => "1"}]}

      {micros, result} =
        :timer.tc(fn -> group_ops(List.duplicate(operation, 100_000)) end)

      assert {:ok, parsed} = result
      assert length(parsed) == 100_000
      assert micros < 3_000_000
    end
  end

  test "boolean/1 reads SCIM booleans" do
    assert Patch.boolean(true) == {:ok, true}
    assert Patch.boolean(" false ") == {:ok, false}
    assert Patch.boolean(1) == :error
  end

  test "compose_name/1 returns nil without text" do
    assert Patch.compose_name(%{given: "  ", display: ""}) == nil
    assert Patch.compose_name(%{family: "Lovelace"}) == "Lovelace"
  end
end
