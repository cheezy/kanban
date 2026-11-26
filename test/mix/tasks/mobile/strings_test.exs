defmodule Mix.Tasks.Mobile.StringsTest do
  # async: false — swaps the process-wide Mix shell and changes the working
  # directory.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Kanban.Mobile.StringCatalog
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

  # Call run([]) only inside the tmp dir, and generate/1 only with every path:
  # otherwise they write the repository's own files.
  test "generate/1 writes one JSON per locale and the catalog, creating their folders",
       %{tmp_dir: dir} do
    source = Path.join(dir, "gettext")
    output = Path.join([dir, "nested", "strings"])
    catalog = Path.join([dir, "resources", "Localizable.xcstrings"])
    opts = [source: source, output: output, catalog: catalog]
    copy_domain!(source)

    printed = capture_io(fn -> assert @task.generate(opts) == :ok end)
    rendered = Strings.render!(source)

    assert printed =~ "Wrote #{catalog}"
    assert File.read!(catalog) == source |> Strings.build!() |> StringCatalog.render()

    for locale <- Strings.locales() do
      path = Path.join(output, locale <> ".json")
      assert printed =~ "Wrote #{path}"
      assert File.read!(path) == rendered[locale]
    end

    first = [File.read!(catalog) | read_all(output)]
    capture_io(fn -> @task.generate(opts) end)
    second = [File.read!(catalog) | read_all(output)]
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

    assert dir |> Path.join(StringCatalog.output_path()) |> File.read!() ==
             dir
             |> Path.join(Strings.source_path())
             |> Strings.build!()
             |> StringCatalog.render()
  end

  test "a broken domain writes nothing", %{tmp_dir: dir} do
    source = Path.join(dir, "gettext")
    output = Path.join(dir, "strings")
    catalog = Path.join(dir, "Localizable.xcstrings")
    copy_domain!(source)
    [source, "zh", "LC_MESSAGES", "mobile.po"] |> Path.join() |> File.rm!()

    assert_raise ArgumentError, ~r/zh/, fn ->
      @task.generate(source: source, output: output, catalog: catalog)
    end

    refute File.exists?(output)
    refute File.exists?(catalog)
  end

  test "the task takes no arguments" do
    assert_raise Mix.Error, ~r/takes no arguments, got: --force/, fn -> @task.run(["--force"]) end
  end
end
