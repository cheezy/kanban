defmodule Kanban.Attachments.Storage.Local.TreeTest do
  use ExUnit.Case, async: true

  alias Kanban.Attachments.Storage.Local.Tree

  @key "boards/12/0b9c4e2a-6f1d-4c8e-9a7b-3d2e1f0a9b8c"

  setup do
    base =
      Path.join([
        System.tmp_dir!(),
        "stride_tree_test",
        Integer.to_string(System.unique_integer([:positive]))
      ])

    File.mkdir_p!(base)
    File.chmod!(base, 0o755)
    on_exit(fn -> File.rm_rf(base) end)

    %{base: Path.expand(base)}
  end

  defp private_dir!(path) do
    File.mkdir_p!(path)
    File.chmod!(path, 0o700)
    path
  end

  defp mode(path), do: Bitwise.band(File.stat!(path).mode, 0o777)

  defp identity(path) do
    stat = File.lstat!(path)
    {stat.major_device, stat.inode}
  end

  test "staging/1 names the .staging directory under the root", %{base: base} do
    assert Tree.staging(base) == Path.join(base, ".staging")
  end

  describe "check_root/2" do
    test "accepts a directory it owns that others cannot write", %{base: base} do
      assert Tree.check_root(base, false) == :ok
    end

    test "refuses a directory others can write", %{base: base} do
      File.chmod!(base, 0o757)
      assert Tree.check_root(base, false) == {:error, :untrusted_directory}
    end

    test "follows a symlinked root only when asked to", %{base: base} do
      target = private_dir!(Path.join(base, "target"))
      link = Path.join(base, "link")
      File.ln_s!(target, link)

      assert Tree.check_root(link, true) == :ok
      assert Tree.check_root(link, false) == {:error, :symlink}
    end

    test "reports a missing root and a file", %{base: base} do
      file = Path.join(base, "file")
      File.write!(file, "x")

      assert base |> Path.join("missing") |> Tree.check_root(false) == {:error, :enoent}
      assert Tree.check_root(file, false) == {:error, :not_a_directory}
    end
  end

  describe "ensure_root/2" do
    test "creates the root and its missing ancestors 0o700, leaving existing ones alone",
         %{base: base} do
      root = Path.join([base, "a", "b", "root"])

      assert Tree.ensure_root(root, false) == :ok

      assert mode(Path.join(base, "a")) == 0o700
      assert mode(Path.join(base, "a/b")) == 0o700
      assert mode(root) == 0o700
      assert mode(base) == 0o755
    end

    test "checks a root that already exists without changing it", %{base: base} do
      root = Path.join(base, "root")
      File.mkdir_p!(root)
      File.chmod!(root, 0o755)

      assert Tree.ensure_root(root, false) == :ok
      assert mode(root) == 0o755

      File.chmod!(root, 0o775)
      assert Tree.ensure_root(root, false) == {:error, :untrusted_directory}
    end

    test "fails when an ancestor is a plain file", %{base: base} do
      base |> Path.join("file") |> File.write!("x")

      assert {:error, _reason} = base |> Path.join("file/root") |> Tree.ensure_root(false)
    end
  end

  describe "trusted_tree/3 and ensure_key_dir/3" do
    test "ensure_key_dir creates the key's directories 0o700 and trusted_tree accepts them",
         %{base: base} do
      root = Path.join(base, "root")

      assert Tree.trusted_tree(root, @key, false) == {:error, :enoent}
      assert Tree.ensure_key_dir(root, @key, false) == :ok
      assert mode(Path.join(root, "boards")) == 0o700
      assert mode(Path.join(root, "boards/12")) == 0o700
      assert Tree.trusted_tree(root, @key, false) == :ok
    end

    test "a key with no directory needs only the root", %{base: base} do
      root = private_dir!(Path.join(base, "root"))

      assert Tree.ensure_key_dir(root, "top-level-key", false) == :ok
      assert Tree.trusted_tree(root, "top-level-key", false) == :ok
    end

    test "refuses a symlinked or writable directory on the way to the key", %{base: base} do
      root = private_dir!(Path.join(base, "root"))
      elsewhere = private_dir!(Path.join(base, "elsewhere"))
      File.ln_s!(elsewhere, Path.join(root, "boards"))

      assert Tree.trusted_tree(root, @key, false) == {:error, :symlink}
      assert Tree.ensure_key_dir(root, @key, false) == {:error, :symlink}

      root |> Path.join("boards") |> File.rm!()
      boards = private_dir!(Path.join(root, "boards"))
      File.chmod!(boards, 0o777)

      assert Tree.trusted_tree(root, @key, false) == {:error, :untrusted_directory}
      assert Tree.ensure_key_dir(root, @key, false) == {:error, :untrusted_directory}
    end
  end

  describe "ensure_staging/1 and private_dir/1" do
    test "creates .staging 0o700 and returns its path", %{base: base} do
      root = private_dir!(Path.join(base, "root"))
      staging = Path.join(root, ".staging")

      assert Tree.ensure_staging(root) == {:ok, staging}
      assert mode(staging) == 0o700
      assert Tree.private_dir(staging) == :ok
      assert Tree.ensure_staging(root) == {:ok, staging}
    end

    test "refuses a .staging others can read, or one that is a symlink", %{base: base} do
      root = private_dir!(Path.join(base, "root"))
      staging = Path.join(root, ".staging")
      File.mkdir!(staging)
      File.chmod!(staging, 0o750)

      assert Tree.ensure_staging(root) == {:error, :untrusted_directory}
      assert Tree.private_dir(staging) == {:error, :untrusted_directory}

      File.rmdir!(staging)
      base |> Path.join("elsewhere") |> private_dir!() |> File.ln_s!(staging)

      assert Tree.ensure_staging(root) == {:error, :symlink}
      assert Tree.private_dir(staging) == {:error, :symlink}
    end

    test "private_dir reports a missing directory", %{base: base} do
      assert base |> Path.join("missing") |> Tree.private_dir() == {:error, :enoent}
    end
  end

  describe "file_identity/1" do
    test "is the device and inode of a regular file", %{base: base} do
      file = Path.join(base, "file")
      File.write!(file, "x")

      assert Tree.file_identity(file) == {:ok, identity(file)}
    end

    test "changes when the file is replaced under the same name", %{base: base} do
      file = Path.join(base, "file")
      File.write!(file, "x")
      {:ok, before} = Tree.file_identity(file)
      File.rename!(file, Path.join(base, "moved"))
      File.write!(file, "x")

      assert {:ok, now} = Tree.file_identity(file)
      refute now == before
    end

    test "refuses a link, a directory and a missing path", %{base: base} do
      file = Path.join(base, "file")
      File.write!(file, "x")
      link = Path.join(base, "link")
      File.ln_s!(file, link)

      assert Tree.file_identity(link) == {:error, :not_a_regular_file}
      assert Tree.file_identity(base) == {:error, :not_a_regular_file}
      assert base |> Path.join("missing") |> Tree.file_identity() == {:error, :enoent}
    end
  end

  describe "confined?/3" do
    test "a file must lie beneath the real root; a directory may be the root", %{base: base} do
      root = private_dir!(Path.join(base, "root"))
      inside = Path.join(root, "file")
      File.write!(inside, "x")
      outside = Path.join(base, "outside")
      File.write!(outside, "x")
      link = Path.join(root, "link")
      File.ln_s!(outside, link)

      assert Tree.confined?(inside, root, :file)
      assert Tree.confined?(root, root, :dir)
      refute Tree.confined?(root, root, :file)
      refute Tree.confined?(link, root, :file)
    end

    test "a sibling whose name starts with the root's is outside it", %{base: base} do
      root = private_dir!(Path.join(base, "root"))
      sibling = private_dir!(Path.join(base, "root-sibling"))
      file = Path.join(sibling, "file")
      File.write!(file, "x")

      refute Tree.confined?(file, root, :file)
    end
  end

  test "own_uid/0 is the owner of a file this process creates", %{base: base} do
    file = Path.join(base, "mine")
    File.write!(file, "x")

    assert Tree.own_uid() == {:ok, File.lstat!(file).uid}
  end
end
