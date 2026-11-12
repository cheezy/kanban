defmodule Kanban.AuditLog.Signing.DevKeyTest do
  # async: false — one test asserts that a load logs nothing, and
  # capture_log/1 also collects what other tests running at the same time log.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Kanban.AuditLog.Signing
  alias Kanban.AuditLog.Signing.DevKey

  @moduletag :tmp_dir

  # RFC 8032 section 7.1, TEST 1: a published test vector, not a secret.
  @test1_seed Base.decode16!("9D61B19DEFFD5A60BA844AF492EC2CC44449C5697B326919703BAC031CAE7F60")
  @test1_key_id "k1-21fe31dfa154a261"

  defp seed, do: :crypto.strong_rand_bytes(32)

  defp public_key(seed) do
    {public_key, _private_key} = :crypto.generate_key(:eddsa, :ed25519, seed)
    public_key
  end

  # Key ids rather than seeds are compared, so a failed assertion never
  # prints a seed.
  defp key_id(seed), do: seed |> public_key() |> Signing.key_id()

  # The PKCS#8 PEM of a seed, built by OTP's own encoder rather than by
  # DevKey, so the tests don't check the module against itself.
  defp private_pem(seed) do
    entry = :public_key.pem_entry_encode(:PrivateKeyInfo, ed25519_record(seed))
    :public_key.pem_encode([entry])
  end

  defp ed25519_record(seed) do
    {:ECPrivateKey, 1, seed, {:namedCurve, {1, 3, 101, 112}}, public_key(seed), :asn1_NOVALUE}
  end

  defp mode(path), do: Bitwise.band(File.stat!(path).mode, 0o777)

  defp run_on_go(parent, fun) do
    send(parent, {:ready, self()})

    receive do
      :go -> fun.()
    end
  end

  # Runs `fun` in `count` processes that all start at the same moment.
  defp race(count, fun) do
    parent = self()

    tasks = for _task <- 1..count, do: Task.async(fn -> run_on_go(parent, fun) end)

    pids =
      for _task <- tasks do
        assert_receive {:ready, pid}
        pid
      end

    Enum.each(pids, &send(&1, :go))
    Task.await_many(tasks, 30_000)
  end

  test "dev_key_seed/1 creates the key file 0600 on first load and reads it back after",
       %{tmp_dir: tmp_dir} do
    dir = Path.join(tmp_dir, "not-there-yet")
    path = Path.join(dir, "audit_signing_key.pem")

    refute File.exists?(dir)
    key_id = key_id(DevKey.dev_key_seed(path))
    pem = File.read!(path)

    assert mode(path) == 0o600
    assert File.ls!(dir) == ["audit_signing_key.pem"]
    assert [{:PrivateKeyInfo, _der, :not_encrypted}] = :public_key.pem_decode(pem)

    assert key_id(DevKey.dev_key_seed(path)) == key_id
    assert File.read!(path) == pem
    assert File.ls!(dir) == ["audit_signing_key.pem"]
  end

  test "a key directory that cannot be listed still loads the key and skips the staging cleanup",
       %{tmp_dir: tmp_dir} do
    directory = Path.join(tmp_dir, "search-only")
    File.mkdir!(directory)
    path = Path.join(directory, "audit_signing_key.pem")
    File.write!(path, private_pem(@test1_seed))
    File.chmod!(path, 0o600)
    File.chmod!(directory, 0o100)
    on_exit(fn -> File.chmod(directory, 0o700) end)

    # Root lists any directory, so there is nothing to check when running as root.
    if match?({:error, :eacces}, File.ls(directory)) do
      assert key_id(DevKey.dev_key_seed(path)) == @test1_key_id
      assert mode(path) == 0o600
    end
  end

  # The bytes are pinned, not only the key: the file is the PEM OTP writes,
  # less the blank line OTP ends it with, and `openssl genpkey` writes the same.
  test "the key file DevKey writes is OTP's PEM for the same seed, with one final newline",
       %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "audit_signing_key.pem")

    seed = DevKey.create_dev_key_seed(path)

    assert File.read!(path) == (seed |> private_pem() |> String.trim_trailing()) <> "\n"
  end

  test "a dev key file that is a symlink is refused, even to a valid key", %{tmp_dir: tmp_dir} do
    target = Path.join(tmp_dir, "elsewhere.pem")
    path = Path.join(tmp_dir, "audit_signing_key.pem")
    File.write!(target, private_pem(@test1_seed))
    File.ln_s!(target, path)

    error = assert_raise RuntimeError, fn -> DevKey.dev_key_seed(path) end

    assert Exception.message(error) =~ path
    assert Exception.message(error) =~ "is not a regular file"
    assert File.read_link!(path) == target
    assert File.read!(target) == private_pem(@test1_seed)
  end

  test "a dev key file the app cannot read raises naming the path and is not replaced",
       %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "audit_signing_key.pem")
    File.write!(path, private_pem(@test1_seed))
    File.chmod!(path, 0o000)
    on_exit(fn -> File.chmod(path, 0o600) end)

    # Root reads any file, so there is nothing to check when running as root.
    if match?({:error, :eacces}, File.read(path)) do
      error = assert_raise RuntimeError, fn -> DevKey.dev_key_seed(path) end

      assert Exception.message(error) =~ path
      assert Exception.message(error) =~ "cannot be read (eacces)"
      assert mode(path) == 0o000
      assert File.ls!(tmp_dir) == ["audit_signing_key.pem"]
    end
  end

  test "a dev key path that cannot be created raises naming the path", %{tmp_dir: tmp_dir} do
    blocker = Path.join(tmp_dir, "a-file")
    File.write!(blocker, "")
    path = Path.join(blocker, "audit_signing_key.pem")

    error = assert_raise RuntimeError, fn -> DevKey.dev_key_seed(path) end

    assert Exception.message(error) =~ path
    assert Exception.message(error) =~ "cannot be reached (enotdir)"
    assert Exception.message(error) =~ "did not create a key there"
    refute Exception.message(error) =~ "did not replace"
    assert File.read!(blocker) == ""
  end

  test "a dev key directory that cannot be written raises without naming a file to fix",
       %{tmp_dir: tmp_dir} do
    directory = Path.join(tmp_dir, "read-only")
    File.mkdir!(directory)
    File.chmod!(directory, 0o500)
    on_exit(fn -> File.chmod(directory, 0o700) end)
    path = Path.join(directory, "audit_signing_key.pem")

    # Root writes anywhere, so there is nothing to check when running as root.
    probe = Path.join(directory, "probe")

    if match?({:error, :eacces}, File.write(probe, "")) do
      error = assert_raise RuntimeError, fn -> DevKey.dev_key_seed(path) end

      assert Exception.message(error) =~ path
      assert Exception.message(error) =~ "cannot be created (eacces)"
      assert Exception.message(error) =~ "did not create a key there"
      refute Exception.message(error) =~ "did not replace"
      assert File.ls!(directory) == []
    end
  end

  test "blank lines around the PEM are accepted and other text is refused",
       %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "audit_signing_key.pem")
    File.write!(path, "\n \r\n" <> private_pem(@test1_seed) <> "\n\n")
    File.chmod!(path, 0o600)

    assert key_id(DevKey.dev_key_seed(path)) == @test1_key_id

    File.write!(path, "a note\n" <> private_pem(@test1_seed))

    error = assert_raise RuntimeError, fn -> DevKey.dev_key_seed(path) end
    assert Exception.message(error) =~ "is not an Ed25519 private key"
  end

  test "a dev key file other users can read is set to 0600 and a warning is logged",
       %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "audit_signing_key.pem")
    File.write!(path, private_pem(@test1_seed))
    File.chmod!(path, 0o644)

    log = capture_log(fn -> assert key_id(DevKey.dev_key_seed(path)) == @test1_key_id end)

    assert mode(path) == 0o600
    assert log =~ path
    assert log =~ "mode 644"
    assert log =~ "Stride set it to 600"

    assert capture_log(fn -> DevKey.dev_key_seed(path) end) == ""
    assert mode(path) == 0o600
  end

  # W2724: the user-immutable flag makes chmod fail for the file's own
  # owner. chflags is BSD and macOS only, so the test is skipped elsewhere.
  @tag skip: System.find_executable("chflags") == nil && "needs chflags"
  test "a dev key file other users can read whose chmod fails is used and logged",
       %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "audit_signing_key.pem")
    File.write!(path, private_pem(@test1_seed))
    File.chmod!(path, 0o640)
    assert {_output, 0} = System.cmd("chflags", ["uchg", path])
    on_exit(fn -> System.cmd("chflags", ["nouchg", path]) end)

    log = capture_log(fn -> assert key_id(DevKey.dev_key_seed(path)) == @test1_key_id end)

    assert mode(path) == 0o640
    assert log =~ path
    assert log =~ "mode 640"
    assert log =~ "Stride could not set it to 600 (eperm)"
  end

  test "a stale staging directory is removed on load and a fresh one is kept",
       %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "audit_signing_key.pem")
    [stale, stale_empty, fresh] = for name <- ~w(old oldempty new), do: "#{path}.tmp-#{name}"
    Enum.each([stale, stale_empty, fresh], &File.mkdir!/1)
    stale |> Path.join("key") |> File.write!(private_pem(seed()))
    fresh |> Path.join("key") |> File.write!(private_pem(seed()))
    an_hour_ago = System.os_time(:second) - 3600
    Enum.each([stale, stale_empty], &File.touch!(&1, an_hour_ago))
    planted = "#{path}.tmp-link"
    File.ln_s!(stale, planted)

    assert "k1-" <> _hex = key_id(DevKey.dev_key_seed(path))

    assert tmp_dir |> File.ls!() |> Enum.sort() == [
             "audit_signing_key.pem",
             "audit_signing_key.pem.tmp-link",
             "audit_signing_key.pem.tmp-new"
           ]

    assert File.ls!(fresh) == ["key"]
  end

  test "create_dev_key_seed/1 never replaces a key file that is already there", %{
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "audit_signing_key.pem")
    File.write!(path, private_pem(@test1_seed))

    assert key_id(DevKey.create_dev_key_seed(path)) == @test1_key_id
    assert File.read!(path) == private_pem(@test1_seed)
    assert File.ls!(tmp_dir) == ["audit_signing_key.pem"]
  end

  test "create_dev_key_seed/1 never writes through a planted symlink", %{tmp_dir: tmp_dir} do
    target = Path.join(tmp_dir, "elsewhere.pem")
    path = Path.join(tmp_dir, "audit_signing_key.pem")
    File.ln_s!(target, path)

    assert_raise RuntimeError, ~r/is not a regular file/, fn ->
      DevKey.create_dev_key_seed(path)
    end

    refute File.exists?(target)
    assert tmp_dir |> File.ls!() |> Enum.sort() == ["audit_signing_key.pem"]
  end

  test "two concurrent first uses of the dev key file end with the same key",
       %{tmp_dir: tmp_dir} do
    # Every process stages its own key and tries to link it into place, as
    # two BEAM processes starting together would.
    path = Path.join(tmp_dir, "audit_signing_key.pem")

    key_ids = race(16, fn -> path |> DevKey.create_dev_key_seed() |> key_id() end)

    assert [key_id] = Enum.uniq(key_ids)
    assert mode(path) == 0o600
    assert File.ls!(tmp_dir) == ["audit_signing_key.pem"]

    assert key_id(DevKey.dev_key_seed(path)) == key_id
  end
end
