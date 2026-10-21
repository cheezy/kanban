defmodule Kanban.Workspaces.Export.Importer.RefsTest do
  use ExUnit.Case, async: true

  alias Kanban.Workspaces.Export.Importer.Refs

  doctest Refs, import: true

  test "shorten/1 cuts at 60 characters, counting multibyte characters as one" do
    sixty = String.duplicate("a", 60)

    assert Refs.shorten(sixty) == sixty
    assert Refs.shorten(sixty <> "a") == sixty <> "…"
    assert "日" |> String.duplicate(100) |> Refs.shorten() == String.duplicate("日", 60) <> "…"
  end

  test "shorten/1 never echoes a NUL byte or invalid UTF-8" do
    assert Refs.shorten("bad\0name") == "(text that cannot be shown)"
    assert Refs.shorten(<<0xFF, 0xFE>>) == "(text that cannot be shown)"
  end

  test "name_ref/1 keeps an integer id in full and shortens a text id" do
    name = String.duplicate("x", 200)
    id = 123_456_789_012

    assert Refs.name_ref(%{"id" => id, "name" => name}) ==
             ~s("#{String.duplicate("x", 60)}…", id 123456789012)

    assert Refs.name_ref(%{"id" => String.duplicate("7", 80)}) ==
             "id " <> String.duplicate("7", 60) <> "…"
  end

  test "name_ref/1 leaves out a name or id of another type" do
    assert Refs.name_ref(%{"id" => 4, "name" => %{"nested" => true}}) == "id 4"
    assert Refs.name_ref(%{"id" => [1], "name" => 5}) == "unnamed row"
    assert Refs.name_ref(%{}) == "unnamed row"
  end

  test "ref/1 handles every subject without raising" do
    assert Refs.ref(42) == "42"
    assert "W" |> String.duplicate(70) |> Refs.ref() == String.duplicate("W", 60) <> "…"
    assert Refs.ref(%{"id" => 1, "name" => "Todo"}) == ~s("Todo", id 1)
    assert Refs.ref(nil) == "unnamed row"
    assert Refs.ref([1, 2]) == "unnamed row"
    assert Refs.ref(1.5) == "unnamed row"
  end
end
