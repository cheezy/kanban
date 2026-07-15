defmodule Kanban.Accounts.UserNotifier do
  import Swoosh.Email

  alias Kanban.Mailer

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
    This link will expire in 7 days.
    </p>

    Regards,<br/>
    Team at Stride
    </div>
    """)
  end
end
