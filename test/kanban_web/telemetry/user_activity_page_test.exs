defmodule KanbanWeb.Telemetry.UserActivityPageTest do
  use ExUnit.Case, async: true

  alias KanbanWeb.Telemetry.UserActivityPage

  describe "escape_like/1" do
    test "escapes the three LIKE metacharacters" do
      assert UserActivityPage.escape_like("50% off") == "50\\% off"
      assert UserActivityPage.escape_like("foo_bar") == "foo\\_bar"
      assert UserActivityPage.escape_like("a\\b") == "a\\\\b"
    end

    test "passes plain strings through unchanged" do
      assert UserActivityPage.escape_like("alice@example.com") == "alice@example.com"
      assert UserActivityPage.escape_like("") == ""
    end

    test "escapes every occurrence, not just the first" do
      assert UserActivityPage.escape_like("a%b%c") == "a\\%b\\%c"
      assert UserActivityPage.escape_like("__init__") == "\\_\\_init\\_\\_"
    end

    test "handles a string that is entirely metacharacters" do
      assert UserActivityPage.escape_like("%%__\\\\") == "\\%\\%\\_\\_\\\\\\\\"
    end
  end
end
