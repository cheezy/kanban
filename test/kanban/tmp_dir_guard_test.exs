defmodule Kanban.TmpDirGuardTest do
  # async: false — the guard tests use the application's Kanban.TaskSupervisor
  # and a named supervisor of their own.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Kanban.TmpDirGuard
  alias Kanban.Workspaces.Export.Writer

  @moduletag :tmp_dir
  @label "test label"

  setup %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "root")
    File.mkdir!(root)

    %{root: root, create: fn -> Writer.create_tmp_dir(root) end}
  end

  defp mode(path), do: Bitwise.band(File.stat!(path).mode, 0o777)

  # Checks a directory out in a process of its own, which then runs `then`.
  defp checkout_in_process(create, then) do
    test_pid = self()

    owner =
      spawn(fn ->
        {:ok, scratch} = TmpDirGuard.checkout(create, @label)
        scratch.path |> Path.join("rows.json") |> File.write!("held")
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

  defp scratch_name,
    do: ".tmp-" <> (16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))

  # A directory named as Writer.create_tmp_dir/1 names one, last changed
  # `age` seconds ago.
  defp aged_dir!(root, age, name \\ nil) do
    path = Path.join(root, name || scratch_name())

    File.mkdir!(path)
    path |> Path.join("rows.json") |> File.write!("left behind")
    File.touch!(path, System.os_time(:second) - age)

    path
  end

  defp no_child_supervisor, do: start_supervised!({Task.Supervisor, max_children: 0})

  describe "checkout/3 and release/2" do
    test "checkout creates the directory through the given create function", %{root: root} do
      test_pid = self()

      create = fn ->
        send(test_pid, {:created_by, self()})
        Writer.create_tmp_dir(root)
      end

      assert {:ok, scratch} = TmpDirGuard.checkout(create, @label)

      assert_received {:created_by, creator}
      assert creator == scratch.guard
      assert Path.dirname(scratch.path) == root
      assert mode(scratch.path) == 0o700
      assert Process.alive?(scratch.guard)

      assert TmpDirGuard.release(scratch, @label) == :ok
      assert File.ls!(root) == []
      assert_guard_down(scratch)
    end

    test "a create function that returns an error gives that error and leaves nothing",
         %{root: root} do
      assert TmpDirGuard.checkout(fn -> {:error, :eacces} end, @label) == {:error, :eacces}
      assert File.ls!(root) == []
    end

    test "a guard that cannot start gives {:error, :no_guard}", %{root: root} do
      test_pid = self()

      create = fn ->
        send(test_pid, :create_ran)
        Writer.create_tmp_dir(root)
      end

      assert TmpDirGuard.checkout(create, @label, supervisor: no_child_supervisor()) ==
               {:error, :no_guard}

      refute_received :create_ran
      assert File.ls!(root) == []
    end

    test "a guard that dies before it answers gives {:error, :no_guard}", %{root: root} do
      capture_log(fn ->
        assert TmpDirGuard.checkout(fn -> exit(:boom) end, @label) == {:error, :no_guard}
      end)

      assert File.ls!(root) == []
    end

    test "a release the operating system refuses is logged with the label, without the path",
         %{root: root, create: create} do
      assert {:ok, scratch} = TmpDirGuard.checkout(create, @label)
      read_only!(root)

      log = capture_log(fn -> assert TmpDirGuard.release(scratch, @label) == :ok end)

      assert File.dir?(scratch.path)
      assert log =~ "test label: a temporary directory could not be removed: :eacces"
      refute log =~ root

      assert_guard_down(scratch)
    end
  end

  describe "the guard" do
    test "the guard removes the directory when the owner is killed",
         %{root: root, create: create} do
      {owner, scratch} = checkout_in_process(create, fn -> Process.sleep(:infinity) end)
      assert File.ls!(root) == [Path.basename(scratch.path)]

      Process.exit(owner, :kill)

      assert_guard_down(scratch)
      assert File.ls!(root) == []
    end

    test "removes the directory when the owner ends without releasing it",
         %{root: root, create: create} do
      {_owner, scratch} = checkout_in_process(create, fn -> :ok end)

      assert_guard_down(scratch)
      assert File.ls!(root) == []
    end

    test "removes the directory when the task supervisor stops the guard",
         %{root: root, create: create} do
      {owner, scratch} = checkout_in_process(create, fn -> Process.sleep(:infinity) end)

      assert :ok = Task.Supervisor.terminate_child(Kanban.TaskSupervisor, scratch.guard)

      refute Process.alive?(scratch.guard)
      assert File.ls!(root) == []

      Process.exit(owner, :kill)
    end

    test "removes the directory when the owner is killed before it receives the path",
         %{root: root} do
      test_pid = self()

      # The guard has created the directory and is held before it can answer.
      create = fn ->
        {:ok, path} = Writer.create_tmp_dir(root)
        send(test_pid, {:created, self(), path})

        receive do
          :go -> {:ok, path}
        end
      end

      owner = spawn(fn -> TmpDirGuard.checkout(create, @label) end)
      assert_receive {:created, guard, path}, 5_000
      assert File.dir?(path)

      monitor = Process.monitor(guard)
      Process.exit(owner, :kill)
      send(guard, :go)

      assert_receive {:DOWN, ^monitor, :process, _pid, _reason}, 5_000
      refute File.exists?(path)
      assert File.ls!(root) == []
    end
  end

  describe "sweep/3" do
    test "sweep removes only directories named like a scratch directory and older than the threshold",
         %{root: root, tmp_dir: tmp_dir} do
      stale = aged_dir!(root, 700)
      recent = aged_dir!(root, 500)
      unrelated = aged_dir!(root, 700, "kept-by-someone-else")

      file = Path.join(root, ".tmp-" <> String.duplicate("a", 22))
      File.write!(file, "")
      File.touch!(file, System.os_time(:second) - 700)

      # A symlink named like a scratch directory, pointing at an aged one
      # outside the root: neither the link nor its target is touched.
      outside = Path.join(tmp_dir, "outside")
      File.mkdir!(outside)
      target = aged_dir!(outside, 700)
      link = Path.join(root, scratch_name())
      File.ln_s!(target, link)

      log = capture_log(fn -> assert TmpDirGuard.sweep(root, 600, @label) == 1 end)

      refute File.exists?(stale)
      assert File.dir?(recent)
      assert File.dir?(unrelated)
      assert File.regular?(file)
      assert {:ok, %File.Stat{type: :symlink}} = File.lstat(link)
      assert target |> Path.join("rows.json") |> File.regular?()

      assert log =~ "test label: removed 1 stale temporary directories"
      refute log =~ root
    end

    test "returns 0 and logs nothing when nothing is stale", %{root: root} do
      recent = aged_dir!(root, 10)

      assert capture_log(fn -> assert TmpDirGuard.sweep(root, 600, @label) == 0 end) == ""
      assert File.dir?(recent)
    end

    test "returns 0 when the root does not exist", %{root: root} do
      missing = Path.join(root, "missing")

      assert TmpDirGuard.sweep(missing, 600, @label) == 0
    end

    test "a directory the operating system refuses to remove is logged and not counted",
         %{root: root} do
      stale = aged_dir!(root, 700)
      read_only!(root)

      log = capture_log(fn -> assert TmpDirGuard.sweep(root, 600, @label) == 0 end)

      assert File.dir?(stale)
      assert log =~ "test label: a temporary directory could not be removed: :eacces"
      refute log =~ "stale temporary directories"
      refute log =~ root
    end
  end

  describe "sweep/4 with an owner" do
    setup %{root: root} do
      File.chmod!(root, 0o700)
      {:ok, uid} = TmpDirGuard.own_uid()
      %{uid: uid}
    end

    test "own_uid/0 is the owner of a directory this VM creates", %{root: root, uid: uid} do
      assert uid == File.lstat!(root).uid
    end

    test "sweeps an owner-only root of that user", %{root: root, uid: uid} do
      stale = aged_dir!(root, 700)

      capture_log(fn -> assert TmpDirGuard.sweep(root, 600, @label, owner: uid) == 1 end)

      refute File.exists?(stale)
    end

    test "sweeps nothing in a root that others can write to, and says so without the path",
         %{root: root, uid: uid} do
      stale = aged_dir!(root, 700)
      File.chmod!(root, 0o770)

      log = capture_log(fn -> assert TmpDirGuard.sweep(root, 600, @label, owner: uid) == 0 end)

      assert File.dir?(stale)
      assert log =~ "test label: the temporary directory root is not an owner-only directory"
      refute log =~ root
    end

    test "sweeps nothing in a root another user owns, and says so", %{root: root, uid: uid} do
      stale = aged_dir!(root, 700)

      log =
        capture_log(fn -> assert TmpDirGuard.sweep(root, 600, @label, owner: uid + 1) == 0 end)

      assert File.dir?(stale)
      assert log =~ "test label: the temporary directory root is not an owner-only directory"
    end

    test "sweeps nothing through a symlink planted as the root",
         %{root: root, uid: uid, tmp_dir: tmp_dir} do
      stale = aged_dir!(root, 700)
      link = Path.join(tmp_dir, "root-link")
      File.ln_s!(root, link)

      capture_log(fn -> assert TmpDirGuard.sweep(link, 600, @label, owner: uid) == 0 end)

      assert File.dir?(stale)
    end

    test "a root that does not exist sweeps nothing and logs nothing", %{root: root, uid: uid} do
      missing = Path.join(root, "missing")

      assert capture_log(fn ->
               assert TmpDirGuard.sweep(missing, 600, @label, owner: uid) == 0
             end) ==
               ""
    end
  end
end
