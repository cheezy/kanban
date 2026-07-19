defmodule KanbanWeb.MetricsPdfHTMLPolicyTest do
  @moduledoc """
  Guards the fixed-palette policy for BOTH PDF metrics exports.

  PDFs must render identically regardless of the active daisyUI / Stride
  theme. The policy comments in `KanbanWeb.MetricsPdfHTML`'s and
  `KanbanWeb.WorkspaceMetricsPdfHTML`'s moduledocs forbid any `var(--…)`
  reference inside the PDF module sources and their embedded templates.
  This test enumerates those files and fails the build if a CSS
  custom-property reference slips in.

  The paths below are hardcoded, so a NEW PDF module or template directory
  is silently unguarded until it is added here. Adding a PDF surface means
  adding it to this test.
  """

  use ExUnit.Case, async: true

  @pdf_module_path "lib/kanban_web/controllers/metrics_pdf_html.ex"
  @pdf_templates_dir "lib/kanban_web/controllers/metrics_pdf_html"
  @workspace_pdf_module_path "lib/kanban_web/controllers/workspace_metrics_pdf_html.ex"
  @workspace_pdf_templates_dir "lib/kanban_web/controllers/workspace_metrics_pdf_html"

  describe "PDF fixed-palette policy" do
    test "metrics_pdf_html.ex contains no var(--…) references" do
      contents = File.read!(@pdf_module_path)
      refute_var_custom_property(contents, @pdf_module_path)
    end

    test "every metrics_pdf_html template contains no var(--…) references" do
      templates = @pdf_templates_dir |> Path.join("*.heex") |> Path.wildcard()

      assert templates != [],
             "expected PDF templates under #{@pdf_templates_dir}/*.heex, found none"

      for path <- templates do
        contents = File.read!(path)
        refute_var_custom_property(contents, path)
      end
    end

    test "workspace_metrics_pdf_html.ex contains no var(--…) references" do
      contents = File.read!(@workspace_pdf_module_path)
      refute_var_custom_property(contents, @workspace_pdf_module_path)
    end

    test "every workspace_metrics_pdf_html template contains no var(--…) references" do
      templates = @workspace_pdf_templates_dir |> Path.join("*.heex") |> Path.wildcard()

      assert templates != [],
             "expected PDF templates under #{@workspace_pdf_templates_dir}/*.heex, found none"

      for path <- templates do
        contents = File.read!(path)
        refute_var_custom_property(contents, path)
      end
    end
  end

  # Matches a real CSS custom-property reference: `var(--` followed by a
  # word character (e.g. `var(--color-base-100)`). The policy moduledoc
  # refers to the pattern using `var(--…)` with a unicode ellipsis, which
  # does not have a word char after `--` and is therefore not matched.
  @var_custom_property_pattern ~r/var\(--\w/

  defp refute_var_custom_property(contents, path) do
    offending_lines =
      contents
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.filter(fn {line, _idx} ->
        Regex.match?(@var_custom_property_pattern, line)
      end)

    assert offending_lines == [],
           "fixed-palette policy violated: #{path} contains a real CSS " <>
             "`var(--…)` reference (see moduledoc on KanbanWeb.MetricsPdfHTML).\n" <>
             "Offending lines:\n" <>
             Enum.map_join(offending_lines, "\n", fn {line, idx} ->
               "  #{idx}: #{String.trim(line)}"
             end)
  end
end
