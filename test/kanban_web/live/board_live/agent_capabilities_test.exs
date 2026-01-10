defmodule KanbanWeb.BoardLive.AgentCapabilitiesTest do
  use KanbanWeb.ConnCase

  import Phoenix.LiveViewTest

  import Kanban.AccountsFixtures

  alias Kanban.ApiTokens
  alias Kanban.Boards

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, board} = Boards.create_ai_optimized_board(user, %{name: "Test AI Board"})

    conn = log_in_user(conn, user)

    %{conn: conn, user: user, board: board}
  end

  describe "agent capabilities parsing" do
    test "board is AI optimized", %{board: board} do
      assert board.ai_optimized_board == true
    end

    test "parses single capability", %{conn: conn, board: board} do
      {:ok, lv, _html} = live(conn, ~p"/boards/#{board}/api_tokens")

      lv
      |> form("form[phx-submit=create_token]", %{
        "api_token" => %{
          "name" => "Test Token",
          "agent_capabilities" => "code_generation"
        }
      })
      |> render_submit()

      tokens = ApiTokens.list_api_tokens(board)
      token = Enum.find(tokens, &(&1.name == "Test Token"))

      assert token.agent_capabilities == ["code_generation"]
    end

    test "parses multiple capabilities with proper trimming", %{conn: conn, board: board} do
      {:ok, lv, _html} = live(conn, ~p"/boards/#{board}/api_tokens")

      lv
      |> form("form[phx-submit=create_token]", %{
        "api_token" => %{
          "name" => "Multi Capability Token",
          "agent_capabilities" => "code_generation, testing, documentation"
        }
      })
      |> render_submit()

      tokens = ApiTokens.list_api_tokens(board)
      token = Enum.find(tokens, &(&1.name == "Multi Capability Token"))

      assert token.agent_capabilities == ["code_generation", "testing", "documentation"]
    end

    test "parses all standard capabilities", %{conn: conn, board: board} do
      {:ok, lv, _html} = live(conn, ~p"/boards/#{board}/api_tokens")

      all_capabilities = "code_generation, code_review, database_design, testing, documentation, debugging, refactoring, api_design, ui_implementation, performance_optimization, security_analysis, devops"

      lv
      |> form("form[phx-submit=create_token]", %{
        "api_token" => %{
          "name" => "All Capabilities Token",
          "agent_capabilities" => all_capabilities
        }
      })
      |> render_submit()

      tokens = ApiTokens.list_api_tokens(board)
      token = Enum.find(tokens, &(&1.name == "All Capabilities Token"))

      expected = [
        "code_generation",
        "code_review",
        "database_design",
        "testing",
        "documentation",
        "debugging",
        "refactoring",
        "api_design",
        "ui_implementation",
        "performance_optimization",
        "security_analysis",
        "devops"
      ]

      assert token.agent_capabilities == expected
    end

    test "handles empty string as empty array", %{conn: conn, board: board} do
      {:ok, lv, _html} = live(conn, ~p"/boards/#{board}/api_tokens")

      lv
      |> form("form[phx-submit=create_token]", %{
        "api_token" => %{
          "name" => "No Capabilities Token",
          "agent_capabilities" => ""
        }
      })
      |> render_submit()

      tokens = ApiTokens.list_api_tokens(board)
      token = Enum.find(tokens, &(&1.name == "No Capabilities Token"))

      assert token.agent_capabilities == []
    end

    test "handles whitespace-only string as empty array", %{conn: conn, board: board} do
      {:ok, lv, _html} = live(conn, ~p"/boards/#{board}/api_tokens")

      lv
      |> form("form[phx-submit=create_token]", %{
        "api_token" => %{
          "name" => "Whitespace Token",
          "agent_capabilities" => "   "
        }
      })
      |> render_submit()

      tokens = ApiTokens.list_api_tokens(board)
      token = Enum.find(tokens, &(&1.name == "Whitespace Token"))

      assert token.agent_capabilities == []
    end

    test "trims extra whitespace around capabilities", %{conn: conn, board: board} do
      {:ok, lv, _html} = live(conn, ~p"/boards/#{board}/api_tokens")

      lv
      |> form("form[phx-submit=create_token]", %{
        "api_token" => %{
          "name" => "Whitespace Trimming Token",
          "agent_capabilities" => "  code_generation  ,  testing  ,  documentation  "
        }
      })
      |> render_submit()

      tokens = ApiTokens.list_api_tokens(board)
      token = Enum.find(tokens, &(&1.name == "Whitespace Trimming Token"))

      assert token.agent_capabilities == ["code_generation", "testing", "documentation"]
    end

    test "handles trailing commas", %{conn: conn, board: board} do
      {:ok, lv, _html} = live(conn, ~p"/boards/#{board}/api_tokens")

      lv
      |> form("form[phx-submit=create_token]", %{
        "api_token" => %{
          "name" => "Trailing Comma Token",
          "agent_capabilities" => "code_generation, testing,"
        }
      })
      |> render_submit()

      tokens = ApiTokens.list_api_tokens(board)
      token = Enum.find(tokens, &(&1.name == "Trailing Comma Token"))

      assert token.agent_capabilities == ["code_generation", "testing"]
    end

    test "handles leading commas", %{conn: conn, board: board} do
      {:ok, lv, _html} = live(conn, ~p"/boards/#{board}/api_tokens")

      lv
      |> form("form[phx-submit=create_token]", %{
        "api_token" => %{
          "name" => "Leading Comma Token",
          "agent_capabilities" => ",code_generation, testing"
        }
      })
      |> render_submit()

      tokens = ApiTokens.list_api_tokens(board)
      token = Enum.find(tokens, &(&1.name == "Leading Comma Token"))

      assert token.agent_capabilities == ["code_generation", "testing"]
    end

    test "handles multiple consecutive commas", %{conn: conn, board: board} do
      {:ok, lv, _html} = live(conn, ~p"/boards/#{board}/api_tokens")

      lv
      |> form("form[phx-submit=create_token]", %{
        "api_token" => %{
          "name" => "Multiple Commas Token",
          "agent_capabilities" => "code_generation,,,testing,,documentation"
        }
      })
      |> render_submit()

      tokens = ApiTokens.list_api_tokens(board)
      token = Enum.find(tokens, &(&1.name == "Multiple Commas Token"))

      assert token.agent_capabilities == ["code_generation", "testing", "documentation"]
    end

    test "preserves order of capabilities", %{conn: conn, board: board} do
      {:ok, lv, _html} = live(conn, ~p"/boards/#{board}/api_tokens")

      lv
      |> form("form[phx-submit=create_token]", %{
        "api_token" => %{
          "name" => "Order Preservation Token",
          "agent_capabilities" => "testing, code_generation, documentation"
        }
      })
      |> render_submit()

      tokens = ApiTokens.list_api_tokens(board)
      token = Enum.find(tokens, &(&1.name == "Order Preservation Token"))

      assert token.agent_capabilities == ["testing", "code_generation", "documentation"]
    end

    test "handles custom capabilities (not in standard list)", %{conn: conn, board: board} do
      {:ok, lv, _html} = live(conn, ~p"/boards/#{board}/api_tokens")

      lv
      |> form("form[phx-submit=create_token]", %{
        "api_token" => %{
          "name" => "Custom Capabilities Token",
          "agent_capabilities" => "ml_training, data_analysis, custom_capability"
        }
      })
      |> render_submit()

      tokens = ApiTokens.list_api_tokens(board)
      token = Enum.find(tokens, &(&1.name == "Custom Capabilities Token"))

      assert token.agent_capabilities == ["ml_training", "data_analysis", "custom_capability"]
    end

    test "handles mixed case (converts to exact input)", %{conn: conn, board: board} do
      {:ok, lv, _html} = live(conn, ~p"/boards/#{board}/api_tokens")

      lv
      |> form("form[phx-submit=create_token]", %{
        "api_token" => %{
          "name" => "Mixed Case Token",
          "agent_capabilities" => "Code_Generation, TESTING, Documentation"
        }
      })
      |> render_submit()

      tokens = ApiTokens.list_api_tokens(board)
      token = Enum.find(tokens, &(&1.name == "Mixed Case Token"))

      # Parser preserves case as entered
      assert token.agent_capabilities == ["Code_Generation", "TESTING", "Documentation"]
    end

    test "removes duplicate capabilities", %{conn: conn, board: board} do
      {:ok, lv, _html} = live(conn, ~p"/boards/#{board}/api_tokens")

      lv
      |> form("form[phx-submit=create_token]", %{
        "api_token" => %{
          "name" => "Duplicate Token",
          "agent_capabilities" => "code_generation, testing, code_generation, documentation"
        }
      })
      |> render_submit()

      tokens = ApiTokens.list_api_tokens(board)
      token = Enum.find(tokens, &(&1.name == "Duplicate Token"))

      # First occurrence is kept
      assert token.agent_capabilities == ["code_generation", "testing", "documentation"]
    end
  end
end
