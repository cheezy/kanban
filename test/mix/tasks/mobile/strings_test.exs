defmodule Mix.Tasks.Mobile.StringsTest do
  # async: false — swaps the process-wide Mix shell and changes the working
  # directory.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Kanban.Mobile.Strings

  @moduletag :tmp_dir

  @task Mix.Tasks.Mobile.Strings
  @gettext Path.expand("../../../../priv/gettext", __DIR__)

  setup do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.IO)
    on_exit(fn -> Mix.shell(previous_shell) end)
    :ok
  end

  defp copy_domain!(gettext_dir) do
    File.mkdir_p!(gettext_dir)
    @gettext |> Path.join("mobile.pot") |> File.cp!(Path.join(gettext_dir, "mobile.pot"))

    for locale <- Strings.locales() do
      folder = Path.join([gettext_dir, locale, "LC_MESSAGES"])
      folder |> File.mkdir_p!()

      [@gettext, locale, "LC_MESSAGES", "mobile.po"]
      |> Path.join()
      |> File.cp!(Path.join(folder, "mobile.po"))
    end
  end

  defp read_all(dir) do
    dir |> File.ls!() |> Enum.sort() |> Enum.map(&(dir |> Path.join(&1) |> File.read!()))
  end

  # Call run([]) only inside the tmp dir: elsewhere it writes the
  # repository's mobile/shared/strings.
  test "generate/1 writes one JSON per locale, creating its folder", %{tmp_dir: dir} do
    source = Path.join(dir, "gettext")
    output = Path.join([dir, "nested", "strings"])
    copy_domain!(source)

    printed = capture_io(fn -> assert @task.generate(source: source, output: output) == :ok end)
    rendered = Strings.render!(source)

    for locale <- Strings.locales() do
      path = Path.join(output, locale <> ".json")
      assert printed =~ "Wrote #{path}"
      assert File.read!(path) == rendered[locale]
    end

    first = read_all(output)
    capture_io(fn -> @task.generate(source: source, output: output) end)
    second = read_all(output)
    assert second == first
  end

  test "run/1 with no arguments writes the default paths relative to the working directory",
       %{tmp_dir: dir} do
    dir |> Path.join(Strings.source_path()) |> copy_domain!()

    File.cd!(dir, fn -> capture_io(fn -> assert @task.run([]) == :ok end) end)

    rendered = dir |> Path.join(Strings.source_path()) |> Strings.render!()

    for locale <- Strings.locales() do
      written = dir |> Path.join(Strings.output_path(locale)) |> File.read!()
      assert written == rendered[locale]
    end
  end

  test "the task takes no arguments" do
    assert_raise Mix.Error, ~r/takes no arguments, got: --force/, fn -> @task.run(["--force"]) end
  end
end
