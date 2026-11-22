defmodule Kanban.Mobile.TokensTest do
  @moduledoc """
  The native apps' design tokens, generated from app.css (W2776).
  """
  use ExUnit.Case, async: true

  alias Kanban.Mobile.Tokens

  @root Path.expand("../../..", __DIR__)
  @refresh_hint "mobile/shared/tokens/tokens.json is stale. Refresh it with: MIX_ENV=test mix mobile.tokens"

  # A stylesheet shaped like app.css: the light block and the dark override at
  # column 0, the type scale in the light block and the narrow font size under
  # the phone media query.
  defp css(light, dark \\ "", opts \\ []) do
    type =
      Keyword.get(opts, :type, "font-size: 13px; line-height: 1.45; letter-spacing: -0.005em;")

    narrow = Keyword.get(opts, :narrow, "font-size: 14.5px;")

    """
    .stride-marketing,
    .stride-screen {
      #{light}
      #{type}
    }

    :where([data-theme="dark"]) .stride-marketing,
    :where([data-theme="dark"]) .stride-screen {
      #{dark}
    }

    @media (max-width: 767px) {
      .stride-marketing,
      .stride-screen {
        #{narrow}
      }
    }
    """
  end

  defp theme(css, name), do: css |> Tokens.build!() |> get_in(["themes", name])

  defp color(css, theme, token), do: css |> theme(theme) |> get_in(["color", token])

  defp channels("#" <> hex) do
    hex
    |> Base.decode16!(case: :lower)
    |> :binary.bin_to_list()
  end

  defp assert_close(actual, expected) do
    pairs = actual |> channels() |> Enum.zip(channels(expected))

    for {a, e} <- pairs do
      assert abs(a - e) <= 1, "#{actual} is not within 1 per channel of #{expected}"
    end
  end

  defp keys_sorted?(%Jason.OrderedObject{values: values}) do
    keys = Enum.map(values, &elem(&1, 0))
    keys == Enum.sort(keys) and Enum.all?(values, fn {_key, value} -> keys_sorted?(value) end)
  end

  defp keys_sorted?(_value), do: true

  defp app_css, do: @root |> Path.join(Tokens.source_path()) |> File.read!()

  defp committed, do: @root |> Path.join(Tokens.output_path()) |> File.read!()

  describe "parse!/1 and build!/1" do
    test "parses light and dark values for the same token" do
      css = css("--ink: oklch(18% 0.005 270);", "--ink: oklch(95% 0.005 270);")

      assert color(css, "light", "ink") == %{
               "hex" => "#111114",
               "oklch" => "oklch(18% 0.005 270)"
             }

      assert color(css, "dark", "ink") == %{"hex" => "#edeef2", "oklch" => "oklch(95% 0.005 270)"}
    end

    test "converts oklch to hex within rounding" do
      css =
        css("""
        --white: oklch(100% 0 0);
        --black: oklch(0% 0 0);
        --red: oklch(62.8% 0.2577 29.23);
        --orange: oklch(66% 0.17 47);
        --grey: oklch(50% 0 0);
        --surface: #FFFFFF;
        """)

      assert color(css, "light", "white")["hex"] == "#ffffff"
      assert color(css, "light", "black")["hex"] == "#000000"
      assert_close(color(css, "light", "red")["hex"], "#ff0000")
      assert_close(color(css, "light", "orange")["hex"], "#e36a1f")
      assert_close(color(css, "light", "grey")["hex"], "#636363")
      assert color(css, "light", "surface") == %{"hex" => "#ffffff"}
    end

    test "carries an alpha as an eight-digit hex, alpha last" do
      css = css("--banner-border: oklch(85% 0.12 50 / 0.55); --opaque: oklch(50% 0 0 / 1);")

      assert color(css, "light", "banner-border") == %{
               "hex" => "#ffb6858c",
               "oklch" => "oklch(85% 0.12 50 / 0.55)"
             }

      assert String.ends_with?(color(css, "light", "opaque")["hex"], "ff")
    end

    test "a token defined only in light keeps light in dark" do
      css =
        css(
          "--r-sm: 4px; --font-sans: 'Geist', sans-serif; --bg: oklch(98% 0 0);",
          "--bg: oklch(16% 0 0);"
        )

      for theme <- ["light", "dark"] do
        assert get_in(theme(css, theme), ["radius", "r-sm"]) == 4
        assert get_in(theme(css, theme), ["font", "font-sans"]) == "'Geist', sans-serif"
      end

      refute color(css, "light", "bg") == color(css, "dark", "bg")
    end

    test "resolves var() references within each theme" do
      css =
        css(
          """
          --accent: oklch(66% 0.17 47);
          --bar: linear-gradient(to right, var(--accent) 0%, var( --accent ) 100%);
          """,
          "--accent: oklch(72% 0.18 47);"
        )

      assert get_in(theme(css, "light"), ["composite", "bar"]) ==
               "linear-gradient(to right, oklch(66% 0.17 47) 0%, oklch(66% 0.17 47) 100%)"

      assert get_in(theme(css, "dark"), ["composite", "bar"]) ==
               "linear-gradient(to right, oklch(72% 0.18 47) 0%, oklch(72% 0.18 47) 100%)"
    end

    test "keeps shadows and gradients as CSS strings" do
      css =
        css("""
        --shadow-sm: 0 1px 0 rgba(20,18,15,.03), 0 1px 2px rgba(20,18,15,.04);
        --glow: linear-gradient(135deg, oklch(97% 0.05 60 / 0.85) 0%, oklch(96% 0.04 290 / 0.4) 100%);
        """)

      assert theme(css, "light")["composite"] == %{
               "shadow-sm" => "0 1px 0 rgba(20,18,15,.03), 0 1px 2px rgba(20,18,15,.04)",
               "glow" =>
                 "linear-gradient(135deg, oklch(97% 0.05 60 / 0.85) 0%, oklch(96% 0.04 290 / 0.4) 100%)"
             }
    end

    test "reads the type scale into both themes" do
      css = css("--bg: oklch(98% 0 0);")

      type = %{
        "font_size_px" => 13,
        "font_size_narrow_px" => 14.5,
        "letter_spacing_em" => -0.005,
        "line_height" => 1.45
      }

      assert theme(css, "light")["type"] == type
      assert theme(css, "dark")["type"] == type
    end

    test "ignores comments, including token names inside them" do
      css = css("/* --fake: oklch(1% 0 0); */ --bg: oklch(98% 0 0); /* } */")

      assert Map.keys(theme(css, "light")["color"]) == ["bg"]
    end

    test "every group is present even when it is empty" do
      css = css("--bg: oklch(98% 0 0);")

      assert css |> theme("dark") |> Map.keys() |> Enum.sort() ==
               ["color", "composite", "font", "radius", "type"]

      assert Tokens.build!(css)["generator"] == "mix mobile.tokens"
      assert Tokens.build!(css)["source"] == "assets/css/app.css"
    end
  end

  describe "errors" do
    test "an unparseable value fails with the token name" do
      assert_raise ArgumentError, ~r/--bg "oklch\(nope\)"/, fn ->
        "--bg: oklch(nope);" |> css() |> Tokens.build!()
      end
    end

    test "every malformed stylesheet fails naming what is wrong" do
      cases = [
        {css("--bg: #12345;"), ~r/--bg .* six-digit hex/},
        {css("--mix: color-mix(in oklch, red, blue);"), ~r/--mix .* is not a colour/},
        {css("--r-sm: 1rem;"), ~r/--r-sm "1rem" is not a number in px/},
        {css("--bar: linear-gradient(var(--missing), red);"), ~r/--bar .* undefined --missing/},
        {css("--bar: linear-gradient(var(--a, red), red);"), ~r/--bar .* var\(\) this generator/},
        {css("--bg: oklch(98% 0 0);", "--glow: oklch(30% 0 0);"), ~r/--glow .* only in dark/},
        {css("--bg: oklch(98% 0 0);", "", type: "line-height: 1.45; letter-spacing: 0;"),
         ~r/no font-size/},
        {css("--bg: oklch(98% 0 0);", "",
           type: "font-size: 13px; line-height: 1.45; letter-spacing: normal;"
         ), ~r/letter-spacing "normal" is not a number in em/},
        {css("--bg: oklch(98% 0 0);", "",
           type: "font-size: 13px; line-height: tall; letter-spacing: 0em;"
         ), ~r/line-height "tall" is not a number in plain units/},
        {css("--bg oklch(98% 0 0);"), ~r/is not a declaration/},
        {"", ~r/no light .stride-screen block/},
        {"--bg: oklch(98% 0 0);"
         |> css()
         |> String.replace(~s/:where([data-theme="dark"])/, ".x"),
         ~r/no dark .stride-screen block/},
        {"--bg: oklch(98% 0 0);" |> css() |> String.replace("767px", "640px"),
         ~r/no narrow .stride-screen block/},
        {css("--bg: oklch(98% 0 0);") <> css("--bg: oklch(50% 0 0);"),
         ~r/more than one light .stride-screen block/}
      ]

      for {stylesheet, message} <- cases do
        assert_raise ArgumentError, message, fn -> Tokens.build!(stylesheet) end
      end
    end
  end

  describe "render!/1" do
    test "output is sorted and stable" do
      css =
        css(
          "--zeta: oklch(50% 0 0); --alpha: #000000; --r-xl: 14px; --r-sm: 4px;",
          "--zeta: oklch(60% 0 0);"
        )

      json = Tokens.render!(css)

      assert json == Tokens.render!(css)
      assert String.ends_with?(json, "}\n")
      assert json |> Jason.decode!(objects: :ordered_objects) |> keys_sorted?()
      assert Jason.decode!(json) == Tokens.build!(css)
    end
  end

  describe "the committed tokens.json" do
    test "the committed tokens.json is up to date" do
      assert committed() == Tokens.render!(app_css()), @refresh_hint
    end

    test "a changed app.css value changes the render, so the staleness test catches it" do
      css = app_css()
      assert css =~ "--ink: oklch(18% 0.005 270);"

      changed =
        String.replace(css, "--ink: oklch(18% 0.005 270);", "--ink: oklch(19% 0.005 270);")

      refute Tokens.render!(changed) == committed()
    end

    test "every dark-mode contract token is present in both themes" do
      statuses = ~w(backlog ready doing review done blocked)
      labels = ~w(gray red orange yellow green teal blue purple pink)

      colors =
        ~w(bg surface surface-2 surface-sunken ink ink-2 ink-3 ink-4 line line-2 line-strong line-input
           banner-border) ++
          Enum.flat_map(statuses, &["st-#{&1}", "st-#{&1}-soft"]) ++
          Enum.flat_map(labels, &["label-#{&1}", "label-#{&1}-soft"]) ++
          Enum.flat_map(
            ~w(orange violet),
            &["stride-#{&1}", "stride-#{&1}-soft", "stride-#{&1}-ink"]
          ) ++
          ~w(hitme-navy hitme-cyan hitme-yellow hitme-lead hitme-caption hitme-white hitme-on-cyan)

      tokens = Jason.decode!(committed())

      for theme <- ["light", "dark"], token <- colors do
        hex = get_in(tokens, ["themes", theme, "color", token, "hex"])
        assert hex =~ ~r/^#[0-9a-f]{6}([0-9a-f]{2})?$/, "#{theme} has no hex for --#{token}"
      end

      for theme <- ["light", "dark"], token <- ~w(banner-gradient loading-bar-gradient) do
        refute get_in(tokens, ["themes", theme, "composite", token]) =~ "var("
      end
    end

    test "the paths are relative to the project root" do
      assert Tokens.source_path() == "assets/css/app.css"
      assert Tokens.output_path() == "mobile/shared/tokens/tokens.json"
    end
  end
end
