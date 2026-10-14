defmodule Kanban.ChromeWatchdogTest do
  @moduledoc """
  Pins Kanban.ChromeWatchdog and priv/chrome/chrome_watchdog.sh, which stop
  ChromicPDF's Chrome once the VM that launched it is gone.

  The script tests run the real script with a fake Chrome: a shell script
  that ignores SIGTERM and never exits on its own, which is the worst case an
  orphaned Chrome presents. A `sleep` OS process stands in for the VM, so a
  test can end it without stopping this VM. Every signal goes to a process
  the test started itself.
  """
  use ExUnit.Case, async: true

  alias Kanban.ChromeWatchdog

  @moduletag :tmp_dir

  @opts [
    no_sandbox: true,
    chrome_args: "--disable-dev-shm-usage --disable-gpu",
    chrome_executable: "/opt/chrome/chrome"
  ]

  describe "wrap/4" do
    test "on macOS runs the real Chrome through the watchdog script with this VM's pid" do
      wrapped = ChromeWatchdog.wrap(@opts, {:unix, :darwin}, "4242")

      assert wrapped[:chrome_executable] == ChromeWatchdog.script_path()
      assert wrapped[:no_sandbox] == true

      assert wrapped[:chrome_args] ==
               "--disable-dev-shm-usage --disable-gpu " <>
                 "--kanban-chrome='/opt/chrome/chrome' --kanban-watch-pid=4242"
    end

    test "defaults the VM pid to this VM's OS pid" do
      wrapped = ChromeWatchdog.wrap(@opts, {:unix, :darwin})

      assert wrapped[:chrome_args] =~ "--kanban-watch-pid=#{System.pid()}"
    end

    test "quotes a Chrome path with spaces and quotes so the shell passes it as one argument",
         %{tmp_dir: tmp_dir} do
      chrome = Path.join(tmp_dir, "it's Google Chrome")
      opts = Keyword.put(@opts, :chrome_executable, chrome)

      args = ChromeWatchdog.wrap(opts, {:unix, :darwin}, "7")[:chrome_args]
      {printed, 0} = System.cmd("sh", ["-c", "printf '%s\\n' " <> args])

      assert String.split(printed, "\n", trim: true) == [
               "--disable-dev-shm-usage",
               "--disable-gpu",
               "--kanban-chrome=" <> chrome,
               "--kanban-watch-pid=7"
             ]
    end

    test "adds the watchdog arguments when there are no chrome_args yet" do
      opts = Keyword.delete(@opts, :chrome_args)

      assert ChromeWatchdog.wrap(opts, {:unix, :darwin}, "9")[:chrome_args] ==
               "--kanban-chrome='/opt/chrome/chrome' --kanban-watch-pid=9"
    end

    test "leaves the options unchanged on any OS other than macOS" do
      assert ChromeWatchdog.wrap(@opts, {:unix, :linux}, "1") == @opts
      assert ChromeWatchdog.wrap(@opts, {:win32, :nt}, "1") == @opts
    end

    test "leaves the options unchanged on macOS when no Chrome can be found" do
      opts = Keyword.delete(@opts, :chrome_executable)

      assert ChromeWatchdog.wrap(opts, {:unix, :darwin}, "1", ["/no/such/chrome"]) == opts
    end
  end

  describe "chrome_path/2" do
    test "prefers the configured executable" do
      assert ChromeWatchdog.chrome_path(@opts, ["/bin/sh"]) == "/opt/chrome/chrome"
    end

    test "falls back to the first candidate found on this machine, else nil" do
      assert ChromeWatchdog.chrome_path([], ["/no/such/chrome", "/bin/sh"]) == "/bin/sh"
      assert ChromeWatchdog.chrome_path([], ["/no/such/chrome"]) == nil
      assert ChromeWatchdog.chrome_path([], []) == nil
    end
  end

  describe "script_path/0" do
    test "is the executable script in the app's priv directory" do
      path = ChromeWatchdog.script_path()

      assert String.ends_with?(path, "/priv/chrome/chrome_watchdog.sh")
      assert %File.Stat{mode: mode} = File.stat!(path)
      assert Bitwise.band(mode, 0o111) != 0
    end
  end

  describe "chrome_watchdog.sh" do
    test "without a watch pid it runs Chrome directly and passes its arguments through" do
      assert {"hello world\n", 0} = run_script(["--kanban-chrome=/bin/echo", "hello", "world"])
    end

    test "refuses to start without --kanban-chrome or with a non-numeric watch pid" do
      assert {"chrome_watchdog.sh: --kanban-chrome=PATH is required\n", 64} =
               run_script(["--headless"])

      assert {"chrome_watchdog.sh: --kanban-watch-pid must be a number\n", 64} =
               run_script(["--kanban-chrome=/bin/echo", "--kanban-watch-pid=1;rm"])
    end

    test "exits with Chrome's exit status" do
      args = ["--kanban-chrome=/bin/sh", "-c", "exit 3", "--kanban-watch-pid=#{System.pid()}"]

      assert {_output, 3} = run_script(args)
    end

    test "hands Chrome its arguments without the watchdog's own", %{tmp_dir: tmp_dir} do
      fake = start_fake_chrome(tmp_dir, ["--headless", "two words"], System.pid())

      assert File.read!(fake.args_file) == "--headless\ntwo words\n"
      stop_script(fake)
    end

    test "keeps Chrome running while the watched VM is alive", %{tmp_dir: tmp_dir} do
      fake = start_fake_chrome(tmp_dir, [], System.pid())

      Process.sleep(2_500)
      assert os_process_alive?(fake.chrome_pid)
      stop_script(fake)
    end

    test "stops a Chrome that ignores SIGTERM once the watched VM is gone", %{tmp_dir: tmp_dir} do
      vm_pid = start_stand_in_vm()
      fake = start_fake_chrome(tmp_dir, [], vm_pid)
      assert os_process_alive?(fake.chrome_pid)

      kill(vm_pid)

      assert_eventually(fn -> not os_process_alive?(fake.chrome_pid) end)
      # Chrome was SIGKILLed, and the script exits with its status.
      assert_receive {_port, {:exit_status, 137}}, 5_000
    end

    test "stops Chrome when the script itself is sent SIGTERM", %{tmp_dir: tmp_dir} do
      fake = start_fake_chrome(tmp_dir, [], System.pid())

      kill(fake.script_pid)

      assert_eventually(fn -> not os_process_alive?(fake.chrome_pid) end)
      assert_receive {_port, {:exit_status, 137}}, 5_000
    end
  end

  defp run_script(args) do
    System.cmd("sh", [ChromeWatchdog.script_path() | args], stderr_to_stdout: true)
  end

  # A fake Chrome that records its pid and arguments, ignores SIGTERM, and
  # never exits on its own. The watchdog runs it with `watch_pid` as the VM.
  defp start_fake_chrome(tmp_dir, chrome_args, watch_pid) do
    pid_file = Path.join(tmp_dir, "chrome.pid")
    args_file = Path.join(tmp_dir, "chrome.args")

    args =
      ["--kanban-chrome=#{write_fake_chrome(tmp_dir)}"] ++
        chrome_args ++ ["--kanban-watch-pid=#{watch_pid}"]

    port = open_script(args, FAKE_CHROME_ARGS_FILE: args_file, FAKE_CHROME_PID_FILE: pid_file)
    {:os_pid, script_pid} = Port.info(port, :os_pid)

    assert_eventually(fn -> File.exists?(pid_file) and File.read!(pid_file) =~ ~r/\d+\n/ end)
    chrome_pid = pid_file |> File.read!() |> String.trim()

    on_exit(fn -> kill_quietly(["-KILL", chrome_pid, "#{script_pid}"]) end)

    %{port: port, script_pid: script_pid, chrome_pid: chrome_pid, args_file: args_file}
  end

  defp write_fake_chrome(tmp_dir) do
    chrome = Path.join(tmp_dir, "fake_chrome.sh")

    File.write!(chrome, """
    #!/bin/sh
    trap '' TERM
    printf '%s\\n' "$@" > "$FAKE_CHROME_ARGS_FILE"
    echo $$ > "$FAKE_CHROME_PID_FILE"
    while :; do sleep 1; done
    """)

    File.chmod!(chrome, 0o755)
    chrome
  end

  # stderr_to_stdout keeps the shell's "Killed: 9" job notices out of the
  # test output; they arrive as port data, which no test reads.
  defp open_script(args, env) do
    Port.open({:spawn_executable, "/bin/sh"}, [
      :exit_status,
      :stderr_to_stdout,
      args: [ChromeWatchdog.script_path() | args],
      env: Enum.map(env, fn {name, value} -> {~c"#{name}", String.to_charlist(value)} end)
    ])
  end

  defp stop_script(%{script_pid: script_pid, chrome_pid: chrome_pid}) do
    kill(script_pid)
    assert_eventually(fn -> not os_process_alive?(chrome_pid) end)
  end

  # A `sleep` OS process standing in for the VM that launched Chrome.
  defp start_stand_in_vm do
    port = Port.open({:spawn_executable, "/bin/sleep"}, args: ["300"])
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    on_exit(fn -> kill_quietly(["-KILL", "#{os_pid}"]) end)
    os_pid
  end

  defp kill(os_pid), do: System.cmd("kill", ["-TERM", "#{os_pid}"])

  # on_exit cleanup: the processes have normally exited already.
  defp kill_quietly(args), do: System.cmd("kill", args, stderr_to_stdout: true)

  # Read-only liveness probe: `ps -p` exits non-zero once the pid is gone.
  defp os_process_alive?(os_pid) do
    {_output, status} = System.cmd("ps", ["-p", "#{os_pid}"])
    status == 0
  end

  defp assert_eventually(fun, attempts \\ 80)
  defp assert_eventually(fun, 0), do: assert(fun.())

  defp assert_eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(100)
      assert_eventually(fun, attempts - 1)
    end
  end
end
