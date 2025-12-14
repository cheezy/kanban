defmodule Kanban.Accounts.UserNotifier do
  import Swoosh.Email

  alias Kanban.Mailer

  # Delivers the email using the application mailer.
  defp deliver(recipient, subject, body) do
    email =
      new()
      |> to(recipient)
      |> from({"Stride Support", "noreply@StrideLikeABoss.com"})
      |> subject(subject)
      |> html_body(body)

    with {:ok, _metadata} <- Mailer.deliver(email) do
      {:ok, email}
    end
  end

  @doc """
  Deliver instructions to update a user email.
  """
  def deliver_update_email_instructions(user, url) do
    deliver(user.email, "Update email instructions", """
    <div>
    Hi #{user.name},

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
    Hi #{user.name},

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
end
