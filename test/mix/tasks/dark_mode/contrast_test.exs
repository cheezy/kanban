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

  describe "mix task integration" do
    test "report-only mode prints a both-theme report and returns :ok" do
      output = capture_io(fn -> assert Contrast.run([]) == :ok end)
      assert output =~ "WCAG contrast report"
      assert output =~ "LIGHT THEME"
      assert output =~ "DARK THEME"
      assert output =~ "pairs checked"
    end

    test "enforcing mode exits non-zero because the current palette has failures" do
      output =
        capture_io(fn ->
          try do
            Contrast.run(["--enforce"])
            send(self(), :no_exit)
          catch
            :exit, {:shutdown, 1} -> send(self(), :exited)
          end
        end)

      assert output =~ "WCAG contrast report"
      assert_received :exited
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
