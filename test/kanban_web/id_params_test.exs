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

  describe "parse_index/1" do
    test "parse_index accepts 0 and refuses negative and oversized values" do
      assert IdParams.parse_index("0") == {:ok, 0}
      assert IdParams.parse_index(0) == {:ok, 0}
      assert IdParams.parse_index("3") == {:ok, 3}
      assert IdParams.parse_index(10_000) == {:ok, 10_000}
      assert IdParams.parse_index("10000") == {:ok, 10_000}

      for index <- ["-1", -1, 10_001, "10001", "99999999999999999999"] do
        assert IdParams.parse_index(index) == :error, "expected #{inspect(index)} to be refused"
      end
    end

    test "parse_index refuses empty and nil" do
      assert IdParams.parse_index("") == :error
      assert IdParams.parse_index(nil) == :error
    end

    test "refuses anything that is not exactly a list position" do
      for index <- ["abc", "1x", "1abc", " 1", "1 ", "1.5", 1.0, %{}, ["0"], :zero] do
        assert IdParams.parse_index(index) == :error, "expected #{inspect(index)} to be refused"
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
