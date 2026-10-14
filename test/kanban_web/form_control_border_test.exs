defmodule KanbanWeb.FormControlBorderTest do
  @moduledoc """
  D375: an `<input>`, `<select>` or `<textarea>` is filled with the panel
  colour, so its border is the only thing that identifies it, and WCAG 2.1
  SC 1.4.11 asks 3:1 for it. Only `--line-input` is gated at 3:1 by
  `mix dark_mode.contrast`; `--line`, `--line-2` and `--line-strong` are
  decorative 1.5:1 tokens. This test reads the templates under
  `lib/kanban_web` and fails when a form control draws its border with any
  token other than `--line-input`, whether the style is inline or comes from a
  zero-arity style helper (`style={input_style()}`).
  """
  use ExUnit.Case, async: true

  @source_root "lib/kanban_web"
  @form_tags ~w(input select textarea .input)
  @tag_re ~r/<(\.?[a-zA-Z][a-zA-Z0-9_.-]*)/
  @border_token_re ~r/(?:border(?:-[a-z]+)?:[^;"]*|border-color:\s*)var\((--line[a-z0-9-]*)\)/
  @helper_call_re ~r/style=\{([a-z_]+)\(\)\}/

  describe "form-control border token" do
    test "inline form-control borders use --line-input" do
      offenders =
        for {path, lines} <- sources(),
            {tag, line, number} <- tagged_lines(lines),
            tag in @form_tags,
            token <- border_tokens(line),
            token != "--line-input",
            do: "#{path}:#{number} <#{tag}> uses #{token}"

      assert offenders == [],
             "form controls on a decorative border:\n" <> Enum.join(offenders, "\n")
    end

    test "style helpers applied to form controls use --line-input" do
      offenders =
        for {path, lines} <- sources(),
            source = Enum.join(lines, "\n"),
            helper <- form_control_helpers(lines),
            token <- helper_border_tokens(source, helper),
            token != "--line-input",
            do: "#{path} #{helper}/0 uses #{token}"

      assert offenders == [],
             "form-control style helpers on a decorative border:\n" <> Enum.join(offenders, "\n")
    end

    test "the scan sees the helper and inline form controls it is meant to guard" do
      inline =
        for {_path, lines} <- sources(),
            {tag, line, _} <- tagged_lines(lines),
            tag in @form_tags,
            border_tokens(line) != [],
            do: tag

      helpers = for {_path, lines} <- sources(), helper <- form_control_helpers(lines), do: helper

      # Guard against a vacuous pass: a regex that stopped matching would
      # report no offenders because it found no form controls at all.
      assert length(inline) >= 40
      assert "input_style" in helpers
      assert "select_style" in helpers
      assert "control_style" in helpers
    end

    # The core `<.input>` component renders daisyUI .input/.select/.textarea,
    # which take their border from --input-color (base-content at 20% alpha by
    # default, about 1.5:1). Those controls carry no token in source, so the two
    # scans above cannot see them; app.css re-points --input-color instead.
    test "daisyUI form controls take their resting border from --line-input" do
      css = File.read!("assets/css/app.css")

      [rule] =
        Regex.scan(~r/:where\(\.stride-screen, \.stride-marketing\)[^{]*\{[^}]*\}/, css)
        |> List.flatten()
        |> Enum.filter(&String.contains?(&1, "--input-color"))

      assert rule =~ "--input-color: var(--line-input);"

      for class <- ~w(.input .select .textarea),
          do: assert(rule =~ class, "#{class} must take --line-input")

      # Focus and error borders stay daisyUI's, so they must be excluded.
      for state <- ~w(:focus :focus-within .input-error .select-error .textarea-error),
          do: assert(rule =~ state, "#{state} must keep daisyUI's own border")
    end

    test "a decorative token on a form control is reported" do
      lines = [~s|<select|, ~s|  style="border: 1px solid var(--line);"|]
      assert {"select", _, 2} = lines |> tagged_lines() |> List.last()
      assert border_tokens(Enum.at(lines, 1)) == ["--line"]
    end
  end

  defp sources do
    [@source_root, "**", "*.{ex,heex}"]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.map(&{&1, &1 |> File.read!() |> String.split("\n")})
  end

  # Pairs each line with the most recently opened tag, so a style attribute on
  # its own line is attributed to the element it belongs to.
  defp tagged_lines(lines) do
    lines
    |> Enum.with_index(1)
    |> Enum.map_reduce(nil, fn {line, number}, tag ->
      tag = last_tag(line) || tag
      {{tag, line, number}, tag}
    end)
    |> elem(0)
  end

  defp last_tag(line) do
    case Regex.scan(@tag_re, line) do
      [] -> nil
      matches -> matches |> List.last() |> List.last()
    end
  end

  defp border_tokens(line) do
    @border_token_re |> Regex.scan(line) |> Enum.map(&List.last/1)
  end

  defp form_control_helpers(lines) do
    for {tag, line, _} <- tagged_lines(lines),
        tag in @form_tags,
        [_, helper] <- Regex.scan(@helper_call_re, line),
        uniq: true,
        do: helper
  end

  defp helper_border_tokens(source, helper) do
    case Regex.run(~r/defp #{helper} do\n(.*?)\n  end/s, source) do
      [_, body] -> border_tokens(body)
      nil -> []
    end
  end
end
