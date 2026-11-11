defmodule Kanban.AuditLog.SignedExport.ScratchTest do
  # async: false — the tests set Kanban.AuditLog.SignedExport's application
  # config and the TMPDIR environment variable, both global to the VM.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Kanban.AuditLog.SignedExport
  alias Kanban.AuditLog.SignedExport.Scratch

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    saved = Application.fetch_env(:kanban, SignedExport)
    Application.put_env(:kanban, SignedExport, tmp_root: tmp_dir)

    on_exit(fn ->
      case saved do
        {:ok, config} -> Application.put_env(:kanban, SignedExport, config)
        :error -> Application.delete_env(:kanban, SignedExport)
      end
    end)

    %{root: tmp_dir}
  end

  defp mode(path), do: Bitwise.band(File.stat!(path).mode, 0o777)

  # Checks a directory out in a process of its own, which then runs `then`.
  defp checkout_in_process(then) do
    test_pid = self()

    owner =
      spawn(fn ->
        {:ok, scratch} = Scratch.checkout()
        scratch.path |> Path.join("audit_log.csv") |> File.write!("held")
        send(test_pid, {:checked_out, scratch})
        then.()
      end)

    assert_receive {:checked_out, scratch}, 5_000

    {owner, scratch}
  end

  defp assert_guard_down(scratch) do
    monitor = Process.monitor(scratch.guard)
    assert_receive {:DOWN, ^monitor, :process, _pid, _reason}, 5_000
  end

  # Entries of `root` can no longer be removed, until the test ends.
  defp read_only!(root) do
    File.chmod!(root, 0o500)
    on_exit(fn -> File.chmod(root, 0o700) end)
  end

  # A directory named as Writer.create_tmp_dir/1 names one, last changed
  # `age` seconds ago.
  defp aged_dir!(root, age, name \\ nil) do
    name =
      name || ".tmp-" <> (16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))

    path = Path.join(root, name)

    File.mkdir!(path)
    path |> Path.join("audit_log.csv") |> File.write!("left behind")
    File.touch!(path, System.os_time(:second) - age)

    path
  end

  describe "checkout/0 and release/1" do
    test "checkout creates an owner-only directory with an unpredictable name in the root",
         %{root: root} do
      assert {:ok, scratch} = Scratch.checkout()

      assert Path.dirname(scratch.path) == root
      assert Path.basename(scratch.path) =~ ~r/\A\.tmp-[A-Za-z0-9_-]{22}\z/
      assert mode(scratch.path) == 0o700
      assert Process.alive?(scratch.guard)

      Scratch.release(scratch)
    end

    test "two checkouts get two directories", %{root: root} do
      assert {:ok, first} = Scratch.checkout()
      assert {:ok, second} = Scratch.checkout()

      refute first.path == second.path
      assert length(File.ls!(root)) == 2

      Scratch.release(first)
      assert File.ls!(root) == [Path.basename(second.path)]

      Scratch.release(second)
    end

    test "release removes the directory and what it holds before it returns, and ends the guard",
         %{root: root} do
      assert {:ok, scratch} = Scratch.checkout()
      scratch.path |> Path.join("audit_log.csv") |> File.write!("held")

      assert Scratch.release(scratch) == :ok
      assert File.ls!(root) == []

      assert_guard_down(scratch)
    end

    test "a removal the operating system refuses is logged, without the path", %{root: root} do
      assert {:ok, scratch} = Scratch.checkout()
      read_only!(root)

      log = capture_log(fn -> assert Scratch.release(scratch) == :ok end)

      assert File.dir?(scratch.path)
      assert log =~ "signed audit export: a temporary directory could not be removed: :eacces"
      refute log =~ root

      assert_guard_down(scratch)
    end

    test "a root that is missing or is a file gives an error and leaves nothing", %{root: root} do
      file = Path.join(root, "a-file")
      File.write!(file, "")

      for unusable <- [Path.join(root, "missing"), file] do
        Application.put_env(:kanban, SignedExport, tmp_root: unusable)

        assert {:error, reason} = Scratch.checkout()
        assert is_atom(reason)
      end

      assert File.ls!(root) == ["a-file"]
    end
  end

  describe "the guard" do
    test "removes the directory when the owner is killed", %{root: root} do
      {owner, scratch} = checkout_in_process(fn -> Process.sleep(:infinity) end)
      assert File.ls!(root) == [Path.basename(scratch.path)]

      Process.exit(owner, :kill)

      assert_guard_down(scratch)
      assert File.ls!(root) == []
    end

    test "removes the directory when the owner ends without releasing it", %{root: root} do
      {_owner, scratch} = checkout_in_process(fn -> :ok end)

      assert_guard_down(scratch)
      assert File.ls!(root) == []
    end

    test "removes the directory when the task supervisor stops the guard", %{root: root} do
      {owner, scratch} = checkout_in_process(fn -> Process.sleep(:infinity) end)

      assert :ok = Task.Supervisor.terminate_child(Kanban.TaskSupervisor, scratch.guard)

      refute Process.alive?(scratch.guard)
      assert File.ls!(root) == []

      Process.exit(owner, :kill)
    end
  end

  describe "the default root" do
    setup %{root: root} do
      Application.delete_env(:kanban, SignedExport)

      saved = System.get_env("TMPDIR")
      System.put_env("TMPDIR", root)

      on_exit(fn ->
        if saved, do: System.put_env("TMPDIR", saved), else: System.delete_env("TMPDIR")
      end)

      %{default: Path.join(root, "stride-signed-exports")}
    end

    test "is a directory of its own under the system temporary directory, owner-only, and reused",
         %{default: default} do
      assert {:ok, first} = Scratch.checkout()

      assert Path.dirname(first.path) == default
      assert mode(default) == 0o700
      Scratch.release(first)

      assert {:ok, second} = Scratch.checkout()
      assert Path.dirname(second.path) == default
      Scratch.release(second)

      assert File.ls!(default) == []
    end

    test "an existing directory under the name is made owner-only", %{default: default} do
      File.mkdir!(default)
      File.chmod!(default, 0o755)

      assert {:ok, scratch} = Scratch.checkout()
      assert mode(default) == 0o700

      Scratch.release(scratch)
    end

    test "a symlink or a file under the name is refused", %{root: root, default: default} do
      elsewhere = Path.join(root, "elsewhere")
      File.mkdir!(elsewhere)

      File.ln_s!(elsewhere, default)
      assert Scratch.checkout() == {:error, :no_root}
      assert File.ls!(elsewhere) == []

      File.rm!(default)
      File.write!(default, "")
      assert Scratch.checkout() == {:error, :no_root}
    end

    test "the sweep leaves a symlink under the name alone", %{root: root, default: default} do
      elsewhere = Path.join(root, "elsewhere")
      File.mkdir!(elsewhere)
      stale = aged_dir!(elsewhere, 3_700)
      File.ln_s!(elsewhere, default)

      assert capture_log(fn -> assert Scratch.sweep() == 0 end) == ""
      assert File.dir?(stale)
    end

    test "the sweep removes what is stale in the directory it owns", %{default: default} do
      File.mkdir!(default)
      stale = aged_dir!(default, 3_700)

      capture_log(fn -> assert Scratch.sweep() == 1 end)

      refute File.exists?(stale)
    end
  end

  describe "owned_directory?/2" do
    test "is true only for a real directory that the given user owns", %{root: root} do
      uid = File.stat!(root).uid

      assert Scratch.owned_directory?(root, uid)
      refute Scratch.owned_directory?(root, uid + 1)

      missing = Path.join(root, "missing")
      refute Scratch.owned_directory?(missing, uid)

      file = Path.join(root, "a-file")
      File.write!(file, "")
      refute Scratch.owned_directory?(file, uid)

      link = Path.join(root, "a-link")
      File.ln_s!(root, link)
      refute Scratch.owned_directory?(link, uid)
    end
  end

  describe "sweep/0" do
    test "removes only directories named like a scratch directory that are over an hour old",
         %{root: root} do
      stale = aged_dir!(root, 3_700)
      recent = aged_dir!(root, 3_500)
      unrelated = aged_dir!(root, 3_700, "kept-by-someone-else")

      file = Path.join(root, ".tmp-" <> String.duplicate("a", 22))
      File.write!(file, "")
      File.touch!(file, System.os_time(:second) - 3_700)

      log = capture_log(fn -> assert Scratch.sweep() == 1 end)

      refute File.exists?(stale)
      assert File.dir?(recent)
      assert File.dir?(unrelated)
      assert File.regular?(file)

      assert log =~ "signed audit export: removed 1 stale temporary directories"
      refute log =~ root
    end

    test "returns 0 and logs nothing when nothing is stale", %{root: root} do
      recent = aged_dir!(root, 10)

      assert capture_log(fn -> assert Scratch.sweep() == 0 end) == ""
      assert File.dir?(recent)
    end

    test "returns 0 when the root does not exist", %{root: root} do
      Application.put_env(:kanban, SignedExport, tmp_root: Path.join(root, "missing"))

      assert Scratch.sweep() == 0
    end

    test "a directory the operating system refuses to remove is logged and not counted",
         %{root: root} do
      stale = aged_dir!(root, 3_700)
      read_only!(root)

      log = capture_log(fn -> assert Scratch.sweep() == 0 end)

      assert File.dir?(stale)
      assert log =~ "signed audit export: a temporary directory could not be removed: :eacces"
      refute log =~ "stale temporary directories"
      refute log =~ root
    end
  end
end
