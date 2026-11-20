defmodule KanbanWeb.AppLinksRuntimeConfigTest do
  # The app links block of config/runtime.exs is cut out of the file, written
  # to a temporary config file and read with Config.Reader, so each test sees
  # the block exactly as it is deployed. It sets environment variables, so the
  # module is not async; every variable it sets is removed afterwards.
  use ExUnit.Case, async: false

  @runtime Path.expand("../../config/runtime.exs", __DIR__)
  @start "# App links (W2764)"
  @finish "# End of the app links block"

  @names ~w(STRIDE_IOS_TEAM_ID STRIDE_IOS_BUNDLE_ID STRIDE_ANDROID_PACKAGE STRIDE_ANDROID_CERT_FINGERPRINTS)

  @fingerprint "AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99"
  @second_fingerprint "11:22:33:44:55:66:77:88:99:00:AA:BB:CC:DD:EE:FF:11:22:33:44:55:66:77:88:99:00:AA:BB:CC:DD:EE:FF"

  setup do
    saved = Map.new(@names, &{&1, System.get_env(&1)})
    Enum.each(@names, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    path =
      Path.join(System.tmp_dir!(), "app_links_runtime_#{System.unique_integer([:positive])}.exs")

    File.write!(path, block_script())
    on_exit(fn -> File.rm(path) end)

    %{path: path}
  end

  defp block_script do
    source = File.read!(@runtime)
    [_before, rest] = String.split(source, @start, parts: 2)
    [block, _after] = String.split(rest, @finish, parts: 2)

    """
    import Config

    #{@start}#{block}
    """
  end

  defp read(path), do: path |> Config.Reader.read!(env: :prod) |> Keyword.get(:kanban, [])

  defp put(vars), do: Enum.each(vars, fn {name, value} -> System.put_env(name, value) end)

  test "with no variables set nothing is configured", %{path: path} do
    refute path |> read() |> Keyword.has_key?(:app_links)
  end

  test "blank variables count as unset", %{path: path} do
    put(Map.new(@names, &{&1, "  "}))

    refute path |> read() |> Keyword.has_key?(:app_links)
  end

  test "all four variables configure both platforms, trimmed, fingerprints upper-cased",
       %{path: path} do
    put(%{
      "STRIDE_IOS_TEAM_ID" => " ABCDE12345 ",
      "STRIDE_IOS_BUNDLE_ID" => "com.example.stride",
      "STRIDE_ANDROID_PACKAGE" => "com.example.stride",
      "STRIDE_ANDROID_CERT_FINGERPRINTS" =>
        String.downcase(@fingerprint) <> " , ," <> @second_fingerprint
    })

    assert read(path)[:app_links] == [
             ios_team_id: "ABCDE12345",
             ios_bundle_id: "com.example.stride",
             android_package: "com.example.stride",
             android_cert_fingerprints: [@fingerprint, @second_fingerprint]
           ]
  end

  test "one platform alone sets only its keys", %{path: path} do
    put(%{"STRIDE_IOS_TEAM_ID" => "ABCDE12345", "STRIDE_IOS_BUNDLE_ID" => "com.example.stride"})

    assert read(path)[:app_links] == [
             ios_team_id: "ABCDE12345",
             ios_bundle_id: "com.example.stride"
           ]
  end

  test "one id of a platform without the other stops the boot", %{path: path} do
    for {set, unset} <- [
          {%{"STRIDE_IOS_TEAM_ID" => "ABCDE12345"}, "STRIDE_IOS_BUNDLE_ID"},
          {%{"STRIDE_IOS_BUNDLE_ID" => "com.example.stride"}, "STRIDE_IOS_TEAM_ID"},
          {%{"STRIDE_ANDROID_PACKAGE" => "com.example.stride"},
           "STRIDE_ANDROID_CERT_FINGERPRINTS"},
          {%{"STRIDE_ANDROID_CERT_FINGERPRINTS" => @fingerprint}, "STRIDE_ANDROID_PACKAGE"},
          {%{
             "STRIDE_ANDROID_PACKAGE" => "com.example.stride",
             "STRIDE_ANDROID_CERT_FINGERPRINTS" => " , "
           }, "STRIDE_ANDROID_CERT_FINGERPRINTS"}
        ] do
      Enum.each(@names, &System.delete_env/1)
      put(set)

      error = assert_raise RuntimeError, fn -> read(path) end
      assert error.message =~ "but #{unset} is not"
    end
  end

  test "a value not in its shape stops the boot without printing it", %{path: path} do
    for {name, value} <- [
          {"STRIDE_IOS_TEAM_ID", "SHORT9"},
          {"STRIDE_IOS_BUNDLE_ID", "nodots"},
          {"STRIDE_ANDROID_PACKAGE", "1com.example"},
          {"STRIDE_ANDROID_CERT_FINGERPRINTS", @fingerprint <> ",AA:BB"}
        ] do
      Enum.each(@names, &System.delete_env/1)
      put(%{name => value})

      error = assert_raise RuntimeError, fn -> read(path) end
      assert error.message =~ "#{name} is not in the expected format"
      refute error.message =~ value
    end
  end
end
