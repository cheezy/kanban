defmodule Kanban.ChangesetTextTest do
  use ExUnit.Case, async: true

  import Ecto.Changeset

  alias Kanban.ChangesetText

  @message "contains characters that are not allowed"

  @types %{name: :string, tags: {:array, :string}, details: :map, count: :integer}

  defp changeset(attrs, data \\ %{}) do
    {data, @types}
    |> cast(attrs, Map.keys(@types))
    |> ChangesetText.validate_storable([:name, :tags, :details, :count])
  end

  defp errors(changeset) do
    traverse_errors(changeset, fn {message, _opts} -> message end)
  end

  test "accepts valid unicode, tabs and newlines" do
    for name <- [
          "École déjà vu",
          "日本語のボード",
          "Ship it 🚀",
          # A ZWJ family emoji sequence
          "👨‍👩‍👧",
          "line one\nline two\ttabbed\r\n",
          # Other control characters are valid text, not unstorable bytes
          "bell\a and escape\e"
        ] do
      changeset = changeset(%{name: name})
      assert changeset.valid?, inspect(name)
      assert get_change(changeset, :name) == name
    end
  end

  test "refuses truncated and stray bytes" do
    for name <- [
          # A lone continuation byte
          <<0x80>>,
          <<"ab", 0x80, "cd">>,
          # A truncated two-byte sequence ("é" is <<0xC3, 0xA9>>)
          <<0xC3>>,
          <<"caf", 0xC3>>,
          # A truncated three-byte sequence ("日" is <<0xE6, 0x97, 0xA5>>)
          <<0xE6, 0x97>>,
          # A truncated four-byte sequence (an emoji)
          <<0xF0, 0x9F, 0x9A>>
        ] do
      assert %{name: [@message]} = errors(changeset(%{name: name})), inspect(name)
    end
  end

  test "refuses NUL and invalid UTF-8" do
    for name <- [<<0>>, <<"De", 0, "sign">>, <<"Design", 0xFF>>, <<0xFE, 0xFF>>] do
      changeset = changeset(%{name: name})
      refute changeset.valid?
      assert errors(changeset) == %{name: [@message]}, inspect(name)
    end
  end

  test "refuses NUL and invalid UTF-8 in list elements and nested map keys and values" do
    assert %{tags: [@message]} = errors(changeset(%{tags: ["ok", <<"b", 0>>]}))
    assert %{tags: [@message]} = errors(changeset(%{tags: ["ok", <<0xFF>>]}))

    assert %{details: [@message]} =
             errors(changeset(%{details: %{"unit" => ["fine", <<"x", 0, "y">>]}}))

    assert %{details: [@message]} =
             errors(changeset(%{details: %{"outer" => %{"inner" => <<0xC3>>}}}))

    assert %{details: [@message]} = errors(changeset(%{details: %{<<"k", 0>> => "v"}}))

    assert changeset(%{tags: ["a", "b"], details: %{"a" => [1, true, nil, "ok"]}}).valid?
  end

  test "skips nil and unchanged fields" do
    assert changeset(%{name: nil, tags: nil, details: nil}).valid?
    assert changeset(%{name: ""}).valid?
    assert changeset(%{count: 3}).valid?

    # A field already holding bad bytes is not re-checked when it does not
    # change, and a field the changeset does not list is never checked.
    assert changeset(%{count: 4}, %{name: <<0>>}).valid?

    unlisted =
      {%{}, @types}
      |> cast(%{name: <<0>>}, [:name])
      |> ChangesetText.validate_storable([:tags])

    assert unlisted.valid?
  end

  test "the error never echoes the offending bytes" do
    changeset = changeset(%{name: <<"secret", 0, "value">>})
    [{:name, {message, opts}}] = changeset.errors
    assert message == @message
    refute message =~ "secret"
    refute Enum.any?(opts, fn {_key, value} -> is_binary(value) and value =~ "secret" end)
  end

  test "the :message option replaces the default message" do
    changeset =
      {%{}, @types}
      |> cast(%{name: <<"a", 0>>}, [:name])
      |> ChangesetText.validate_storable([:name], message: "is invalid")

    assert errors(changeset) == %{name: ["is invalid"]}
  end

  test "storable?/1 checks strings, lists, maps and structs, and passes other values" do
    assert ChangesetText.storable?("plain")
    assert ChangesetText.storable?(["a", %{"b" => "c"}])
    assert ChangesetText.storable?(42)
    assert ChangesetText.storable?(:atom_key)
    assert ChangesetText.storable?(~D[2026-10-20])
    refute ChangesetText.storable?(<<0>>)
    refute ChangesetText.storable?([%{"b" => <<0xFF>>}])
    refute ChangesetText.storable?(%URI{path: <<"a", 0>>})
  end

  test "message/0 is the default message" do
    assert ChangesetText.message() == @message
  end
end
