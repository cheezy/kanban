defmodule Mix.Tasks.Kanban.OgImagesTest do
  # async: false — swaps the process-wide Mix shell and the task's app env.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias KanbanWeb.OgImages

  @moduletag :tmp_dir

  @task Mix.Tasks.Kanban.OgImages

  setup do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.IO)
    on_exit(fn -> Mix.shell(previous_shell) end)
    :ok
  end

  defp found(_name), do: "/fake/rsvg-convert"

  defp recording_converter(test_pid) do
    fn executable, svg, png_path ->
      File.write!(png_path, "png")
      send(test_pid, {:converted, executable, svg, png_path})
      :ok
    end
  end

  defp fake_rsvg(dir, body) do
    path = Path.join(dir, "rsvg-convert")
    File.write!(path, "#!/bin/sh\n" <> body)
    File.chmod!(path, 0o755)
    path
  end

  describe "generate/1" do
    test "the task writes one PNG per page through the converter it is given", %{tmp_dir: dir} do
      output =
        capture_io(fn ->
          assert @task.generate(
                   output_dir: dir,
                   find_executable: &found/1,
                   converter: recording_converter(self())
                 ) == :ok
        end)

      pages = OgImages.pages()
      assert output =~ "Wrote #{length(pages)} images"

      for page <- pages do
        png_path = Path.join(dir, String.replace_prefix(page.path, "/images/og/", ""))
        assert File.read!(png_path) == "png"
        assert_received {:converted, "/fake/rsvg-convert", svg, ^png_path}
        assert svg == OgImages.svg(page)
      end

      assert File.ls!(dir) |> Enum.sort() == ["docs", "how-to", "integrations"]
    end

    test "the task stops with a clear message naming librsvg when rsvg-convert is missing",
         %{tmp_dir: dir} do
      assert_raise Mix.Error, ~r/rsvg-convert not found\. Install librsvg/, fn ->
        @task.generate(output_dir: dir, find_executable: fn _ -> nil end)
      end

      assert File.ls!(dir) == []
    end

    test "a converter error stops the task and names the page", %{tmp_dir: dir} do
      [page | _] = OgImages.pages()

      assert_raise Mix.Error, ~r/Could not write #{Regex.escape(page.path)}: boom/, fn ->
        @task.generate(
          output_dir: dir,
          pages: [page],
          find_executable: &found/1,
          converter: fn _exe, _svg, _png -> {:error, "boom"} end
        )
      end
    end
  end

  describe "rsvg_convert/3" do
    test "calls the executable with an argument list and writes the PNG", %{tmp_dir: dir} do
      exe = fake_rsvg(dir, ~s(echo "$@" > "#{dir}/args"\nshift 7\ncp "$2" "$1"\n))
      png_path = Path.join(dir, "out.png")

      assert @task.rsvg_convert(exe, "<svg/>", png_path) == :ok
      assert File.read!(png_path) == "<svg/>"

      args = dir |> Path.join("args") |> File.read!() |> String.split()

      assert Enum.take(args, 8) ==
               ~w(--width 1200 --height 630 --format png --output) ++ [png_path]

      refute args |> List.last() |> File.exists?()
    end

    test "returns the exit status and output when the converter fails", %{tmp_dir: dir} do
      exe = fake_rsvg(dir, "echo broken svg\nexit 3\n")

      assert @task.rsvg_convert(exe, "<svg/>", Path.join(dir, "out.png")) ==
               {:error, "rsvg-convert exited 3: broken svg"}
    end
  end

  describe "run/1" do
    test "reads its options from the app env", %{tmp_dir: dir} do
      [page | _] = OgImages.pages()

      Application.put_env(:kanban, @task,
        output_dir: dir,
        pages: [page],
        find_executable: &found/1,
        converter: recording_converter(self())
      )

      on_exit(fn -> Application.delete_env(:kanban, @task) end)

      output = capture_io(fn -> assert @task.run([]) == :ok end)
      assert output =~ "Wrote 1 images to #{dir}"
      assert_received {:converted, _exe, _svg, _png}
    end

    test "refuses arguments" do
      assert_raise Mix.Error, ~r/takes no arguments, got: --force/, fn ->
        @task.run(["--force"])
      end
    end
  end
end
