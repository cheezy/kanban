defmodule Kanban.RuntimeEncryptionKeyTest do
  # async: false — evaluates config/runtime.exs for :prod, which reads (and so
  # needs this test to set) process-wide environment variables.
  use ExUnit.Case, async: false

  @runtime Path.expand("../../config/runtime.exs", __DIR__)

  # The prod block also needs a database URL and a secret key base; a
  # Fly-internal host passes its plaintext-database guard.
  @env %{
    "DATABASE_URL" => "ecto://user:pass@db.internal/kanban",
    "SECRET_KEY_BASE" => String.duplicate("s", 64)
  }

  @touched ~w(DATABASE_URL SECRET_KEY_BASE ENCRYPTION_KEY DATABASE_SSL PHX_SERVER)

  setup do
    saved = Map.new(@touched, &{&1, System.get_env(&1)})

    on_exit(fn ->
      for {name, value} <- saved do
        if value, do: System.put_env(name, value), else: System.delete_env(name)
      end
    end)

    for name <- @touched, do: System.delete_env(name)
    System.put_env(@env)
    :ok
  end

  defp read_prod_config, do: Config.Reader.read!(@runtime, env: :prod, target: :host)

  test "reads a base64 32-byte ENCRYPTION_KEY into Kanban.Encryption's key" do
    key = :crypto.strong_rand_bytes(32)
    System.put_env("ENCRYPTION_KEY", Base.encode64(key))

    assert read_prod_config()[:kanban][Kanban.Encryption][:key] == key
  end

  test "refuses to boot without ENCRYPTION_KEY" do
    assert_raise RuntimeError, ~r/ENCRYPTION_KEY is missing/, &read_prod_config/0
  end

  test "refuses a key that is not 32 bytes or not base64" do
    for bad <- [16 |> :crypto.strong_rand_bytes() |> Base.encode64(), "not base64!", ""] do
      System.put_env("ENCRYPTION_KEY", bad)

      assert_raise RuntimeError, ~r/not 32 base64-encoded bytes/, &read_prod_config/0
    end
  end
end
