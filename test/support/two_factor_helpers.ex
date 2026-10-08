defmodule Kanban.TwoFactorHelpers do
  @moduledoc """
  Test helpers for users with two-factor authentication turned on.
  """

  alias Kanban.Accounts

  @doc """
  The code an authenticator would show `offset_steps` 30-second steps from
  now. Enrolling uses up the current step, so a sign-in right after
  `enroll/1` needs `code(secret, 1)`.
  """
  def code(secret, offset_steps \\ 0) do
    NimbleTOTP.verification_code(secret, time: System.os_time(:second) + offset_steps * 30)
  end

  @doc """
  Waits out the last two seconds of a 30-second step, so a test that pins a
  code to a step offset cannot see the step change under it.
  """
  def away_from_step_boundary do
    if rem(System.os_time(:second), 30) >= 28, do: Process.sleep(2_100)
    :ok
  end

  @doc "Turns two-factor on for `user`, returning the secret and recovery codes."
  def enroll(user) do
    away_from_step_boundary()
    {:ok, %{secret: secret}} = Accounts.begin_two_factor_enrollment(user)
    {:ok, recovery_codes} = Accounts.confirm_two_factor_enrollment(user, code(secret))
    %{secret: secret, recovery_codes: recovery_codes}
  end
end
