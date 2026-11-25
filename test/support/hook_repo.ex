defmodule Kanban.HookRepo do
  @moduledoc """
  Throwaway git repositories for the tests of the Stride hook sets, where a
  hook line or script can run without touching this checkout.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  # A git repo on main with a stub suite and a tracked .stride.md.
  def throwaway_repo(_context) do
    # The OS pid keeps two partitions of the suite, which are two VMs, apart.
    unique = "#{System.pid()}-#{System.unique_integer([:positive])}"
    repo = Path.join(System.tmp_dir!(), "stride-hooks-#{unique}")
    repo |> Path.join("test") |> File.mkdir_p!()
    on_exit(fn -> File.rm_rf!(repo) end)

    stub = """
    echo STUB_SUITE_RAN
    exit "${STUB_EXIT:-0}"
    """

    repo |> Path.join("test/partitioned_test.sh") |> File.write!(stub)
    repo |> Path.join(".stride.md") |> File.write!("the committed set\n")

    git!(repo, ["init", "--quiet", "--initial-branch", "main"])
    git!(repo, ["config", "user.name", "t"])
    git!(repo, ["config", "user.email", "t@t"])
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "--quiet", "-m", "init"])

    %{repo: repo}
  end

  def run_bash(repo, args, env) do
    System.cmd("bash", args, cd: repo, env: env, stderr_to_stdout: true)
  end

  def git!(repo, args) do
    {output, 0} = System.cmd("git", args, cd: repo, stderr_to_stdout: true)
    output
  end
end
