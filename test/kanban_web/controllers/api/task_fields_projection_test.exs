defmodule KanbanWeb.API.TaskFieldsProjectionTest do
  use ExUnit.Case, async: true

  alias KanbanWeb.API.TaskFieldsProjection

  describe "resolve/1" do
    test "returns {:ok, nil} when fields is absent" do
      assert TaskFieldsProjection.resolve(%{}) == {:ok, nil}
      assert TaskFieldsProjection.resolve(%{"id" => "42"}) == {:ok, nil}
    end

    test "returns {:ok, nil} for a blank or effectively-empty fields value" do
      assert TaskFieldsProjection.resolve(%{"fields" => ""}) == {:ok, nil}
      assert TaskFieldsProjection.resolve(%{"fields" => "   "}) == {:ok, nil}
      assert TaskFieldsProjection.resolve(%{"fields" => ",, ,"}) == {:ok, nil}
    end

    test "rejects a present-but-non-binary fields shape (W2094)" do
      assert TaskFieldsProjection.resolve(%{"fields" => ["title"]}) == {:error, :invalid_shape}

      assert TaskFieldsProjection.resolve(%{"fields" => %{"x" => "title"}}) ==
               {:error, :invalid_shape}
    end

    test "mutual exclusion still wins over the shape check (W2094)" do
      assert TaskFieldsProjection.resolve(%{"fields" => ["title"], "response_view" => "slim"}) ==
               {:error, :mutually_exclusive}
    end

    test "trimming is Unicode-wide, by design (W2094)" do
      # String.trim/1 strips any Unicode whitespace — NBSP and tab included —
      # so programmatically-generated names with exotic padding still resolve.
      assert TaskFieldsProjection.resolve(%{"fields" => " title ,\tstatus\t"}) ==
               {:ok, ~w(id identifier title status)}
    end

    test "always leads with id and identifier, without duplicating them" do
      assert TaskFieldsProjection.resolve(%{"fields" => "review_status"}) ==
               {:ok, ~w(id identifier review_status)}

      assert TaskFieldsProjection.resolve(%{"fields" => "identifier,title,id"}) ==
               {:ok, ~w(id identifier title)}
    end

    test "splits, trims, drops blanks, and deduplicates in string space" do
      assert TaskFieldsProjection.resolve(%{"fields" => " title , ,title,status,"}) ==
               {:ok, ~w(id identifier title status)}
    end

    test "rejects unknown names, all of them, in request order" do
      assert TaskFieldsProjection.resolve(%{"fields" => "title,bogus,status,zzz,bogus"}) ==
               {:error, {:unknown_fields, ~w(bogus zzz)}}
    end

    test "never mints atoms from requested names" do
      value = "no_such_field_#{System.unique_integer([:positive])}"

      assert {:error, {:unknown_fields, [^value]}} =
               TaskFieldsProjection.resolve(%{"fields" => value})

      assert_raise ArgumentError, fn -> String.to_existing_atom(value) end
    end

    test "rejects fields combined with response_view regardless of either value" do
      for rv <- ["slim", "full", "", "bogus"] do
        assert TaskFieldsProjection.resolve(%{"fields" => "title", "response_view" => rv}) ==
                 {:error, :mutually_exclusive}
      end

      assert TaskFieldsProjection.resolve(%{"fields" => "", "response_view" => "slim"}) ==
               {:error, :mutually_exclusive}
    end
  end

  describe "unknown_field_message/1" do
    test "names the field and the endpoint" do
      assert TaskFieldsProjection.unknown_field_message("bogus") ==
               "bogus is not in the allow-listed fields for GET /api/tasks/:id"
    end
  end
end
