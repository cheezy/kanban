defmodule Kanban.Workspaces.Export.SerializerSkippedTest do
  use ExUnit.Case, async: true

  alias Kanban.Workspaces.Export.Serializer

  @exported_at ~U[2026-11-03 12:00:00Z]

  defp manifest(skipped) do
    "Workspace"
    |> Serializer.encode_manifest(%{attachments: 1}, @exported_at, skipped)
    |> IO.iodata_to_binary()
    |> Jason.decode!()
  end

  describe "encode_manifest/4" do
    test "lists the attachments left out, with their reasons, in order" do
      assert manifest([%{id: 7, reason: :missing}, %{id: 3, reason: :changed}])[
               "skipped_attachments"
             ] == [%{"id" => 7, "reason" => "missing"}, %{"id" => 3, "reason" => "changed"}]
    end

    test "writes no key when nothing was left out" do
      refute [] |> manifest() |> Map.has_key?("skipped_attachments")

      without_arg =
        "Workspace"
        |> Serializer.encode_manifest(%{}, @exported_at)
        |> IO.iodata_to_binary()
        |> Jason.decode!()

      refute Map.has_key?(without_arg, "skipped_attachments")
    end

    test "a manifest that lists skips still decodes" do
      binary =
        "Workspace"
        |> Serializer.encode_manifest(%{}, @exported_at, [%{id: 1, reason: :missing}])
        |> IO.iodata_to_binary()

      assert {:ok, %{"skipped_attachments" => [_]}} = Serializer.decode_manifest(binary)
    end
  end

  describe "skipped_attachments/1" do
    test "reads back what encode_manifest/4 wrote" do
      skipped = [%{id: 7, reason: :missing}, %{id: 3, reason: :changed}]
      assert skipped |> manifest() |> Serializer.skipped_attachments() == skipped
    end

    test "a manifest without the key, or not a list, has none" do
      assert Serializer.skipped_attachments(%{}) == []
      assert Serializer.skipped_attachments(%{"skipped_attachments" => "1"}) == []
      assert Serializer.skipped_attachments(%{"skipped_attachments" => nil}) == []
      assert Serializer.skipped_attachments(nil) == []
    end

    test "ignores entries of any other shape, since the manifest is untrusted" do
      entries = [
        %{"id" => 0, "reason" => "missing"},
        %{"id" => -1, "reason" => "missing"},
        %{"id" => "5", "reason" => "missing"},
        %{"id" => 5.0, "reason" => "missing"},
        %{"id" => 5, "reason" => "deleted"},
        %{"id" => 5, "reason" => nil},
        %{"id" => 5},
        "5",
        nil,
        [5, "missing"],
        %{"id" => 9, "reason" => "changed", "extra" => "ignored"}
      ]

      assert Serializer.skipped_attachments(%{"skipped_attachments" => entries}) ==
               [%{id: 9, reason: :changed}]
    end

    test "names an attachment listed twice once" do
      entry = %{"id" => 4, "reason" => "missing"}

      assert Serializer.skipped_attachments(%{"skipped_attachments" => [entry, entry]}) ==
               [%{id: 4, reason: :missing}]
    end
  end
end
