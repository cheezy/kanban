defmodule Kanban.AuditLog.SignedExport.SweeperTest do
  # async: false — the tests set Kanban.AuditLog.SignedExport's application
  # config, which is global to the VM.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Kanban.AuditLog.SignedExport
  alias Kanban.AuditLog.SignedExport.Sweeper

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

  # A directory named as Writer.create_tmp_dir/1 names one, last changed
  # `age` seconds ago.
  defp aged_dir!(root, age) do
    name = ".tmp-" <> (16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))
    path = Path.join(root, name)

    File.mkdir!(path)
    path |> Path.join("audit_log.csv") |> File.write!("left behind")
    File.touch!(path, System.os_time(:second) - age)

    path
  end

  # The sweep runs in a task, so the directory goes a moment later.
  defp removed?(path, attempts \\ 200) do
    cond do
      not File.exists?(path) ->
        true

      attempts == 0 ->
        false

      true ->
        Process.sleep(10)
        removed?(path, attempts - 1)
    end
  end

  test "sweeps when it starts", %{root: root} do
    stale = aged_dir!(root, 3_700)

    capture_log(fn ->
      start_supervised!({Sweeper, interval: :timer.hours(1)})

      assert removed?(stale)
    end)
  end

  test "sweeps again on its timer: a directory too young at the start goes once it is stale",
       %{root: root} do
    young = aged_dir!(root, 3_500)

    capture_log(fn ->
      start_supervised!({Sweeper, interval: 20})

      # Several sweeps look at the directory in this time and keep it.
      Process.sleep(100)
      assert File.dir?(young)

      File.touch!(young, System.os_time(:second) - 3_700)

      assert removed?(young)
    end)
  end

  test "ignores a message that is not its own", %{root: root} do
    recent = aged_dir!(root, 10)
    sweeper = start_supervised!({Sweeper, interval: :timer.hours(1)})

    send(sweeper, :something_else)

    assert :sys.get_state(sweeper) == :timer.hours(1)
    assert File.dir?(recent)
  end

  test "rejects an unknown option" do
    assert_raise ArgumentError, fn -> Sweeper.start_link(every: 5) end
  end

  test "the application runs one under its own name" do
    assert Sweeper |> Process.whereis() |> is_pid()

    children = Supervisor.which_children(Kanban.Supervisor)

    assert Enum.any?(children, &match?({Sweeper, pid, :worker, [Sweeper]} when is_pid(pid), &1))
  end
end
