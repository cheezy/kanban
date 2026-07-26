defmodule Mix.Tasks.DarkMode.ContrastTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Mix.Tasks.DarkMode.Contrast

  describe "contrast/2 against known reference values" do
    test "pure black on white is ~21:1 (hex)" do
      assert_in_delta Contrast.contrast("#000000", "#ffffff"), 21.0, 0.01
    end

    test "pure black on white is ~21:1 (oklch)" do
      assert_in_delta Contrast.contrast("oklch(0% 0 0)", "oklch(100% 0 0)"), 21.0, 0.1
    end

    test "is symmetric — order of the two colors does not matter" do
      a = Contrast.contrast("#000000", "#ffffff")
      b = Contrast.contrast("#ffffff", "#000000")
      assert_in_delta a, b, 0.0001
    end

    test "a color against itself is 1:1" do
      assert_in_delta Contrast.contrast("#777777", "#777777"), 1.0, 0.0001
    end

    test "mid grey #808080 on white is ~3.95:1 (known reference)" do
      assert_in_delta Contrast.contrast("#808080", "#ffffff"), 3.95, 0.05
    end

    test "#767676 on white sits at the ~4.54:1 AA boundary (known reference)" do
      assert_in_delta Contrast.contrast("#767676", "#ffffff"), 4.54, 0.06
    end
  end

  describe "to_linear_rgb/1 and relative_luminance/1" do
    test "white has luminance ~1.0 from both hex and oklch" do
      hex = "#ffffff" |> Contrast.to_linear_rgb() |> Contrast.relative_luminance()
      oklch = "oklch(100% 0 0)" |> Contrast.to_linear_rgb() |> Contrast.relative_luminance()
      assert_in_delta hex, 1.0, 0.0001
      assert_in_delta oklch, 1.0, 0.01
    end

    test "black has luminance ~0.0" do
      lum = "#000000" |> Contrast.to_linear_rgb() |> Contrast.relative_luminance()
      assert_in_delta lum, 0.0, 0.0001
    end

    test "oklch lightness is NOT used directly as luminance (62% -> ~0.24, not 0.62)" do
      lum = "oklch(62% 0.005 270)" |> Contrast.to_linear_rgb() |> Contrast.relative_luminance()
      assert lum < 0.30
      assert lum > 0.18
      refute_in_delta lum, 0.62, 0.1
    end

    test "clamps out-of-gamut oklch channels into 0.0..1.0" do
      {r, g, b} = Contrast.to_linear_rgb("oklch(80% 0.20 25)")

      for channel <- [r, g, b] do
        assert channel >= 0.0
        assert channel <= 1.0
      end
    end
  end

  describe "dark-mode border separation (the real failure baseline)" do
    test "--line (28%) on --surface (20%) falls below the 1.5:1 border floor" do
      assert Contrast.contrast("oklch(28% 0.005 270)", "oklch(20% 0.005 270)") < 1.5
    end

    test "--ink-4 (62%) on --surface (20%) actually clears AA — correcting the goal's assumption" do
      assert Contrast.contrast("oklch(62% 0.005 270)", "oklch(20% 0.005 270)") >= 4.5
    end
  end

  describe "spec coverage (W1922)" do
    test "border specs cover --surface-sunken, matching the quiet-ink specs" do
      borders = specs_in("border-vs-surface")

      for fg <- ~w(--line --line-2 --line-strong) do
        assert Enum.any?(borders, &(&1.fg == fg and &1.bg == "--surface-sunken")),
               "#{fg} must be checked against --surface-sunken"
      end
    end

    test "every status soft fill is checked against the border token" do
      chip = specs_in("chip-border")

      for s <- ~w(backlog ready doing review done blocked) do
        assert Enum.any?(chip, &(&1.fg == "--line" and &1.bg == "--st-#{s}-soft")),
               "--st-#{s}-soft must be checked for chip delineation"
      end
    end

    test "chip-border specs use the border floor, not a text floor" do
      for spec <- specs_in("chip-border"), do: assert(spec.threshold == 1.5)
    end

    # The soft fill alone is ~1.05:1 against the card it sits on, so the border
    # is what delineates the chip. Gating the fill would fail app-wide and force
    # a retint of every status token; the contract is "soft fill PLUS border".
    # Contrast is symmetric and spec/4 accepts either ordering, so both
    # orientations must be rejected — checking only fg would let the same pair
    # through written backwards.
    test "a soft fill is deliberately never gated against a surface, in either orientation" do
      surfaces = ~w(--bg --surface --surface-2 --surface-sunken)
      soft_vs_surface? = &(String.ends_with?(&1, "-soft") and &2 in surfaces)

      refute Enum.any?(
               Contrast.__pair_specs__(),
               &(soft_vs_surface?.(&1.fg, &1.bg) or soft_vs_surface?.(&1.bg, &1.fg))
             )
    end

    # An unresolvable token is not reported — evaluate_pair/3 returns nil and the
    # pair is silently dropped, so the only visible symptom is a smaller count.
    # Assert the count so a spec that stops resolving fails loudly instead.
    test "every spec resolves to real tokens in both themes" do
      output = capture_io(fn -> Contrast.run([]) end)
      expected = length(Contrast.__pair_specs__()) * 2

      assert output =~ "#{expected} pairs checked",
             "every spec must resolve in both themes; a dropped pair shrinks the count"
    end

    defp specs_in(category) do
      Enum.filter(Contrast.__pair_specs__(), &(&1.category == category))
    end
  end

  describe "mix task integration" do
    test "report-only mode prints a both-theme report and returns :ok" do
      output = capture_io(fn -> assert Contrast.run([]) == :ok end)
      assert output =~ "WCAG contrast report"
      assert output =~ "LIGHT THEME"
      assert output =~ "DARK THEME"
      assert output =~ "pairs checked"
    end

    test "enforcing mode passes (returns :ok) on the current palette — the W940 gate" do
      # After G202 the whole palette clears its thresholds in both themes, so
      # the precommit gate (`dark_mode.contrast --enforce`) must pass.
      output = capture_io(fn -> assert Contrast.run(["--enforce"]) == :ok end)
      assert output =~ "WCAG contrast report"
      assert output =~ "0 failing"
    end

    test "enforcing mode exits {:shutdown, 1} when a pair is below threshold" do
      capture_io(:stderr, fn ->
        assert catch_exit(Contrast.__finish__(true, [%{fail?: true}])) == {:shutdown, 1}
      end)
    end

    test "report-only mode never exits even with failures present" do
      assert Contrast.__finish__(false, [%{fail?: true}]) == :ok
      assert Contrast.__finish__(true, []) == :ok
    end

    test "evaluate detects a sub-threshold pair as failing (end-to-end detection)" do
      tokens = %{"--fg" => "oklch(52% 0 0)", "--bg" => "oklch(50% 0 0)"}
      spec = %{category: "t", fg: "--fg", bg: "--bg", threshold: 4.5}
      result = Contrast.__evaluate_pair__(spec, tokens, :light)
      assert result.fail?
      assert result.ratio < 4.5
    end

    test "evaluate detects an above-threshold pair as passing" do
      tokens = %{"--fg" => "oklch(0% 0 0)", "--bg" => "oklch(100% 0 0)"}
      spec = %{category: "t", fg: "--fg", bg: "--bg", threshold: 4.5}
      result = Contrast.__evaluate_pair__(spec, tokens, :light)
      refute result.fail?
      assert result.ratio > 4.5
    end

    test "--theme dark restricts the report to the dark theme only" do
      output = capture_io(fn -> Contrast.run(["--theme", "dark"]) end)
      assert output =~ "DARK THEME"
      refute output =~ "LIGHT THEME"
    end

    test "an unknown --theme aborts with a Mix error" do
      assert_raise Mix.Error, ~r/unknown --theme/, fn ->
        capture_io(fn -> Contrast.run(["--theme", "bogus"]) end)
      end
    end
  end
end
