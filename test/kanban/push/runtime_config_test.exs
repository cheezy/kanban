defmodule Kanban.Push.RuntimeConfigTest do
  # The native push block of config/runtime.exs runs only in production, so it
  # is evaluated here on its own: the block is cut out of the file, written to
  # a temporary config file after the attachments_value helper it uses, and
  # read with Config.Reader for env :prod. It sets environment variables, so
  # the module is not async; every variable it sets is removed afterwards.
  use ExUnit.Case, async: false

  @runtime Path.expand("../../../config/runtime.exs", __DIR__)
  @start "# Native push credentials (W2770"
  @finish "# End of the native push credentials block"
  @helper "attachments_value = fn name ->"

  @names ~w(APNS_KEY APNS_KEY_ID APNS_TEAM_ID APNS_TOPIC FCM_PROJECT_ID FCM_SERVICE_ACCOUNT_JSON)

  setup do
    saved = Map.new(@names, &{&1, System.get_env(&1)})
    Enum.each(@names, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    path = Path.join(System.tmp_dir!(), "push_runtime_#{System.unique_integer([:positive])}.exs")
    File.write!(path, block_script())
    on_exit(fn -> File.rm(path) end)

    %{path: path}
  end

  # The push block, preceded by the attachments_value helper it calls, both
  # cut from config/runtime.exs itself so the test never runs a stale copy.
  defp block_script do
    source = File.read!(@runtime)
    [_before, rest] = String.split(source, @start, parts: 2)
    [block, _after] = String.split(rest, @finish, parts: 2)

    [_before, helper_rest] = String.split(source, @helper, parts: 2)
    [helper_body, _after] = String.split(helper_rest, "\nend\n", parts: 2)

    """
    import Config

    #{@helper}#{helper_body}
    end

    #{@start}#{block}
    """
  end

  defp read(path), do: path |> Config.Reader.read!(env: :prod) |> Keyword.get(:kanban, [])

  # A real, freshly generated P-256 key in the PKCS#8 PEM shape of an APNs .p8
  # file. It is made in the test and never leaves it.
  defp p8_pem do
    key = :public_key.generate_key({:namedCurve, :secp256r1})
    der = :public_key.der_encode(:PrivateKeyInfo, key)
    :public_key.pem_encode([{:PrivateKeyInfo, der, :not_encrypted}])
  end

  defp put_apns(overrides \\ %{}) do
    %{
      "APNS_KEY" => p8_pem(),
      "APNS_KEY_ID" => "ABC1234567",
      "APNS_TEAM_ID" => "DEF1234567",
      "APNS_TOPIC" => "com.example.stride"
    }
    |> Map.merge(overrides)
    |> Enum.each(fn {name, value} -> System.put_env(name, value) end)
  end

  @service_account ~s({"type":"service_account","private_key":"fake","client_email":"push@example.test"})

  test "with no push variables set nothing is configured", %{path: path} do
    config = read(path)

    refute Keyword.has_key?(config, Kanban.Push.APNs)
    refute Keyword.has_key?(config, Kanban.Push.FCM)
  end

  test "a full APNs set configures the APNs adapter from the environment", %{path: path} do
    put_apns()

    apns = path |> read() |> Keyword.fetch!(Kanban.Push.APNs)

    assert apns[:key_identifier] == "ABC1234567"
    assert apns[:team_id] == "DEF1234567"
    assert apns[:topic] == "com.example.stride"
    assert apns[:key] =~ "-----BEGIN PRIVATE KEY-----"
  end

  test "an APNs key pasted on one line with \\n is turned back into a PEM", %{path: path} do
    put_apns(%{"APNS_KEY" => String.replace(p8_pem(), "\n", "\\n")})

    apns = path |> read() |> Keyword.fetch!(Kanban.Push.APNs)

    assert [{:PrivateKeyInfo, _der, :not_encrypted}] = :public_key.pem_decode(apns[:key])
  end

  test "a partial APNs set stops the boot and names what is missing", %{path: path} do
    System.put_env("APNS_KEY_ID", "ABC1234567")

    error = assert_raise RuntimeError, fn -> read(path) end
    assert error.message =~ "APNS_KEY, APNS_TEAM_ID, APNS_TOPIC is not set"
  end

  test "an APNs key that is not a .p8 key stops the boot without printing it", %{path: path} do
    put_apns(%{"APNS_KEY" => "not-a-key-value"})

    error = assert_raise RuntimeError, fn -> read(path) end
    assert error.message =~ "APNS_KEY must be the contents of an APNs .p8 auth key file"
    refute error.message =~ "not-a-key-value"
  end

  test "a malformed key id or team id stops the boot", %{path: path} do
    put_apns(%{"APNS_TEAM_ID" => "team"})

    error = assert_raise RuntimeError, fn -> read(path) end
    assert error.message =~ "APNS_TEAM_ID must be 10 capital letters and digits"
  end

  test "a full FCM set configures the FCM adapter with the decoded account", %{path: path} do
    System.put_env("FCM_PROJECT_ID", "stride-push-test")
    System.put_env("FCM_SERVICE_ACCOUNT_JSON", @service_account)

    fcm = path |> read() |> Keyword.fetch!(Kanban.Push.FCM)

    assert fcm[:project_id] == "stride-push-test"
    assert fcm[:service_account]["client_email"] == "push@example.test"
  end

  test "FCM JSON that is not a service account stops the boot without printing it",
       %{path: path} do
    System.put_env("FCM_PROJECT_ID", "stride-push-test")
    System.put_env("FCM_SERVICE_ACCOUNT_JSON", ~s({"secret-marker": 1}))

    error = assert_raise RuntimeError, fn -> read(path) end
    assert error.message =~ "FCM_SERVICE_ACCOUNT_JSON must be the JSON key file"
    refute error.message =~ "secret-marker"
  end

  test "a Firebase project id is 6 to 30 characters", %{path: path} do
    System.put_env("FCM_SERVICE_ACCOUNT_JSON", @service_account)

    for id <- ["abcdef", "a" <> String.duplicate("b", 28) <> "c"] do
      System.put_env("FCM_PROJECT_ID", id)
      assert path |> read() |> Keyword.fetch!(Kanban.Push.FCM) |> Keyword.get(:project_id) == id
    end

    for id <- ["abcde", "a" <> String.duplicate("b", 29) <> "c", "Upper-case"] do
      System.put_env("FCM_PROJECT_ID", id)
      error = assert_raise RuntimeError, fn -> read(path) end
      assert error.message =~ "FCM_PROJECT_ID must be a Firebase project id"
    end
  end

  test "a value that is only whitespace counts as unset", %{path: path} do
    System.put_env("APNS_KEY_ID", "   ")
    assert path |> read() |> Keyword.has_key?(Kanban.Push.APNs) == false
  end

  test "a partial FCM set stops the boot", %{path: path} do
    System.put_env("FCM_SERVICE_ACCOUNT_JSON", @service_account)

    error = assert_raise RuntimeError, fn -> read(path) end
    assert error.message =~ "FCM_PROJECT_ID is not set"
  end

  test "the block is guarded by config_env() == :prod" do
    [_before, rest] = @runtime |> File.read!() |> String.split(@start, parts: 2)
    [block, _after] = String.split(rest, @finish, parts: 2)

    assert block =~ "\nif config_env() == :prod do\n"
  end
end
