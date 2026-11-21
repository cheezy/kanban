defmodule Mix.Tasks.Kanban.OgImages do
  @shortdoc "Generates the per-page link-preview images"

  @moduledoc """
  Writes one 1200x630 link-preview PNG for every how-to, `/docs` page and
  `/integrations` runtime listed by `KanbanWeb.OgImages.pages/0` (W2904), to
  `priv/static/images/og/<kind>/<slug>.png`.

  Each image is `priv/og/template.svg` filled with the page's title, converted
  with `rsvg-convert` from librsvg. Commit the PNGs it writes: pages read the
  committed files and nothing is generated at request time.

  ## Usage

      MIX_ENV=test mix kanban.og_images

  It takes no arguments. Rerun it after adding, renaming or retitling a how-to,
  a docs page or a runtime; `test/kanban_web/og_images_test.exs` fails until
  every page has its image. It needs `rsvg-convert` on the `PATH`
  (`brew install librsvg`, or `apt-get install librsvg2-bin`) and stops with a
  message naming librsvg when it is missing.
  """
  use Mix.Task

  alias KanbanWeb.OgImages

  @size ["--width", "1200", "--height", "630"]

  @impl Mix.Task
  def run([]) do
    Mix.Task.run("app.config")
    generate(Application.get_env(:kanban, __MODULE__, []))
  end

  def run(args) do
    Mix.raise(
      "mix kanban.og_images takes no arguments, got: #{Enum.join(args, " ")}. " <>
        "See mix help kanban.og_images."
    )
  end

  @doc """
  Writes every page's image and returns `:ok`.

  Options, all of which tests use to avoid needing librsvg:

    * `:output_dir` - where the kind directories go, default
      `priv/static/images/og` under the current directory
    * `:find_executable` - finds `rsvg-convert`, default
      `System.find_executable/1`
    * `:converter` - `(executable, svg, png_path) -> :ok | {:error, message}`,
      default `rsvg_convert/3`
    * `:pages` - the pages to write, default `KanbanWeb.OgImages.pages/0`
  """
  @spec generate(keyword()) :: :ok
  def generate(opts) do
    output_dir = Keyword.get_lazy(opts, :output_dir, &default_output_dir/0)
    pages = Keyword.get_lazy(opts, :pages, &OgImages.pages/0)
    executable = find_converter(opts)
    converter = Keyword.get(opts, :converter, &rsvg_convert/3)

    Enum.each(pages, &write(&1, executable, converter, output_dir))

    Mix.shell().info("Wrote #{length(pages)} images to #{output_dir} (#{counts(pages)})")
  end

  defp find_converter(opts) do
    find_executable = Keyword.get(opts, :find_executable, &System.find_executable/1)
    find_executable.("rsvg-convert") || missing_converter()
  end

  @doc false
  @spec rsvg_convert(String.t(), String.t(), String.t()) :: :ok | {:error, String.t()}
  def rsvg_convert(executable, svg, png_path) do
    svg_path = Path.join(System.tmp_dir!(), "stride-og-#{System.unique_integer([:positive])}.svg")

    try do
      # :exclusive refuses a path that already exists, a planted symlink included.
      File.write!(svg_path, svg, [:exclusive])
      args = @size ++ ["--format", "png", "--output", png_path, svg_path]

      case System.cmd(executable, args, stderr_to_stdout: true) do
        {_output, 0} -> :ok
        {output, status} -> {:error, "rsvg-convert exited #{status}: #{String.trim(output)}"}
      end
    after
      File.rm(svg_path)
    end
  end

  defp default_output_dir, do: Path.join(File.cwd!(), "priv/static/images/og")

  defp missing_converter do
    Mix.raise(
      "rsvg-convert not found. Install librsvg (brew install librsvg, or " <>
        "apt-get install librsvg2-bin) and rerun mix kanban.og_images."
    )
  end

  # The file name comes from the page's allow-listed path, never from input.
  defp write(page, executable, converter, output_dir) do
    png_path =
      page.path |> String.replace_prefix("/images/og/", "") |> then(&Path.join(output_dir, &1))

    png_path |> Path.dirname() |> File.mkdir_p!()

    case converter.(executable, OgImages.svg(page), png_path) do
      :ok -> :ok
      {:error, message} -> Mix.raise("Could not write #{page.path}: #{message}")
    end
  end

  defp counts(pages) do
    pages
    |> Enum.frequencies_by(& &1.kind)
    |> Enum.sort()
    |> Enum.map_join(", ", fn {kind, count} -> "#{count} #{kind}" end)
  end
end
