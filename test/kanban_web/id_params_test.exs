defmodule KanbanWeb.IdParamsTest do
  use ExUnit.Case, async: true

  alias KanbanWeb.IdParams

  doctest KanbanWeb.IdParams

  @max_bigint 9_223_372_036_854_775_807

  describe "parse/1" do
    test "accepts positive integers and decimal strings within the bigint range" do
      assert IdParams.parse(1) == {:ok, 1}
      assert IdParams.parse("17") == {:ok, 17}
      assert IdParams.parse(@max_bigint) == {:ok, @max_bigint}
      assert @max_bigint |> Integer.to_string() |> IdParams.parse() == {:ok, @max_bigint}
    end

    test "refuses anything that cannot name a row" do
      for id <- [
            "abc",
            "",
            " 1",
            "1 ",
            "1.5",
            "1abc",
            "0",
            "-3",
            0,
            -3,
            @max_bigint + 1,
            Integer.to_string(@max_bigint + 1),
            "99999999999999999999",
            1.0,
            nil,
            %{},
            ["1"],
            :one
          ] do
        assert IdParams.parse(id) == :error, "expected #{inspect(id)} to be refused"
      end
    end
  end

  describe "parse_list/1" do
    test "parses every element in order" do
      assert IdParams.parse_list(["3", 1, "2"]) == {:ok, [3, 1, 2]}
      assert IdParams.parse_list([]) == {:ok, []}
    end

    test "refuses a list with any bad element, or a non-list" do
      assert IdParams.parse_list(["3", "abc"]) == :error
      assert IdParams.parse_list(["99999999999999999999"]) == :error
      assert IdParams.parse_list("1,2") == :error
      assert IdParams.parse_list(%{"0" => "1"}) == :error
      assert IdParams.parse_list(nil) == :error
    end
  end
end
