defmodule Kanban.AuditLog.SigningTest do
  # async: false — tests here replace the application config of
  # Kanban.AuditLog.Signing, which is global, and some erase its
  # :persistent_term cache.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Kanban.AuditLog.Signing

  # RFC 8032 section 7.1, TEST 1: a published test vector, not a secret.
  @test1_seed Base.decode16!("9D61B19DEFFD5A60BA844AF492EC2CC44449C5697B326919703BAC031CAE7F60")
  @test1_public Base.decode16!("D75A980182B10AB7D54BFED3C964073A0EE172F3DAA62325AF021A68F707511A")
  @test1_key_id "k1-21fe31dfa154a261"
  @test1_fingerprint "21fe31dfa154a261626bf854046fd2271b7bed4b6abe45aa58877ef47f9721b9"
  @test1_signature Base.decode16!(
                     "E5564300C360AC729086E2CC806E828A84877F1EB8E5D974D873E06522490155" <>
                       "5FB8821590A33BACC61E39701CF9B46BD25BF5F0595BBE24655141438E7A100B"
                   )
  @test1_public_pem """
  -----BEGIN PUBLIC KEY-----
  MCowBQYDK2VwAyEA11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo=
  -----END PUBLIC KEY-----
  """

  setup do
    saved = Application.fetch_env(:kanban, Signing)

    on_exit(fn ->
      case saved do
        {:ok, config} -> Application.put_env(:kanban, Signing, config)
        :error -> Application.delete_env(:kanban, Signing)
      end
    end)
  end

  defp configure(config), do: Application.put_env(:kanban, Signing, config)

  defp seed, do: :crypto.strong_rand_bytes(32)

  defp public_key(seed) do
    {public_key, _private_key} = :crypto.generate_key(:eddsa, :ed25519, seed)
    public_key
  end

  defp key_id(seed), do: seed |> public_key() |> Signing.key_id()

  # The PKCS#8 PEM of a seed, built by OTP's own encoder rather than by
  # Signing, so the tests don't check the module against itself.
  defp private_pem(seed) do
    entry = :public_key.pem_entry_encode(:PrivateKeyInfo, ed25519_record(seed))
    :public_key.pem_encode([entry])
  end

  defp ed25519_record(seed) do
    {:ECPrivateKey, 1, seed, {:namedCurve, {1, 3, 101, 112}}, public_key(seed), :asn1_NOVALUE}
  end

  defp rsa_pem do
    key = :public_key.generate_key({:rsa, 2048, 65_537})
    :public_key.pem_encode([:public_key.pem_entry_encode(:PrivateKeyInfo, key)])
  end

  # Uses the development key file at `path`, forgetting its cached key when
  # the test ends.
  defp use_dev_file(path) do
    term = dev_file_term(path)
    on_exit(fn -> :persistent_term.erase(term) end)
    configure(fallback: :dev_file, dev_key_path: path)
  end

  defp dev_file_term(path), do: {Signing, {:dev_file, path}}

  # What a restart does to the cached development key.
  defp forget_dev_key(path) do
    term = dev_file_term(path)

    assert <<_::binary-size(32)>> = :persistent_term.get(term, nil)
    :persistent_term.erase(term)
    assert :persistent_term.get(term, nil) == nil
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

  describe "sign/1 and verify/3" do
    test "sign/1 then verify/3 round trip returns true and the signature is 64 bytes" do
      seed = seed()
      configure(private_key: seed)

      assert {:ok, %{signature: signature, key_id: key_id}} = Signing.sign("t.42.body")

      assert byte_size(signature) == 64
      assert key_id == key_id(seed)
      assert Signing.verify("t.42.body", signature, key_id)
      assert Signing.enabled?()
    end

    test "sign/1 with the RFC 8032 TEST 1 key gives the RFC signature" do
      configure(private_key: @test1_seed)

      assert Signing.sign("") == {:ok, %{signature: @test1_signature, key_id: @test1_key_id}}
    end

    test "verify/3 is false when one byte of the message or of the signature changes" do
      configure(private_key: seed())
      {:ok, %{signature: signature, key_id: key_id}} = Signing.sign("t.42.body")
      <<first, rest::binary>> = signature

      assert Signing.verify("t.42.body", signature, key_id)
      refute Signing.verify("t.43.body", signature, key_id)
      refute Signing.verify("t.42.body", <<Bitwise.bxor(first, 1), rest::binary>>, key_id)
    end

    test "verify/3 is false for an unknown key id and for anything that is not a signature" do
      configure(private_key: seed())
      {:ok, %{signature: signature, key_id: key_id}} = Signing.sign("body")

      refute Signing.verify("body", signature, "k1-0000000000000000")
      refute Signing.verify("body", signature, nil)
      refute Signing.verify("body", binary_part(signature, 0, 63), key_id)
      refute Signing.verify("body", :not_a_signature, key_id)
    end

    test "verify/3 accepts a signature made by a previous key and iodata for the message" do
      retired = seed()
      configure(private_key: retired)
      {:ok, %{signature: signature, key_id: key_id}} = Signing.sign("t.42.body")

      configure(private_key: seed(), previous: [public_key(retired)])

      assert Signing.verify(["t", ?., "42", [".", "body"]], signature, key_id)
    end

    test "sign/1 over iodata equals sign/1 over the same binary" do
      configure(private_key: seed())

      assert {:ok, %{signature: <<_::binary-size(64)>>}} = signed = Signing.sign("t.42.body")
      assert Signing.sign(["t", ?., ["42", "."], ~c"body"]) == signed
      refute Signing.sign("t.42.bodx") == signed
    end

    test "with fallback none and no key, enabled?/0 is false and sign/1 returns not_configured" do
      for config <- [[fallback: :none], [], [private_key: nil, previous: [@test1_public]]] do
        configure(config)

        refute Signing.enabled?()
        assert Signing.sign("body") == {:error, :not_configured}
        assert Signing.current_key() == nil
        assert Signing.published_keys().current == nil
      end
    end

    test "a private key that is not 32 bytes raises without showing it" do
      configure(private_key: "sentinel-value-never-printed")

      error = assert_raise ArgumentError, fn -> Signing.sign("body") end

      assert Exception.message(error) =~ ":private_key must be a 32-byte"
      refute Exception.message(error) =~ "sentinel"
    end
  end

  describe "a configuration that would expose the private key" do
    test "a private key also listed as a previous or revoked key raises without showing it" do
      seed = String.duplicate("S", 32)

      for lists <- [[previous: [seed]], [revoked: [{seed, nil}]], [revoked: [seed]]] do
        configure([private_key: seed] ++ lists)

        for call <- [&Signing.enabled?/0, &Signing.published_keys/0, fn -> Signing.sign("m") end] do
          error = assert_raise ArgumentError, call

          assert Exception.message(error) =~ ":previous or :revoked"
          refute Exception.message(error) =~ "SSSS"
        end
      end
    end

    test "a config that is not a keyword list raises without the seed in its stack frames" do
      configure(%{private_key: String.duplicate("S", 32)})

      for call <- [&Signing.enabled?/0, &Signing.published_keys/0, fn -> Signing.sign("m") end] do
        {error, stacktrace} =
          try do
            call.()
          rescue
            error -> {error, __STACKTRACE__}
          end

        assert %ArgumentError{} = error
        assert Exception.message(error) =~ "must be a keyword list"
        refute Exception.format(:error, error, stacktrace) =~ "SSSS"
      end
    end
  end

  describe "guard_seed/1" do
    test "a failing :crypto call is raised again as a fixed message without its frames" do
      # 31 bytes is not an Ed25519 seed, so :crypto refuses it.
      not_a_seed = :binary.copy(<<0xA7>>, 31)

      {error, stacktrace} =
        try do
          Signing.guard_seed(fn -> :crypto.generate_key(:eddsa, :ed25519, not_a_seed) end)
        rescue
          error -> {error, __STACKTRACE__}
        end

      assert %RuntimeError{} = error
      assert Exception.message(error) =~ "The key is not shown here"
      refute Enum.any?(stacktrace, &match?({:crypto, _function, _arity, _location}, &1))
      refute Exception.format(:error, error, stacktrace) =~ "167, 167"

      assert Signing.guard_seed(fn -> :unchanged end) == :unchanged
    end
  end

  describe "key id and fingerprint" do
    test "key id and fingerprint known answer for the RFC 8032 TEST 1 public key" do
      assert Signing.key_id(@test1_public) == @test1_key_id
      assert Signing.fingerprint(@test1_public) == @test1_fingerprint

      configure(private_key: @test1_seed)

      assert Signing.current_key() == %{
               key_id: @test1_key_id,
               fingerprint: @test1_fingerprint,
               public_key: @test1_public
             }
    end

    test "inspect of current_key/0 contains no private seed bytes" do
      seed = seed()
      configure(private_key: seed, previous: [@test1_public])

      key = Signing.current_key()
      {:ok, signed} = Signing.sign("body")

      assert key |> Map.keys() |> Enum.sort() == [:fingerprint, :key_id, :public_key]

      for term <- [key, signed, Signing.published_keys(), Signing.find_published(key.key_id)] do
        assert term |> :erlang.term_to_binary() |> :binary.match(seed) == :nomatch
        refute inspect(term, limit: :infinity) =~ inspect(seed, limit: :infinity)
        refute inspect(term, limit: :infinity) =~ Base.encode64(seed)
      end
    end
  end

  describe "the ephemeral test key" do
    test "the ephemeral test key is stable across calls in one run" do
      configure(fallback: :ephemeral)

      key = Signing.current_key()

      assert %{key_id: "k1-" <> _hex, public_key: <<_::binary-size(32)>>} = key
      assert Signing.current_key() == key
      assert {:ok, %{key_id: key_id}} = Signing.sign("body")
      assert key_id == key.key_id
      assert Signing.enabled?()
    end

    test "concurrent first uses of the ephemeral key end with one key" do
      term = {Signing, :ephemeral}
      saved = :persistent_term.get(term, nil)

      on_exit(fn ->
        if saved, do: :persistent_term.put(term, saved), else: :persistent_term.erase(term)
      end)

      configure(fallback: :ephemeral)

      for _round <- 1..6 do
        :persistent_term.erase(term)
        keys = race(50, &Signing.current_key/0)

        assert [%{key_id: "k1-" <> _hex}] = Enum.uniq(keys)
      end
    end
  end

  describe "the development key file" do
    @describetag :tmp_dir

    test "dev key file is created 0600 on first use and reused on the next", %{tmp_dir: tmp_dir} do
      dir = Path.join(tmp_dir, "not-there-yet")
      path = Path.join(dir, "audit_signing_key.pem")
      use_dev_file(path)

      refute File.exists?(dir)
      key = Signing.current_key()
      pem = File.read!(path)

      assert mode(path) == 0o600
      assert File.ls!(dir) == ["audit_signing_key.pem"]
      assert [{:PrivateKeyInfo, _der, :not_encrypted}] = :public_key.pem_decode(pem)
      assert Signing.enabled?()

      # A restart: nothing is cached, and the key comes back from the file.
      forget_dev_key(path)

      assert Signing.current_key() == key
      assert File.read!(path) == pem
      assert File.ls!(dir) == ["audit_signing_key.pem"]
    end

    test "the dev key file is read, not remembered: another key in it is the key in use",
         %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "audit_signing_key.pem")
      use_dev_file(path)
      first = Signing.current_key()

      File.write!(path, private_pem(@test1_seed))
      forget_dev_key(path)

      refute Signing.current_key() == first
      assert Signing.current_key().key_id == @test1_key_id
      assert Signing.sign("") == {:ok, %{signature: @test1_signature, key_id: @test1_key_id}}
    end

    test "a malformed dev key file raises naming the path and is not replaced",
         %{tmp_dir: tmp_dir} do
      truncated = @test1_seed |> private_pem() |> binary_part(0, 60)

      for {name, contents} <- [{"truncated", truncated}, {"empty", ""}, {"rsa", rsa_pem()}] do
        path = Path.join(tmp_dir, "#{name}.pem")
        File.write!(path, contents)
        use_dev_file(path)

        error = assert_raise RuntimeError, fn -> Signing.current_key() end

        assert Exception.message(error) =~ path
        assert Exception.message(error) =~ "is not an Ed25519 private key"
        assert File.read!(path) == contents
        assert_raise RuntimeError, fn -> Signing.sign("body") end
      end

      assert tmp_dir |> File.ls!() |> Enum.sort() == ["empty.pem", "rsa.pem", "truncated.pem"]
    end

    test "a dev key file that is a symlink is refused, even to a valid key", %{tmp_dir: tmp_dir} do
      target = Path.join(tmp_dir, "elsewhere.pem")
      path = Path.join(tmp_dir, "audit_signing_key.pem")
      File.write!(target, private_pem(@test1_seed))
      File.ln_s!(target, path)
      use_dev_file(path)

      error = assert_raise RuntimeError, fn -> Signing.current_key() end

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
      use_dev_file(path)

      # Root reads any file, so there is nothing to check when running as root.
      if match?({:error, :eacces}, File.read(path)) do
        error = assert_raise RuntimeError, fn -> Signing.current_key() end

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
      use_dev_file(path)

      error = assert_raise RuntimeError, fn -> Signing.current_key() end

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
      use_dev_file(path)

      # Root writes anywhere, so there is nothing to check when running as root.
      probe = Path.join(directory, "probe")

      if match?({:error, :eacces}, File.write(probe, "")) do
        error = assert_raise RuntimeError, fn -> Signing.current_key() end

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
      use_dev_file(path)

      assert Signing.current_key().key_id == @test1_key_id

      forget_dev_key(path)
      File.write!(path, "a note\n" <> private_pem(@test1_seed))

      error = assert_raise RuntimeError, fn -> Signing.current_key() end
      assert Exception.message(error) =~ "is not an Ed25519 private key"
    end

    test "a dev key file other users can read is set to 0600 and a warning is logged",
         %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "audit_signing_key.pem")
      File.write!(path, private_pem(@test1_seed))
      File.chmod!(path, 0o644)
      use_dev_file(path)

      log = capture_log(fn -> assert Signing.current_key().key_id == @test1_key_id end)

      assert mode(path) == 0o600
      assert log =~ path
      assert log =~ "mode 644"
      assert log =~ "Stride set it to 600"

      forget_dev_key(path)
      assert capture_log(fn -> Signing.current_key() end) == ""
      assert mode(path) == 0o600
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
      use_dev_file(path)

      assert %{key_id: "k1-" <> _hex} = Signing.current_key()

      assert tmp_dir |> File.ls!() |> Enum.sort() == [
               "audit_signing_key.pem",
               "audit_signing_key.pem.tmp-link",
               "audit_signing_key.pem.tmp-new"
             ]

      assert File.ls!(fresh) == ["key"]
    end

    test "the dev file fallback without a path raises" do
      configure(fallback: :dev_file)

      assert_raise ArgumentError, ~r/:dev_key_path/, fn -> Signing.current_key() end
    end

    test "create_dev_key/1 never replaces a key file that is already there", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "audit_signing_key.pem")
      File.write!(path, private_pem(@test1_seed))

      assert Signing.create_dev_key(path).key_id == @test1_key_id
      assert File.read!(path) == private_pem(@test1_seed)
      assert File.ls!(tmp_dir) == ["audit_signing_key.pem"]
    end

    test "create_dev_key/1 never writes through a planted symlink", %{tmp_dir: tmp_dir} do
      target = Path.join(tmp_dir, "elsewhere.pem")
      path = Path.join(tmp_dir, "audit_signing_key.pem")
      File.ln_s!(target, path)

      assert_raise RuntimeError, ~r/is not a regular file/, fn -> Signing.create_dev_key(path) end

      refute File.exists?(target)
      assert tmp_dir |> File.ls!() |> Enum.sort() == ["audit_signing_key.pem"]
    end

    test "two concurrent first uses of the dev key file end with the same key",
         %{tmp_dir: tmp_dir} do
      # Every process stages its own key and tries to link it into place, as
      # two BEAM processes starting together would.
      path = Path.join(tmp_dir, "audit_signing_key.pem")

      keys = race(16, fn -> Signing.create_dev_key(path) end)

      assert [%{key_id: key_id}] = Enum.uniq(keys)
      assert mode(path) == 0o600
      assert File.ls!(tmp_dir) == ["audit_signing_key.pem"]

      use_dev_file(path)
      assert Signing.current_key().key_id == key_id
    end

    test "concurrent first uses through the fallback end with the same key",
         %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "audit_signing_key.pem")
      use_dev_file(path)

      keys = race(16, &Signing.current_key/0)

      assert [%{key_id: key_id}] = Enum.uniq(keys)
      assert File.ls!(tmp_dir) == ["audit_signing_key.pem"]

      forget_dev_key(path)
      assert Signing.current_key().key_id == key_id
    end

    test "a dev key that has been revoked does not sign and is not published",
         %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "audit_signing_key.pem")
      File.write!(path, private_pem(@test1_seed))
      use_dev_file(path)
      assert Signing.enabled?()

      configure(fallback: :dev_file, dev_key_path: path, revoked: [{@test1_public, nil}])

      refute Signing.enabled?()
      assert Signing.sign("body") == {:error, :not_configured}
      assert Signing.current_key() == nil
      assert Signing.find_published(@test1_key_id) == {:error, :not_found}
      refute Signing.verify("", @test1_signature, @test1_key_id)

      assert Signing.published_keys() == %{
               current: nil,
               previous: [],
               revoked: [%{key_id: @test1_key_id, revoked_on: nil}]
             }
    end
  end

  describe "published_keys/0 and find_published/1" do
    test "published_keys/0 lists current, previous and revoked ids with dates" do
      [current, retired, leaked, leaked_undated] = for _key <- 1..4, do: seed()

      configure(
        private_key: current,
        previous: [public_key(retired), @test1_public, public_key(retired), public_key(current)],
        revoked: [{public_key(leaked), ~D[2026-11-11]}, {public_key(leaked_undated), nil}]
      )

      published = Signing.published_keys()

      assert published.current == Signing.current_key()
      assert published.current.public_key == public_key(current)

      assert published.previous == [
               %{
                 key_id: key_id(retired),
                 fingerprint: retired |> public_key() |> Signing.fingerprint(),
                 public_key: public_key(retired)
               },
               %{
                 key_id: @test1_key_id,
                 fingerprint: @test1_fingerprint,
                 public_key: @test1_public
               }
             ]

      assert published.revoked == [
               %{key_id: key_id(leaked), revoked_on: ~D[2026-11-11]},
               %{key_id: key_id(leaked_undated), revoked_on: nil}
             ]
    end

    test "a revoked entry given as a bare key still revokes it" do
      leaked = seed()
      configure(private_key: leaked, revoked: [public_key(leaked), :not_a_key, {1, 2, 3}])

      refute Signing.enabled?()
      assert Signing.sign("body") == {:error, :not_configured}
      assert Signing.published_keys().revoked == [%{key_id: key_id(leaked), revoked_on: nil}]
    end

    test "a key revoked twice keeps its first place and its earliest date" do
      [first, second] = for _key <- 1..2, do: public_key(seed())

      configure(
        revoked: [
          {first, nil},
          {second, ~D[2026-02-02]},
          {first, ~D[2026-03-03]},
          first,
          {first, ~D[2026-01-01]},
          {second, "not a date"}
        ]
      )

      assert Signing.published_keys().revoked == [
               %{key_id: Signing.key_id(first), revoked_on: ~D[2026-01-01]},
               %{key_id: Signing.key_id(second), revoked_on: ~D[2026-02-02]}
             ]
    end

    test "a revoked key is never a current or a previous key" do
      leaked = seed()

      configure(
        private_key: leaked,
        previous: [public_key(leaked), @test1_public],
        revoked: [{@test1_public, ~D[2026-11-11]}, {public_key(leaked), nil}]
      )

      refute Signing.enabled?()
      assert Signing.sign("body") == {:error, :not_configured}

      assert Signing.published_keys() == %{
               current: nil,
               previous: [],
               revoked: [
                 %{key_id: @test1_key_id, revoked_on: ~D[2026-11-11]},
                 %{key_id: key_id(leaked), revoked_on: nil}
               ]
             }
    end

    test "find_published/1 finds current and previous keys, not revoked or unknown ids" do
      [current, leaked] = [seed(), seed()]

      configure(
        private_key: current,
        previous: [@test1_public, public_key(leaked)],
        revoked: [{public_key(leaked), ~D[2026-11-11]}]
      )

      assert current |> key_id() |> Signing.find_published() ==
               {:ok, Signing.current_key()}

      assert {:ok, %{public_key: @test1_public, fingerprint: @test1_fingerprint}} =
               Signing.find_published(@test1_key_id)

      assert leaked |> key_id() |> Signing.find_published() == {:error, :not_found}
      assert Signing.find_published("k1-0000000000000000") == {:error, :not_found}
      assert Signing.find_published(nil) == {:error, :not_found}
      assert Signing.find_published(["k1-21fe31dfa154a261"]) == {:error, :not_found}
    end
  end

  describe "public_key_pem/1" do
    test "public_key_pem/1 decodes with :public_key.pem_decode back to the 32 bytes" do
      public_key = public_key(seed())

      assert [{:SubjectPublicKeyInfo, der, :not_encrypted}] =
               public_key |> Signing.public_key_pem() |> :public_key.pem_decode()

      assert binary_part(der, byte_size(der) - 32, 32) == public_key
      assert byte_size(der) == 44
      assert Signing.public_key_pem(@test1_public) == @test1_public_pem
    end

    @tag :tmp_dir
    test "openssl reads public_key_pem/1 and agrees on the key id", %{tmp_dir: tmp_dir} do
      # Skipped where there is no openssl on the PATH.
      if openssl = System.find_executable("openssl") do
        public_key = public_key(seed())
        pem_path = Path.join(tmp_dir, "public.pem")
        File.write!(pem_path, Signing.public_key_pem(public_key))

        assert {der, 0} = System.cmd(openssl, ~w(pkey -pubin -in #{pem_path} -outform DER))
        raw = binary_part(der, byte_size(der) - 32, 32)

        assert raw == public_key

        assert "k1-" <>
                 (:sha256
                  |> :crypto.hash(raw)
                  |> Base.encode16(case: :lower)
                  |> binary_part(0, 16)) ==
                 Signing.key_id(public_key)
      end
    end
  end
end
