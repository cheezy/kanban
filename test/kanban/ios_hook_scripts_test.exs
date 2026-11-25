defmodule Kanban.IosHookScriptsTest do
  @moduledoc """
  Runs the two scripts of the iOS hook set (`.ios_dev.md`) in a throwaway git
  repository, with stubs for `mix`, `xcodegen` and `xcodebuild`, so what they
  run and when they fail is pinned.
  """
  use ExUnit.Case, async: true

  import Kanban.HookRepo

  @root Path.expand("../..", __DIR__)

  describe "test/ios_elixir_checks.sh" do
    setup :throwaway_repo
    setup :task_branch

    test "runs the tests that read mobile/ when only the iOS app changed", %{repo: repo} do
      write!(repo, "mobile/ios/View.swift")
      git!(repo, ["add", "-A"])
      git!(repo, ["commit", "--quiet", "-m", "task"])
      write!(repo, ".github/workflows/ios.yml")
      write!(repo, ".stride.md")

      assert {output, 0} = run_script(repo, "ios_elixir_checks.sh")
      assert output =~ "mix[test] test --warnings-as-errors test/kanban/mobile "
      refute output =~ "STUB_SUITE_RAN"
    end

    test "fails when one of those tests fails", %{repo: repo} do
      write!(repo, "mobile/ios/View.swift")

      assert {_, 1} = run_script(repo, "ios_elixir_checks.sh", [{"STUB_MIX_FAILS", "test"}])
    end

    test "runs the suite and the static gates when anything else changed", %{repo: repo} do
      write!(repo, "mobile/ios/View.swift")
      write!(repo, "lib/x.ex")

      assert {output, 0} = run_script(repo, "ios_elixir_checks.sh")
      assert output =~ "lib/x.ex is outside mobile/"

      assert [_, _, _, _] =
               Regex.run(
                 ~r/(STUB_SUITE_RAN).*(mix\[test\] format --check-formatted).*(mix\[test\] credo --strict)\nmix\[test\] sobelow --config/s,
                 output
               )
    end

    test "counts a deleted file, and a commit made on the branch", %{repo: repo} do
      git!(repo, ["rm", "--quiet", "lib/kept.ex"])
      git!(repo, ["commit", "--quiet", "-m", "task"])

      assert {output, 0} = run_script(repo, "ios_elixir_checks.sh")
      assert output =~ "lib/kept.ex is outside mobile/"
    end

    test "counts a file moved into mobile/ from outside it", %{repo: repo} do
      repo |> Path.join("mobile") |> File.mkdir_p!()
      git!(repo, ["mv", "lib/kept.ex", "mobile/kept.ex"])
      git!(repo, ["commit", "--quiet", "-m", "task"])

      assert {output, 0} = run_script(repo, "ios_elixir_checks.sh")
      assert output =~ "STUB_SUITE_RAN"
    end

    test "runs the suite when the branch's base cannot be found", %{repo: repo} do
      git!(repo, ["branch", "-D", "main"])
      write!(repo, "mobile/ios/View.swift")

      assert {output, 0} = run_script(repo, "ios_elixir_checks.sh")
      assert output =~ "STUB_SUITE_RAN"
    end

    test "fails when the suite or any static gate fails", %{repo: repo} do
      write!(repo, "lib/x.ex")

      assert {_, 1} = run_script(repo, "ios_elixir_checks.sh", [{"STUB_EXIT", "1"}])

      for gate <- ~w(format credo sobelow) do
        assert {_, 1} = run_script(repo, "ios_elixir_checks.sh", [{"STUB_MIX_FAILS", gate}])
      end
    end

    test "lists every test that names a mobile/ path or ios.yml" do
      script = @root |> Path.join("test/ios_elixir_checks.sh") |> File.read!()
      [_, list] = Regex.run(~r/^guards=\(\n(.*?)^\)/ms, script)
      guards = String.split(list)

      for guard <- guards do
        assert @root |> Path.join(guard) |> File.exists?(), "#{guard} does not exist"
      end

      missing =
        for path <- @root |> Path.join("test/**/*_test.exs") |> Path.wildcard(),
            File.read!(path) =~ ~r{mobile/(ios|android|shared)/|workflows/ios\.yml},
            relative = Path.relative_to(path, @root),
            not Enum.any?(guards, &String.starts_with?(relative, &1)),
            do: relative

      assert missing == []
    end
  end

  describe "test/ios_test.sh" do
    setup :throwaway_repo
    setup :task_branch

    @passed "Test run with 12 tests in 3 suites passed after 0.1 seconds.\n** TEST SUCCEEDED **"

    test "generates the project and runs the whole scheme on an iPhone 17", %{repo: repo} do
      assert {output, 0} = run_script(repo, "ios_test.sh", [{"STUB_XCODE", @passed}])

      assert calls(repo) == """
             xcodegen generate --quiet --spec mobile/ios/project.yml
             xcodebuild test -project mobile/ios/Stride.xcodeproj -scheme Stride -skipPackagePluginValidation -destination platform=iOS Simulator,name=iPhone 17
             """

      assert output =~ "Test run with 12 tests"
    end

    test "takes another destination from IOS_TEST_DESTINATION", %{repo: repo} do
      env = [{"STUB_XCODE", @passed}, {"IOS_TEST_DESTINATION", "id=ABC"}]

      assert {_, 0} = run_script(repo, "ios_test.sh", env)
      assert calls(repo) =~ "-destination id=ABC\n"
    end

    test "fails and names the failure when xcodebuild fails", %{repo: repo} do
      env = [{"STUB_XCODE", "View.swift:3:1: error: no such type"}, {"STUB_XCODE_EXIT", "65"}]

      assert {output, 1} = run_script(repo, "ios_test.sh", env)
      assert output =~ "error: no such type"
    end

    test "fails when no test ran", %{repo: repo} do
      for log <- ["** TEST SUCCEEDED **", "Test run with 0 tests in 0 suites passed"] do
        assert {output, 1} = run_script(repo, "ios_test.sh", [{"STUB_XCODE", log}])
        assert output =~ "ran no Swift Testing tests"
      end
    end

    test "fails before the build when the project cannot be generated", %{repo: repo} do
      assert {_, 1} = run_script(repo, "ios_test.sh", [{"STUB_XCODEGEN_EXIT", "1"}])
      refute calls(repo) =~ "xcodebuild"
    end
  end

  # The repo's real scripts on main, and a task branch checked out from it.
  # The stub tools sit in bin/, which git ignores.
  defp task_branch(%{repo: repo}) do
    for script <- ["ios_elixir_checks.sh", "ios_test.sh"] do
      copy!(repo, Path.join("test", script))
    end

    stub_tools!(repo)
    write!(repo, "lib/kept.ex")
    repo |> Path.join(".gitignore") |> File.write!("bin/\ncalls\n")
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "--quiet", "-m", "scripts"])
    git!(repo, ["checkout", "--quiet", "-b", "W1"])
    :ok
  end

  defp stub_tools!(repo) do
    stub!(repo, "mix", """
    echo "mix[$MIX_ENV] $*"
    [ "${STUB_MIX_FAILS:-}" != "$1" ]
    """)

    stub!(repo, "xcodegen", """
    echo "xcodegen $*" >> calls
    exit "${STUB_XCODEGEN_EXIT:-0}"
    """)

    stub!(repo, "xcodebuild", """
    echo "xcodebuild $*" >> calls
    printf '%b\\n' "$STUB_XCODE"
    exit "${STUB_XCODE_EXIT:-0}"
    """)
  end

  defp copy!(repo, file), do: @root |> Path.join(file) |> File.cp!(Path.join(repo, file))
  defp calls(repo), do: repo |> Path.join("calls") |> File.read!()

  defp stub!(repo, name, body) do
    path = Path.join([repo, "bin", name])
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, "#!/usr/bin/env bash\n" <> body)
    File.chmod!(path, 0o755)
  end

  defp write!(repo, path) do
    path = Path.join(repo, path)
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, "changed\n")
  end

  defp run_script(repo, script, env \\ []) do
    path = Path.join(repo, "bin") <> ":" <> System.fetch_env!("PATH")
    run_bash(repo, ["test/" <> script], [{"PATH", path}, {"MIX_ENV", nil} | env])
  end
end
