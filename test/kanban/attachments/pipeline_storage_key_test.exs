defmodule Kanban.Attachments.PipelineStorageKeyTest do
  use ExUnit.Case, async: true

  alias Kanban.Attachments.Pipeline
  alias Kanban.Attachments.Storage

  describe "storage_key/1" do
    test "is a valid storage key under the board's prefix" do
      key = Pipeline.storage_key(12)

      assert "boards/12/" <> uuid = key
      assert {:ok, ^uuid} = Ecto.UUID.cast(uuid)
      assert Storage.valid_key?(key)
    end

    test "is new on every call" do
      refute Pipeline.storage_key(12) == Pipeline.storage_key(12)
    end
  end
end
