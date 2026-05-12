import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/kanban start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :kanban, KanbanWeb.Endpoint, server: true
end

# GitHub integration for issue submission
# Set GITHUB_TOKEN to a personal access token with repo/issues write permission
# Set GITHUB_REPO to the owner/repo format (e.g., "username/kanban")
if github_token = System.get_env("GITHUB_TOKEN") do
  config :kanban, :github,
    token: github_token,
    repo: System.get_env("GITHUB_REPO")
end

# Flip /complete explorer_result / reviewer_result validation to strict mode
# without a redeploy by setting STRIDE_STRICT_COMPLETION_VALIDATION=true.
if System.get_env("STRIDE_STRICT_COMPLETION_VALIDATION") == "true" do
  config :kanban, :strict_completion_validation, true
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  # W394 + post-deploy fix: encrypt Postgres connections in production, but let
  # the deployment opt into peer certificate verification.
  #
  #   DATABASE_SSL_VERIFY=peer  → verify_peer against DATABASE_SSL_CACERTFILE
  #                               (or CAStore.file_path() if unset). Required
  #                               when the DB is reached over the public
  #                               internet (Neon, Supabase, RDS public IP, …).
  #
  #   DATABASE_SSL_VERIFY=none  → verify_none, encrypted but no chain check.
  #                               This is the safe default on Fly.io's 6PN
  #                               private network where Postgres presents a
  #                               self-signed Fly-internal cert and the network
  #                               itself is the trust boundary.
  #
  # Default is :verify_none so first-deploy on Fly doesn't fail; operators
  # serving public-internet Postgres must explicitly set DATABASE_SSL_VERIFY=peer.
  #
  # Note: Postgrex splits TLS configuration across TWO keys — `ssl:` is the
  # boolean flag (enable/disable TLS) and `ssl_opts:` is the keyword list
  # passed through to `:ssl.connect/3`. Putting the keyword list under `ssl:`
  # makes Postgrex enable TLS (the list is truthy) but never threads the
  # verify option into the actual handshake, which is what caused the original
  # `Certificate Unknown` alert in the Fly deploy.
  ssl_opts =
    case System.get_env("DATABASE_SSL_VERIFY", "none") do
      "peer" ->
        cacertfile = System.get_env("DATABASE_SSL_CACERTFILE") || CAStore.file_path()
        [verify: :verify_peer, cacertfile: cacertfile, server_name_indication: :disable]

      "none" ->
        [verify: :verify_none, server_name_indication: :disable]

      other ->
        raise """
        Invalid DATABASE_SSL_VERIFY value: #{inspect(other)}. Expected "peer" or "none".
        """
    end

  config :kanban, Kanban.Repo,
    ssl: true,
    ssl_opts: ssl_opts,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6,
    disconnect_on_error_codes: [:fatal_postmaster, :closed]

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "www.stridelikeaboss.com"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :kanban, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :kanban, KanbanWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :kanban, KanbanWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :kanban, KanbanWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :kanban, Kanban.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.
  config :kanban, Kanban.Mailer,
    adapter: Swoosh.Adapters.SMTP,
    username: System.get_env("SMTP_USERNAME"),
    password: System.get_env("SMTP_PASSWORD"),
    relay: System.get_env("SMTP_RELAY") || "smtp.gmail.com",
    ssl: true,
    auth: :always,
    port: 465,
    retries: 1
end
