defmodule Kanban.Attachments.StorageTest do
  # Not async: the dispatch tests change the application-wide adapter.
  use ExUnit.Case, async: false

  alias Kanban.Attachments.Storage
  alias Kanban.Attachments.Storage.Local

  defmodule RecordingAdapter do
    @moduledoc false
    @behaviour Kanban.Attachments.Storage

    @impl true
    def put(key, source, opts), do: record({:put, key, source, opts}, :ok)

    @impl true
    def stream(key), do: record({:stream, key}, {:ok, ["bytes"]})

    @impl true
    def delete(key), do: record({:delete, key}, :ok)

    @impl true
    def exists(key), do: record({:exists, key}, {:ok, true})

    defp record(call, result) do
      send(self(), {:adapter_called, call})
      result
    end
  end

  describe "valid_key?/1" do
    test "accepts a key of lowercase letters, digits, slashes and dashes" do
      assert Storage.valid_key?("boards/12/0b9c4e2a-6f1d-4c8e-9a7b-3d2e1f0a9b8c")
      assert Storage.valid_key?("a")
      assert Storage.valid_key?("snake_case/with-dash/123")
      assert "a" |> String.duplicate(Storage.max_key_length()) |> Storage.valid_key?()
    end

    test "refuses traversal, absolute, empty-segment, uppercase, trailing-newline and over-long keys" do
      refused = [
        "../x",
        "a/../b",
        "./a",
        "a/.",
        "/abs",
        "a//b",
        "a/",
        "",
        "Boards/1",
        "boards/ÿ",
        "boards/1 2",
        "boards\\1",
        "x\n",
        "x\nboards/1",
        "a.b",
        String.duplicate("a", Storage.max_key_length() + 1)
      ]

      for key <- refused do
        refute Storage.valid_key?(key), "expected #{inspect(key)} to be refused"
      end

      refute Storage.valid_key?(nil)
      refute Storage.valid_key?(:boards)
      refute Storage.valid_key?(~c"boards/1")
    end
  end

  describe "the facade" do
    setup do
      previous = Application.get_env(:kanban, Storage)
      Application.put_env(:kanban, Storage, adapter: RecordingAdapter)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:kanban, Storage, previous),
          else: Application.delete_env(:kanban, Storage)
      end)
    end

    test "dispatches to the adapter named in config and defaults to Local" do
      assert Storage.adapter() == RecordingAdapter

      assert :ok = Storage.put("boards/1/a", {:binary, "x"}, content_type: "text/plain")

      assert_received {:adapter_called,
                       {:put, "boards/1/a", {:binary, "x"}, [content_type: "text/plain"]}}

      assert :ok = Storage.put("boards/1/b", {:file, "/tmp/upload"})
      assert_received {:adapter_called, {:put, "boards/1/b", {:file, "/tmp/upload"}, []}}

      assert {:ok, ["bytes"]} = Storage.stream("boards/1/a")
      assert_received {:adapter_called, {:stream, "boards/1/a"}}

      assert :ok = Storage.delete("boards/1/a")
      assert_received {:adapter_called, {:delete, "boards/1/a"}}

      assert {:ok, true} = Storage.exists("boards/1/a")
      assert_received {:adapter_called, {:exists, "boards/1/a"}}

      Application.delete_env(:kanban, Storage)
      assert Storage.adapter() == Local
    end

    test "refuses an invalid key with :invalid_key before any adapter runs" do
      for key <- ["../etc/passwd", "/abs", "a//b", "x\n", nil] do
        assert {:error, :invalid_key} = Storage.put(key, {:binary, "x"})
        assert {:error, :invalid_key} = Storage.stream(key)
        assert {:error, :invalid_key} = Storage.delete(key)
        assert {:error, :invalid_key} = Storage.exists(key)
      end

      refute_received {:adapter_called, _call}
    end
  end
end
