defmodule Mix.Tasks.Stride.OidcDemo do
  @shortdoc "Runs a disposable Dex-backed OIDC demo for local Stride"

  @moduledoc """
  Runs a small, disposable Dex-backed OIDC demo for local Stride development.

      mix stride.oidc_demo

  The task starts a Dex container, configures Stride to use it as the OIDC
  provider, runs dev database setup, then starts the Phoenix server.

  Demo login:

      email:    admin@example.com
      password: password

  Options:

    * `--stop` - stop and remove the Dex demo container
    * `--verify` - run a headless browser through the full SSO flow, then stop
    * `--no-setup` - skip `ecto.create` and `ecto.migrate`
    * `--no-server` - start Dex and print settings without starting Phoenix

  This is intentionally a throwaway demonstration harness, not production
  deployment machinery.
  """

  use Mix.Task

  @container "stride-oidc-demo-dex"
  @client_id "stride"
  @client_secret "stride-secret"
  @display_name "Dex Demo"
  @email "admin@example.com"
  @password "password"

  @impl Mix.Task
  def run(args) do
    {opts, _argv, _invalid} =
      OptionParser.parse(args,
        strict: [
          stop: :boolean,
          verify: :boolean,
          no_setup: :boolean,
          no_server: :boolean
        ]
      )

    if opts[:stop] do
      stop_dex()
    else
      start_demo(opts)
    end
  end

  defp start_demo(opts) do
    ensure_docker!()

    public_host = "localhost"
    config_path = write_dex_config(public_host)
    restart_dex(config_path)
    wait_for_dex!(public_host)

    unless opts[:no_setup] do
      Mix.Task.run("ecto.create", ["--quiet"])
      Mix.Task.reenable("ecto.migrate")
      Mix.Task.run("ecto.migrate", [])
    end

    configure_stride(public_host)
    print_ready(opts)

    cond do
      opts[:verify] ->
        try do
          start_stride_server!(public_host)
          run_browser_verifier!(public_host)
          verify_database!(public_host)
          Mix.shell().info("OIDC e2e verification passed.")
        after
          stop_dex(:quiet)
        end

      opts[:no_server] ->
        :ok

      true ->
        System.at_exit(fn _status -> stop_dex(:quiet) end)
        Mix.Task.run("phx.server")
    end
  end

  defp ensure_docker! do
    case System.find_executable("docker") do
      nil ->
        Mix.raise("docker was not found. Start OrbStack or install Docker, then try again.")

      _docker ->
        :ok
    end
  end

  defp restart_dex(config_path) do
    stop_dex(:quiet)

    image = System.get_env("STRIDE_OIDC_DEMO_DEX_IMAGE", "dexidp/dex:v2.43.1")
    port = dex_port()

    docker!(
      [
        "run",
        "--detach",
        "--name",
        @container,
        "--publish",
        "#{port}:5556",
        "--volume",
        "#{config_path}:/etc/dex/config.yaml:ro",
        image,
        "dex",
        "serve",
        "/etc/dex/config.yaml"
      ],
      "failed to start Dex"
    )

    :ok
  end

  defp stop_dex(mode \\ :normal) do
    case docker(["rm", "--force", @container], stderr_to_stdout: true) do
      {_output, 0} ->
        unless mode == :quiet do
          Mix.shell().info("Stopped #{@container}.")
        end

      {_output, _status} ->
        unless mode == :quiet do
          Mix.shell().info("#{@container} was not running.")
        end
    end
  end

  defp wait_for_dex!(public_host) do
    Application.ensure_all_started(:req)

    discovery_url = "#{issuer(public_host)}/.well-known/openid-configuration"

    1..50
    |> Enum.reduce_while(nil, fn _attempt, _ ->
      case Req.get(discovery_url, retry: false) do
        {:ok, %{status: status}} when status in 200..299 ->
          {:halt, :ok}

        _result ->
          Process.sleep(200)
          {:cont, nil}
      end
    end)
    |> case do
      :ok -> :ok
      _ -> Mix.raise("Dex did not become ready at #{discovery_url}")
    end
  end

  defp configure_stride(public_host) do
    Application.put_env(:kanban, :oidc,
      enabled: true,
      issuer: issuer(public_host),
      client_id: @client_id,
      client_secret: @client_secret,
      display_name: @display_name,
      scopes: "openid email profile",
      admin_group_claim: "groups",
      admin_groups: []
    )
  end

  defp print_ready(opts) do
    public_host = "localhost"

    Mix.shell().info("""

    Stride OIDC demo is ready.

      Stride: http://localhost:#{stride_port()}
      Dex:    #{issuer(public_host)}

      Email:    #{@email}
      Password: #{@password}

    Click "Sign in with #{@display_name}" on the Stride login page.
    """)

    if opts[:no_server] == true and opts[:verify] != true do
      Mix.shell().info("""
      Run Stride separately with:

        STRIDE_OIDC_ISSUER=#{issuer(public_host)} \\
        STRIDE_OIDC_CLIENT_ID=#{@client_id} \\
        STRIDE_OIDC_CLIENT_SECRET=#{@client_secret} \\
        STRIDE_OIDC_DISPLAY_NAME="#{@display_name}" \\
        mix phx.server

      Stop Dex with:

        mix stride.oidc_demo --stop
      """)
    end
  end

  defp start_stride_server!(public_host) do
    endpoint_config = Application.get_env(:kanban, KanbanWeb.Endpoint, [])
    Application.put_env(:kanban, KanbanWeb.Endpoint, Keyword.put(endpoint_config, :server, true))

    System.put_env("PHX_HOST", public_host)
    Mix.Task.run("app.start")
    wait_for_stride!(public_host)
  end

  defp wait_for_stride!(public_host) do
    Application.ensure_all_started(:req)

    login_url = "http://#{public_host}:#{stride_port()}/users/log-in"

    1..50
    |> Enum.reduce_while(nil, fn _attempt, _ ->
      case Req.get(login_url, retry: false) do
        {:ok, %{status: status}} when status in 200..299 ->
          {:halt, :ok}

        _result ->
          Process.sleep(200)
          {:cont, nil}
      end
    end)
    |> case do
      :ok -> :ok
      _ -> Mix.raise("Stride did not become ready at #{login_url}")
    end
  end

  defp run_browser_verifier!(public_host) do
    script_path = write_verifier_script()

    image =
      System.get_env(
        "STRIDE_OIDC_DEMO_PLAYWRIGHT_IMAGE",
        "mcr.microsoft.com/playwright:v1.56.1-noble"
      )

    docker!(
      [
        "run",
        "--rm",
        "--network",
        "host",
        "--volume",
        "#{script_path}:/tmp/stride-oidc-demo.spec.js:ro",
        "--env",
        "STRIDE_URL=http://#{public_host}:#{stride_port()}",
        "--env",
        "DEX_EMAIL=#{@email}",
        "--env",
        "DEX_PASSWORD=#{@password}",
        "--env",
        "PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1",
        image,
        "sh",
        "-lc",
        "npm install --prefix /tmp/stride-playwright --silent --no-audit --no-fund @playwright/test@1.56.1 >/dev/null && NODE_PATH=/tmp/stride-playwright/node_modules /tmp/stride-playwright/node_modules/.bin/playwright test /tmp/stride-oidc-demo.spec.js --browser=chromium --reporter=line"
      ],
      "OIDC browser verification failed"
    )
  end

  defp verify_database!(public_host) do
    alias Kanban.Accounts.User
    alias Kanban.Accounts.UserIdentity
    alias Kanban.Repo

    user = Repo.get_by(User, email: @email) || Mix.raise("OIDC demo user was not created")

    Repo.get_by(UserIdentity,
      user_id: user.id,
      issuer: issuer(public_host),
      email: @email
    ) || Mix.raise("OIDC demo identity row was not created")
  end

  defp write_dex_config(public_host) do
    dir = Path.join(System.tmp_dir!(), "stride-oidc-demo")
    File.mkdir_p!(dir)

    path = Path.join(dir, "dex.yaml")
    File.write!(path, dex_config(public_host))
    path
  end

  defp dex_config(public_host) do
    """
    issuer: #{issuer(public_host)}

    storage:
      type: memory

    web:
      http: 0.0.0.0:5556

    oauth2:
      skipApprovalScreen: true

    enablePasswordDB: true

    staticClients:
      - id: #{@client_id}
        name: Stride
        secret: #{@client_secret}
        redirectURIs:
          - http://localhost:#{stride_port()}/users/sso/callback
          - http://host.docker.internal:#{stride_port()}/users/sso/callback

    staticPasswords:
      - email: "#{@email}"
        # bcrypt hash for "password"
        hash: "$2a$10$2b2cU8CPhOTaGrs1HRQuAueS7JTT5ZHsHSzYiFPm1leZck7Mc8T4W"
        username: "admin"
        userID: "stride-oidc-demo-admin"
    """
  end

  defp write_verifier_script do
    dir = Path.join(System.tmp_dir!(), "stride-oidc-demo")
    File.mkdir_p!(dir)

    path = Path.join(dir, "verify-oidc.spec.js")
    File.write!(path, verifier_script())
    path
  end

  defp verifier_script do
    """
    const { test, expect } = require('@playwright/test');

    const strideUrl = process.env.STRIDE_URL;
    const email = process.env.DEX_EMAIL;
    const password = process.env.DEX_PASSWORD;

    test('logs into Stride through Dex OIDC', async ({ page }) => {
      await page.goto(`${strideUrl}/users/log-in`);
      await expect(page.getByRole('link', { name: /sign in with dex demo/i })).toBeVisible();
      await page.getByRole('link', { name: /sign in with dex demo/i }).click();

      await page.locator('input[name="login"]').fill(email);
      await page.locator('input[name="password"]').fill(password);
      await page.locator('button[type="submit"], input[type="submit"]').click();

      await expect(page).toHaveURL(/\\/boards(?:$|[?#])/, { timeout: 15000 });
      await expect(page.getByText(/boards/i).first()).toBeVisible({ timeout: 15000 });
    });
    """
  end

  defp issuer(public_host), do: "http://#{public_host}:#{dex_port()}/dex"

  defp dex_port do
    System.get_env("STRIDE_OIDC_DEMO_DEX_PORT", "5556")
  end

  defp stride_port do
    System.get_env("PORT", "4000")
  end

  defp docker(args, opts \\ []) do
    System.cmd("docker", args, Keyword.merge([stderr_to_stdout: true], opts))
  end

  defp docker!(args, message) do
    case docker(args) do
      {_output, 0} ->
        :ok

      {output, status} ->
        Mix.raise("""
        #{message} (docker exited #{status}).

        #{String.trim(output)}
        """)
    end
  end
end
