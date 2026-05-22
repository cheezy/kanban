import Config

# Mark this as test environment
config :kanban, :env, :test

# Disable the BoardLive.Index periodic metrics refresh during tests so
# the 30s timer doesn't fire after the Ecto sandbox is checked back in,
# which would otherwise spray Postgrex disconnect errors into the log.
config :kanban, :board_index_refresh_ms, 0

# Enable the Phoenix.Ecto.SQL.Sandbox plug in the endpoint so LiveView
# processes spawned by tests share the test owner's sandbox connection
# instead of checking out their own (and triggering disconnect logs).
config :kanban, :sql_sandbox, true

# Only in tests, remove the complexity from the password hashing algorithm
config :bcrypt_elixir, :log_rounds, 1

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :kanban, Kanban.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "kanban_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :kanban, KanbanWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "7YQl5fs9op/3Wifv7co9100Y4tYeE0mimiZEpMlsppsJNn76U2yxPfHthYIJmI0X",
  server: false

# In test we don't send emails
config :kanban, Kanban.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Use Oban's manual testing mode so jobs are inserted but not executed
# until tests drain them explicitly via Oban.Testing helpers.
config :kanban, Oban, testing: :manual

# Speed up the after_goal grace window for tests so timing assertions
# can run synchronously.
config :kanban, :after_goal_grace_window_seconds, 1
