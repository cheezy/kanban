defmodule KanbanWeb.API.FallbackControllerTest do
  @moduledoc """
  Direct unit tests for the API fallback error-to-response mapping (W1448). The
  module is wired as `action_fallback` but every current action handles its own
  errors, so it is tested by calling `call/2` directly. Asserts the exact status
  and body per error shape, and that no internal detail (changeset struct, stack
  trace) leaks into the response.
  """
  use KanbanWeb.ConnCase, async: true

  alias KanbanWeb.API.FallbackController

  defp json_conn, do: build_conn() |> Phoenix.Controller.put_format("json")

  # Sourced through Process.get/2 (return type term()) so the compiler's type
  # checker can't narrow it and reject the deliberately-unmapped error shape at
  # compile time (call/2 only specs {:error, Ecto.Changeset | :not_found}).
  defp unmapped_error, do: Process.get(:__unmapped_error__, {:error, :some_unmapped_reason})

  describe "call/2 — changeset error" do
    test "renders 422 with translated field errors and doc links, leaking nothing internal" do
      changeset =
        {%{}, %{title: :string}}
        |> Ecto.Changeset.cast(%{}, [:title])
        |> Ecto.Changeset.validate_required([:title])

      conn = FallbackController.call(json_conn(), {:error, changeset})

      body = json_response(conn, 422)

      assert body["errors"] == %{"title" => ["can't be blank"]}
      assert Map.has_key?(body, "documentation")
      # Only the curated keys — no raw changeset, data, or valid? leaks.
      assert body |> Map.keys() |> Enum.sort() == ["documentation", "errors"]
      refute Map.has_key?(body, "changeset")
      refute Map.has_key?(body, "data")
    end
  end

  describe "call/2 — not found" do
    test "renders a clean, static 404 with no leaked identifiers" do
      conn = FallbackController.call(json_conn(), {:error, :not_found})

      assert json_response(conn, 404) == %{"errors" => %{"detail" => "Not Found"}}
    end
  end

  describe "call/2 — unmatched error shape" do
    test "raises FunctionClauseError (no catch-all masks an unmapped error)" do
      assert_raise FunctionClauseError, fn ->
        FallbackController.call(json_conn(), unmapped_error())
      end
    end
  end
end
