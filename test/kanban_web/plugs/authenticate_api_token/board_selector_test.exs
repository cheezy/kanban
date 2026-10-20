defmodule KanbanWeb.Plugs.AuthenticateApiToken.BoardSelectorTest do
  @moduledoc """
  `read/1` on hand-built conns. The end-to-end behaviour through the router is
  covered by `KanbanWeb.API.WorkspaceTokenFlowTest`.
  """
  use ExUnit.Case, async: true

  import Plug.Conn, only: [put_req_header: 3]

  alias KanbanWeb.Plugs.AuthenticateApiToken.BoardSelector

  describe "read/1" do
    test "takes the header or the param" do
      assert read([], " 12 ") == {:ok, 12}
      assert read(params: %{"board_id" => "012"}) == {:ok, 12}
      assert read(params: %{"board_id" => 12}) == {:ok, 12}
    end

    test "is :none without a selector, or with only blank ones" do
      assert read([]) == :none
      assert read(params: %{"board_id" => " "}) == :none
      assert read(query: "board_id=") == :none
    end

    test "accepts a header and a param that agree, and refuses ones that do not" do
      assert read([params: %{"board_id" => 12}], "12") == {:ok, 12}
      assert read([params: %{"board_id" => 13}], "12") == :conflict
    end

    test "refuses a repeated query-string board_id, whatever the values" do
      for query <- [
            "board_id=1&board_id=2",
            "board_id=1&board_id=1",
            "board_id=1&x=2&board_id=",
            "board_id[]=1&board_id=2",
            "board_id%5B%5D=1&board%5Fid=2"
          ] do
        assert read(query: query, params: %{"board_id" => "2"}) ==
                 :conflict,
               query
      end
    end

    test "takes a single query-string board_id beside other parameters" do
      conn = conn(query: "limit=5&board_id=7&board_idx=9", params: %{"board_id" => "7"})
      assert BoardSelector.read(conn) == {:ok, 7}
    end

    test "does not raise on a raw key it cannot decode" do
      assert read(query: "%ZZ=1&board_id=3", params: %{"board_id" => "3"}) ==
               {:ok, 3}
    end

    test "refuses a query-string board_id that disagrees with the body's" do
      conn = conn(query_params: %{"board_id" => "1"}, body_params: %{"board_id" => 2})
      assert BoardSelector.read(conn) == :conflict
    end

    test "accepts a query-string and a body board_id that agree, or one blank" do
      for {query, body, expected} <- [{"1", 1, 1}, {" 1 ", "001", 1}, {"", 4, 4}, {"5", "", 5}] do
        conn =
          conn(
            query_params: %{"board_id" => query},
            body_params: %{"board_id" => body},
            params: %{"board_id" => body}
          )

        assert BoardSelector.read(conn) == {:ok, expected}
      end
    end

    test "refuses a repeated header" do
      conn =
        conn()
        |> Map.update!(:req_headers, &[{"x-stride-board", "1"}, {"x-stride-board", "1"} | &1])

      assert BoardSelector.read(conn) == :conflict
    end
  end

  defp read(opts, header \\ nil) do
    opts
    |> conn()
    |> put_header(header)
    |> BoardSelector.read()
  end

  defp put_header(conn, nil), do: conn
  defp put_header(conn, value), do: put_req_header(conn, "x-stride-board", value)

  defp conn(opts \\ []) do
    conn = Plug.Test.conn(:get, "/api/tasks")

    %{
      conn
      | query_string: Keyword.get(opts, :query, ""),
        params: Keyword.get(opts, :params, %{}),
        query_params: Keyword.get(opts, :query_params, conn.query_params),
        body_params: Keyword.get(opts, :body_params, conn.body_params)
    }
  end
end
