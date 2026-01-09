defmodule KanbanWeb.Router do
  use KanbanWeb, :router
  use ErrorTracker.Web, :router

  import KanbanWeb.UserAuth
  import Phoenix.LiveDashboard.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {KanbanWeb.Layouts, :root}
    plug :protect_from_forgery

    plug :put_secure_browser_headers, %{
      "content-security-policy" =>
        "default-src 'self'; script-src 'self' 'unsafe-inline'; img-src 'self' data:; style-src 'self' 'unsafe-inline'"
    }

    plug :fetch_current_scope_for_user
    plug KanbanWeb.Plugs.Locale, "en"
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug KanbanWeb.Plugs.ApiTelemetry
    plug KanbanWeb.Plugs.AuthenticateApiToken
  end

  pipeline :api_public do
    plug :accepts, ["json"]
    plug KanbanWeb.Plugs.ApiTelemetry
  end

  scope "/", KanbanWeb do
    pipe_through :browser

    get "/", PageController, :home
    get "/about", PageController, :about
    get "/tango", PageController, :tango
    get "/changelog", PageController, :changelog
    post "/locale/:locale", PageController, :set_locale
  end

  # Public API routes (no authentication required)
  scope "/api", KanbanWeb.API, as: :api do
    pipe_through :api_public

    get "/agent/onboarding", AgentController, :onboarding
  end

  # API routes with token authentication
  scope "/api", KanbanWeb.API, as: :api do
    pipe_through :api

    get "/tasks/next", TaskController, :next
    post "/tasks/claim", TaskController, :claim
    post "/tasks/batch", TaskController, :batch_create
    post "/tasks/:id/unclaim", TaskController, :unclaim
    patch "/tasks/:id/complete", TaskController, :complete
    patch "/tasks/:id/mark_reviewed", TaskController, :mark_reviewed
    patch "/tasks/:id/mark_done", TaskController, :mark_done
    get "/tasks/:id/dependencies", TaskController, :dependencies
    get "/tasks/:id/dependents", TaskController, :dependents
    get "/tasks/:id/tree", TaskController, :tree
    resources "/tasks", TaskController, only: [:index, :show, :create, :update]
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:kanban, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).

    scope "/dev" do
      pipe_through :browser

      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  scope "/admin" do
    pipe_through [:browser, :require_authenticated_user, :require_admin_user]

    live_dashboard "/dashboard",
      metrics: {KanbanWeb.Telemetry, :metrics},
      ecto_repos: [Kanban.Repo],
      ecto_psql_extras_options: [long_running_queries_threshold: [threshold: "200 milliseconds"]]

    error_tracker_dashboard("/errors",
      on_mount: [{KanbanWeb.LocaleOnMount, :set_locale}]
    )
  end

  ## Authentication routes

  scope "/", KanbanWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [
        {KanbanWeb.LocaleOnMount, :set_locale},
        {KanbanWeb.UserAuth, :require_authenticated}
      ] do
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email

      live "/boards", BoardLive.Index, :index
      live "/boards/new", BoardLive.Form, :new
      live "/boards/:id/edit", BoardLive.Form, :edit

      live "/boards/:id", BoardLive.Show, :show
      live "/boards/:id/archive", ArchiveLive.Index, :index
      live "/boards/:id/api_tokens", BoardLive.Show, :api_tokens
      live "/boards/:id/columns/new", BoardLive.Show, :new_column
      live "/boards/:id/columns/:column_id/edit", BoardLive.Show, :edit_column
      live "/boards/:id/columns/:column_id/tasks/new", BoardLive.Show, :new_task
      live "/boards/:id/tasks/:task_id/edit", BoardLive.Show, :edit_task
    end

    post "/users/update-password", UserSessionController, :update_password
  end

  scope "/", KanbanWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [
        {KanbanWeb.LocaleOnMount, :set_locale},
        {KanbanWeb.UserAuth, :mount_current_scope}
      ] do
      live "/users/register", UserLive.Registration, :new
      live "/users/log-in", UserLive.Login, :new
      live "/users/confirm/:token", UserLive.Confirmation, :new
      live "/users/forgot-password", UserLive.ForgotPassword, :new
      live "/users/reset-password/:token", UserLive.ResetPassword, :edit
    end

    live_session :public,
      on_mount: [{KanbanWeb.LocaleOnMount, :set_locale}] do
      live "/issue", IssueLive.Form, :new
    end

    post "/users/register", UserSessionController, :register
    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end
end
