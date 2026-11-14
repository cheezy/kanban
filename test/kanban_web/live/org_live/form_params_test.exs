defmodule KanbanWeb.OrgLive.FormParamsTest do
  use ExUnit.Case, async: true

  alias KanbanWeb.OrgLive.FormParams

  describe "scalar/2" do
    test "keeps every string value, whatever the field is called" do
      params = %{"issuer" => "https://idp.example.com", "new_field" => "x", "blank" => ""}
      assert FormParams.scalar(params) == params
    end

    test "turns a map, a list, an integer or nil into a blank" do
      params = %{
        "a" => %{"b" => "1"},
        "c" => [%{"d" => "1"}],
        "e" => ["f"],
        "g" => 42,
        "h" => nil
      }

      assert FormParams.scalar(params) ==
               %{"a" => "", "c" => "", "e" => "", "g" => "", "h" => ""}
    end

    test "keeps a checkbox only as the true or false the checkbox sends" do
      assert FormParams.scalar(%{"enabled" => "true"}, ["enabled"]) == %{"enabled" => "true"}
      assert FormParams.scalar(%{"enabled" => "false"}, ["enabled"]) == %{"enabled" => "false"}

      for value <- [%{"a" => "1"}, ["true"], "yes", "", nil, 1] do
        assert FormParams.scalar(%{"enabled" => value, "name" => "n"}, ["enabled"]) ==
                 %{"name" => "n"}
      end
    end

    test "treats a field as a checkbox only when it is named one" do
      assert FormParams.scalar(%{"enabled" => %{"a" => "1"}}) == %{"enabled" => ""}
    end
  end
end
