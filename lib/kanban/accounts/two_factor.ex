defmodule Kanban.Accounts.TwoFactor do
  @moduledoc """
  TOTP two-factor authentication: enrollment, code checks and recovery codes.

  Exposed through the `Kanban.Accounts` facade via `defdelegate` — call these
  as `Accounts.begin_two_factor_enrollment/1` and so on rather than reaching
  into this module directly.

  ## Lifecycle

    1. `begin_enrollment/1` stores a new secret on an unconfirmed
       `Kanban.Accounts.UserTotp` row (replacing any earlier unconfirmed one)
       and returns what the authenticator app needs. Two-factor is NOT on yet.
    2. `confirm_enrollment/2` turns it on only after the user proves they hold
       the secret with a valid current code, and returns ten recovery codes —
       the only time they are ever available in plain text.
    3. `valid_code?/2` and `consume_recovery_code/2` check a second factor.
    4. `regenerate_recovery_codes/2` (needs a current code) and `disable/2`
       (a current code or an unused recovery code) manage it afterwards.

  ## Security

    * The secret is encrypted at rest (`Kanban.Encryption.EncryptedBinary`).
    * A code is accepted for the current 30-second step or one step either
      side (clock drift), and only for a step later than the last accepted
      one. The step is recorded with a conditional update, so two requests
      racing with the same code cannot both succeed.
    * Recovery codes are stored only as HMAC-SHA256 digests keyed with a key
      derived from the server's encryption key (`Kanban.Encryption.hmac/1`)
      and the user id, so a database dump alone cannot be searched for them.
      They are compared in constant time against every stored digest and
      removed with a conditional update, so each works exactly once.
    * Every code check is throttled per user (`Kanban.RateLimit`, surface
      `:two_factor`). Each attempt is counted atomically BEFORE the code is
      looked at, right or wrong, so many requests sent at once cannot slip past
      the limit; once it is reached, checks return `{:error, :rate_limited}`
      (or `false`) until the window passes.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts.User
  alias Kanban.Accounts.UserTotp
  alias Kanban.AuditLog
  alias Kanban.Encryption
  alias Kanban.RateLimit
  alias Kanban.Repo

  @issuer "Stride"
  @period 30
  @drift_steps [0, -1, 1]
  @recovery_code_count 10
  # 32 symbols, so a random byte maps onto it without bias (256 = 8 * 32).
  # Leaves out i, l, o and 1, which are easy to misread.
  @recovery_alphabet ~c"023456789abcdefghjkmnpqrstuvwxyz"
  @recovery_code_length 10

  @typedoc "What an authenticator app needs to add the account."
  @type enrollment :: %{secret: binary(), otpauth_uri: String.t()}

  @doc """
  Returns the user's two-factor record, confirmed or not, or `nil`.
  """
  @spec get_user_totp(User.t()) :: UserTotp.t() | nil
  def get_user_totp(%User{id: user_id}), do: Repo.get_by(UserTotp, user_id: user_id)

  @doc """
  Returns true when the user has confirmed two-factor enrollment.

  ## Examples

      iex> enabled?(user)
      false

  """
  @spec enabled?(User.t()) :: boolean()
  def enabled?(%User{id: user_id}) do
    UserTotp
    |> where([t], t.user_id == ^user_id and not is_nil(t.confirmed_at))
    |> Repo.exists?()
  end

  @doc """
  Starts enrollment: stores a new secret on an unconfirmed record and returns
  the secret and the `otpauth://` URI for the QR code.

  Starting again replaces the earlier unconfirmed secret. Returns
  `{:error, :already_enabled}` when two-factor is already on.
  """
  @spec begin_enrollment(User.t()) :: {:ok, enrollment()} | {:error, :already_enabled}
  def begin_enrollment(%User{} = user) do
    secret = NimbleTOTP.secret()

    # Locked, so a confirm in another tab cannot land between the check and
    # the write: overwriting a just-confirmed secret would lock the user out.
    Repo.transact(fn ->
      case lock_user_totp(user) do
        %UserTotp{confirmed_at: %DateTime{}} ->
          {:error, :already_enabled}

        pending ->
          (pending || %UserTotp{user_id: user.id})
          |> Ecto.Changeset.change(secret: secret, last_used_step: nil, recovery_code_hashes: [])
          |> Repo.insert_or_update!()

          uri = NimbleTOTP.otpauth_uri("#{@issuer}:#{user.email}", secret, issuer: @issuer)
          {:ok, %{secret: secret, otpauth_uri: uri}}
      end
    end)
  end

  @doc """
  Abandons an enrollment in progress. Leaves a confirmed record alone.
  """
  @spec cancel_enrollment(User.t()) :: :ok
  def cancel_enrollment(%User{id: user_id}) do
    UserTotp
    |> where([t], t.user_id == ^user_id and is_nil(t.confirmed_at))
    |> Repo.delete_all()

    :ok
  end

  @doc """
  Turns two-factor on once `code` is valid for the pending secret, and returns
  the ten recovery codes in plain text — the only time they are available.

  Records a `two_factor_enabled` audit event.
  """
  @spec confirm_enrollment(User.t(), String.t()) ::
          {:ok, [String.t()]} | {:error, :invalid_code | :not_enrolling | :rate_limited}
  def confirm_enrollment(%User{} = user, code) do
    result =
      throttled(user, fn -> do_confirm_enrollment(user, code) end)

    with {:ok, _codes} <- result do
      AuditLog.event(:two_factor_enabled, user_id: user.id)
      result
    end
  end

  defp do_confirm_enrollment(user, code) do
    Repo.transact(fn ->
      with {:ok, totp} <- lock_pending(user),
           {:ok, step} <- matching_step(totp, code) do
        {codes, hashes} = new_recovery_codes(user)

        totp
        |> Ecto.Changeset.change(
          confirmed_at: DateTime.utc_now(:second),
          last_used_step: step,
          recovery_code_hashes: hashes
        )
        |> Repo.update!()

        {:ok, codes}
      end
    end)
  end

  @doc """
  Returns true when `code` is a valid, not yet used code for the user's
  confirmed two-factor secret, and records it as used.

  The same code is rejected the second time, even within its 30 seconds, and
  every code is rejected while the user is throttled for too many attempts.
  """
  @spec valid_code?(User.t(), String.t()) :: boolean()
  def valid_code?(%User{} = user, code) do
    throttled(user, fn ->
      with {:ok, totp} <- fetch_enabled(user), do: use_code(totp, code)
    end) == :ok
  end

  @doc """
  Uses up one of the user's recovery codes.

  Spaces, dashes and letter case in `code` are ignored. Returns `:ok` once per
  code; the same code is rejected afterwards.
  """
  @spec consume_recovery_code(User.t(), String.t()) ::
          :ok | {:error, :invalid_code | :rate_limited}
  def consume_recovery_code(%User{} = user, code) do
    throttled(user, fn ->
      case get_user_totp(user) do
        %UserTotp{confirmed_at: %DateTime{}} = totp -> use_recovery_code(totp, code)
        _none_or_unconfirmed -> {:error, :invalid_code}
      end
    end)
  end

  @doc """
  Replaces every recovery code with ten new ones, after checking a current
  TOTP code. Returns the new codes in plain text.

  Records a `recovery_codes_regenerated` audit event.
  """
  @spec regenerate_recovery_codes(User.t(), String.t()) ::
          {:ok, [String.t()]} | {:error, :invalid_code | :not_enabled | :rate_limited}
  def regenerate_recovery_codes(%User{} = user, code) do
    # Locked, so a disable in another tab cannot delete the row mid-update.
    result =
      throttled(user, fn -> Repo.transact(fn -> replace_recovery_codes(user, code) end) end)

    with {:ok, _codes} <- result do
      AuditLog.event(:recovery_codes_regenerated, user_id: user.id)
      result
    end
  end

  defp replace_recovery_codes(user, code) do
    with {:ok, totp} <- lock_enabled(user),
         :ok <- use_code(totp, code) do
      {codes, hashes} = new_recovery_codes(user)

      totp
      |> Ecto.Changeset.change(recovery_code_hashes: hashes)
      |> Repo.update!()

      {:ok, codes}
    end
  end

  @doc """
  Turns two-factor off, after checking either a current TOTP code or an unused
  recovery code (which is used up). A user who has lost their authenticator
  can therefore still turn it off and enroll again.

  Records a `two_factor_disabled` audit event naming which kind of code was
  used.
  """
  @spec disable(User.t(), String.t()) ::
          :ok | {:error, :invalid_code | :not_enabled | :rate_limited}
  def disable(%User{} = user, code) do
    throttled(user, fn ->
      with {:ok, totp} <- fetch_enabled(user),
           {:ok, method} <- check_any_code(totp, code) do
        UserTotp |> where([t], t.id == ^totp.id) |> Repo.delete_all()
        AuditLog.event(:two_factor_disabled, user_id: user.id, method: method)
        :ok
      end
    end)
  end

  # -- helpers ---------------------------------------------------------------

  defp lock_user_totp(%User{id: user_id}) do
    UserTotp
    |> where([t], t.user_id == ^user_id)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp lock_enabled(user) do
    case lock_user_totp(user) do
      %UserTotp{confirmed_at: %DateTime{}} = totp -> {:ok, totp}
      _none_or_unconfirmed -> {:error, :not_enabled}
    end
  end

  # Runs a code check unless the user has used up their attempts in the
  # window. The attempt is counted (an atomic increment) before the code is
  # checked, so concurrent requests cannot all pass a count taken before any of
  # them failed. valid_code?/2 turns the refusal into `false`.
  defp throttled(%User{id: user_id}, check) do
    case RateLimit.check(:two_factor, identity: "user:#{user_id}") do
      {:error, {:rate_limited, _retry_after_ms}} -> {:error, :rate_limited}
      :ok -> check.()
    end
  end

  defp lock_pending(user) do
    case lock_user_totp(user) do
      %UserTotp{confirmed_at: nil} = totp -> {:ok, totp}
      _none_or_confirmed -> {:error, :not_enrolling}
    end
  end

  defp fetch_enabled(user) do
    case get_user_totp(user) do
      %UserTotp{confirmed_at: %DateTime{}} = totp -> {:ok, totp}
      _none_or_unconfirmed -> {:error, :not_enabled}
    end
  end

  defp check_any_code(totp, code) do
    cond do
      use_code(totp, code) == :ok -> {:ok, :totp}
      use_recovery_code(totp, code) == :ok -> {:ok, :recovery_code}
      true -> {:error, :invalid_code}
    end
  end

  # Accepts the code and records its step, unless that step (or a later one)
  # was already used. The conditional update makes the check-and-record atomic.
  defp use_code(%UserTotp{id: id} = totp, code) do
    with {:ok, step} <- matching_step(totp, code) do
      {count, _} =
        UserTotp
        |> where([t], t.id == ^id and (is_nil(t.last_used_step) or t.last_used_step < ^step))
        |> Repo.update_all(set: [last_used_step: step])

      if count == 1, do: :ok, else: {:error, :invalid_code}
    end
  end

  # The TOTP step whose code equals `code`, checking the current step and one
  # either side. Earlier-used steps are rejected here as well as in the update.
  defp matching_step(%UserTotp{secret: secret, last_used_step: last}, code) do
    with {:ok, otp} <- normalize_totp(code) do
      last
      |> candidate_steps()
      |> Enum.find(&code_matches?(secret, otp, &1))
      |> case do
        nil -> {:error, :invalid_code}
        step -> {:ok, step}
      end
    end
  end

  defp candidate_steps(last_used_step) do
    now = div(System.os_time(:second), @period)

    @drift_steps
    |> Enum.map(&(now + &1))
    |> Enum.filter(&(is_nil(last_used_step) or &1 > last_used_step))
  end

  defp code_matches?(secret, otp, step) do
    expected = NimbleTOTP.verification_code(secret, time: step * @period, period: @period)
    Plug.Crypto.secure_compare(expected, otp)
  end

  defp normalize_totp(code) when is_binary(code) do
    otp = String.replace(code, ~r/\s/u, "")
    if otp =~ ~r/\A\d{6}\z/, do: {:ok, otp}, else: {:error, :invalid_code}
  end

  defp normalize_totp(_code), do: {:error, :invalid_code}

  defp use_recovery_code(%UserTotp{id: id, user_id: user_id, recovery_code_hashes: hashes}, code) do
    with {:ok, hash} <- matching_hash(user_id, hashes, code) do
      {count, _} =
        UserTotp
        |> where(
          [t],
          t.id == ^id and fragment("? = ANY(?)", type(^hash, :binary), t.recovery_code_hashes)
        )
        |> update([t],
          set: [
            recovery_code_hashes:
              fragment("array_remove(?, ?)", t.recovery_code_hashes, type(^hash, :binary))
          ]
        )
        |> Repo.update_all([])

      if count == 1, do: :ok, else: {:error, :invalid_code}
    end
  end

  # Compares against every stored hash, without stopping at a match, so the
  # time taken does not reveal which (or whether a) code matched.
  defp matching_hash(user_id, hashes, code) when is_binary(code) do
    hash = hash_recovery_code(user_id, code)

    match =
      Enum.reduce(hashes, nil, fn stored, found ->
        if Plug.Crypto.secure_compare(stored, hash), do: stored, else: found
      end)

    if match, do: {:ok, match}, else: {:error, :invalid_code}
  end

  defp matching_hash(_user_id, _hashes, _code), do: {:error, :invalid_code}

  defp normalize_recovery_code(code) do
    code |> String.downcase() |> String.replace(~r/[\s-]/u, "")
  end

  # Keyed with a server-side secret, so a leaked table alone cannot be searched
  # offline, and bound to the user id, so one user's code never matches another's.
  defp hash_recovery_code(user_id, code) do
    Encryption.hmac("#{user_id}:" <> normalize_recovery_code(code))
  end

  defp new_recovery_codes(%User{id: user_id}) do
    codes = for _ <- 1..@recovery_code_count, do: random_recovery_code()
    {codes, Enum.map(codes, &hash_recovery_code(user_id, &1))}
  end

  # Ten symbols shown as two groups of five, e.g. "a3k9x-q7m2p".
  defp random_recovery_code do
    symbols =
      @recovery_code_length
      |> :crypto.strong_rand_bytes()
      |> :binary.bin_to_list()
      |> Enum.map(&Enum.at(@recovery_alphabet, rem(&1, 32)))
      |> List.to_string()

    String.slice(symbols, 0, 5) <> "-" <> String.slice(symbols, 5, 5)
  end
end
