defmodule KanbanWeb.Plugs.BearerChallengeTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias KanbanWeb.Plugs.BearerChallenge

  describe "put_challenge/2" do
    test ":no_token is a plain Bearer challenge with no error attribute" do
      conn = conn(:get, "/") |> BearerChallenge.put_challenge(:no_token)

      assert get_resp_header(conn, "www-authenticate") == ["Bearer"]
    end

    test ":invalid_token adds error=\"invalid_token\" and nothing else" do
      conn = conn(:get, "/") |> BearerChallenge.put_challenge(:invalid_token)

      assert get_resp_header(conn, "www-authenticate") == [~s(Bearer error="invalid_token")]
    end

    test "names no realm and leaves the status and body alone" do
      for kind <- [:no_token, :invalid_token] do
        conn = conn(:get, "/") |> BearerChallenge.put_challenge(kind)

        [challenge] = get_resp_header(conn, "www-authenticate")
        refute challenge =~ "realm"
        assert conn.status == nil
        assert conn.resp_body == nil
      end
    end

    test "replaces rather than repeats an earlier challenge" do
      conn =
        conn(:get, "/")
        |> BearerChallenge.put_challenge(:no_token)
        |> BearerChallenge.put_challenge(:invalid_token)

      assert get_resp_header(conn, "www-authenticate") == [~s(Bearer error="invalid_token")]
    end
  end
end
