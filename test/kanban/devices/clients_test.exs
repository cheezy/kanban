defmodule Kanban.Devices.ClientsTest do
  use ExUnit.Case, async: true

  import Kanban.DevicesFixtures, only: [valid_code_challenge: 0]

  alias Kanban.Devices.AuthorizationCode
  alias Kanban.Devices.Clients

  @redirect_uri "com.stridelikeaboss.app:/oauth/callback"

  defp params(overrides \\ %{}) do
    Map.merge(
      %{
        "response_type" => "code",
        "client_id" => "stride-android",
        "redirect_uri" => @redirect_uri,
        "code_challenge" => valid_code_challenge(),
        "code_challenge_method" => "S256",
        "state" => "abc 123",
        "device_name" => "Pixel 9",
        "device_class" => "phone"
      },
      overrides
    )
  end

  test "only stride-ios and stride-android with the fixed redirect URI are valid" do
    assert Clients.client_ids() == ["stride-ios", "stride-android"]
    assert Clients.redirect_uri() == @redirect_uri

    assert Clients.valid?("stride-ios", @redirect_uri)
    assert Clients.valid?("stride-android", @redirect_uri)

    for client <- ["stride-web", "STRIDE-IOS", " stride-ios", "", nil, ["stride-ios"], 1] do
      refute Clients.valid_client?(client), inspect(client)
      refute Clients.valid?(client, @redirect_uri), inspect(client)
    end

    for uri <- [
          @redirect_uri <> "/",
          @redirect_uri <> "?x=1",
          "com.stridelikeaboss.app://oauth/callback",
          "COM.STRIDELIKEABOSS.APP:/oauth/callback",
          "https://www.stridelikeaboss.com/oauth/callback",
          " " <> @redirect_uri,
          nil,
          [@redirect_uri]
        ] do
      refute Clients.valid_redirect_uri?(uri), inspect(uri)
      refute Clients.valid?("stride-ios", uri), inspect(uri)
    end
  end

  test "redirect_scheme_source/0 is the redirect URI's scheme as a CSP source" do
    assert Clients.redirect_scheme_source() == "com.stridelikeaboss.app:"
    assert String.starts_with?(Clients.redirect_uri(), Clients.redirect_scheme_source())
  end

  test "device_classes/0 matches the device enum" do
    assert Clients.device_classes() == ["phone", "tablet"]
  end

  describe "validate_authorize_request/1" do
    test "returns the request's fields when every check passes" do
      assert {:ok, request} = Clients.validate_authorize_request(params())

      assert request == %{
               client_id: "stride-android",
               redirect_uri: @redirect_uri,
               code_challenge: valid_code_challenge(),
               state: "abc 123",
               device_name: "Pixel 9",
               device_class: "phone"
             }
    end

    test "accepts an absent response_type and a tablet" do
      params = params(%{"device_class" => "tablet"}) |> Map.delete("response_type")

      assert {:ok, %{device_class: "tablet"}} = Clients.validate_authorize_request(params)
    end

    test "names the first check that failed" do
      for {override, reason} <- [
            {%{"response_type" => "token"}, :unsupported_response_type},
            {%{"client_id" => "other"}, :invalid_client},
            {%{"redirect_uri" => "https://evil.test"}, :invalid_redirect_uri},
            {%{"code_challenge_method" => "plain"}, :invalid_code_challenge_method},
            {%{"code_challenge_method" => "s256"}, :invalid_code_challenge_method},
            {%{"code_challenge" => String.duplicate("a", 42)}, :invalid_code_challenge},
            {%{"code_challenge" => String.duplicate("a", 42) <> "="}, :invalid_code_challenge},
            {%{"state" => ""}, :invalid_state},
            {%{"state" => String.duplicate("s", 256)}, :invalid_state},
            {%{"state" => "tab\there"}, :invalid_state},
            {%{"state" => "café"}, :invalid_state},
            {%{"state" => ["a"]}, :invalid_state},
            {%{"device_name" => ""}, :invalid_device_name},
            {%{"device_name" => "​"}, :invalid_device_name},
            {%{"device_name" => "nul\0byte"}, :invalid_device_name},
            {%{"device_name" => String.duplicate("é", 256)}, :invalid_device_name},
            {%{"device_name" => %{"a" => "b"}}, :invalid_device_name},
            {%{"device_class" => "watch"}, :invalid_device_class},
            {%{"device_class" => ["phone"]}, :invalid_device_class}
          ] do
        assert override |> params() |> Clients.validate_authorize_request() == {:error, reason},
               inspect(override)
      end

      for key <- ~w(client_id redirect_uri code_challenge_method code_challenge state
                    device_name device_class) do
        assert {:error, _reason} =
                 params() |> Map.delete(key) |> Clients.validate_authorize_request(),
               key
      end
    end

    test "accepts a 255-character state and a 255-character device name" do
      params =
        params(%{
          "state" => String.duplicate("s", 255),
          "device_name" => String.duplicate("é", 255)
        })

      assert {:ok, _request} = Clients.validate_authorize_request(params)
    end

    test "counts a device name's length in codepoints, as the stored code does" do
      # 200 graphemes, each an "e" plus a combining acute accent: 400 codepoints.
      decomposed = String.duplicate("e\u0301", 200)
      assert String.length(decomposed) == 200

      assert %{"device_name" => decomposed} |> params() |> Clients.validate_authorize_request() ==
               {:error, :invalid_device_name}
    end
  end

  describe "repeated_parameter?/1" do
    test "is true when a request parameter appears more than once in any form" do
      for query <- [
            "state=a&state=b",
            "state=a&state[]=b",
            "client_id=stride-ios&device_name=x&client_id=stride-ios",
            "device_class[x]=a&device_class=phone",
            "response_type=code&response_type=code"
          ] do
        assert Clients.repeated_parameter?(query), query
      end
    end

    test "is false for a single use of each parameter and for other repeated keys" do
      for query <- [
            "",
            "state=a&client_id=stride-ios",
            "utm=a&utm=b&state=a",
            "state=a%26state%3Db"
          ] do
        refute Clients.repeated_parameter?(query), query
      end
    end
  end

  test "a device name with a control character or bidirectional override is refused" do
    for name <- [
          "Pixel\u202E9",
          "a\u202Ab",
          "a\u2066b\u2069",
          "a\u200Eb",
          "a\u200Fb",
          "a\rb",
          "a\nb",
          "a\tb",
          "a\u007Fb"
        ] do
      assert %{"device_name" => name} |> params() |> Clients.validate_authorize_request() ==
               {:error, :invalid_device_name},
             inspect(name)
    end

    assert {:ok, _request} =
             %{"device_name" => "Jeff’s iPad — 日本"}
             |> params()
             |> Clients.validate_authorize_request()
  end

  test "code_attrs/1 keeps only the fields an authorization code stores" do
    {:ok, request} = Clients.validate_authorize_request(params())

    assert Clients.code_attrs(request) == %{
             client_id: "stride-android",
             code_challenge: valid_code_challenge(),
             redirect_uri: @redirect_uri,
             device_name: "Pixel 9"
           }
  end

  describe "callback_uri/1" do
    test "appends the query to the fixed redirect URI in the order given" do
      assert Clients.callback_uri(code: "sdac_x", state: "s") ==
               @redirect_uri <> "?code=sdac_x&state=s"

      assert Clients.callback_uri(error: "access_denied", state: "s") ==
               @redirect_uri <> "?error=access_denied&state=s"
    end

    test "percent-encodes per RFC 3986, so a space is %20 and a plus survives" do
      uri = Clients.callback_uri(code: "c", state: "a b+c&d=e")

      assert uri == @redirect_uri <> "?code=c&state=a%20b%2Bc%26d%3De"
      assert URI.decode_query(URI.parse(uri).query)["state"] == "a b+c&d=e"
    end
  end

  test "AuthorizationCode.valid_code_challenge?/1 accepts only a 43-character base64url value" do
    assert AuthorizationCode.valid_code_challenge?(valid_code_challenge())
    refute "a" |> String.duplicate(44) |> AuthorizationCode.valid_code_challenge?()
    refute "+" |> String.duplicate(43) |> AuthorizationCode.valid_code_challenge?()
    refute AuthorizationCode.valid_code_challenge?(nil)
    refute AuthorizationCode.valid_code_challenge?(["x"])
  end
end
