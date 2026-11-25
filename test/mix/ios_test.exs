defmodule Mix.IosTest do
  # async: false — changes the environment.
  use ExUnit.Case, async: false

  import Kanban.IosTools

  alias Mix.Ios

  @moduletag :tmp_dir

  describe "default_simulator/0" do
    setup do
      previous = System.get_env("IOS_SIMULATOR")
      on_exit(fn -> System.put_env([{"IOS_SIMULATOR", previous}]) end)
      System.delete_env("IOS_SIMULATOR")
    end

    test "is an iPhone 17 when IOS_SIMULATOR is unset or empty" do
      assert Ios.default_simulator() == "iPhone 17"
      System.put_env("IOS_SIMULATOR", "")
      assert Ios.default_simulator() == "iPhone 17"
    end

    test "is what IOS_SIMULATOR names" do
      System.put_env("IOS_SIMULATOR", "iPad (A16)")
      assert Ios.default_simulator() == "iPad (A16)"
    end
  end

  test "split_args/1 parts the task's arguments from xcodebuild's at the first --" do
    assert Ios.split_args([]) == {[], []}
    assert Ios.split_args(["a", "--b"]) == {["a", "--b"], []}
    assert Ios.split_args(["a", "--", "-x", "--", "y"]) == {["a"], ["-x", "--", "y"]}
  end

  test "find_executable/1 finds a tool on the PATH, and is nil for one that is nowhere" do
    assert Ios.find_executable("sh") == System.find_executable("sh")
    missing = "no-such-tool-#{System.unique_integer([:positive])}"
    assert Ios.find_executable(missing) == nil
  end

  describe "generate_project!/1" do
    test "runs xcodegen on project.yml", %{tmp_dir: dir} do
      opts = stub_tools!(dir)

      assert Ios.generate_project!(opts) == :ok
      assert calls(dir) == ["xcodegen generate --quiet --spec mobile/ios/project.yml"]
    end

    test "raises with xcodegen's output when it fails", %{tmp_dir: dir} do
      opts = stub_tools!(dir, %{"xcodegen" => "echo 'bad spec' >&2; exit 1"})
      assert_raise Mix.Error, ~r/bad spec/, fn -> Ios.generate_project!(opts) end
    end

    test "raises saying how to install xcodegen when it is missing", %{tmp_dir: dir} do
      opts = stub_tools!(dir, %{"xcodegen" => nil})

      assert_raise Mix.Error, ~r/xcodegen is not installed.*brew install xcodegen/, fn ->
        Ios.generate_project!(opts)
      end
    end
  end

  test "xcodebuild_args/3 puts the scheme and destination before the extra arguments" do
    assert Ios.xcodebuild_args(["test"], "id=1", ["-x"]) ==
             ~w(test -project mobile/ios/Stride.xcodeproj -scheme Stride) ++
               ~w(-skipPackagePluginValidation -destination id=1 -x)
  end

  describe "capture/3" do
    test "returns the output and the status, with or without errors", %{tmp_dir: dir} do
      opts = stub_tools!(dir, %{"xcrun" => "echo out; echo err >&2; exit 3"})

      assert Ios.capture("xcrun", ["a b"], opts) == {"out\nerr\n", 3}
      assert Ios.capture("xcrun", ["a b"], [stderr: :discard] ++ opts) == {"out\n", 3}
      assert calls(dir) == ["xcrun a b", "xcrun a b"]
    end

    test "raises when the tool is missing", %{tmp_dir: dir} do
      opts = stub_tools!(dir, %{"xcrun" => nil})
      assert_raise Mix.Error, ~r/xcrun is not installed/, fn -> Ios.capture("xcrun", [], opts) end
    end
  end

  describe "stream/5" do
    test "folds each line, errors included, and returns the status", %{tmp_dir: dir} do
      body = ~S(printf 'one\n'; printf 'two\n' >&2; printf 'no newline'; exit 65)
      opts = stub_tools!(dir, %{"xcodebuild" => body})

      assert {["no newline", "two", "one"], 65} =
               Ios.stream("xcodebuild", ["a b", "$c"], [], &[&1 | &2], opts)

      assert calls(dir) == ["xcodebuild a b $c"]
    end

    test "joins a line that comes in pieces and replaces invalid UTF-8", %{tmp_dir: dir} do
      body = ~S[printf 'on\342'; sleep 0.2; printf '\234\224e\n'; printf '\377\n']
      opts = stub_tools!(dir, %{"xcodebuild" => body})

      assert Ios.stream("xcodebuild", [], [], &[&1 | &2], opts) == {["\uFFFD", "on✔e"], 0}
    end

    test "runs the tool in the root folder", %{tmp_dir: dir} do
      opts = stub_tools!(dir, %{"xcodebuild" => "pwd -P"})

      assert {[pwd], 0} = Ios.stream("xcodebuild", [], [], &[&1 | &2], opts)
      assert Path.basename(pwd) == Path.basename(dir)
    end

    test "stops the tool when the process that reads it ends", %{tmp_dir: dir} do
      opts = stub_tools!(dir, %{"xcodebuild" => "echo $$; exec sleep 60"})
      test = self()

      {reader, monitor} =
        spawn_monitor(fn -> Ios.stream("xcodebuild", [], nil, &send(test, {&1, &2}), opts) end)

      assert_receive {os_pid, nil}, 5_000
      assert alive?(os_pid)

      Process.exit(reader, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^reader, :killed}
      assert stopped?(os_pid, 100)
    end
  end

  defp alive?(os_pid) do
    {_, status} = System.cmd("kill", ["-0", os_pid], stderr_to_stdout: true)
    status == 0
  end

  # The shell that stops it runs beside this VM, so there is no message to await.
  defp stopped?(_os_pid, 0), do: false

  defp stopped?(os_pid, tries) do
    if alive?(os_pid) do
      receive do
      after
        50 -> stopped?(os_pid, tries - 1)
      end
    else
      true
    end
  end
end
