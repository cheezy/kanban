defmodule Kanban.StrideHooksContractTest do
  @moduledoc """
  Pins the quality gates in the Stride hook sets: `.stride_dev.md`, the
  default, and `.ios_dev.md`, the one for iOS work. `./stride_dev.sh` and
  `./ios_dev.sh` copy one of them over `.stride.md`, so the gates are read
  from the two sources and `.stride.md` must be one of them (W2723).

  `## after_goal` no longer runs `mix precommit`: it runs the alias's legs
  without the suite through `mix do`, and runs the suite only when the tree
  it is about to push was not already tested green by `## after_doing`. So
  the leg list now lives in two places, and this test fails when they
  drift, or when a gate moves after the commit or the push it guards.

  In iOS mode `.stride.md` is tracked and differs from HEAD, so the iOS set
  has to leave it out of its dirty checks and commits.
  `test/kanban/ios_hook_scripts_test.exs` tests the two scripts it runs.
  """
  use ExUnit.Case, async: true

  import Kanban.HookRepo

  @root Path.expand("../..", __DIR__)
  @stride_md Path.join(@root, ".stride.md")
  @stride_dev_md Path.join(@root, ".stride_dev.md")
  @ios_dev_md Path.join(@root, ".ios_dev.md")
  @suite_leg "test --warnings-as-errors"

  defp section(name, file \\ @stride_dev_md) do
    [_, rest] = file |> File.read!() |> String.split("## #{name}\n", parts: 2)
    [_, body] = String.split(rest, "```bash\n", parts: 2)
    [body, _] = String.split(body, "```", parts: 2)

    body
    |> String.split("\n", trim: true)
    |> Enum.reject(&String.starts_with?(&1, "#"))
  end

  defp index_of(lines, fragment) do
    Enum.find_index(lines, &String.contains?(&1, fragment)) ||
      flunk("no line containing #{inspect(fragment)} in #{inspect(lines)}")
  end

  defp precommit_legs, do: Mix.Project.config()[:aliases][:precommit]

  describe "## after_goal" do
    test "runs every precommit leg except the suite, in the alias's order" do
      [mix_do] = "after_goal" |> section() |> Enum.filter(&String.contains?(&1, "mix do "))
      [_, legs] = String.split(mix_do, "mix do ", parts: 2)

      assert legs |> String.split(" + ") |> Enum.map(&String.trim/1) ==
               List.delete(precommit_legs(), @suite_leg)
    end

    test "runs the static legs and the suite check after the rebase and before the push" do
      lines = section("after_goal")
      push = index_of(lines, "git push origin main")

      assert index_of(lines, "git rebase origin/main") < index_of(lines, "mix do ")
      assert index_of(lines, "mix do ") < push
      assert index_of(lines, "stride-green-tree") < push
    end

    test "re-runs the suite, and blocks the push, when the tree was not tested green" do
      lines = section("after_goal")
      line = Enum.at(lines, index_of(lines, "stride-green-tree"))

      assert line =~ "else bash test/partitioned_test.sh --warnings-as-errors || {"
      assert line =~ "exit 1"
    end
  end

  describe "## after_doing" do
    test "runs the suite and every static gate before the task commit" do
      lines = section("after_doing")
      commit = index_of(lines, "git commit")

      for gate <- [
            "bash test/partitioned_test.sh --warnings-as-errors",
            "mix format --check-formatted",
            "mix credo --strict",
            "mix sobelow --config"
          ] do
        assert index_of(lines, gate) < commit, "#{gate} must run before the commit"
      end
    end

    test "records the green tree only after the commit, as its last line" do
      lines = section("after_doing")

      assert index_of(lines, "stride-green-tree") == length(lines) - 1
      assert index_of(lines, "git commit") < index_of(lines, "stride-green-tree")
    end
  end

  describe "the commit and green-tree lines, run in a throwaway git repo" do
    # Runs the real lines from .stride_dev.md against a stub
    # test/partitioned_test.sh, so the skip condition itself is pinned, not
    # just its wording.
    setup :throwaway_repo

    test "after_doing records the tree only when the working tree is clean", %{repo: repo} do
      assert {_, 0} = run_line(repo, "after_doing")
      assert repo |> marker() |> File.read!() == git!(repo, ["rev-parse", "HEAD^{tree}"])

      repo |> Path.join("untracked.txt") |> File.write!("x")
      assert {_, 0} = run_line(repo, "after_doing")
      refute repo |> marker() |> File.exists?()
    end

    test "after_goal skips the suite only for a clean tree the marker names", %{repo: repo} do
      run_line(repo, "after_doing")
      {output, 0} = run_line(repo, "after_goal", [{"STUB_EXIT", "1"}])

      assert output =~ "already passed on tree"
      refute output =~ "STUB_SUITE_RAN"
    end

    test "after_goal runs the suite when there is no marker", %{repo: repo} do
      assert {output, 0} = run_line(repo, "after_goal")
      assert output =~ "STUB_SUITE_RAN"
    end

    test "after_goal runs the suite when the marker names another tree", %{repo: repo} do
      repo |> marker() |> File.write!("0000000000000000000000000000000000000000\n")

      assert {output, 0} = run_line(repo, "after_goal")
      assert output =~ "STUB_SUITE_RAN"
    end

    test "after_goal refuses to push a dirty tree, even with a matching marker", %{repo: repo} do
      run_line(repo, "after_doing")
      repo |> Path.join("untracked.txt") |> File.write!("x")

      assert {output, 1} = run_line(repo, "after_goal")
      assert output =~ "not pushing"
      refute output =~ "STUB_SUITE_RAN"
    end

    test "after_goal refuses to push a tracked file changed after the commit", %{repo: repo} do
      repo |> Path.join("test/partitioned_test.sh") |> File.write!("exit 0\n")

      assert {output, 1} = run_line(repo, "after_goal")
      assert output =~ "not pushing"
    end

    test "untracked files count as dirty even when git status hides them", %{repo: repo} do
      git!(repo, ["config", "status.showUntrackedFiles", "no"])
      repo |> Path.join("untracked.txt") |> File.write!("x")

      assert {_, 0} = run_line(repo, "after_doing")
      refute repo |> marker() |> File.exists?()
      assert {_, 1} = run_line(repo, "after_goal")
    end

    test "after_doing commits a task that only adds new files", %{repo: repo} do
      repo |> Path.join("new_module.ex") |> File.write!("x")
      env = [{"TASK_IDENTIFIER", "W1"}, {"TASK_TITLE", "t"}]

      assert {_, 0} = run_line(repo, "after_doing", env, "git commit")
      assert git!(repo, ["log", "-1", "--format=%s"]) == "Completed task W1: t\n"
      assert git!(repo, ["status", "--porcelain", "--untracked-files=all"]) == ""
    end

    test "after_doing makes no commit when nothing changed", %{repo: repo} do
      assert {_, 0} = run_line(repo, "after_doing", [], "git commit")
      assert git!(repo, ["rev-list", "--count", "HEAD"]) == "1\n"
    end

    test "after_goal exits non-zero, before the push, when the re-run suite fails",
         %{repo: repo} do
      assert {output, 1} = run_line(repo, "after_goal", [{"STUB_EXIT", "1"}])
      assert output =~ "STUB_SUITE_RAN"
      assert output =~ "not pushing"
    end
  end

  describe "the iOS hook set" do
    test "runs the iOS tests and the Elixir checks before the task commit" do
      lines = section("after_doing", @ios_dev_md)
      commit = index_of(lines, "git commit")

      assert index_of(lines, "bash test/ios_test.sh") < commit
      assert index_of(lines, "bash test/ios_elixir_checks.sh") < commit
    end

    test "runs the default set's static legs and suite check before the push" do
      lines = section("after_goal", @ios_dev_md)
      legs = Enum.at(lines, index_of(lines, "mix do "))
      suite = Enum.at(lines, index_of(lines, "stride-green-tree"))

      assert legs in section("after_goal")
      assert suite =~ "else bash test/partitioned_test.sh --warnings-as-errors || {"
      assert List.last(lines) == "git push origin main"
      assert index_of(lines, "git rebase") < index_of(lines, "mix do ")
    end

    test "keeps the dependency and security checks before a claim" do
      gates = Enum.filter(section("before_doing"), &String.starts_with?(&1, "mix "))

      assert length(gates) == 5
      assert Enum.filter(section("before_doing", @ios_dev_md), &(&1 in gates)) == gates
    end

    test "merges and reviews as the default set does" do
      for name <- ["before_review", "after_review"] do
        assert section(name, @ios_dev_md) == section(name)
      end
    end

    test "keeps the copied hooks through a pull or a rebase" do
      for {name, rebase} <- [{"before_doing", "git pull"}, {"after_goal", "git rebase"}] do
        lines = section(name, @ios_dev_md)
        index = index_of(lines, rebase)

        assert Enum.at(lines, index) =~ "--autostash"
        assert Enum.at(lines, index + 1) == "git reset --quiet -- .stride.md && ./ios_dev.sh"
      end
    end
  end

  describe "the iOS hook set's lines, run in a throwaway git repo" do
    setup :throwaway_repo

    setup %{repo: repo} do
      # As ./ios_dev.sh leaves it: tracked, and different from HEAD.
      repo |> Path.join(".stride.md") |> File.write!("the iOS set\n")
      :ok
    end

    test "the claim check passes when only .stride.md changed", %{repo: repo} do
      assert {_, 0} = run_ios(repo, "before_doing", "Working tree is dirty")
    end

    test "the claim check stops on any other change, staged or not", %{repo: repo} do
      repo |> Path.join("test/partitioned_test.sh") |> File.write!("exit 0\n")
      assert {output, 1} = run_ios(repo, "before_doing", "Working tree is dirty")
      assert output =~ "dirty"

      git!(repo, ["add", "test/partitioned_test.sh"])
      assert {_, 1} = run_ios(repo, "before_doing", "Working tree is dirty")
    end

    test "the task commit takes new files and leaves .stride.md out", %{repo: repo} do
      repo |> Path.join("View.swift") |> File.write!("x")
      env = [{"TASK_IDENTIFIER", "W1"}, {"TASK_TITLE", "t"}]

      assert {_, 0} = run_ios(repo, "after_doing", "git commit", env)
      assert git!(repo, ["show", "--name-only", "--format=%s"]) =~ "Completed task W1: t"

      assert git!(repo, ["diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD"]) ==
               "View.swift\n"

      assert git!(repo, ["status", "--porcelain"]) == " M .stride.md\n"
    end

    test "the task commit is skipped when only .stride.md changed", %{repo: repo} do
      assert {_, 0} = run_ios(repo, "after_doing", "git commit")
      assert git!(repo, ["rev-list", "--count", "HEAD"]) == "1\n"
    end

    test "after_goal runs the suite before the push, with .stride.md changed", %{repo: repo} do
      assert {output, 0} = run_ios(repo, "after_goal", "stride-green-tree")
      assert output =~ "STUB_SUITE_RAN"

      assert {output, 1} = run_ios(repo, "after_goal", "stride-green-tree", [{"STUB_EXIT", "1"}])
      assert output =~ "not pushing"
    end

    test "after_goal refuses to push any other change", %{repo: repo} do
      repo |> Path.join("untracked.txt") |> File.write!("x")

      assert {output, 1} = run_ios(repo, "after_goal", "stride-green-tree")
      assert output =~ "not pushing"
      refute output =~ "STUB_SUITE_RAN"
    end

    test "./ios_dev.sh and ./stride_dev.sh copy their set over .stride.md", %{repo: repo} do
      for {script, set} <- [{"ios_dev.sh", ".ios_dev.md"}, {"stride_dev.sh", ".stride_dev.md"}] do
        for file <- [script, set], do: File.cp!(Path.join(@root, file), Path.join(repo, file))

        assert {"", 0} = run_bash(repo, ["-c", "./#{script}"], [])
        assert File.read!(Path.join(repo, ".stride.md")) == File.read!(Path.join(@root, set))
      end
    end
  end

  defp run_line(repo, name, env \\ [], fragment \\ "stride-green-tree") do
    run_bash(repo, ["-c", line(name, fragment, @stride_dev_md)], env)
  end

  defp run_ios(repo, name, fragment, env \\ []) do
    run_bash(repo, ["-c", line(name, fragment, @ios_dev_md)], env)
  end

  defp line(name, fragment, file) do
    lines = section(name, file)
    Enum.at(lines, index_of(lines, fragment))
  end

  defp marker(repo), do: Path.join([repo, ".git", "stride-green-tree"])

  test ".stride.md is the Stride hook set or the iOS one" do
    # ./stride_dev.sh and ./ios_dev.sh copy over .stride.md, so a gate that is
    # only in .stride.md is lost the next time the mode is switched.
    assert File.read!(@stride_md) in [File.read!(@stride_dev_md), File.read!(@ios_dev_md)]
  end

  test "the precommit alias still carries the suite leg this file splits out" do
    assert @suite_leg in precommit_legs()
  end
end
