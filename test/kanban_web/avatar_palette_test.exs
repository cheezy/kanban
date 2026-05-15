defmodule KanbanWeb.AvatarPaletteTest do
  @moduledoc """
  Contract tests for `KanbanWeb.AvatarPalette` — the deterministic
  palette resolver consumed by every surface that renders an avatar.
  """
  use ExUnit.Case, async: true

  alias KanbanWeb.AvatarPalette

  describe "for_human/1 — palette set" do
    test "always returns one of the four human-* palette strings for an integer id" do
      palettes = AvatarPalette.human_palettes()

      for id <- 0..50 do
        assert AvatarPalette.for_human(id) in palettes
      end
    end

    test "for_human(0) maps to the first palette" do
      [first | _] = AvatarPalette.human_palettes()
      assert AvatarPalette.for_human(0) == first
    end

    test "consecutive ids step through the palette cyclically (rem-based)" do
      [p0, p1, p2, p3] = AvatarPalette.human_palettes()

      assert AvatarPalette.for_human(0) == p0
      assert AvatarPalette.for_human(1) == p1
      assert AvatarPalette.for_human(2) == p2
      assert AvatarPalette.for_human(3) == p3
      assert AvatarPalette.for_human(4) == p0
      assert AvatarPalette.for_human(5) == p1
    end

    test "the same id always returns the same palette (stable)" do
      for id <- [1, 7, 42, 9999] do
        first = AvatarPalette.for_human(id)
        Enum.each(1..20, fn _ -> assert AvatarPalette.for_human(id) == first end)
      end
    end
  end

  describe "for_human/1 — fallbacks" do
    test "returns human-blue when id is nil" do
      assert AvatarPalette.for_human(nil) == "human-blue"
    end

    test "returns human-blue when id is a string" do
      assert AvatarPalette.for_human("42") == "human-blue"
    end

    test "returns human-blue when id is a map" do
      assert AvatarPalette.for_human(%{id: 1}) == "human-blue"
    end
  end

  describe "for_agent/1 — branded vendors" do
    for {input, expected} <- [
          {"Claude Opus 4.6", "agent-claude"},
          {"claude sonnet 3.5", "agent-claude"},
          {"Cursor", "agent-cursor"},
          {"cursor agent v2", "agent-cursor"},
          {"Aider", "agent-aider"},
          {"AIDER 0.50", "agent-aider"},
          {"Codex", "agent-codex"},
          {"codex 1.0", "agent-codex"}
        ] do
      test "#{inspect(input)} maps to #{expected}" do
        assert AvatarPalette.for_agent(unquote(input)) == unquote(expected)
      end
    end
  end

  describe "for_agent/1 — fallbacks" do
    test "unknown agent name falls back to agent-claude" do
      assert AvatarPalette.for_agent("totally-new-agent") == "agent-claude"
    end

    test "empty string falls back to agent-claude" do
      assert AvatarPalette.for_agent("") == "agent-claude"
    end

    test "nil falls back to agent-claude" do
      assert AvatarPalette.for_agent(nil) == "agent-claude"
    end

    test "non-binary input falls back to agent-claude" do
      assert AvatarPalette.for_agent(:claude) == "agent-claude"
      assert AvatarPalette.for_agent(42) == "agent-claude"
    end
  end

  describe "agent_palettes/0 introspection" do
    test "returns the four canonical agent palette strings" do
      assert AvatarPalette.agent_palettes() == ~w(agent-claude agent-cursor agent-aider agent-codex)
    end
  end

  describe "human_palettes/0 introspection" do
    test "returns the four canonical human palette strings" do
      assert AvatarPalette.human_palettes() == ~w(human-blue human-amber human-green human-pink)
    end
  end
end
