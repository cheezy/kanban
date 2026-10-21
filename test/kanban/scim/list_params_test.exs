defmodule Kanban.SCIM.ListParamsTest do
  use ExUnit.Case, async: true

  alias Kanban.SCIM.ListParams

  doctest Kanban.SCIM.ListParams

  test "clamps values a client gets wrong" do
    assert ListParams.parse(%{"startIndex" => "0", "count" => "-5"}) == %{
             start_index: 1,
             count: 0
           }

    assert ListParams.parse(%{"startIndex" => 7, "count" => 5000}) == %{
             start_index: 7,
             count: 200
           }
  end

  test "falls back to the defaults for non-integers" do
    assert ListParams.parse(%{"startIndex" => "x", "count" => "1.5"}) ==
             %{start_index: 1, count: 100}

    assert ListParams.parse(%{"startIndex" => "99999999999999999999"}) ==
             %{start_index: 1, count: 100}

    assert ListParams.parse(%{"count" => %{}}) == %{start_index: 1, count: 100}
  end

  test "max_count/0 is the page cap" do
    assert ListParams.max_count() == 200
  end
end
