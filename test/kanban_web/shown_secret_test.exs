defmodule KanbanWeb.ShownSecretTest do
  use ExUnit.Case, async: true

  alias KanbanWeb.ShownSecret

  test "inspect prints no field of the struct" do
    secret = %ShownSecret{value: "not-a-token-probe-value-d442"}

    assert inspect(secret) == "#KanbanWeb.ShownSecret<...>"
    refute inspect(%{new_token: secret}) =~ "probe-value"
    assert secret.value == "not-a-token-probe-value-d442"
  end

  test "the value is required" do
    assert_raise ArgumentError, fn -> struct!(ShownSecret, %{}) end
  end
end
