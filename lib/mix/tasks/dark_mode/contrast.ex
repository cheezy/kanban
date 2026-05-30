defmodule Mix.Tasks.DarkMode.Contrast do
  @shortdoc "Reports WCAG contrast ratios for the design-token palette in light and dark themes"

  @moduledoc """
  Computes WCAG contrast ratios for canonical design-token color pairs in BOTH
  the light and dark themes, parsing the token values directly from
  `assets/css/app.css`.

  ## Why

  `mix dark_mode.scan` only detects theme-blind *patterns* (hardcoded greys,
  numbered-palette utilities). It never measures whether the resulting colors
  are actually legible, which is why prior dark-mode goals passed the scanner
  yet dark mode stayed broken. This task supplies the missing objective signal:
  it parses each canonical token pair and reports the measured contrast ratio,
  so dark mode can be verified with numbers instead of eyeballs.

  ## Color math

  oklch lightness is *perceptual* and is NOT the same quantity as WCAG relative
  luminance, so converting the oklch L% directly as luminance is wrong. We
  convert properly:

      oklch(L%, C, H)
        -> OKLab            (a = C * cos H, b = C * sin H)
        -> linear-light RGB (inverse OKLab matrix; cube the l'/m'/s' terms)
        -> WCAG luminance   (Y = 0.2126*R + 0.7152*G + 0.0722*B)

  Hex colors (e.g. `--surface: #ffffff` in the light theme) are gamma-decoded
  with the standard sRGB transfer function before the same luminance formula is
  applied. The contrast ratio is `(L_light + 0.05) / (L_dark + 0.05)`, which
  yields 21:1 for pure black on white.

  ## Thresholds

  | Category            | Threshold | Basis                                    |
  |---------------------|-----------|------------------------------------------|
  | Text on surface     | 4.5:1     | WCAG 2.1 AA, normal-size text (1.4.3)    |
  | Status / brand text | 4.5:1     | WCAG 2.1 AA, normal-size text            |
  | Brand accent on bg  | 3.0:1     | WCAG 2.1 AA, graphical objects (1.4.11)  |
  | Border vs surface   | 1.5:1     | Not a WCAG ratio. A border is decorative |
  |                     |           | separation, so the AA text ratio does    |
  |                     |           | not apply; 1.5:1 is a documented,        |
  |                     |           | project-local floor for a border to be   |
  |                     |           | perceivable against its surface.         |

  ## Modes

  Report-only (default) always exits 0, so it documents the current state as a
  baseline without blocking the other dark-mode tasks. `--enforce` exits
  non-zero when any pair is below its threshold; the final dark-mode lock-in
  task flips precommit to enforcing once the token values are fixed.

  ## Usage

      mix dark_mode.contrast              # report both themes, exit 0
      mix dark_mode.contrast --enforce    # exit 1 on any failure
      mix dark_mode.contrast --theme dark # restrict to one theme
  """

  use Mix.Task

  @css_path "assets/css/app.css"

  @aa_text 4.5
  @aa_graphical 3.0
  @border_min 1.5

  # Selectors that anchor each token-defining block in app.css. The light Stride
  # block opens with `.stride-marketing,` at the start of a line; the dark block
  # is prefixed with the `:where([data-theme="dark"])` guard. The daisyUI themes
  # live in `@plugin` blocks distinguished by their `name:` declaration.
  @stride_light_re ~r/\n\.stride-marketing,\s*\n\s*\.stride-screen\s*\{/
  @stride_dark_re ~r/:where\(\[data-theme="dark"\]\)\s*\.stride-marketing/
  @daisy_light_re ~r/name:\s*"light"/
  @daisy_dark_re ~r/name:\s*"dark"/

  @oklch_re ~r/oklch\(\s*([\d.]+)%\s+([\d.]+)\s+([\d.]+)\s*\)/
  @decl_re ~r/--([a-z0-9-]+)\s*:\s*([^;]+);/

  @impl Mix.Task
  def run(argv) do
    {opts, _argv} = OptionParser.parse!(argv, strict: [enforce: :boolean, theme: :string])

    palettes = @css_path |> File.read!() |> parse_palettes()
    themes = themes_to_report(opts[:theme])

    results =
      Enum.flat_map(themes, fn theme ->
        evaluate_theme(Map.fetch!(palettes, theme), theme)
      end)

    print_report(results, themes)
    finish(opts[:enforce], Enum.filter(results, & &1.fail?))
  end

  defp finish(true, [_ | _] = failures) do
    Mix.shell().error(
      "dark_mode.contrast: #{length(failures)} pair(s) below threshold (enforcing mode)."
    )

    exit({:shutdown, 1})
  end

  defp finish(_enforce, _failures), do: :ok

  defp themes_to_report(nil), do: [:light, :dark]
  defp themes_to_report("light"), do: [:light]
  defp themes_to_report("dark"), do: [:dark]

  defp themes_to_report(other) do
    Mix.raise("dark_mode.contrast: unknown --theme #{inspect(other)} (use light or dark)")
  end

  # --- Token parsing -------------------------------------------------------

  defp parse_palettes(css) do
    stride_light = css |> block(@stride_light_re, "--ink") |> declarations()
    stride_dark = css |> block(@stride_dark_re, "--ink") |> declarations()
    daisy_light = css |> block(@daisy_light_re, "--color-base-content") |> declarations()
    daisy_dark = css |> block(@daisy_dark_re, "--color-base-content") |> declarations()

    %{
      # The dark Stride block only overrides a subset of tokens (e.g. --stride-*
      # accents keep their light values), so layer dark over light, then apply
      # the daisyUI dark base tokens on top.
      light: Map.merge(stride_light, daisy_light),
      dark: stride_light |> Map.merge(stride_dark) |> Map.merge(daisy_dark)
    }
  end

  defp block(css, regex, must_contain) do
    case Regex.run(regex, css, return: :index) do
      [{start, len} | _] ->
        css |> block_body(start, len) |> verify_block(regex, must_contain)

      _ ->
        Mix.raise("dark_mode.contrast: could not locate block #{inspect(Regex.source(regex))}")
    end
  end

  defp block_body(css, start, len) do
    css
    |> binary_part(start + len, byte_size(css) - start - len)
    |> String.split("}", parts: 2)
    |> hd()
  end

  defp verify_block(body, regex, must_contain) do
    if String.contains?(body, must_contain) do
      body
    else
      Mix.raise(
        "dark_mode.contrast: block #{inspect(Regex.source(regex))} missing #{must_contain}"
      )
    end
  end

  defp declarations(body) do
    @decl_re
    |> Regex.scan(body)
    |> Enum.reduce(%{}, fn [_, name, value], acc ->
      value = String.trim(value)

      if color_value?(value) do
        Map.put(acc, "--" <> name, value)
      else
        acc
      end
    end)
  end

  defp color_value?("#" <> _), do: true
  defp color_value?("oklch(" <> _), do: true
  defp color_value?(_), do: false

  # --- Pair evaluation -----------------------------------------------------

  defp evaluate_theme(tokens, theme) do
    pair_specs()
    |> Enum.map(&evaluate_pair(&1, tokens, theme))
    |> Enum.reject(&is_nil/1)
  end

  defp evaluate_pair(spec, tokens, theme) do
    with {:ok, fg} <- Map.fetch(tokens, spec.fg),
         {:ok, bg} <- Map.fetch(tokens, spec.bg) do
      ratio = contrast(fg, bg)

      %{
        theme: theme,
        category: spec.category,
        fg: spec.fg,
        bg: spec.bg,
        threshold: spec.threshold,
        ratio: ratio,
        fail?: ratio < spec.threshold
      }
    else
      :error -> nil
    end
  end

  defp pair_specs do
    List.flatten([
      text_specs(),
      quiet_ink_specs(),
      border_specs(),
      status_specs(),
      brand_specs(),
      daisy_specs()
    ])
  end

  defp text_specs do
    for fg <- ~w(--ink --ink-2 --ink-3),
        bg <- ~w(--bg --surface --surface-2 --surface-sunken) do
      spec("text-on-surface", fg, bg, @aa_text)
    end
  end

  # --ink-4 is the QUIET/incidental ink (separators, idle dots, inactive icons,
  # strikethrough decoration, small metadata) — never primary body text. WCAG
  # exempts incidental text from the AA body ratio and applies 3:1 to large /
  # non-essential text, so --ink-4 is held to the @aa_graphical (3:1) floor, not
  # 4.5. (Forcing it to 4.5 would collapse it onto --ink-3 at 52% L, destroying
  # the quiet-ink tier.) See docs/dark-mode-contract.md.
  defp quiet_ink_specs do
    for bg <- ~w(--bg --surface --surface-2 --surface-sunken) do
      spec("quiet-ink", "--ink-4", bg, @aa_graphical)
    end
  end

  defp border_specs do
    for fg <- ~w(--line --line-2 --line-strong),
        bg <- ~w(--bg --surface --surface-2) do
      spec("border-vs-surface", fg, bg, @border_min)
    end
  end

  defp status_specs do
    for s <- ~w(backlog ready doing review done blocked) do
      spec("status", "--st-#{s}", "--st-#{s}-soft", @aa_text)
    end
  end

  defp brand_specs do
    [
      spec("brand-text", "--stride-orange-ink", "--stride-orange-soft", @aa_text),
      spec("brand-text", "--stride-violet-ink", "--stride-violet-soft", @aa_text),
      spec("brand-accent", "--stride-orange", "--bg", @aa_graphical),
      spec("brand-accent", "--stride-violet", "--bg", @aa_graphical)
    ]
  end

  defp daisy_specs do
    for bg <- ~w(--color-base-100 --color-base-200 --color-base-300) do
      spec("daisyui-base", "--color-base-content", bg, @aa_text)
    end
  end

  defp spec(category, fg, bg, threshold) do
    %{category: category, fg: fg, bg: bg, threshold: threshold}
  end

  # --- Color math (public so the math is unit-tested directly) -------------

  @doc """
  Converts a CSS color string (`oklch(L% C H)` or `#rrggbb`) into a linear-light
  sRGB `{r, g, b}` tuple, each channel in `0.0..1.0`.
  """
  def to_linear_rgb("#" <> hex), do: hex_to_linear_rgb(hex)
  def to_linear_rgb("oklch(" <> _ = value), do: oklch_to_linear_rgb(value)

  @doc "WCAG relative luminance of a linear-light sRGB `{r, g, b}` tuple."
  def relative_luminance({r, g, b}), do: 0.2126 * r + 0.7152 * g + 0.0722 * b

  @doc "WCAG contrast ratio (1.0..21.0) between two CSS color strings."
  def contrast(color_a, color_b) do
    l1 = color_a |> to_linear_rgb() |> relative_luminance()
    l2 = color_b |> to_linear_rgb() |> relative_luminance()
    (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
  end

  defp oklch_to_linear_rgb(value) do
    [_, l, c, h] = Regex.run(@oklch_re, value)
    l = to_float(l) / 100.0
    c = to_float(c)
    h_rad = to_float(h) * :math.pi() / 180.0
    oklab_to_linear_rgb(l, c * :math.cos(h_rad), c * :math.sin(h_rad))
  end

  defp oklab_to_linear_rgb(l, a, b) do
    l_ = l + 0.3963377774 * a + 0.2158037573 * b
    m_ = l - 0.1055613458 * a - 0.0638541728 * b
    s_ = l - 0.0894841775 * a - 1.2914855480 * b
    lms_to_linear_rgb(l_ * l_ * l_, m_ * m_ * m_, s_ * s_ * s_)
  end

  defp lms_to_linear_rgb(l, m, s) do
    r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
    g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
    b = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
    {clamp01(r), clamp01(g), clamp01(b)}
  end

  defp hex_to_linear_rgb(hex) do
    <<r::binary-2, g::binary-2, b::binary-2>> = String.trim(hex)
    {srgb_to_linear(channel(r)), srgb_to_linear(channel(g)), srgb_to_linear(channel(b))}
  end

  defp channel(byte), do: String.to_integer(byte, 16) / 255.0

  defp srgb_to_linear(c) when c <= 0.04045, do: c / 12.92
  defp srgb_to_linear(c), do: :math.pow((c + 0.055) / 1.055, 2.4)

  defp clamp01(x) when x < 0.0, do: 0.0
  defp clamp01(x) when x > 1.0, do: 1.0
  defp clamp01(x), do: x

  defp to_float(string) do
    case Float.parse(string) do
      {value, _rest} -> value
      :error -> 0.0
    end
  end

  # --- Reporting -----------------------------------------------------------

  defp print_report(results, themes) do
    shell = Mix.shell()
    heading = "WCAG contrast report — #{Enum.map_join(themes, ", ", &to_string/1)} theme(s)"
    rule = String.duplicate("=", 64)
    shell.info("")
    shell.info(heading)
    shell.info(rule)

    Enum.each(themes, fn theme ->
      print_theme(theme, Enum.filter(results, &(&1.theme == theme)))
    end)

    print_summary(results)
  end

  defp print_theme(theme, results) do
    shell = Mix.shell()
    shell.info("")
    shell.info("#{theme |> to_string() |> String.upcase()} THEME")

    results
    |> Enum.group_by(& &1.category)
    |> Enum.each(fn {category, rows} ->
      shell.info("  #{category}")
      Enum.each(rows, &shell.info(format_row(&1)))
    end)
  end

  defp format_row(row) do
    status = if row.fail?, do: "FAIL", else: "ok  "
    label = String.pad_trailing("#{row.fg} on #{row.bg}", 40)
    ratio = row.ratio |> Float.round(2) |> to_string() |> String.pad_leading(6)
    "    [#{status}] #{label} #{ratio}:1  (min #{row.threshold})"
  end

  defp print_summary(results) do
    shell = Mix.shell()
    fails = Enum.count(results, & &1.fail?)
    rule = String.duplicate("-", 64)
    shell.info("")
    shell.info(rule)
    shell.info("#{fails} failing / #{length(results)} pairs checked")
  end

  if Mix.env() == :test do
    # Test-only seams: the enforce decision and the per-pair evaluation, so the
    # detection + failure paths can be exercised deterministically without
    # depending on the live token palette.
    def __finish__(enforce?, failures), do: finish(enforce?, failures)
    def __evaluate_pair__(spec, tokens, theme), do: evaluate_pair(spec, tokens, theme)
  end
end
