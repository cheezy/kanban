defmodule KanbanWeb.BoardIdentityTest do
  use ExUnit.Case, async: true

  alias KanbanWeb.BoardIdentity

  describe "board_prefix/1" do
    test "takes the first three letters of an uppercased name" do
      assert BoardIdentity.board_prefix("Stride 2.0") == "STR"
    end

    test "strips non-letters before slicing" do
      assert BoardIdentity.board_prefix("a-1b2c3d") == "ABC"
    end

    test "pads short names with question marks" do
      assert BoardIdentity.board_prefix("Z") == "Z??"
      assert BoardIdentity.board_prefix("Qa") == "QA?"
    end

    test "a name with no letters renders all question marks" do
      assert BoardIdentity.board_prefix("123") == "???"
    end

    test "non-binary input renders ???" do
      assert BoardIdentity.board_prefix(nil) == "???"
      assert BoardIdentity.board_prefix(42) == "???"
    end
  end

  describe "accent_color/1" do
    for {accent, token} <- [
          orange: "var(--stride-orange)",
          ready: "var(--st-ready)",
          doing: "var(--st-doing)",
          violet: "var(--stride-violet)",
          backlog: "var(--st-backlog)",
          blocked: "var(--st-blocked)"
        ] do
      test "maps #{accent} to its CSS variable" do
        assert BoardIdentity.accent_color(unquote(accent)) == unquote(token)
      end
    end

    test "unknown accents fall back to the muted ink token" do
      assert BoardIdentity.accent_color(:chartreuse) == "var(--ink-3)"
      assert BoardIdentity.accent_color(nil) == "var(--ink-3)"
    end
  end

  describe "present?/1" do
    test "false for nil, empty, and whitespace-only strings" do
      refute BoardIdentity.present?(nil)
      refute BoardIdentity.present?("")
      refute BoardIdentity.present?("   ")
    end

    test "true for non-blank binaries" do
      assert BoardIdentity.present?("Stride")
      assert BoardIdentity.present?("  x  ")
    end

    test "false for non-binary values" do
      refute BoardIdentity.present?(42)
      refute BoardIdentity.present?([:a])
    end
  end
end
