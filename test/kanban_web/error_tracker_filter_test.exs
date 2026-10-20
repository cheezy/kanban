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

  @token "YYHYRh-CDCDHBiQ10ok1WyGWd7CSEv1bArGfNI8wqIQ"

  test "redacts an invitation token from the request path, params and referer" do
    context = %{
      "request.path" => "/invitations/#{@token}",
      "request.query" => "",
      "request.params" => %{"token" => @token},
      "request.headers" => %{
        "referer" => "https://example.com/invitations/#{@token}?from=mail",
        "accept" => "text/html"
      }
    }

    sanitized = ErrorTrackerFilter.sanitize(context)

    refute inspect(sanitized) =~ @token
    assert sanitized["request.path"] == "/invitations/[REDACTED]"
    assert sanitized["request.params"] == %{"token" => "[REDACTED]"}

    assert sanitized["request.headers"] == %{
             "referer" => "https://example.com/invitations/[REDACTED]?from=mail",
             "accept" => "text/html"
           }
  end

  test "redacts an invitation token from a LiveView's URI and params" do
    context = %{
      "live_view.view" => KanbanWeb.WorkspaceLive.InvitationAccept,
      "live_view.uri" => "https://example.com/invitations/#{@token}",
      "live_view.params" => %{"token" => @token}
    }

    sanitized = ErrorTrackerFilter.sanitize(context)

    refute inspect(sanitized) =~ @token
    assert sanitized["live_view.uri"] == "https://example.com/invitations/[REDACTED]"
    assert sanitized["live_view.params"] == %{"token" => "[REDACTED]"}
    refute Map.has_key?(sanitized, "request.path")
    refute Map.has_key?(sanitized, "request.params")
  end

  test "redacts password reset and confirmation tokens in the path" do
    for path <- [
          "/users/reset-password/#{@token}",
          "/users/confirm/#{@token}",
          "/users/settings/confirm-email/#{@token}"
        ] do
      sanitized =
        ErrorTrackerFilter.sanitize(%{"request.path" => path, "request.params" => nil})

      refute sanitized["request.path"] =~ @token
      assert sanitized["request.params"] == nil
    end
  end

  test "redacts a referer pointing at an invitation page on any route" do
    context = %{
      "request.path" => "/users/log-in",
      "request.params" => %{"token" => "kept-not-a-path-token"},
      "request.headers" => %{"referer" => "https://example.com/invitations/#{@token}"}
    }

    sanitized = ErrorTrackerFilter.sanitize(context)

    assert sanitized["request.headers"]["referer"] == "https://example.com/invitations/[REDACTED]"
    assert sanitized["request.params"] == %{"token" => "kept-not-a-path-token"}
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
