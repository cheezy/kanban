defmodule KanbanWeb.TokenPathsTest do
  use ExUnit.Case, async: true

  alias KanbanWeb.TokenPaths

  doctest KanbanWeb.TokenPaths, import: true

  @token "YYHYRh-CDCDHBiQ10ok1WyGWd7CSEv1bArGfNI8wqIQ"

  describe "token_path?/1" do
    test "matches every route that carries a token in its path" do
      for prefix <- [
            "/invitations/",
            "/users/reset-password/",
            "/users/confirm/",
            "/users/settings/confirm-email/"
          ] do
        assert TokenPaths.token_path?(prefix <> @token)
        assert TokenPaths.token_path?("https://example.com" <> prefix <> @token <> "?a=1")
      end
    end

    test "matches repeated slashes, which reach the same routes" do
      for path <- [
            "/invitations//#{@token}",
            "/users//reset-password/#{@token}",
            "/users/confirm///#{@token}",
            "/users//settings//confirm-email//#{@token}"
          ] do
        assert TokenPaths.token_path?(path), path
      end
    end

    test "does not match other routes, a bare prefix or a non-string" do
      for value <- [
            "/users/confirmation-pending",
            "/users//confirmation-pending",
            "/users/reset-password",
            "/users/reset-password//",
            "/invitations/",
            "/boards/1",
            "/notifications/unsubscribe?token=x",
            nil,
            42
          ] do
        refute TokenPaths.token_path?(value)
      end
    end
  end

  describe "redact/2" do
    test "replaces only the token segment, keeping the query and later segments" do
      assert TokenPaths.redact("/invitations/#{@token}", "[X]") == "/invitations/[X]"

      assert TokenPaths.redact("https://h/users/reset-password/#{@token}?r=1#top", "[X]") ==
               "https://h/users/reset-password/[X]?r=1#top"

      assert TokenPaths.redact("/invitations/#{@token}/extra", "[X]") == "/invitations/[X]/extra"
    end

    test "redacts the token behind repeated slashes, keeping the slashes" do
      assert TokenPaths.redact("/users//confirm//#{@token}", "[X]") == "/users//confirm//[X]"
    end

    test "redacts encoded and unusual segments too" do
      assert TokenPaths.redact("/invitations/..%2F..%2Fetc", "[X]") == "/invitations/[X]"
    end

    test "leaves other values unchanged" do
      assert TokenPaths.redact("/boards/1?token=x", "[X]") == "/boards/1?token=x"
      assert TokenPaths.redact(nil, "[X]") == nil
      assert TokenPaths.redact(%{"a" => 1}, "[X]") == %{"a" => 1}
    end
  end
end
