defmodule Kanban.Workspaces.Export.Importer.RowErrorsTest do
  use ExUnit.Case, async: true

  alias Kanban.Workspaces.Export.Importer.RowErrors

  defp changeset(errors) do
    Enum.reduce(errors, Ecto.Changeset.change({%{}, %{name: :string, size: :integer}}), fn
      {field, message, opts}, acc -> Ecto.Changeset.add_error(acc, field, message, opts)
    end)
  end

  describe "errors/1" do
    test "maps each field to its messages, placeholders filled in" do
      cs = changeset([{:size, "must be at most %{max}", max: 10}, {:name, "can't be blank", []}])

      assert RowErrors.errors(cs) == %{size: ["must be at most 10"], name: ["can't be blank"]}
    end

    test "fills a placeholder that is not text with its inspected value" do
      cs = changeset([{:name, "is one of %{list}", list: ["a", "b"]}])
      assert RowErrors.errors(cs) == %{name: [~s(is one of ["a", "b"])]}
    end

    test "is empty for a valid changeset" do
      assert [] |> changeset() |> RowErrors.errors() == %{}
    end
  end

  describe "text/1" do
    test "joins the fields in alphabetical order on one line, each field's messages as the changeset holds them" do
      cs =
        changeset([
          {:size, "is invalid", []},
          {:name, "can't be blank", []},
          {:name, "is too long", []}
        ])

      # add_error/3 prepends, so the last message added comes first.
      assert RowErrors.text(cs) == "name is too long, can't be blank; size is invalid"
    end

    test "is empty for a valid changeset" do
      assert [] |> changeset() |> RowErrors.text() == ""
    end
  end
end
