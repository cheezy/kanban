defmodule KanbanWeb.API.Me.PageParamsTest do
  use ExUnit.Case, async: true

  alias KanbanWeb.API.Me.PageParams

  @bad {:error, {:bad_request, "page must be an integer from 1 to 10000."}}

  test "reads a page from 1 to 10,000, and 1 when it is not sent" do
    assert PageParams.parse(%{}) == {:ok, 1}
    assert PageParams.parse(%{"page" => "1"}) == {:ok, 1}
    assert PageParams.parse(%{"page" => "10000"}) == {:ok, 10_000}
    assert PageParams.max_page() == 10_000
  end

  test "refuses anything else" do
    for page <- ["0", "10001", "-1", "2.5", "abc", "", ["1"], %{"a" => "1"}] do
      assert PageParams.parse(%{"page" => page}) == @bad
    end
  end
end
