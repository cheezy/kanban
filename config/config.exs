# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :kanban, :scopes,
  user: [
    default: true,
    module: Kanban.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :id,
    schema_table: :users,
    test_data_fixture: Kanban.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]

config :kanban,
  ecto_repos: [Kanban.Repo],
  generators: [timestamp_type: :utc_datetime]

# Strict mode gate for PATCH /api/tasks/:id/complete explorer_result and
# reviewer_result fields. When false (default), missing or invalid results
# produce a structured warning log but the request succeeds (grace mode).
# When true, missing or invalid results produce a 422 rejection.
# Runtime-toggleable via STRIDE_STRICT_COMPLETION_VALIDATION=true.
config :kanban, :strict_completion_validation, false

# Configures the endpoint
config :kanban, KanbanWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: KanbanWeb.ErrorHTML, json: KanbanWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Kanban.PubSub,
  live_view: [signing_salt: "BTm5DXgl"]

# Configures the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :kanban, Kanban.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  kanban: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.7",
  kanban: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configures Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :task_id, :rejected_fields, :actor_user_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Configure error_tracker
config :error_tracker,
  repo: Kanban.Repo,
  otp_app: :kanban,
  enabled: true

# Oban configuration — runs the after_goal grace-window worker (W493).
# `:after_goal_grace` queue has a depth of 5 because each job is a single
# row update plus a status check; bursts are bounded by goal-completion
# rate, not throughput.
config :kanban, Oban,
  repo: Kanban.Repo,
  engine: Oban.Engines.Basic,
  queues: [after_goal_grace: 5],
  plugins: [{Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7}]

# Configurable grace window (in milliseconds) between detecting the
# last child's completion and assuming the agent will not report
# after_goal. Temporarily set to 500ms while the agent-side after_goal
# client wiring is being built — every last-child completion currently
# routes through the grace worker rather than an agent PATCH. Raise
# this back toward 5 minutes (300_000) once stride-hook.sh, hook-bridge,
# and the workflow skill all know how to call
# `PATCH /api/tasks/:id/after_goal`. Tests override to 1ms.
config :kanban, :after_goal_grace_window_ms, 500

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
