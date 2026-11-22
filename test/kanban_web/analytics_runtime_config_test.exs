defmodule KanbanWeb.AnalyticsRuntimeConfigTest do
  # The Umami block of config/runtime.exs (W2897) is cut out of the file,
  # written to a temporary config file and read with Config.Reader, so each
  # test sees the block exactly as it is deployed. It sets environment
  # variables, so the module is not async; every variable it sets is removed
  # afterwards.
  use ExUnit.Case, async: false

  @runtime Path.expand("../../config/runtime.exs", __DIR__)
  @start "# Umami analytics (W2897)"
  @finish "# End of the Umami block"

  @names ~w(UMAMI_SCRIPT_URL UMAMI_WEBSITE_ID UMAMI_HOST_URL)

  @website_id "0b4c2a3e-1f2d-4c5b-8a9e-7d6f5e4c3b2a"
  @valid %{
    "UMAMI_SCRIPT_URL" => "https://cloud.umami.is/script.js",
    "UMAMI_WEBSITE_ID" => @website_id,
    "UMAMI_HOST_URL" => "https://gateway.umami.is"
  }

  setup do
    saved = Map.new(@names, &{&1, System.get_env(&1)})
    Enum.each(@names, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    path = Path.join(System.tmp_dir!(), "umami_runtime_#{System.unique_integer([:positive])}.exs")

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

  test "with no variables set analytics is off", %{path: path} do
    refute path |> read() |> Keyword.has_key?(:umami)
  end

  test "blank variables count as unset", %{path: path} do
    put(Map.new(@names, &{&1, "  "}))

    refute path |> read() |> Keyword.has_key?(:umami)
  end

  test "all three variables configure Umami, trimmed", %{path: path} do
    put(%{@valid | "UMAMI_WEBSITE_ID" => " #{@website_id} "})

    assert read(path)[:umami] == [
             script_url: "https://cloud.umami.is/script.js",
             website_id: @website_id,
             host_url: "https://gateway.umami.is"
           ]
  end

  test "a partial set stops the boot and names what is missing", %{path: path} do
    put(Map.delete(@valid, "UMAMI_HOST_URL"))

    error = assert_raise RuntimeError, fn -> read(path) end
    assert error.message =~ "UMAMI_HOST_URL not set"
    refute error.message =~ "UMAMI_SCRIPT_URL"
  end

  test "an http URL or user info stops the boot without printing the value", %{path: path} do
    for {name, value} <- [
          {"UMAMI_SCRIPT_URL", "http://cloud.umami.is/script.js"},
          {"UMAMI_HOST_URL", "https://secret-user:secret-pass@gateway.umami.is"},
          {"UMAMI_HOST_URL", "not a url"},
          {"UMAMI_SCRIPT_URL", "https://*.umami.is/script.js"},
          {"UMAMI_HOST_URL", "https://gateway.umami.is;script-src"}
        ] do
      put(Map.put(@valid, name, value))

      error = assert_raise RuntimeError, fn -> read(path) end
      assert error.message =~ "#{name} must be an https URL"
      refute error.message =~ value
    end
  end

  test "a website id that is not a UUID stops the boot without printing it", %{path: path} do
    put(Map.put(@valid, "UMAMI_WEBSITE_ID", "website-1234"))

    error = assert_raise RuntimeError, fn -> read(path) end
    assert error.message =~ "UMAMI_WEBSITE_ID must be a UUID"
    refute error.message =~ "website-1234"
  end
end
