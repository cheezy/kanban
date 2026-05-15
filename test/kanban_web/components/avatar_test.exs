defmodule KanbanWeb.AvatarTest do
  @moduledoc """
  Contract tests for `KanbanWeb.Avatar.avatar/1` and `avatar_stack/1`.
  The marketing mini-board renders `avatar/1` with `size={14}` and pins
  the same oklch palette substrings asserted here, so any palette or
  initials change would break that surface too.
  """
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias KanbanWeb.Avatar

  describe "avatar/1 — border-radius by kind" do
    test "agent renders with 4px border-radius" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <Avatar.avatar kind={:agent} name="Claude" palette="agent-claude" />
        """)

      assert html =~ "border-radius: 4px;"
      refute html =~ "border-radius: 50%;"
    end

    test "human renders with 50% border-radius (circle)" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <Avatar.avatar kind={:human} name="Jamie K" palette="human-green" />
        """)

      assert html =~ "border-radius: 50%;"
      refute html =~ "border-radius: 4px;"
    end
  end

  describe "avatar/1 — agent palette mapping" do
    for {palette, oklch} <- [
          {"agent-claude", "oklch(70% 0.16 47)"},
          {"agent-cursor", "oklch(60% 0.16 240)"},
          {"agent-aider", "oklch(60% 0.14 155)"},
          {"agent-codex", "oklch(60% 0.18 277)"}
        ] do
      test "#{palette} resolves to #{oklch}" do
        assigns = %{palette: unquote(palette)}

        html =
          rendered_to_string(~H"""
          <Avatar.avatar kind={:agent} name="X" palette={@palette} />
          """)

        assert html =~ "background: #{unquote(oklch)};"
      end
    end

    test "unknown agent palette falls back to var(--ink-3)" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <Avatar.avatar kind={:agent} name="X" palette="agent-unknown" />
        """)

      assert html =~ "background: var(--ink-3);"
    end
  end

  describe "avatar/1 — human palette mapping" do
    for {palette, oklch} <- [
          {"human-blue", "oklch(60% 0.10 240)"},
          {"human-amber", "oklch(60% 0.10 60)"},
          {"human-green", "oklch(60% 0.10 155)"},
          {"human-pink", "oklch(60% 0.10 320)"}
        ] do
      test "#{palette} resolves to #{oklch}" do
        assigns = %{palette: unquote(palette)}

        html =
          rendered_to_string(~H"""
          <Avatar.avatar kind={:human} name="X" palette={@palette} />
          """)

        assert html =~ "background: #{unquote(oklch)};"
      end
    end

    test "missing palette falls back to var(--ink-3)" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <Avatar.avatar kind={:human} name="X" />
        """)

      assert html =~ "background: var(--ink-3);"
    end
  end

  describe "avatar/1 — initials algorithm" do
    test "multi-word name produces 2 uppercase initials" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <Avatar.avatar kind={:human} name="Jamie K" palette="human-green" />
        """)

      assert html =~ ~r/>\s*JK\s*</
    end

    test "single-word name produces 1 uppercase initial" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <Avatar.avatar kind={:agent} name="Claude" palette="agent-claude" />
        """)

      assert html =~ ~r/>\s*C\s*</
    end

    test "names with three+ words truncate to the first two words' initials" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <Avatar.avatar kind={:human} name="ann marie smith" palette="human-blue" />
        """)

      assert html =~ ~r/>\s*AM\s*</
    end
  end

  describe "avatar/1 — size attribute" do
    test "default size is 18 with font-size 8" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <Avatar.avatar kind={:agent} name="X" palette="agent-claude" />
        """)

      assert html =~ "width: 18px; height: 18px"
      assert html =~ "font-size: 8px"
    end

    test "explicit size=14 produces width/height 14px with font-size 6px (legacy mini-board parity)" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <Avatar.avatar kind={:agent} name="X" palette="agent-claude" size={14} />
        """)

      assert html =~ "width: 14px; height: 14px"
      assert html =~ "font-size: 6px"
    end
  end

  describe "avatar/1 — ring attribute" do
    test "ring=false (default) omits the surface-colored box-shadow" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <Avatar.avatar kind={:human} name="X" palette="human-blue" />
        """)

      refute html =~ "box-shadow:"
    end

    test "ring=true adds a 2px var(--surface) ring" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <Avatar.avatar kind={:human} name="X" palette="human-blue" ring />
        """)

      assert html =~ "box-shadow: 0 0 0 2px var(--surface);"
    end
  end

  describe "avatar_stack/1" do
    test "renders each member, no overflow chip when members <= max" do
      assigns = %{
        members: [
          %{kind: :agent, name: "Claude", palette: "agent-claude"},
          %{kind: :agent, name: "Cursor", palette: "agent-cursor"},
          %{kind: :human, name: "Jamie K", palette: "human-green"}
        ]
      }

      html =
        rendered_to_string(~H"""
        <Avatar.avatar_stack members={@members} max={5} />
        """)

      # Each member's distinct background should be present.
      assert html =~ "background: oklch(70% 0.16 47);"
      assert html =~ "background: oklch(60% 0.16 240);"
      assert html =~ "background: oklch(60% 0.10 155);"
      # No overflow chip.
      refute html =~ ~r/>\s*\+\d+\s*</
    end

    test "renders +N overflow chip when members > max" do
      members =
        for i <- 1..7 do
          %{kind: :agent, name: "Agent #{i}", palette: "agent-claude"}
        end

      assigns = %{members: members}

      html =
        rendered_to_string(~H"""
        <Avatar.avatar_stack members={@members} max={5} />
        """)

      # Five rendered avatars + a +2 chip (7 - 5 = 2).
      assert html =~ ~r/>\s*\+2\s*</
      assert html =~ "background: var(--ink-3);"
    end

    test "members beyond max are not rendered as avatars (only the chip)" do
      members = [
        %{kind: :agent, name: "Aaa", palette: "agent-claude"},
        %{kind: :agent, name: "Bbb", palette: "agent-cursor"},
        %{kind: :agent, name: "Ccc", palette: "agent-aider"},
        %{kind: :agent, name: "Ddd", palette: "agent-codex"}
      ]

      assigns = %{members: members}

      html =
        rendered_to_string(~H"""
        <Avatar.avatar_stack members={@members} max={2} />
        """)

      # First two render → claude amber, cursor blue.
      assert html =~ "background: oklch(70% 0.16 47);"
      assert html =~ "background: oklch(60% 0.16 240);"
      # Third and fourth (aider green, codex indigo) are absorbed into the +2 chip.
      refute html =~ "background: oklch(60% 0.14 155);"
      refute html =~ "background: oklch(60% 0.18 277);"
      assert html =~ ~r/>\s*\+2\s*</
    end

    test "empty members renders nothing visible (no avatars, no chip)" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <Avatar.avatar_stack members={[]} />
        """)

      refute html =~ "border-radius: 4px"
      refute html =~ "border-radius: 50%"
      refute html =~ ~r/>\s*\+\d+\s*</
    end

    test "stacked avatars use a 5px negative left margin (except the first)" do
      assigns = %{
        members: [
          %{kind: :agent, name: "Claude", palette: "agent-claude"},
          %{kind: :agent, name: "Cursor", palette: "agent-cursor"}
        ]
      }

      html =
        rendered_to_string(~H"""
        <Avatar.avatar_stack members={@members} />
        """)

      assert html =~ "margin-left: -5px;"
    end

    test "stack ring is applied to inner avatars" do
      assigns = %{
        members: [%{kind: :human, name: "Jamie K", palette: "human-green"}]
      }

      html =
        rendered_to_string(~H"""
        <Avatar.avatar_stack members={@members} />
        """)

      assert html =~ "box-shadow: 0 0 0 2px var(--surface);"
    end
  end
end
