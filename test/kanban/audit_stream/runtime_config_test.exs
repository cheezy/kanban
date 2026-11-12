defmodule Kanban.AuditStream.RuntimeConfigTest do
  # Not async: these tests set OS environment variables and the :kanban
  # application environment, which are global.
  use ExUnit.Case, async: false

  alias Kanban.AuditStream.Destination

  @runtime Path.expand("../../../config/runtime.exs", __DIR__)

  @var "AUDIT_STREAM_MAX_DESTINATIONS"

  # Other secrets runtime.exs can read; the boot error must never echo them.
  @sentinel_vars ~w(SECRET_KEY_BASE ENCRYPTION_KEY)

  @vars [@var | @sentinel_vars]

  @sentinel "sentinel-value-never-printed"

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

  # Each read starts from none of @vars set, then sets exactly `env`.
  defp read(env) do
    Enum.each(@vars, &System.delete_env/1)
    System.put_env(env)
    @runtime |> Config.Reader.read!(env: :test) |> Keyword.get(:kanban, [])
  end

  defp max_destinations(env), do: env |> read() |> Keyword.get(Kanban.AuditStream)

  defp boot_error(value) do
    env = Map.new(@sentinel_vars, &{&1, @sentinel}) |> Map.put(@var, value)
    assert_raise RuntimeError, fn -> read(env) end
  end

  describe "AUDIT_STREAM_MAX_DESTINATIONS" do
    test "1 and 50 are accepted" do
      assert max_destinations(%{@var => "1"}) == [max_destinations: 1]
      assert max_destinations(%{@var => "50"}) == [max_destinations: 50]
    end

    test "a value with surrounding whitespace is trimmed" do
      assert max_destinations(%{@var => " 7 "}) == [max_destinations: 7]
    end

    for value <- ["0", "51", "-1", "abc", "2.5", "1e1", "99999999999999999999"] do
      test "#{inspect(value)} stops the boot naming the variable and nothing else" do
        value = unquote(value)
        error = boot_error(value)

        assert error.message =~ @var
        assert error.message =~ "from 1 to 50"
        refute error.message =~ @sentinel
        refute error.message |> String.replace("from 1 to 50", "") |> String.contains?(value)
      end
    end

    test "unset or blank leaves the setting out" do
      assert max_destinations(%{}) == nil
      assert max_destinations(%{@var => ""}) == nil
      assert max_destinations(%{@var => "   "}) == nil
    end
  end

  describe "Destination.max_destinations/0" do
    setup do
      saved = Application.fetch_env(:kanban, Kanban.AuditStream)

      on_exit(fn ->
        case saved do
          {:ok, value} -> Application.put_env(:kanban, Kanban.AuditStream, value)
          :error -> Application.delete_env(:kanban, Kanban.AuditStream)
        end
      end)
    end

    test "is 3 when the setting is unset" do
      Application.delete_env(:kanban, Kanban.AuditStream)

      assert Destination.max_destinations() == 3
    end

    test "reads the setting at call time" do
      Application.put_env(:kanban, Kanban.AuditStream, max_destinations: 7)
      assert Destination.max_destinations() == 7

      Application.put_env(:kanban, Kanban.AuditStream, max_destinations: 50)
      assert Destination.max_destinations() == 50
    end
  end
end
