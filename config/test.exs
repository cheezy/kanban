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
  pool_size: System.schedulers_online() * 2,
  # (D230) DBConnection defaults to a 50ms queue_target, which a machine under
  # ordinary concurrent load routinely exceeds: Ecto's parallel preloader spawns
  # Tasks that each check out a sandbox connection, the checkout queues past the
  # target, and DBConnection begins SHEDDING requests. The test then fails with
  # "could not checkout the connection owned by #PID<...>" — a spurious failure
  # indistinguishable from a real one to whoever reads the result, which is
  # exactly the diagnostic tax D230 exists to remove. Reproduced at 2 failures
  # in 6 runs under 4 CPU burners on an 8-core M2; both were checkouts inside a
  # preloader, and both runs otherwise reported 7460/7461 passing.
  #
  # What this actually changes, stated precisely: queue_target is not a failure
  # deadline. It is the input to a LOAD-SHEDDING heuristic — DBConnection sheds
  # only once queue delay stays above the target across a queue_interval window.
  # The hard deadline for a checkout is :timeout (15s default), which this does
  # NOT touch, so the boundary at which a genuinely stuck query fails is
  # unchanged. queue_interval is deliberately left at its 1000ms default: the
  # measured drops were at 124-270ms, which justifies raising the target and
  # says nothing about widening the window.
  #
  # The cost, named rather than glossed: a pool-starvation or connection-leak
  # regression used to surface fast and loud as a dropped checkout. It now has
  # to sustain >500ms of queue delay to do so, and may instead present as a slow
  # suite or as a :timeout failure later. True deadlock is still caught by
  # ExUnit's own timeout.
  queue_target: 500

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :kanban, KanbanWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "7YQl5fs9op/3Wifv7co9100Y4tYeE0mimiZEpMlsppsJNn76U2yxPfHthYIJmI0X",
  server: false

# In test we don't send emails
config :kanban, Kanban.Mailer, adapter: Swoosh.Adapters.Test

# Deliver auth emails inline (not via the supervised Task) in test so the
# Swoosh test adapter's assert_email_sent/1 assertions are deterministic. The
# off-request async dispatch (D134) is exercised explicitly by the async:false
# UserNotifier task-path test.
config :kanban, :async_email_delivery, false

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
# can run synchronously via Oban.drain_queue(with_scheduled: true).
config :kanban, :after_goal_grace_window_ms, 1

# Rate limiting is disabled by default in the test suite so the shared test IP
# (127.0.0.1 / nil peer) does not cause cross-test interference. The
# throttle-specific tests opt back in with known limits via Application.put_env.
config :kanban, Kanban.RateLimit, enabled: false
