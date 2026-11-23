defmodule KanbanWeb.PathScopeTest do
  use ExUnit.Case, async: true

  alias KanbanWeb.PathScope

  doctest KanbanWeb.PathScope

  test "names each API by its leading segments" do
    for {segments, scope} <- [
          {["api", "me"], :device_api},
          {["api", "me", "devices", "current"], :device_api},
          {["api", "mcp"], :mcp},
          {["api", "mcp", "extra"], :api},
          {["api"], :api},
          {["api", "tasks", "1"], :api},
          {["scim", "v2", "Users"], :scim},
          {[".well-known", "stride-audit-signing-keys"], :audit_signing_keys},
          {[".well-known", "stride-audit-signing-keys", "extra"], :browser},
          {[".well-known", "security.txt"], :browser},
          {["oauth"], :oauth},
          {["oauth", "token"], :oauth},
          {["oauth", "revoke"], :oauth},
          {["oauth", "nope"], :oauth},
          {["oauth", "token", "extra"], :oauth},
          {["oauth", "authorize"], :browser},
          {["oauth", "authorize", "extra"], :browser},
          {[], :browser},
          {["about"], :browser},
          {["apis", "me"], :browser}
        ] do
      assert PathScope.of(segments) == scope, inspect(segments)
    end
  end

  test "compares decoded segments, as the router does" do
    assert PathScope.of(["%61pi", "me", "x"]) == :device_api
    assert PathScope.of(["api", "%6De"]) == :device_api
    assert PathScope.of(["%6Fauth", "nope"]) == :oauth
    assert PathScope.of(["oauth", "%61uthorize"]) == :browser
    assert PathScope.of(["api", "%6Dcp"]) == :mcp
  end

  test "leaves an escape that is not valid percent-encoding undecoded" do
    # The valid escape in the first segment is decoded, so the path is under
    # /api; the second segment keeps its invalid escape, so it is not "me".
    assert PathScope.of(["%61pi", "me%ZZ"]) == :api
    assert PathScope.of(["%61pi", "%"]) == :api
    assert PathScope.of(["%6Fauth", "%6"]) == :oauth
  end

  test "reads the path of a conn" do
    assert :get |> Plug.Test.conn("/api/me/boards") |> PathScope.of() == :device_api
    assert :get |> Plug.Test.conn("/oauth/nope") |> PathScope.of() == :oauth
    assert :get |> Plug.Test.conn("/") |> PathScope.of() == :browser
  end
end
