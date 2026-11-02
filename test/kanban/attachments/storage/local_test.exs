defmodule Kanban.Attachments.Storage.LocalTest do
  # Not async: each test points the application-wide root at its own directory.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Kanban.Attachments.Storage
  alias Kanban.Attachments.Storage.Local

  @key "boards/12/0b9c4e2a-6f1d-4c8e-9a7b-3d2e1f0a9b8c"

  setup do
    base =
      Path.join([
        System.tmp_dir!(),
        "stride_attachments_test",
        Integer.to_string(System.unique_integer([:positive]))
      ])

    root = Path.join(base, "root")
    previous = Application.get_env(:kanban, Local)
    Application.put_env(:kanban, Local, root: root)

    on_exit(fn ->
      restore(Local, previous)
      File.rm_rf(base)
    end)

    %{base: Path.expand(base), root: Path.expand(root)}
  end

  defp read_all(stream), do: stream |> Enum.to_list() |> IO.iodata_to_binary()

  defp entries(dir), do: dir |> File.ls!() |> Enum.sort()

  defp present?(root, relative), do: root |> Path.join(relative) |> File.exists?()

  defp private_dir!(root, relative), do: root |> Path.join(relative) |> File.chmod!(0o700)

  describe "root/0" do
    test "uses the configured root, expanded, and a temp-dir default when unset", %{root: root} do
      assert Local.root() == root

      Application.put_env(:kanban, Local, [])
      assert Local.root() == System.tmp_dir!() |> Path.join("stride_attachments") |> Path.expand()
    end
  end

  test "round-trips bytes through put, stream, exists and delete", %{root: root} do
    bytes = :crypto.strong_rand_bytes(200_000)

    assert {:ok, false} = Local.exists(@key)
    assert :ok = Local.put(@key, {:binary, bytes}, [])
    assert {:ok, true} = Local.exists(@key)
    assert {:ok, stream} = Local.stream(@key)
    assert read_all(stream) == bytes
    assert root |> Path.join(@key) |> File.read!() == bytes

    assert :ok = Local.delete(@key)
    assert {:ok, false} = Local.exists(@key)
    assert {:error, :not_found} = Local.stream(@key)
  end

  test "round-trips through the facade, which defaults to Local" do
    assert :ok = Storage.put(@key, {:binary, ["he", "llo"]})
    assert {:ok, stream} = Storage.stream(@key)
    assert read_all(stream) == "hello"
    assert :ok = Storage.delete(@key)
  end

  test "stores a file source and a zero-byte binary unchanged", %{base: base} do
    source = Path.join(base, "upload.bin")
    File.mkdir_p!(base)
    File.write!(source, "file bytes")

    assert :ok = Local.put(@key, {:file, source}, [])
    assert {:ok, stream} = Local.stream(@key)
    assert read_all(stream) == "file bytes"

    assert :ok = Local.put("boards/12/empty", {:binary, ""}, [])
    assert {:ok, stream} = Local.stream("boards/12/empty")
    assert read_all(stream) == ""
  end

  # The controller sends a 200 the moment stream/1 returns, so a file it
  # cannot read must be refused here, not when the first chunk is read.
  test "a file the app cannot read is unavailable before any byte is read", %{root: root} do
    assert :ok = Local.put(@key, {:binary, "secret"}, [])
    path = Path.join(root, @key)
    File.chmod!(path, 0o000)

    # A superuser reads any file, so there is nothing to refuse.
    if match?({:error, :eacces}, File.read(path)) do
      log = capture_log(fn -> assert {:error, :storage_unavailable} = Local.stream(@key) end)
      assert log =~ "attachment storage read failed: :eacces"
      refute log =~ @key
    end
  end

  test "the stream reads the file it opened, even once the file is removed", %{root: root} do
    bytes = :crypto.strong_rand_bytes(200_000)
    assert :ok = Local.put(@key, {:binary, bytes}, [])

    assert {:ok, stream} = Local.stream(@key)
    root |> Path.join(@key) |> File.rm!()

    assert read_all(stream) == bytes
  end

  test "a put replaces the object already under the key" do
    assert :ok = Local.put(@key, {:binary, "first"}, [])
    assert :ok = Local.put(@key, {:binary, "second"}, [])
    assert {:ok, stream} = Local.stream(@key)
    assert read_all(stream) == "second"
  end

  test "delete of a missing key returns ok", %{root: root} do
    assert :ok = Local.delete(@key)
    refute File.exists?(root)

    assert :ok = Local.put(@key, {:binary, "x"}, [])
    assert :ok = Local.delete(@key)
    assert :ok = Local.delete(@key)
  end

  describe "sweep/1" do
    defp staged(root, name, age_seconds) do
      staging = Path.join(root, ".staging")
      path = Path.join(staging, name)
      File.write!(path, "partial bytes")
      mtime = System.os_time(:second) - age_seconds
      File.touch!(path, mtime)
      path
    end

    test "removes temp files older than the age and keeps younger ones and anything else",
         %{root: root} do
      :ok = Local.put(@key, {:binary, "live"}, [])

      old = staged(root, ".tmp-old", 7_200)
      young = staged(root, ".tmp-young", 60)
      other = staged(root, "not-a-temp-file", 7_200)

      assert Local.sweep(3_600) == :ok

      refute File.exists?(old)
      assert File.exists?(young)
      assert File.exists?(other)
      assert {:ok, true} = Local.exists(@key)
    end

    test "is ok when there is no staging directory or root yet" do
      assert Local.sweep(3_600) == :ok
    end

    test "never sweeps a staging directory others can open", %{root: root} do
      :ok = Local.put(@key, {:binary, "live"}, [])
      old = staged(root, ".tmp-old", 7_200)
      root |> Path.join(".staging") |> File.chmod!(0o755)

      log = capture_log(fn -> assert {:error, :storage_unavailable} = Local.sweep(3_600) end)

      assert log =~ "attachment storage sweep failed: :untrusted_directory"
      assert File.exists?(old)
    end
  end

  describe "directories left after a delete" do
    @sibling "boards/12/7c1d2e3f-4a5b-4c6d-8e9f-0a1b2c3d4e5f"

    test "removing a board's last file removes its now-empty directories, never the root",
         %{root: root} do
      :ok = Local.put(@key, {:binary, "only file"}, [])

      assert :ok = Local.delete(@key)

      refute present?(root, "boards/12")
      refute present?(root, "boards")
      assert File.dir?(root)
      assert entries(root) == [".staging"]
    end

    test "a directory that still holds another file is kept", %{root: root} do
      :ok = Local.put(@key, {:binary, "one"}, [])
      :ok = Local.put(@sibling, {:binary, "two"}, [])

      assert :ok = Local.delete(@key)

      assert root |> Path.join("boards/12") |> entries() == [Path.basename(@sibling)]
      assert {:ok, stream} = Local.stream(@sibling)
      assert read_all(stream) == "two"
    end

    test "a missing file's empty directories are removed too", %{root: root} do
      root |> Path.join("boards/12") |> File.mkdir_p!()
      File.chmod!(root, 0o700)
      private_dir!(root, "boards")
      private_dir!(root, "boards/12")

      assert :ok = Local.delete(@key)

      refute present?(root, "boards")
    end

    test "a put after the directories were removed creates them again" do
      :ok = Local.put(@key, {:binary, "first"}, [])
      :ok = Local.delete(@key)

      assert :ok = Local.put(@key, {:binary, "second"}, [])
      assert {:ok, stream} = Local.stream(@key)
      assert read_all(stream) == "second"
    end

    test "puts racing deletes in the same directory never fail and never lose a file" do
      deleter =
        Task.async(fn ->
          for _ <- 1..300 do
            :ok = Local.put(@key, {:binary, "churn"}, [])
            :ok = Local.delete(@key)
          end
        end)

      results =
        for n <- 1..300 do
          key = "boards/12/" <> Ecto.UUID.generate()
          {Local.put(key, {:binary, "kept #{n}"}, []), key, n}
        end

      Task.await(deleter, 30_000)

      assert Enum.all?(results, fn {result, _key, _n} -> result == :ok end)

      for {:ok, key, n} <- results do
        assert {:ok, stream} = Local.stream(key)
        assert read_all(stream) == "kept #{n}"
      end
    end
  end

  test "exists returns false for a key never written" do
    assert {:ok, false} = Local.exists("boards/1/never-written")
    assert {:error, :not_found} = Local.stream("boards/1/never-written")
  end

  test "a failed write leaves no temp file and no file under the key", %{root: root, base: base} do
    log =
      capture_log(fn ->
        assert {:error, :storage_unavailable} =
                 Local.put(@key, {:file, Path.join(base, "missing-upload")}, [])
      end)

    assert log =~ "attachment storage put failed"
    refute log =~ base

    # The key's directories are created only once there is a file to rename
    # into them, so a failed write leaves none behind.
    refute present?(root, Path.dirname(@key))
    assert entries(Path.join(root, ".staging")) == []
    assert {:ok, false} = Local.exists(@key)
  end

  test "a failed write leaves the previous object in place", %{base: base} do
    assert :ok = Local.put(@key, {:binary, "kept"}, [])

    capture_log(fn ->
      assert {:error, :storage_unavailable} =
               Local.put(@key, {:file, Path.join(base, "missing-upload")}, [])
    end)

    assert {:ok, stream} = Local.stream(@key)
    assert read_all(stream) == "kept"
    assert entries(Path.join(Local.root(), Path.dirname(@key))) == [Path.basename(@key)]
  end

  test "creates directories 0o700 and files 0o600", %{root: root} do
    assert :ok = Local.put(@key, {:binary, "x"}, [])

    assert mode(root) == 0o700
    assert mode(Path.join(root, ".staging")) == 0o700
    assert mode(Path.join(root, "boards")) == 0o700
    assert mode(Path.join(root, "boards/12")) == 0o700
    assert mode(Path.join(root, @key)) == 0o600
  end

  test "creates a root directory that does not exist yet", %{root: root} do
    refute File.exists?(root)
    assert :ok = Local.put("top-level-key", {:binary, "x"}, [])
    assert root |> Path.join("top-level-key") |> File.regular?()
  end

  describe "ownership and mode of the directories" do
    test "refuses a root that group or others can write", %{root: root} do
      File.mkdir_p!(root)

      for writable <- [0o770, 0o707] do
        File.chmod!(root, writable)

        log =
          capture_log(fn ->
            assert {:error, :storage_unavailable} = Local.put(@key, {:binary, "x"}, [])
            assert {:error, :storage_unavailable} = Local.stream(@key)
            assert {:error, :storage_unavailable} = Local.exists(@key)
            assert {:error, :storage_unavailable} = Local.delete(@key)
          end)

        assert log =~ "attachment storage put failed: :untrusted_directory"
        assert log =~ "attachment storage read failed: :untrusted_directory"
        assert log =~ "attachment storage delete failed: :untrusted_directory"
        assert entries(root) == []
      end
    end

    test "refuses a directory under the root that others can write", %{root: root} do
      assert :ok = Local.put(@key, {:binary, "kept"}, [])
      root |> Path.join("boards") |> File.chmod!(0o777)

      log =
        capture_log(fn ->
          assert {:error, :storage_unavailable} = Local.put(@key, {:binary, "replaced"}, [])
          assert {:error, :storage_unavailable} = Local.stream(@key)
          assert {:error, :storage_unavailable} = Local.exists(@key)
          assert {:error, :storage_unavailable} = Local.delete(@key)
        end)

      assert log =~ ":untrusted_directory"
      assert root |> Path.join(@key) |> File.read!() == "kept"
    end

    test "refuses a staging directory that group or others can read", %{root: root} do
      assert :ok = Local.put(@key, {:binary, "kept"}, [])

      for readable <- [0o750, 0o705] do
        root |> Path.join(".staging") |> File.chmod!(readable)

        log =
          capture_log(fn ->
            assert {:error, :storage_unavailable} = Local.put(@key, {:binary, "replaced"}, [])
          end)

        assert log =~ "attachment storage put failed: :untrusted_directory"
        assert root |> Path.join(@key) |> File.read!() == "kept"
      end
    end

    test "delete is ok when a directory on the way to the key is a plain file",
         %{root: root} do
      File.mkdir_p!(root)
      File.chmod!(root, 0o700)
      root |> Path.join("boards") |> File.write!("not a directory")

      assert :ok = Local.delete(@key)
      assert {:error, :not_found} = Local.stream(@key)
      assert {:ok, false} = Local.exists(@key)
    end

    test "accepts a root others can read but not write", %{root: root} do
      File.mkdir_p!(root)
      File.chmod!(root, 0o755)

      assert :ok = Local.put(@key, {:binary, "x"}, [])
      assert {:ok, true} = Local.exists(@key)
    end

    test "refuses a default root that is a symlink, even to a directory it owns",
         %{base: base} do
      tmp = Path.join(base, "tmp")
      target = Path.join(base, "elsewhere")
      File.mkdir_p!(tmp)
      File.mkdir_p!(target)
      File.chmod!(target, 0o700)
      File.ln_s!(target, Path.join(tmp, "stride_attachments"))

      previous_tmpdir = System.get_env("TMPDIR")
      on_exit(fn -> restore_env("TMPDIR", previous_tmpdir) end)
      System.put_env("TMPDIR", tmp)
      Application.put_env(:kanban, Local, [])

      assert Local.root() == tmp |> Path.expand() |> Path.join("stride_attachments")

      capture_log(fn ->
        assert {:error, :storage_unavailable} = Local.put(@key, {:binary, "x"}, [])
      end)

      assert entries(target) == []
    end
  end

  describe "symlinks under the root" do
    setup %{base: base, root: root} do
      outside = Path.join(base, "outside")
      File.mkdir_p!(outside)
      outside |> Path.join("secret") |> File.write!("outside bytes")
      root |> Path.join("boards/12") |> File.mkdir_p!()
      %{outside: outside}
    end

    test "refuses to stream a symlink planted under the root", %{root: root, outside: outside} do
      link = Path.join(root, "boards/12/planted")
      outside |> Path.join("secret") |> File.ln_s!(link)

      assert {:error, :not_found} = Local.stream("boards/12/planted")
      assert {:ok, false} = Local.exists("boards/12/planted")
    end

    test "refuses to serve through a symlinked directory", %{root: root, outside: outside} do
      outside |> Path.join("linked") |> File.mkdir_p!()
      outside |> Path.join("linked/file") |> File.write!("outside bytes")
      outside |> Path.join("linked") |> File.ln_s!(Path.join(root, "boards/linked"))

      assert {:error, :not_found} = Local.stream("boards/linked/file")
      assert {:ok, false} = Local.exists("boards/linked/file")
    end

    test "refuses to write or delete through a symlinked directory",
         %{root: root, outside: outside} do
      File.ln_s!(outside, Path.join(root, "boards/escape"))

      capture_log(fn ->
        assert {:error, :storage_unavailable} =
                 Local.put("boards/escape/secret", {:binary, "overwritten"}, [])

        assert {:error, :storage_unavailable} = Local.delete("boards/escape/secret")
      end)

      assert outside |> Path.join("secret") |> File.read!() == "outside bytes"
      assert entries(outside) == ["secret"]
    end

    test "a put replaces a planted symlink without touching its target",
         %{root: root, outside: outside} do
      outside |> Path.join("secret") |> File.ln_s!(Path.join(root, "boards/12/planted"))

      assert :ok = Local.put("boards/12/planted", {:binary, "new"}, [])
      assert outside |> Path.join("secret") |> File.read!() == "outside bytes"
      assert {:ok, stream} = Local.stream("boards/12/planted")
      assert read_all(stream) == "new"
    end

    test "serves files when the root itself is a symlink to a real directory",
         %{base: base, outside: outside} do
      linked_root = Path.join(base, "linked-root")
      File.ln_s!(outside, linked_root)
      Application.put_env(:kanban, Local, root: linked_root)

      assert :ok = Local.put(@key, {:binary, "via link"}, [])
      assert {:ok, stream} = Local.stream(@key)
      assert read_all(stream) == "via link"
    end
  end

  defp mode(path), do: Bitwise.band(File.stat!(path).mode, 0o777)

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

  defp restore(module, nil), do: Application.delete_env(:kanban, module)
  defp restore(module, previous), do: Application.put_env(:kanban, module, previous)
end
