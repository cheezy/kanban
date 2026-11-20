defmodule KanbanWeb.AppLinksControllerTest do
  # async: false — tests here replace the :app_links application config,
  # which is global.
  use KanbanWeb.ConnCase, async: false

  import Kanban.AccountsFixtures

  @apple "/.well-known/apple-app-site-association"
  @android "/.well-known/assetlinks.json"
  @paths [@apple, @android]
  @public_cache "public, max-age=3600"

  @fingerprint "AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99"
  @second_fingerprint "11:22:33:44:55:66:77:88:99:00:AA:BB:CC:DD:EE:FF:11:22:33:44:55:66:77:88:99:00:AA:BB:CC:DD:EE:FF"

  # The six router paths the app handles (design §6.20). Nothing else may
  # open it.
  @app_routes [
    "/review",
    "/agents",
    "/boards/:id",
    "/boards/:id/goals/:goal_id",
    "/boards/:id/tasks/:task_id/edit",
    "/targets/:id"
  ]

  setup do
    saved = Application.fetch_env(:kanban, :app_links)

    on_exit(fn ->
      case saved do
        {:ok, config} -> Application.put_env(:kanban, :app_links, config)
        :error -> Application.delete_env(:kanban, :app_links)
      end
    end)
  end

  defp configure(config), do: Application.put_env(:kanban, :app_links, config)

  defp full_config(overrides \\ []) do
    Keyword.merge(
      [
        ios_team_id: "ABCDE12345",
        ios_bundle_id: "com.example.stride",
        android_package: "com.example.stride",
        android_cert_fingerprints: [@fingerprint]
      ],
      overrides
    )
  end

  # Apple's components matching: entries are tried in order and the first
  # whose pattern matches the whole path decides; `*` is any run of
  # characters including `/`, and `?` is exactly one. Written here from
  # Apple's rules rather than taken from the controller, so the served list
  # is checked against an independent reading of it.
  defp opens_app?(components, path) do
    case Enum.find(components, &(&1 |> Map.fetch!("/") |> glob() |> Regex.match?(path))) do
      nil -> false
      component -> component["exclude"] != true
    end
  end

  defp glob(pattern) do
    body =
      pattern
      |> String.graphemes()
      |> Enum.map_join(fn
        "*" -> ".*"
        "?" -> "."
        char -> Regex.escape(char)
      end)

    Regex.compile!("\\A" <> body <> "\\z")
  end

  # A router path with every parameter filled in, as a link would carry it.
  defp sample(path) do
    path
    |> String.split("/")
    |> Enum.map_join("/", fn
      ":" <> _param -> "42"
      "*" <> _glob -> "a/b"
      segment -> segment
    end)
  end

  defp served_components do
    %{"applinks" => %{"details" => [%{"components" => components}]}} =
      build_conn() |> get(@apple) |> json_response(200)

    components
  end

  describe "apple-app-site-association" do
    test "apple-app-site-association lists only the app paths" do
      configure(full_config())

      body = build_conn() |> get(@apple) |> json_response(200)

      assert %{"applinks" => %{"details" => [detail]}} = body
      assert map_size(body) == 1
      assert detail["appIDs"] == ["ABCDE12345.com.example.stride"]

      components = detail["components"]
      refute Enum.any?(components, &(&1["/"] in ["*", "/*", "/"]))

      get_paths =
        KanbanWeb.Router.__routes__()
        |> Enum.filter(&(&1.verb == :get))
        |> Enum.map(& &1.path)
        |> Enum.uniq()

      # Every one of the six exists in the router, so a renamed route fails
      # here rather than leaving a dead link in the file.
      for route <- @app_routes, do: assert(route in get_paths)

      opening = Enum.filter(get_paths, &opens_app?(components, sample(&1)))
      assert Enum.sort(opening) == Enum.sort(@app_routes)
    end

    test "the app paths open the app and their neighbours stay in the browser" do
      configure(full_config())
      components = served_components()

      for path <-
            ~w(/review /agents /boards/7 /boards/7/goals/9 /boards/7/tasks/9/edit /targets/7) do
        assert opens_app?(components, path), "expected #{path} to open the app"
      end

      for path <- ~w(
            / /reviews /review/ /agents/ /agents/7 /boards /boards/ /boards/new
            /boards/7/ /boards/7/settings /boards/7/goals/new /boards/7/goals/9/
            /boards/7/goals/9/edit /boards/7/tasks/9 /boards/7/tasks/9/edit/
            /targets /targets/ /targets/new /targets/archived /targets/7/edit
            /users/settings /api/me
          ) do
        refute opens_app?(components, path), "expected #{path} to stay in the browser"
      end
    end

    test "with only the team id or only the bundle id no app is listed" do
      for overrides <- [[ios_bundle_id: nil], [ios_team_id: nil], [ios_team_id: ""]] do
        configure(full_config(overrides))

        assert build_conn() |> get(@apple) |> json_response(200) ==
                 %{"applinks" => %{"details" => []}}
      end
    end
  end

  describe "assetlinks.json" do
    test "assetlinks.json lists the package and fingerprints" do
      configure(full_config(android_cert_fingerprints: [@fingerprint, @second_fingerprint]))

      assert build_conn() |> get(@android) |> json_response(200) == [
               %{
                 "relation" => ["delegate_permission/common.handle_all_urls"],
                 "target" => %{
                   "namespace" => "android_app",
                   "package_name" => "com.example.stride",
                   "sha256_cert_fingerprints" => [@fingerprint, @second_fingerprint]
                 }
               }
             ]
    end

    test "a blank fingerprint among several is dropped and the rest are listed" do
      configure(
        full_config(android_cert_fingerprints: [@fingerprint, "", "  ", @second_fingerprint])
      )

      assert [%{"target" => %{"sha256_cert_fingerprints" => fingerprints}}] =
               build_conn() |> get(@android) |> json_response(200)

      assert fingerprints == [@fingerprint, @second_fingerprint]
    end

    test "with no fingerprint or no package no app is listed" do
      for overrides <- [
            [android_cert_fingerprints: []],
            [android_cert_fingerprints: [""]],
            [android_cert_fingerprints: nil],
            [android_package: nil],
            [android_package: " "]
          ] do
        configure(full_config(overrides))

        assert build_conn() |> get(@android) |> json_response(200) == []
      end
    end
  end

  describe "both files" do
    test "with no config both files list no apps" do
      Application.delete_env(:kanban, :app_links)

      assert build_conn() |> get(@apple) |> json_response(200) ==
               %{"applinks" => %{"details" => []}}

      assert build_conn() |> get(@android) |> json_response(200) == []

      configure([])

      assert build_conn() |> get(@apple) |> json_response(200) ==
               %{"applinks" => %{"details" => []}}

      assert build_conn() |> get(@android) |> json_response(200) == []
    end

    test "the test config lists one app per platform" do
      assert %{"applinks" => %{"details" => [%{"appIDs" => ["TEST123456.com.stride.test"]}]}} =
               build_conn() |> get(@apple) |> json_response(200)

      assert [%{"target" => %{"package_name" => "com.stride.test"}}] =
               build_conn() |> get(@android) |> json_response(200)
    end

    test "both answer application/json without a session or redirect" do
      configure(full_config())

      for path <- @paths, accept <- ["*/*", "application/json", "text/html"] do
        conn = build_conn() |> put_req_header("accept", accept) |> get(path)

        assert conn.status == 200
        assert [content_type] = get_resp_header(conn, "content-type")
        assert content_type =~ ~r{\Aapplication/json}
        assert get_resp_header(conn, "location") == []
        assert get_resp_header(conn, "set-cookie") == []
        assert conn.resp_cookies == %{}
        assert get_resp_header(conn, "cache-control") == [@public_cache]
        assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]

        assert get_resp_header(conn, "content-security-policy") == [
                 "default-src 'none'; frame-ancestors 'none'"
               ]

        assert {:ok, _decoded} = Jason.decode(conn.resp_body)
      end
    end

    test "both are served to signed-out requests", %{conn: conn} do
      configure(full_config())
      signed_in = log_in_user(conn, user_fixture())

      for path <- @paths do
        anonymous = build_conn() |> get(path)

        assert anonymous.status == 200
        assert response(anonymous, 200) == signed_in |> get(path) |> response(200)
      end
    end

    test "the paths with a trailing slash serve the same files" do
      configure(full_config())

      for path <- @paths do
        assert build_conn() |> get(path <> "/") |> response(200) ==
                 build_conn() |> get(path) |> response(200)
      end
    end

    test "POST, PUT, PATCH and DELETE are not routed" do
      for path <- @paths, method <- [:post, :put, :patch, :delete] do
        conn = dispatch(build_conn(), @endpoint, method, path)

        assert conn.status == 404
        assert conn.private[:phoenix_controller] == nil
      end
    end
  end
end
