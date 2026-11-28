defmodule Kanban.IosHookScriptsTest do
  @moduledoc """
  Runs the script of the iOS hook set (`.ios_dev.md`) in a throwaway git
  repository, with a stub for `mix`, so what it runs and when it fails is
  pinned. `mix ios.test`, which the set also runs, has its own tests.
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

    test "adds the format check and credo on the string files when the app's strings changed",
         %{repo: repo} do
      write!(repo, "mobile/ios/View.swift")
      write!(repo, "lib/kanban/mobile/strings/msgids.ex")
      write!(repo, "priv/gettext/mobile.pot")
      write!(repo, "priv/gettext/de/LC_MESSAGES/mobile.po")
      write!(repo, "test/kanban/mobile/strings_test.exs")

      assert {output, 0} = run_script(repo, "ios_elixir_checks.sh")
      refute output =~ "STUB_SUITE_RAN"
      sources = "lib/kanban/mobile/strings/msgids.ex test/kanban/mobile/strings_test.exs"

      assert [_, _, _, _] =
               Regex.run(
                 ~r/(mix\[test\] test --warnings-as-errors test\/kanban\/mobile ).*(mix\[test\] format --check-formatted #{sources}\n).*(mix\[test\] credo --strict #{sources}\n)/s,
                 output
               )

      refute output =~ "sobelow"
    end

    test "fails when the format check or credo fails on the string files", %{repo: repo} do
      write!(repo, "lib/kanban/mobile/strings/msgids.ex")

      for gate <- ~w(test format credo) do
        assert {output, 1} = run_script(repo, "ios_elixir_checks.sh", [{"STUB_MIX_FAILS", gate}])
        refute output =~ "STUB_SUITE_RAN"
      end
    end

    test "runs only the tests when the string files changed are not Elixir", %{repo: repo} do
      write!(repo, "priv/gettext/fr/LC_MESSAGES/mobile.po")

      assert {output, 0} = run_script(repo, "ios_elixir_checks.sh")
      refute output =~ "format"
      refute output =~ "credo"
    end

    test "leaves a deleted string file out of the format check and credo", %{repo: repo} do
      git!(repo, ["checkout", "--quiet", "main"])
      write!(repo, "lib/kanban/mobile/strings/msgids.ex")
      git!(repo, ["add", "-A"])
      git!(repo, ["commit", "--quiet", "-m", "strings"])
      git!(repo, ["checkout", "--quiet", "-B", "W1"])
      git!(repo, ["rm", "--quiet", "lib/kanban/mobile/strings/msgids.ex"])
      write!(repo, "test/kanban/mobile/strings_test.exs")

      assert {output, 0} = run_script(repo, "ios_elixir_checks.sh")
      assert output =~ "format --check-formatted test/kanban/mobile/strings_test.exs\n"
      refute output =~ "msgids.ex"
    end

    test "runs the suite for the web's strings and the strings module's code", %{repo: repo} do
      for path <- ["priv/gettext/de/LC_MESSAGES/default.po", "lib/kanban/mobile/strings.ex"] do
        git!(repo, ["checkout", "--quiet", "--force", "W1"])
        git!(repo, ["clean", "--quiet", "-fd"])
        write!(repo, path)

        assert {output, 0} = run_script(repo, "ios_elixir_checks.sh")
        assert output =~ "#{path} is outside mobile/"
        assert output =~ "STUB_SUITE_RAN"
      end
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

  # The repo's real script on main, and a task branch checked out from it.
  # The stub mix sits in bin/, which git ignores.
  defp task_branch(%{repo: repo}) do
    copy!(repo, "test/ios_elixir_checks.sh")
    stub_mix!(repo)
    write!(repo, "lib/kept.ex")
    repo |> Path.join(".gitignore") |> File.write!("bin/\n")
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "--quiet", "-m", "script"])
    git!(repo, ["checkout", "--quiet", "-b", "W1"])
    :ok
  end

  defp stub_mix!(repo) do
    stub!(repo, "mix", """
    echo "mix[$MIX_ENV] $*"
    [ "${STUB_MIX_FAILS:-}" != "$1" ]
    """)
  end

  defp copy!(repo, file), do: @root |> Path.join(file) |> File.cp!(Path.join(repo, file))

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
