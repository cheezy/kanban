defmodule Mix.Tasks.Mobile.TokensTest do
  # async: false — swaps the process-wide Mix shell and changes the working
  # directory.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Kanban.Mobile.IosDesignSystem
  alias Kanban.Mobile.Tokens

  @moduletag :tmp_dir

  @task Mix.Tasks.Mobile.Tokens

  @css """
  .stride-marketing,
  .stride-screen {
    --bg: oklch(98% 0 0);
    --r-sm: 4px;
    --font-sans: 'Geist', ui-sans-serif, sans-serif;
    --font-mono: 'Geist Mono', ui-monospace, monospace;
    font-size: 13px;
    line-height: 1.45;
    letter-spacing: -0.005em;
  }

  :where([data-theme="dark"]) .stride-marketing,
  :where([data-theme="dark"]) .stride-screen {
    --bg: oklch(16% 0 0);
  }

  @media (max-width: 767px) {
    .stride-marketing,
    .stride-screen {
      font-size: 14.5px;
    }
  }
  """

  setup do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.IO)
    on_exit(fn -> Mix.shell(previous_shell) end)
    :ok
  end

  # Call run([]) only inside the tmp dir, and give generate/1 a :root in it:
  # elsewhere they write the repository's tokens.json and iOS files.
  test "generate/1 writes the render to the output path, creating its folder", %{tmp_dir: dir} do
    source = Path.join(dir, "app.css")
    output = Path.join([dir, "nested", "tokens.json"])
    opts = [source: source, output: output, root: dir]
    File.write!(source, @css)

    printed = capture_io(fn -> assert @task.generate(opts) == :ok end)

    assert printed =~ "Wrote #{output}"
    assert File.read!(output) == Tokens.render!(@css)

    for {path, content} <- @css |> Tokens.build!() |> IosDesignSystem.render!() do
      assert dir |> Path.join(path) |> File.read!() == content
    end

    first = File.read!(output)
    capture_io(fn -> @task.generate(opts) end)
    assert File.read!(output) == first
  end

  test "run/1 with no arguments writes the default paths relative to the working directory",
       %{tmp_dir: dir} do
    source = Path.join(dir, Tokens.source_path())
    source |> Path.dirname() |> File.mkdir_p!()
    File.write!(source, @css)

    File.cd!(dir, fn -> capture_io(fn -> assert @task.run([]) == :ok end) end)

    written = dir |> Path.join(Tokens.output_path()) |> File.read!()
    assert written == Tokens.render!(@css)
  end

  test "the task takes no arguments" do
    assert_raise Mix.Error, ~r/takes no arguments, got: --force/, fn -> @task.run(["--force"]) end
  end
end
