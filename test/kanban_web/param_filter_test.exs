defmodule KanbanWeb.ParamFilterTest do
  use ExUnit.Case, async: true

  alias KanbanWeb.ParamFilter

  @params %{
    "name" => "SIEM",
    "secret_token" => %{"url" => "https://siem.example.org/x", "credential" => "abc"},
    "nested" => [%{"password" => "pw", "note" => "token=abc", "kept" => "plain"}, "leaf"],
    "empty" => [],
    "count" => 3,
    "at" => ~D[2026-11-13]
  }

  test "discards a key holding a filtered word and a value holding word=, in nested maps and lists, and keeps structs" do
    assert ParamFilter.filter(@params, ["password", "token"]) == %{
             "name" => "SIEM",
             "secret_token" => "[FILTERED]",
             "nested" => [
               %{"password" => "[FILTERED]", "note" => "[FILTERED]", "kept" => "plain"},
               "leaf"
             ],
             "empty" => [],
             "count" => 3,
             "at" => ~D[2026-11-13]
           }
  end

  test "with no filtered words returns the params unchanged" do
    assert ParamFilter.filter(@params, []) == @params
  end

  test "{:discard, words} and a single word filter like a plain list" do
    expected = ParamFilter.filter(@params, ["token"])

    assert expected["secret_token"] == "[FILTERED]"
    assert ParamFilter.filter(@params, {:discard, ["token"]}) == expected
    assert ParamFilter.filter(@params, "token") == expected
  end

  test "keep mode keeps only the listed keys and filters every other leaf, structs and empty lists included" do
    assert ParamFilter.filter(@params, {:keep, ["name", "kept"]}) == %{
             "name" => "SIEM",
             "secret_token" => %{"url" => "[FILTERED]", "credential" => "[FILTERED]"},
             "nested" => [
               %{"password" => "[FILTERED]", "note" => "[FILTERED]", "kept" => "plain"},
               "[FILTERED]"
             ],
             "empty" => "[FILTERED]",
             "count" => "[FILTERED]",
             "at" => "[FILTERED]"
           }
  end

  test "reads :filter_parameters by default, in the compiled form Phoenix stores at start" do
    assert {:compiled, _words, _pairs} = Application.get_env(:phoenix, :filter_parameters)

    filtered = ParamFilter.filter(@params)

    assert filtered["secret_token"] == "[FILTERED]"
    assert filtered["nested"] |> hd() |> Map.fetch!("password") == "[FILTERED]"
    assert filtered["name"] == "SIEM"
  end

  test "a compiled filter discards like the word list it was compiled from" do
    words = ["password", "token"]
    pairs = Enum.map(words, &(&1 <> "="))
    compiled = {:compiled, :binary.compile_pattern(words), :binary.compile_pattern(pairs)}

    assert ParamFilter.filter(@params, compiled) == ParamFilter.filter(@params, words)
  end

  test "leaves a leaf or a non-binary key alone in discard mode" do
    assert ParamFilter.filter("token=abc", ["token"]) == "token=abc"
    assert ParamFilter.filter(%{1 => "token=abc"}, ["token"]) == %{1 => "[FILTERED]"}
  end
end
