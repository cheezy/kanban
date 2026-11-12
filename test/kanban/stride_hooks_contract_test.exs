defmodule Kanban.StrideHooksContractTest do
  @moduledoc """
  Pins the quality gates in `.stride.md` (W2723).

  `## after_goal` no longer runs `mix precommit`: it runs the alias's legs
  without the suite through `mix do`, and runs the suite only when the tree
  it is about to push was not already tested green by `## after_doing`. So
  the leg list now lives in two places, and this test fails when they
  drift, or when a gate moves after the commit or the push it guards. It
  also keeps `.stride_dev.md`, the copy `stride_dev.sh` restores, in step.
  """
  use ExUnit.Case, async: true

  @stride_md Path.expand("../../.stride.md", __DIR__)
  @stride_dev_md Path.expand("../../.stride_dev.md", __DIR__)
  @suite_leg "test --warnings-as-errors"

  defp section(name, file \\ @stride_md) do
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
    # Runs the real lines from .stride.md against a stub
    # test/partitioned_test.sh, so the skip condition itself is pinned, not
    # just its wording.
    setup do
      repo = Path.join(System.tmp_dir!(), "stride-hooks-#{System.unique_integer([:positive])}")
      repo |> Path.join("test") |> File.mkdir_p!()
      on_exit(fn -> File.rm_rf!(repo) end)

      stub = """
      echo STUB_SUITE_RAN
      exit "${STUB_EXIT:-0}"
      """

      repo |> Path.join("test/partitioned_test.sh") |> File.write!(stub)

      git!(repo, ["init", "--quiet"])
      git!(repo, ["config", "user.name", "t"])
      git!(repo, ["config", "user.email", "t@t"])
      git!(repo, ["add", "-A"])
      git!(repo, ["commit", "--quiet", "-m", "init"])

      %{repo: repo}
    end

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

  defp run_line(repo, name, env \\ [], fragment \\ "stride-green-tree") do
    lines = section(name)
    line = Enum.at(lines, index_of(lines, fragment))
    System.cmd("bash", ["-c", line], cd: repo, env: env, stderr_to_stdout: true)
  end

  defp marker(repo), do: Path.join([repo, ".git", "stride-green-tree"])

  defp git!(repo, args) do
    {output, 0} = System.cmd("git", args, cd: repo, stderr_to_stdout: true)
    output
  end

  test ".stride_dev.md carries the same after_doing and after_goal as .stride.md" do
    # stride_dev.sh copies .stride_dev.md over .stride.md, so a gate that is
    # only in .stride.md is lost the next time the mode is switched.
    for name <- ["after_doing", "after_goal"] do
      assert section(name, @stride_dev_md) == section(name), "## #{name} differs"
    end
  end

  test "the precommit alias still carries the suite leg this file splits out" do
    assert @suite_leg in precommit_legs()
  end
end
