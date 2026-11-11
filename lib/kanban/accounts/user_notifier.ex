defmodule Kanban.Accounts.UserNotifier do
  import Swoosh.Email

  alias Kanban.Mailer
  alias KanbanWeb.ResourcesLive.HowToData

  require Logger

  # HTML-escapes user-controlled string content before it is interpolated into
  # the raw HTML body heredoc. Without this, a user whose :name contains script
  # or markup escapes would inject arbitrary HTML into the reset-password,
  # confirmation, and email-change templates (CWE-79). Nil names fall through
  # as an empty string.
  defp escape_name(nil), do: ""

  defp escape_name(name) when is_binary(name) do
    name |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
  end

  # Builds the email and dispatches actual delivery OFF the request path via a
  # supervised Task, so the response returns immediately and — crucially —
  # equivalently whether or not the recipient's account exists. A synchronous
  # send would leak account existence through response latency even though the
  # flash/redirect are identical (timing-based enumeration, D134 / W1676 L1).
  #
  # The email is built synchronously so callers still get `{:ok, email}` with
  # no delivery dependency. Delivery is dispatched by `dispatch_delivery/1`,
  # which runs inline in the test environment (see `:async_email_delivery`) so
  # the Swoosh test adapter's assertions stay deterministic.
  defp deliver(recipient, subject, body) do
    email =
      new()
      |> to(recipient)
      |> from({"Stride Support", "noreply@stridelikeaboss.com"})
      |> subject(subject)
      |> html_body(body)
      |> header("Message-ID", "<#{System.unique_integer([:positive])}@stridelikeaboss.com>")

    dispatch_delivery(email)
    {:ok, email}
  end

  defp dispatch_delivery(email) do
    if Application.get_env(:kanban, :async_email_delivery, true) do
      case Task.Supervisor.start_child(Kanban.TaskSupervisor, fn -> deliver_now(email) end) do
        {:ok, _pid} ->
          :ok

        {:error, reason} ->
          # The email was never dispatched — surface it (without the body) so
          # the drop is observable rather than silent.
          Logger.error(
            "auth email dispatch failed (subject=#{inspect(email.subject)}): #{inspect(reason)}"
          )
      end
    else
      deliver_now(email)
    end

    :ok
  end

  # Performs the actual send and logs failures WITHOUT the token-bearing body,
  # so bounces are observable without leaking secrets. Runs inside the
  # supervised Task in prod/dev, inline in test.
  defp deliver_now(email) do
    case Mailer.deliver(email) do
      {:ok, _metadata} = ok ->
        ok

      {:error, reason} = error ->
        # Log enough to observe bounces, never the token-bearing body.
        Logger.error(
          "auth email delivery failed (subject=#{inspect(email.subject)}): #{inspect(reason)}"
        )

        error
    end
  end

  @doc """
  Deliver instructions to update a user email.
  """
  def deliver_update_email_instructions(user, url) do
    deliver(user.email, "Update email instructions", """
    <div>
    Hi #{escape_name(user.name)},

    <p>
    You are receiving this email because you requested to change the
    email associated with your account at Stride. Click <a href="#{url}">here</a>
    to continue with this change.
    </p>

    <p>
    If this change was not requested by you, please ignore this email.
    </p>

    Regards,<br/>
    Team at Stride
    </div>
    """)
  end

  @doc """
  Deliver instructions to confirm account.
  """
  def deliver_confirmation_instructions(user, url) do
    deliver(user.email, "Confirm your Stride account", """
    <div>
    Hi #{escape_name(user.name)},

    <p>
    Welcome to Stride! We received your request to create an account with Stride.
    You are receiving this email because this address was associated with
    the new account. Please click <a href="#{url}">here</a> to verify your email
    address.
    </p>

    #{new_user_guides_html()}

    <p>
    Do not forward this email to anyone.
    </p>

    <p>
    You can safely ignore this email If you didn't create an account with us.
    </p>

    Thank you,<br/>
    Team at Stride
    </div>
    """)
  end

  @doc """
  Deliver confirmation instructions to an account a site admin created by
  appointing its email as an org-admin of `organization_name`.

  The generic confirmation email says the recipient asked for an account,
  which a provisioned org-admin never did, so this one names the Organization
  and says who created the account.
  """
  def deliver_org_admin_confirmation_instructions(user, organization_name, url) do
    deliver(
      user.email,
      "Confirm your Stride account for #{header_text(organization_name)}",
      """
      <div>
      Hi #{escape_name(user.name)},

      <p>
      A Stride site admin has created an account for this email address and made
      you an org-admin of <strong>#{escape_name(organization_name)}</strong>. As an
      org-admin you can see your Organization's details, members and audit log
      in Stride.
      </p>

      <p>
      Please click <a href="#{url}">here</a> to confirm your email address. A
      second email lets you choose your password.
      </p>

      #{org_admin_guides_html()}

      <p>
      Do not forward this email to anyone.
      </p>

      <p>
      If you weren't expecting this, you can ignore this email.
      </p>

      Thank you,<br/>
      Team at Stride
      </div>
      """
    )
  end

  @doc """
  Deliver the link to choose a first password to an account a site admin
  created by appointing its email as an org-admin of `organization_name`.

  The generic reset email says the recipient asked to reset a password they
  never had. This one explains that the account has no password yet and what
  to do once the link has expired.
  """
  def deliver_org_admin_password_instructions(user, organization_name, url, valid_minutes) do
    deliver(user.email, "Choose your Stride password", """
    <div>
    Hi #{escape_name(user.name)},

    <p>
    Your new Stride account for <strong>#{escape_name(organization_name)}</strong>
    has no password yet. Click <a href="#{url}">here</a> to choose one.
    </p>

    <p>
    This link expires in #{valid_minutes} minutes. If it has expired, choose
    "Forgot your password?" on the Stride login page and enter this email
    address to get a new link.
    </p>

    <p>
    Do not forward this email to anyone.
    </p>

    Regards,<br/>
    Team at Stride
    </div>
    """)
  end

  @doc """
  Tells the holder of an existing account that a site admin has made them an
  org-admin of `organization_name`, with the guides for setting it up.

  An account created by the appointment gets
  `deliver_org_admin_confirmation_instructions/3` instead, which carries the
  same guides.
  """
  def deliver_org_admin_appointed_notice(user, organization_name) do
    deliver(
      user.email,
      "You're now an org-admin of #{header_text(organization_name)} on Stride",
      """
      <div>
      Hi #{escape_name(user.name)},

      <p>
      A Stride site admin has made you an org-admin of
      <strong>#{escape_name(organization_name)}</strong>. As an org-admin you can
      see your Organization's details, members and audit log in Stride.
      </p>

      <p>
      Nothing changes about how you sign in: <a href="#{KanbanWeb.Endpoint.url()}/users/log-in">sign in</a>
      with your existing account.
      </p>

      #{org_admin_guides_html()}

      <p>
      If you weren't expecting this, let your Stride site admin know.
      </p>

      Thank you,<br/>
      Team at Stride
      </div>
      """
    )
  end

  # The Resources guides an org-admin needs to set an Organization up. Each id
  # must be a guide in KanbanWeb.ResourcesLive.HowToData, and
  # user_notifier_test.exs checks that they are.
  @org_admin_guides [
    {"accepting-an-invitation", "Accepting an Invitation",
     "what the people you invite do with their invitation email, and what to do when a link doesn't work."},
    {"administering-your-organization", "Administering Your Organization",
     "open the Organization console, see its details and members, and create workspaces."},
    {"organization-security-policy", "Setting Your Organization's Security Policy",
     "require two-factor authentication for every member and decide how long audit events are kept."},
    {"reading-the-organization-audit-log", "Reading the Organization Audit Log",
     "find your Organization's security events, filter them and export them."}
  ]

  @doc false
  def org_admin_guide_ids, do: Enum.map(@org_admin_guides, &elem(&1, 0))

  @doc """
  The Resources guides the catalog labels Getting started (tagged
  `getting-started`), in catalog order. The sign-up confirmation email and the
  invitation email link them all, so a new guide with that tag is added to
  them with no change here.
  """
  def getting_started_guides do
    Enum.filter(HowToData.all_how_tos(), &("getting-started" in &1.tags))
  end

  @doc """
  The Resources guides the catalog labels For developers: tagged `developer`
  and not `getting-started`, in catalog order. The sign-up confirmation email
  and the invitation email link them all.
  """
  def developer_guides do
    Enum.filter(
      HowToData.all_how_tos(),
      &("developer" in &1.tags and "getting-started" not in &1.tags)
    )
  end

  # The Getting started and For developers guides, for someone new to Stride:
  # the sign-up confirmation email and the workspace or board invitation.
  defp new_user_guides_html do
    """
    <p>
    <strong>Getting started.</strong> These guides walk you through your first
    board and its tasks:
    </p>

    <ul>
    #{guide_links_html(getting_started_guides())}
    </ul>

    <p>
    <strong>For developers.</strong> If you connect AI agents or your own tools
    to Stride, these guides show you how:
    </p>

    <ul>
    #{guide_links_html(developer_guides())}
    </ul>
    """
  end

  defp guide_links_html(how_tos) do
    Enum.map_join(how_tos, "\n", fn how_to ->
      ~s|<li><a href="#{resource_url(how_to.id)}">#{escape_name(how_to.title)}</a>: | <>
        ~s|#{escape_name(how_to.description)}</li>|
    end)
  end

  defp resource_url(id), do: "#{KanbanWeb.Endpoint.url()}/resources/#{id}"

  defp org_admin_guides_html do
    items =
      Enum.map_join(@org_admin_guides, "\n", fn {id, title, purpose} ->
        ~s|<li><a href="#{resource_url(id)}">#{title}</a>: #{purpose}</li>|
      end)

    """
    <p>
    <strong>Save these guides.</strong> Keep this email or bookmark the links
    below. They walk you through setting up your Organization properly, and you
    can come back to them whenever you need to:
    </p>

    <ul>
    #{items}
    </ul>
    """
  end

  # An Organization name goes into a Subject header, so line breaks are folded
  # into spaces before Swoosh encodes it.
  defp header_text(text) when is_binary(text), do: String.replace(text, ~r/[\r\n]+/, " ")

  @doc """
  Deliver an invitation to join a workspace or a board (W2219).

  `email` is the invited address. `details` names the inviter
  (`:inviter_name`, which may be `nil`) and what they invite to
  (`:target_name`, a workspace or board name, with `:target` `:workspace` or
  `:board`). Both names are user-controlled, so they are HTML-escaped in the
  body and folded onto one line in the subject. `url` is the single-use accept
  link; it is the only place the invitation's plaintext token ever appears.
  """
  def deliver_workspace_invitation(email, details, url) when is_binary(email) do
    target_name = Map.get(details, :target_name) || ""
    inviter = escape_name(Map.get(details, :inviter_name))
    target_noun = if Map.get(details, :target) == :board, do: "board", else: "workspace"
    invited_by = if inviter == "", do: "Someone", else: inviter

    deliver(email, "You're invited to #{header_text(target_name)} on Stride", """
    <div>
    Hi,

    <p>
    #{invited_by} has invited you to the #{target_noun}
    <strong>#{escape_name(target_name)}</strong> on Stride.
    </p>

    <p>
    Click <a href="#{url}">here</a> to accept the invitation. If you don't have a
    Stride account yet, you can create one from that page with this email
    address. The link works once and expires in #{Kanban.Workspaces.Invitation.validity_days()} days.
    </p>

    #{new_user_guides_html()}

    <p>
    Do not forward this email to anyone.
    </p>

    <p>
    If you weren't expecting this invitation, you can ignore this email.
    </p>

    Thank you,<br/>
    Team at Stride
    </div>
    """)
  end

  @doc """
  Deliver instructions to reset a user password.
  """
  def deliver_reset_password_instructions(user, url) do
    deliver(user.email, "Reset your Stride password", """
    <div>
    Hi #{escape_name(user.name)},

    <p>
    You are receiving this email because you (or someone else) requested to reset your
    password for your Stride account. Click <a href="#{url}">here</a> to reset your password.
    </p>

    <p>
    If you didn't request this change, please ignore this email. Your password will remain
    unchanged.
    </p>

    <p>
    This link will expire in 15 minutes.
    </p>

    Regards,<br/>
    Team at Stride
    </div>
    """)
  end
end
