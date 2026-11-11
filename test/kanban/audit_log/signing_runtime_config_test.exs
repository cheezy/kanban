defmodule Kanban.AuditLog.SigningRuntimeConfigTest do
  # Not async: these tests set OS environment variables, which are global.
  use ExUnit.Case, async: false

  alias Kanban.AuditLog.Signing

  @runtime Path.expand("../../../config/runtime.exs", __DIR__)

  @vars ~w(
    AUDIT_SIGNING_KEY AUDIT_SIGNING_KEYS_PREVIOUS AUDIT_SIGNING_KEYS_REVOKED
    DATABASE_URL SECRET_KEY_BASE ENCRYPTION_KEY DATABASE_SSL PHX_SERVER
  )

  # What the prod block needs besides the signing key; a Fly-internal
  # database host passes its plaintext-database guard.
  @prod_env %{
    "DATABASE_URL" => "ecto://user:pass@db.internal/kanban",
    "SECRET_KEY_BASE" => String.duplicate("s", 64),
    "ENCRYPTION_KEY" => "k" |> String.duplicate(32) |> Base.encode64()
  }

  @sentinel "sentinel-value-never-printed"

  @key "AUDIT_SIGNING_KEY"
  @previous "AUDIT_SIGNING_KEYS_PREVIOUS"
  @revoked "AUDIT_SIGNING_KEYS_REVOKED"

  setup do
    saved = Map.new(@vars, &{&1, System.get_env(&1)})
    Enum.each(@vars, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)
  end

  # Each read starts from none of @vars set, then sets exactly `env`. Returns
  # what runtime.exs configures for Kanban.AuditLog.Signing, or nil.
  defp read(env) do
    Enum.each(@vars, &System.delete_env/1)
    System.put_env(env)
    @runtime |> Config.Reader.read!(env: :test) |> get_in([:kanban, Signing])
  end

  # A prod read of `env` on top of @prod_env: the Signing config and what the
  # read printed to stderr.
  defp read_prod(env) do
    Enum.each(@vars, &System.delete_env/1)
    @prod_env |> Map.merge(env) |> System.put_env()

    {config, stderr} =
      ExUnit.CaptureIO.with_io(:stderr, fn ->
        Config.Reader.read!(@runtime, env: :prod, target: :host)
      end)

    {get_in(config, [:kanban, Signing]), stderr}
  end

  # The boot error for `env`. No error message may ever carry the sentinel.
  defp boot_error(env) do
    message = RuntimeError |> assert_raise(fn -> read(env) end) |> Exception.message()
    refute message =~ @sentinel
    message
  end

  defp warnings(stderr), do: length(String.split(stderr, "AUDIT_SIGNING_KEY is not set")) - 1

  defp seed, do: :crypto.strong_rand_bytes(32)

  defp public_key(seed) do
    {public_key, _private_key} = :crypto.generate_key(:eddsa, :ed25519, seed)
    public_key
  end

  defp url64(public_key), do: Base.url_encode64(public_key, padding: false)

  # PEMs come from OTP's own encoder, never from the code under test.
  defp pem(record) do
    :public_key.pem_encode([:public_key.pem_entry_encode(:PrivateKeyInfo, record)])
  end

  defp ed25519_pem(seed) do
    pem(
      {:ECPrivateKey, 1, seed, {:namedCurve, {1, 3, 101, 112}}, public_key(seed), :asn1_NOVALUE}
    )
  end

  describe "AUDIT_SIGNING_KEY" do
    test "a PEM key and the base64 seed of the same key give the same configured seed" do
      seed = seed()
      pem = ed25519_pem(seed)

      assert pem =~ "-----BEGIN PRIVATE KEY-----"
      assert read(%{@key => pem}) == [private_key: seed]
      assert read(%{@key => Base.encode64(seed)}) == [private_key: seed]
      assert read(%{@key => Base.encode64(seed, padding: false)}) == [private_key: seed]
      assert read(%{@key => "  #{Base.encode64(seed)}\n"}) == [private_key: seed]
      assert read(%{@key => String.replace(pem, "\n", "\r\n")}) == [private_key: seed]
    end

    test "a PEM pasted with literal backslash-n sequences is the same key" do
      seed = seed()
      one_line = seed |> ed25519_pem() |> String.replace("\n", "\\n")

      refute one_line =~ "\n"
      assert one_line =~ "KEY-----\\n"
      assert read(%{@key => one_line}) == [private_key: seed]
      assert read(%{@key => String.replace(one_line, "\\n", "\\r\\n")}) == [private_key: seed]
    end

    @tag :tmp_dir
    test "a key written by Signing's development key file is read back as the same key",
         %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "audit_signing_key.pem")
      key = Signing.create_dev_key(path)

      assert [private_key: seed] = read(%{@key => File.read!(path)})
      assert public_key(seed) == key.public_key
    end

    test "a malformed AUDIT_SIGNING_KEY raises naming the variable without the sentinel value" do
      thirty_one = 31 |> :crypto.strong_rand_bytes() |> Base.encode64()
      thirty_three = 33 |> :crypto.strong_rand_bytes() |> Base.encode64()

      sentinel_pem =
        "-----BEGIN PRIVATE KEY-----\n#{Base.encode64(@sentinel)}\n-----END PRIVATE KEY-----"

      for bad <- [@sentinel, thirty_one, thirty_three, sentinel_pem, "#{@sentinel}-----BEGIN"] do
        message = boot_error(%{@key => bad})

        assert message =~ "AUDIT_SIGNING_KEY must be an Ed25519 private key"
        refute message =~ bad
      end
    end

    test "an RSA or P-256 PEM in AUDIT_SIGNING_KEY is refused" do
      rsa = :public_key.generate_key({:rsa, 2048, 65_537})
      p256 = :public_key.generate_key({:namedCurve, :secp256r1})
      seed = seed()

      pkcs1_rsa = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, rsa)])
      sec1_ec = :public_key.pem_encode([:public_key.pem_entry_encode(:ECPrivateKey, p256)])

      # X25519 differs from Ed25519 in one byte of the algorithm identifier.
      x25519 =
        "-----BEGIN PRIVATE KEY-----\n" <>
          Base.encode64(Base.decode16!("302E020100300506032B656E04220420") <> seed) <>
          "\n-----END PRIVATE KEY-----\n"

      # The Ed25519 public key of a real seed is not a private key either.
      public = seed |> public_key() |> Signing.public_key_pem()

      for refused <- [pem(rsa), pem(p256), pkcs1_rsa, sec1_ec, x25519, public] do
        assert refused =~ "-----BEGIN"

        assert boot_error(%{@key => refused}) =~
                 "AUDIT_SIGNING_KEY must be an Ed25519 private key"
      end
    end

    test "a blank variable counts as unset" do
      for blank <- ["", "   ", " \n\t "] do
        assert read(%{@key => blank, @previous => blank, @revoked => blank}) == nil
      end

      assert read(%{}) == nil
      assert read(%{@previous => " , ,"}) == [previous: []]
    end
  end

  describe "AUDIT_SIGNING_KEYS_PREVIOUS and AUDIT_SIGNING_KEYS_REVOKED" do
    test "previous and revoked lists parse with whitespace, empty entries and an optional revocation date" do
      [one, two, three] = for _key <- 1..3, do: public_key(seed())

      previous = "  #{url64(one)} ,, #{Base.url_encode64(two)},\n#{url64(one)}, "
      revoked = " #{url64(three)} : 2026-11-11 ,,#{Base.url_encode64(one)},"

      assert read(%{@previous => previous}) == [previous: [one, two]]
      assert read(%{@revoked => revoked}) == [revoked: [{three, ~D[2026-11-11]}, {one, nil}]]

      seed = seed()
      env = %{@key => Base.encode64(seed), @previous => url64(one), @revoked => url64(two)}

      assert read(env) == [private_key: seed, previous: [one], revoked: [{two, nil}]]
    end

    test "a 31-byte or non-base64url list entry raises naming its variable" do
      good = url64(public_key(seed()))
      thirty_one = 31 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
      thirty_three = 33 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
      # 32 bytes whose standard base64 needs + and /, which base64url does not have.
      standard = Base.encode64(<<0xFB, 0xFF, 0xBF>> <> :binary.copy(<<0xFF>>, 29))

      assert standard =~ "+" and standard =~ "/"

      for bad <- [thirty_one, thirty_three, standard, @sentinel, "#{good}:#{@sentinel}"] do
        assert boot_error(%{@previous => "#{good},#{bad}"}) =~
                 "AUDIT_SIGNING_KEYS_PREVIOUS must be a comma-separated list"
      end

      for bad <- [thirty_one, thirty_three, standard, @sentinel] do
        assert boot_error(%{@revoked => "#{good}, #{bad}:2026-11-11"}) =~
                 "AUDIT_SIGNING_KEYS_REVOKED must be a comma-separated list"
      end

      assert read(%{@previous => good, @revoked => "#{url64(public_key(seed()))}:2026-11-11"})
    end

    test "a revoked entry with a malformed date suffix raises naming the variable" do
      good = url64(public_key(seed()))

      for date <- ["", " ", "11/11/2026", "2026-13-01", "2026-11-11T00:00:00Z", @sentinel] do
        assert boot_error(%{@revoked => "#{good}:#{date}"}) =~
                 "AUDIT_SIGNING_KEYS_REVOKED must be a comma-separated list"
      end
    end

    test "AUDIT_SIGNING_KEY with the same bytes as a previous or revoked key raises" do
      seed = seed()
      listed = url64(seed)
      other = url64(public_key(seed()))

      for key <- [Base.encode64(seed), ed25519_pem(seed)],
          lists <- [
            %{@previous => "#{other},#{listed}"},
            %{@revoked => "#{listed}:2026-11-11"},
            %{@revoked => listed}
          ] do
        message = boot_error(Map.put(lists, @key, key))

        assert message =~ "AUDIT_SIGNING_KEY holds the same 32 bytes as a key listed in"
        refute message =~ listed
        refute message =~ Base.encode64(seed)
      end

      assert read(%{@key => Base.encode64(seed), @previous => other})
    end

    test "a key listed twice in AUDIT_SIGNING_KEYS_REVOKED keeps both dates for Signing" do
      key = public_key(seed())
      listed = url64(key)

      config =
        read(%{@revoked => "#{listed},#{listed}:2026-03-03,#{listed}:2026-01-01,#{listed}"})

      assert config[:revoked] == [{key, nil}, {key, ~D[2026-03-03]}, {key, ~D[2026-01-01]}]
    end

    test "a key both previous and revoked, or a revoked current key, raises" do
      seed = seed()
      leaked = url64(public_key(seed))
      other = url64(public_key(seed()))

      both = boot_error(%{@previous => "#{other},#{leaked}", @revoked => "#{leaked}:2026-11-11"})

      assert both =~ "AUDIT_SIGNING_KEYS_PREVIOUS"
      assert both =~ "AUDIT_SIGNING_KEYS_REVOKED"

      for key <- [Base.encode64(seed), ed25519_pem(seed)] do
        current = boot_error(%{@key => key, @revoked => "#{other}, #{leaked}"})

        assert current =~ "AUDIT_SIGNING_KEY is a key that AUDIT_SIGNING_KEYS_REVOKED lists"
        refute current =~ leaked
      end

      # The current key may still be listed as previous, mid-rotation.
      assert read(%{@key => Base.encode64(seed), @previous => leaked, @revoked => other})
    end
  end

  describe "production" do
    test "prod with the key unset prints one warning naming AUDIT_SIGNING_KEY" do
      {config, stderr} = read_prod(%{})

      assert warnings(stderr) == 1
      assert stderr =~ "cannot sign audit exports"
      assert config == nil

      {config, stderr} = read_prod(%{@key => "  ", @previous => url64(public_key(seed()))})

      assert warnings(stderr) == 1
      assert [previous: [_public_key]] = config
    end

    test "prod with the key set configures it and does not warn" do
      seed = seed()

      {config, stderr} = read_prod(%{@key => Base.encode64(seed)})

      assert config == [private_key: seed]
      assert warnings(stderr) == 0
      refute stderr =~ Base.encode64(seed)
    end

    test "the warning is for production only" do
      {config, stderr} =
        ExUnit.CaptureIO.with_io(:stderr, fn -> read(%{}) end)

      assert config == nil
      assert warnings(stderr) == 0
    end

    test "a malformed key stops a production boot too" do
      error = assert_raise RuntimeError, fn -> read_prod(%{@key => @sentinel}) end

      assert Exception.message(error) =~ "AUDIT_SIGNING_KEY must be an Ed25519 private key"
      refute Exception.message(error) =~ @sentinel
    end
  end
end
