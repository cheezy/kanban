defmodule KanbanWeb.Router do
  use KanbanWeb, :router
  use ErrorTracker.Web, :router

  import KanbanWeb.UserAuth
  import Phoenix.LiveDashboard.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    # Resolve the real client IP behind the Fly proxy before anything reads
    # conn.remote_ip (rate limiting) — after :fetch_session so it can also stash
    # the IP for LiveView.
    plug KanbanWeb.Plugs.RemoteClientIp
    plug :fetch_live_flash
    plug :put_root_layout, html: {KanbanWeb.Layouts, :root}
    plug :protect_from_forgery

    # Framework-default security headers (X-Frame-Options,
    # X-Content-Type-Options, etc.) plus a placeholder Content-Security-Policy
    # so static analyzers (Sobelow Config.CSP) see a policy declared here.
    # The placeholder is intentionally restrictive — `default-src 'self'` and
    # nothing else — so even if CspNonce somehow fails to fire later in the
    # pipeline, the response still ships a defense-grade CSP rather than no
    # policy at all. CspNonce overwrites this header with the per-request
    # nonce'd policy via Plug.Conn.put_resp_header (single-value semantics:
    # last write wins).
    plug :put_secure_browser_headers, %{
      "content-security-policy" => "default-src 'self'"
    }

    plug KanbanWeb.Plugs.CspNonce

    plug :fetch_current_scope_for_user
    plug KanbanWeb.Plugs.Locale, "en"
  end

  # Pins the response format to json for every /api route (D351). It must be
  # its own pipeline, piped through BEFORE :api / :api_public, rather than a
  # plug inside them: when `plug :accepts, ["json"]` rejects an unsupported
  # Accept header (e.g. text/html) it raises Phoenix.NotAcceptableError, and
  # the router re-raises with the conn as it ENTERED the failing pipeline, so
  # anything set earlier in that same pipeline is lost. Phoenix.Endpoint.
  # RenderErrors then renders the 406 in the format already on the conn, and
  # falls back to the first render_errors format (html) when none is set —
  # which crashed in KanbanWeb.ErrorHTML. With the pin, the 406 renders through
  # KanbanWeb.ErrorJSON. Never add this to :browser.
  pipeline :api_json do
    plug :put_format, "json"
  end

  pipeline :api do
    plug :accepts, ["json"]
    # Resolve the real client IP behind the Fly proxy before the token plug
    # reads conn.remote_ip for failure-based rate limiting.
    plug KanbanWeb.Plugs.RemoteClientIp
    plug KanbanWeb.Plugs.ApiTelemetry
    plug KanbanWeb.Plugs.AuthenticateApiToken
  end

  # Enforces an Organization's two-factor requirement on authenticated browser
  # requests (W2244). Piped after :require_authenticated_user and never added
  # to :browser, so log-in, log-out and the two-factor sign-in step are never
  # redirected; the settings scope below leaves it out, because that is where
  # an overdue member is sent to enroll.
  pipeline :enforce_organization_two_factor do
    plug KanbanWeb.UserAuth.OrganizationTwoFactorGate
  end

  pipeline :api_public do
    plug :accepts, ["json"]
    plug KanbanWeb.Plugs.ApiTelemetry
  end

  # SCIM 2.0 provisioning (W2247). No :accepts: identity providers vary their
  # Accept header, and every response is application/scim+json. The scim
  # format renders raised errors through KanbanWeb.SCIM.ErrorJSON.
  pipeline :scim do
    plug :put_format, "scim"
    plug KanbanWeb.Plugs.RemoteClientIp
    plug KanbanWeb.Plugs.AuthenticateScimToken
  end

  scope "/scim/v2", KanbanWeb.SCIM do
    pipe_through :scim

    get "/ServiceProviderConfig", DiscoveryController, :service_provider_config
    get "/ResourceTypes", DiscoveryController, :resource_types
    get "/ResourceTypes/:id", DiscoveryController, :resource_type
    get "/Schemas", DiscoveryController, :schemas
    get "/Schemas/:id", DiscoveryController, :schema

    get "/Users", UserController, :index
    post "/Users", UserController, :create
    get "/Users/:id", UserController, :show
    put "/Users/:id", UserController, :update
    patch "/Users/:id", UserController, :patch
    delete "/Users/:id", UserController, :delete

    get "/Groups", GroupController, :index
    get "/Groups/:id", GroupController, :show
    patch "/Groups/:id", GroupController, :patch
    post "/Groups", GroupController, :unsupported
    put "/Groups/:id", GroupController, :unsupported
    delete "/Groups/:id", GroupController, :unsupported
  end

  scope "/", KanbanWeb do
    pipe_through :browser

    get "/", PageController, :home
    get "/about", PageController, :about
    get "/acceptable-use", PageController, :acceptable_use
    get "/HitMe", PageController, :hit_me
    get "/pricing", PageController, :pricing
    get "/privacy", PageController, :privacy
    get "/product", PageController, :product
    get "/security", PageController, :security
    get "/tango", PageController, :tango
    get "/terms", PageController, :terms
    get "/workflows", PageController, :workflows
    get "/changelog", PageController, :changelog
    post "/locale/:locale", PageController, :set_locale
  end

  # Notification email unsubscribe (W2202). These sit outside the
  # authenticated scopes on purpose: the signed token in the ?token= query
  # parameter is the only credential, and it can only turn one category of
  # email off for one user. GET only renders a confirmation (mail scanners
  # prefetch links); the confirmation form POSTs through :browser, so it keeps
  # session, flash and CSRF protection.
  scope "/notifications", KanbanWeb do
    pipe_through :browser

    get "/unsubscribe", NotificationUnsubscribeController, :show
    post "/unsubscribe", NotificationUnsubscribeController, :update
    # The List-Unsubscribe header carries the one-click URL. Mail clients
    # without RFC 8058 support open it with GET (RFC 2369), so a GET there
    # shows the same no-change confirmation page.
    get "/unsubscribe/one-click", NotificationUnsubscribeController, :show
  end

  # RFC 8058 one-click unsubscribe: mail providers POST
  # "List-Unsubscribe=One-Click" to the List-Unsubscribe URL with no session
  # and no CSRF token, so this pipeline fetches neither. The controller
  # accepts only a valid signed token and only ever turns email off. Its
  # responses have empty bodies, so the policy allows nothing at all.
  pipeline :one_click_unsubscribe do
    plug :put_secure_browser_headers, %{
      "content-security-policy" => "default-src 'none'; frame-ancestors 'none'"
    }
  end

  scope "/notifications", KanbanWeb do
    pipe_through :one_click_unsubscribe

    post "/unsubscribe/one-click", NotificationUnsubscribeController, :one_click
  end

  # SAML assertion consumer service (W2246). The identity provider's browser
  # POST is cross-site and carries no CSRF token, and a SameSite=Lax session
  # cookie is not sent with it, so this pipeline skips protect_from_forgery
  # and the controller finds the sign-in by its RelayState in the database.
  # It fetches the session and flash only to write the signed-in session and
  # the result message. Only the ACS route uses it; every other SSO route
  # stays in :browser.
  # sobelow_skip ["Config.CSRF"]
  pipeline :saml do
    plug :fetch_session
    plug KanbanWeb.Plugs.RemoteClientIp
    plug :fetch_flash

    plug :put_secure_browser_headers, %{
      "content-security-policy" => "default-src 'none'; frame-ancestors 'none'"
    }
  end

  scope "/users/sso/saml", KanbanWeb do
    pipe_through :saml

    post "/:organization_id/acs", SAMLController, :acs
  end

  # Public API routes (no authentication required)
  scope "/api", KanbanWeb.API, as: :api do
    pipe_through [:api_json, :api_public]

    get "/agent/onboarding", AgentController, :onboarding
    get "/openapi.json", OpenApiController, :show
  end

  # API routes with token authentication
  scope "/api", KanbanWeb.API, as: :api do
    pipe_through [:api_json, :api]

    get "/tasks/next", TaskController, :next
    post "/tasks/claim", TaskController, :claim
    post "/tasks/batch", TaskController, :batch_create
    post "/tasks/:id/unclaim", TaskController, :unclaim
    patch "/tasks/:id/complete", TaskController, :complete
    put "/tasks/:id/changed_files", TaskController, :put_changed_files
    patch "/tasks/:id/mark_reviewed", TaskController, :mark_reviewed
    patch "/tasks/:id/mark_done", TaskController, :mark_done
    patch "/tasks/:id/after_goal", TaskController, :after_goal
    get "/tasks/:id/dependencies", TaskController, :dependencies
    get "/tasks/:id/dependents", TaskController, :dependents
    get "/tasks/:id/tree", TaskController, :tree
    get "/tasks/:id/after_goal_status", TaskController, :after_goal_status
    get "/tasks/:id/comments", TaskCommentController, :index
    post "/tasks/:id/comments", TaskCommentController, :create
    resources "/tasks", TaskController, only: [:index, :show, :create, :update]
  end

  # Lets a workspace token's MCP discovery request (initialize, ping,
  # tools/list, notifications) through without naming a board. It reads the
  # parsed body, so the :api pipeline must come after it.
  pipeline :mcp_discovery do
    plug KanbanWeb.Plugs.McpDiscoverySelector
  end

  # Model Context Protocol over Streamable HTTP (W2231), behind the same
  # Bearer-token pipeline as the task API.
  scope "/api", KanbanWeb.API, as: :api do
    pipe_through [:api_json, :mcp_discovery, :api]

    post "/mcp", McpController, :handle
  end

  # Marks a route that does not act on one board, so a workspace token reaches
  # it without naming a board (W2220). Authentication is the same :api
  # pipeline, which must come after it.
  pipeline :api_board_optional do
    plug KanbanWeb.Plugs.BoardSelectorOptional
  end

  scope "/api", KanbanWeb.API, as: :api do
    pipe_through [:api_json, :api_board_optional, :api]

    get "/boards", BoardController, :index
  end

  pipeline :mcp_event_stream_accept do
    plug KanbanWeb.Plugs.McpEventStreamAccept
  end

  # GET and DELETE /api/mcp answer 405: the MCP server opens no SSE stream and
  # keeps no session. A client probing for the stream sends
  # Accept: text/event-stream, which :api's accepts plug would refuse with 406
  # before the 405, so this scope lets that one Accept value through first
  # (W2231). Authentication is the same :api pipeline. Neither verb acts on a
  # board, so a workspace token gets the 405 without naming one (W2220).
  scope "/api", KanbanWeb.API, as: :api do
    pipe_through [:api_json, :mcp_event_stream_accept, :api_board_optional, :api]

    get "/mcp", McpController, :get_not_allowed
    delete "/mcp", McpController, :delete_not_allowed
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
    pipe_through [
      :browser,
      :require_authenticated_user,
      :require_admin_user,
      :enforce_organization_two_factor
    ]

    live_dashboard "/dashboard",
      metrics: KanbanWeb.Telemetry,
      metrics_history: {KanbanWeb.Telemetry.MetricsStorage, :metrics_history, []},
      ecto_repos: [Kanban.Repo],
      ecto_psql_extras_options: [long_running_queries_threshold: [threshold: "200 milliseconds"]]

    # csp_nonce_assign_key lets ErrorTracker stamp our per-request CSP nonce
    # (KanbanWeb.Plugs.CspNonce) onto its inline <script>/<style> tags —
    # without it the browser blocks the dashboard's inlined JS and buttons
    # like "Mark as resolved" silently do nothing.
    error_tracker_dashboard("/errors",
      csp_nonce_assign_key: :csp_nonce,
      on_mount: [{KanbanWeb.LocaleOnMount, :set_locale}]
    )
  end

  scope "/admin", KanbanWeb.Admin do
    pipe_through [
      :browser,
      :require_authenticated_user,
      :require_admin_user,
      :enforce_organization_two_factor
    ]

    live_session :admin,
      on_mount: [
        {KanbanWeb.SandboxOnMount, :default},
        {KanbanWeb.LocaleOnMount, :set_locale},
        {KanbanWeb.UserAuth, :require_admin},
        {KanbanWeb.UserAuth.OrganizationTwoFactorGate, :enforce},
        {KanbanWeb.NotificationsOnMount, :default},
        {KanbanWeb.TwoFactorReminderOnMount, :default}
      ],
      root_layout: {KanbanWeb.Layouts, :app_chrome} do
      live "/messages", MessageLive.Index, :index
      live "/users", UserLive.Index, :index
      live "/audit-log", AuditLogLive.Index, :index
      # Only site admins create Organizations and edit their details (D1).
      live "/organizations", OrganizationLive.Index, :index
      live "/organizations/new", OrganizationLive.Form, :new
      # Only site admins appoint or remove org-admins (D2).
      live "/organizations/:id", OrganizationLive.Show, :show
      live "/organizations/:id/edit", OrganizationLive.Form, :edit
    end

    # Same admin-only pipeline as the live_session above. `alias: false` keeps
    # the controller's real module name (it is not under KanbanWeb.Admin).
    get "/audit-log/export", KanbanWeb.AuditLogExportController, :export, alias: false
  end

  ## Authentication routes

  # Account settings and the password update are left out of the
  # Organization two-factor enforcement: an overdue member is redirected to the
  # settings page to enroll, so enforcing it here would loop. The banner hook
  # still shows them the requirement.
  scope "/", KanbanWeb do
    pipe_through [:browser, :require_authenticated_user]

    # Account settings mutate the credentials themselves (password, email), so
    # they sit behind a re-authentication (sudo) gate rather than a plain
    # authenticated session — a borrowed/hijacked session or the long-lived
    # remember-me cookie must not be enough to change the password or email
    # (D155). The re-auth surface is the existing /users/log-in page.
    live_session :require_sudo_mode,
      on_mount: [
        {KanbanWeb.SandboxOnMount, :default},
        {KanbanWeb.LocaleOnMount, :set_locale},
        {KanbanWeb.UserAuth, :require_sudo_mode},
        {KanbanWeb.UserAuth.OrganizationTwoFactorGate, :banner},
        {KanbanWeb.NotificationsOnMount, :default},
        {KanbanWeb.TwoFactorReminderOnMount, :default}
      ],
      root_layout: {KanbanWeb.Layouts, :app_chrome} do
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email
    end

    post "/users/update-password", UserSessionController, :update_password
  end

  scope "/", KanbanWeb do
    pipe_through [:browser, :require_authenticated_user, :enforce_organization_two_factor]

    live_session :require_authenticated_user,
      on_mount: [
        {KanbanWeb.SandboxOnMount, :default},
        {KanbanWeb.LocaleOnMount, :set_locale},
        {KanbanWeb.UserAuth, :require_authenticated},
        {KanbanWeb.UserAuth.OrganizationTwoFactorGate, :enforce},
        {KanbanWeb.NotificationsOnMount, :default},
        {KanbanWeb.TwoFactorReminderOnMount, :default}
      ],
      root_layout: {KanbanWeb.Layouts, :app_chrome} do
      live "/boards", BoardLive.Index, :index
      live "/boards/new", BoardLive.Form, :new

      live "/targets/new", TargetLive.Form, :new
      live "/targets/:id/edit", TargetLive.Form, :edit
      # /targets/archived must precede /targets/:id or "archived" is captured as an id
      live "/targets/archived", TargetLive.Archived, :index
      live "/targets/:id", TargetLive.Show, :show

      live "/agents", AgentsLive, :index
      live "/review", ReviewLive, :index
      live "/my-work", MyWorkLive, :index
      live "/notifications", NotificationLive.Index, :index
      # Notification preferences live here rather than in the sudo-gated
      # settings session: they are not credentials, and the unsubscribe pages
      # and email footers link straight to them, so a stale session must not
      # force a password prompt first.
      live "/users/notifications", UserLive.NotificationPreferences, :edit
      live "/metrics", MetricsLive.Workspace, :index
      # Org-admins are ordinary signed-in users, so the org console lives here;
      # OrgLive.Console re-declares the :require_org_admin on_mount gate.
      live "/org", OrgLive.Console, :index
      # The org-admin audit log; OrgLive.AuditLog re-declares the same gate and
      # forces the Organization filter from the membership.
      live "/org/audit", OrgLive.AuditLog, :index
      # The org-admin security policy page (W2244); OrgLive.Security re-declares
      # the same gate and re-checks the role on every event.
      live "/org/security", OrgLive.Security, :index
      # The org-admin single sign-on page (W2245): verified domains and the
      # OIDC connection. OrgLive.SSO re-declares the same gate and re-checks
      # the role and paid access on every event.
      live "/org/sso", OrgLive.SSO, :index
      # The org-admin SCIM token page (W2247); OrgLive.SCIM re-declares the
      # same gate and re-checks the role on every event that changes or
      # validates a token.
      live "/org/scim", OrgLive.SCIM, :index
      # Workspace settings for the current workspace; the LiveView checks paid
      # access and reach on mount and re-checks the org-admin role on every
      # event.
      live "/workspace/settings", WorkspaceLive.Settings, :index
      live "/boards/:id/edit", BoardLive.Form, :edit

      live "/boards/:id", BoardLive.Show, :show
      live "/boards/:id/metrics", MetricsLive.Dashboard, :dashboard
      live "/boards/:id/metrics/throughput", MetricsLive.Throughput, :throughput
      live "/boards/:id/metrics/cycle-time", MetricsLive.CycleTime, :cycle_time
      live "/boards/:id/metrics/lead-time", MetricsLive.LeadTime, :lead_time
      live "/boards/:id/metrics/wait-time", MetricsLive.WaitTime, :wait_time
      live "/boards/:id/metrics/compliance", MetricsLive.Compliance, :compliance
      live "/boards/:id/archive", ArchiveLive.Index, :index
      live "/boards/:id/api_tokens", BoardLive.Show, :api_tokens
      live "/boards/:id/members", BoardLive.Show, :manage_members
      live "/boards/:id/settings", BoardLive.Show, :board_settings
      live "/boards/:id/integrations", BoardLive.Show, :integrations
      live "/boards/:id/columns/new", BoardLive.Show, :new_column
      live "/boards/:id/columns/:column_id/edit", BoardLive.Show, :edit_column
      live "/boards/:id/columns/:column_id/tasks/new", BoardLive.Show, :new_task

      live "/boards/:id/columns/:column_id/tasks/:task_id/edit",
           BoardLive.Show,
           :edit_task_in_column

      live "/boards/:id/tasks/:task_id/edit", BoardLive.Show, :edit_task

      # /goals/new must precede /goals/:goal_id or "new" is captured as a goal_id
      live "/boards/:id/goals/new", BoardLive.Show, :new_goal
      live "/boards/:id/goals/:goal_id", GoalLive.Show, :show
    end

    get "/boards/:id/metrics/:metric/export", MetricsPdfController, :export
    get "/metrics/export", WorkspaceMetricsExportController, :export
    get "/boards/:id/archive/export", ArchiveExportController, :export
    # A finished workspace export archive (W2222). Signed-in users only; the
    # controller re-checks org-admin of the export's own workspace on every
    # request, which the org-wide /org gate below could not express.
    get "/workspace/exports/:id/download", WorkspaceExportController, :download
    # Counts a locked feature's Available to organizations click (signed-in
    # users only, so anonymous traffic cannot inflate the stored metric).
    get "/locked/:feature", LockedFeatureController, :show
    # The workspace switcher. Signed-in users only; the controller checks paid
    # access and reach before it changes the session.
    post "/workspace/switch", WorkspaceSessionController, :switch
  end

  # Org-admin audit export. The pipeline gates on the org-admin role, and the
  # controller re-declares the plug as defense in depth.
  scope "/org", KanbanWeb do
    pipe_through [
      :browser,
      :require_authenticated_user,
      :require_org_admin_user,
      :enforce_organization_two_factor
    ]

    get "/audit/export", OrgAuditLogExportController, :export
    # Stride's SAML service provider metadata for the org-admin's Organization
    # (W2246).
    get "/sso/saml/metadata", SAMLController, :metadata
  end

  scope "/", KanbanWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [
        {KanbanWeb.SandboxOnMount, :default},
        {KanbanWeb.LocaleOnMount, :set_locale},
        {KanbanWeb.UserAuth, :mount_current_scope}
      ] do
      live "/users/register", UserLive.Registration, :new
      live "/users/log-in", UserLive.Login, :new
      live "/users/two-factor", UserLive.TwoFactor, :new
      live "/users/confirm/:token", UserLive.Confirmation, :new
      live "/users/forgot-password", UserLive.ForgotPassword, :new
      live "/users/reset-password/:token", UserLive.ResetPassword, :edit
      live "/users/confirmation-pending", UserLive.ConfirmationPending, :new
      # Works with or without a signed-in user: an invitee may not have an
      # account yet (W2219).
      live "/invitations/:token", WorkspaceLive.InvitationAccept, :show
    end

    live_session :public,
      on_mount: [
        {KanbanWeb.SandboxOnMount, :default},
        {KanbanWeb.LocaleOnMount, :set_locale}
      ],
      root_layout: {KanbanWeb.Layouts, :marketing} do
      live "/issue", IssueLive.Form, :new
    end

    live_session :public_app_shell,
      on_mount: [
        {KanbanWeb.SandboxOnMount, :default},
        {KanbanWeb.LocaleOnMount, :set_locale},
        {KanbanWeb.UserAuth, :mount_current_scope},
        # No-op for visitors; keeps a signed-in user's bell live here too.
        {KanbanWeb.NotificationsOnMount, :default}
      ],
      root_layout: {KanbanWeb.Layouts, :app_chrome} do
      live "/resources", ResourcesLive.Index, :index
      live "/resources/:id", ResourcesLive.Show, :show
    end

    post "/users/register", UserSessionController, :register
    post "/users/log-in", UserSessionController, :create
    post "/users/two-factor", UserSessionController, :verify_two_factor
    delete "/users/log-out", UserSessionController, :delete
    # Single sign-on (W2245). Public because the person is not signed in yet;
    # both GET routes are rate limited per IP inside the controller, and the
    # callback accepts only the flow it finds in this browser's session.
    get "/users/sso/start", SSOController, :start
    get "/users/sso/callback", SSOController, :callback
  end
end
