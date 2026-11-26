defmodule Kanban.Mobile.TypeScaleTest do
  @moduledoc """
  The native apps' text styles, written into the design tokens (W2787).
  """
  use ExUnit.Case, async: true

  alias Kanban.Mobile.Tokens
  alias Kanban.Mobile.TypeScale

  @body %{"letter_spacing_em" => -0.005, "line_height" => 1.45}

  describe "build/1" do
    test "names every style the apps show" do
      assert @body |> TypeScale.build() |> Map.keys() |> Enum.sort() ==
               ~w(body callout code footnote headline label large-title subheadline title)
    end

    test "gives every style a family, size, weight, spacing, line height and case" do
      for {name, style} <- TypeScale.build(@body) do
        assert style["family"] in ["font-sans", "font-mono"], name
        assert is_integer(style["size_pt"]) and style["size_pt"] >= 11, name
        assert style["weight"] in [400, 500, 600, 700], name
        assert is_number(style["letter_spacing_em"]), name
        assert is_number(style["line_height"]) and style["line_height"] >= 1, name
        assert is_boolean(style["uppercase"]), name
      end
    end

    test "takes the body's letter spacing and line height from the stylesheet" do
      styles = TypeScale.build(%{"letter_spacing_em" => 0.01, "line_height" => 1.6})

      assert styles["body"]["letter_spacing_em"] == 0.01
      assert styles["body"]["line_height"] == 1.6
      assert styles["footnote"]["line_height"] == 1.6
      assert styles["headline"]["letter_spacing_em"] == 0.01
      assert styles["title"]["letter_spacing_em"] == -0.02
    end

    test "sets running text at 15 pt and labels in capitals" do
      styles = TypeScale.build(@body)

      assert styles["body"]["size_pt"] == 15
      assert styles["label"]["uppercase"]
      assert styles["label"]["family"] == "font-mono"
      refute styles["body"]["uppercase"]
    end
  end

  describe "the tokens" do
    test "carry the text styles in both themes" do
      tokens =
        [File.cwd!(), Tokens.source_path()] |> Path.join() |> File.read!() |> Tokens.build!()

      for theme <- ["light", "dark"] do
        type = tokens["themes"][theme]["type"]
        assert tokens["themes"][theme]["text_style"] == TypeScale.build(type)
      end
    end
  end
end
