defmodule KanbanWeb.ErrorTrackerFilterTest do
  use ExUnit.Case, async: true

  alias KanbanWeb.ErrorTrackerFilter

  test "is the configured ErrorTracker filter" do
    assert Application.get_env(:error_tracker, :filter) == ErrorTrackerFilter
  end

  test "redacts the query string and token param on unsubscribe routes" do
    context = %{
      "request.path" => "/notifications/unsubscribe/one-click",
      "request.query" => "token=secret",
      "request.params" => %{"token" => "secret", "List-Unsubscribe" => "One-Click"},
      "request.headers" => %{"user-agent" => "mail"}
    }

    sanitized = ErrorTrackerFilter.sanitize(context)

    assert sanitized["request.query"] == "[REDACTED]"

    assert sanitized["request.params"] == %{
             "token" => "[REDACTED]",
             "List-Unsubscribe" => "One-Click"
           }

    assert sanitized["request.headers"] == %{"user-agent" => "mail"}
  end

  test "redacts a referer pointing at an unsubscribe page on any route" do
    context = %{
      "request.path" => "/users/notifications",
      "request.query" => "",
      "request.params" => %{},
      "request.headers" => %{
        "referer" => "https://example.com/notifications/unsubscribe?token=secret",
        "accept" => "text/html"
      }
    }

    sanitized = ErrorTrackerFilter.sanitize(context)

    assert sanitized["request.headers"]["referer"] == "[REDACTED]"
    assert sanitized["request.headers"]["accept"] == "text/html"
    assert sanitized["request.query"] == ""
  end

  test "leaves unrelated contexts unchanged" do
    context = %{
      "request.path" => "/boards",
      "request.query" => "page=2",
      "request.params" => %{"page" => "2"},
      "request.headers" => %{"referer" => "https://example.com/boards"}
    }

    assert ErrorTrackerFilter.sanitize(context) == context
  end

  test "tolerates contexts without request data or with unfetched params" do
    assert ErrorTrackerFilter.sanitize(%{}) == %{}
    assert ErrorTrackerFilter.sanitize(nil) == nil

    assert %{"request.params" => nil, "request.query" => "[REDACTED]"} =
             ErrorTrackerFilter.sanitize(%{
               "request.path" => "/notifications/unsubscribe",
               "request.params" => nil
             })
  end
end
