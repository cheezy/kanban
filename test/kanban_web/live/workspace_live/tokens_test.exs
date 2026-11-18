defmodule KanbanWeb.WorkspaceLive.TokensTest do
  use ExUnit.Case, async: true

  alias KanbanWeb.WorkspaceLive.Tokens

  describe "normalize_capabilities/1 (D449)" do
    test "a comma-separated string gives trimmed, unique, non-blank names" do
      assert Tokens.normalize_capabilities(" testing, code_generation,,testing ") ==
               ["testing", "code_generation"]
    end

    test "a list of strings is cleaned the same way as a string" do
      assert Tokens.normalize_capabilities([" testing ", "testing", ""]) == ["testing"]
    end

    test "a missing value gives no capabilities" do
      assert Tokens.normalize_capabilities(nil) == []
    end

    test "any other shape is invalid" do
      for value <- [%{"a" => 1}, [1], ["ok", %{}], 7, :atom] do
        assert Tokens.normalize_capabilities(value) == :invalid
      end
    end
  end
end
