defmodule Kanban.Accounts.TwoFactorTest do
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures

  alias Kanban.Accounts
  alias Kanban.Accounts.TwoFactor
  alias Kanban.Accounts.User
  alias Kanban.Accounts.UserTotp
  alias Kanban.AuditLog
  alias Kanban.Encryption

  # Waits out the last two seconds of a 30-second step, so a test that pins a
  # code to a step offset cannot see the step change under it.
  defp away_from_step_boundary do
    if rem(System.os_time(:second), 30) >= 28, do: Process.sleep(2_100)
    :ok
  end

  # The code an authenticator would show `offset_steps` 30-second steps from now.
  defp code(secret, offset_steps \\ 0) do
    NimbleTOTP.verification_code(secret, time: System.os_time(:second) + offset_steps * 30)
  end

  defp enroll(user) do
    {:ok, %{secret: secret}} = Accounts.begin_two_factor_enrollment(user)
    {:ok, recovery_codes} = Accounts.confirm_two_factor_enrollment(user, code(secret))
    %{secret: secret, recovery_codes: recovery_codes}
  end

  defp audit_actions(user) do
    [actor_user_id: user.id]
    |> AuditLog.list_events()
    |> Enum.map(& &1.action)
  end

  setup do
    %{user: user_fixture()}
  end

  describe "show_reminder?/2" do
    test "show_reminder?/2 is true for a user who never enrolled or dismissed", %{user: user} do
      assert user.two_factor_reminder_dismissed_at == nil
      assert TwoFactor.show_reminder?(user)
      assert Accounts.show_two_factor_reminder?(user)
    end

    test "show_reminder?/2 is false once two-factor is on", %{user: user} do
      enroll(user)

      refute TwoFactor.show_reminder?(user)
    end

    test "show_reminder?/2 stays true during an unconfirmed enrollment", %{user: user} do
      {:ok, _enrollment} = Accounts.begin_two_factor_enrollment(user)
      assert %UserTotp{confirmed_at: nil} = TwoFactor.get_user_totp(user)

      assert TwoFactor.show_reminder?(user)
    end

    test "show_reminder?/2 hides the reminder for 10 days after dismissal and shows it again after",
         %{user: user} do
      dismissed_at = ~U[2026-10-01 12:00:00Z]
      {:ok, user} = TwoFactor.dismiss_reminder(user, dismissed_at)

      refute TwoFactor.show_reminder?(user, dismissed_at)
      refute TwoFactor.show_reminder?(user, DateTime.add(dismissed_at, 9, :day))
      refute TwoFactor.show_reminder?(user, DateTime.add(dismissed_at, 10 * 86_400 - 1, :second))
      assert TwoFactor.show_reminder?(user, DateTime.add(dismissed_at, 10, :day))
      assert TwoFactor.show_reminder?(user, DateTime.add(dismissed_at, 11, :day))
    end

    test "comes back after two-factor is turned off again", %{user: user} do
      %{recovery_codes: [recovery | _]} = enroll(user)
      refute TwoFactor.show_reminder?(user)

      assert Accounts.disable_two_factor(user, recovery) == :ok

      assert TwoFactor.show_reminder?(user)
    end

    test "stays false for a two-factor user whose snooze has run out", %{user: user} do
      enroll(user)
      {:ok, user} = TwoFactor.dismiss_reminder(user, ~U[2026-01-01 00:00:00Z])

      refute TwoFactor.show_reminder?(user, ~U[2026-10-01 00:00:00Z])
    end
  end

  describe "dismiss_reminder/2" do
    test "dismiss_reminder/2 records the time on the user's own row only", %{user: user} do
      other = user_fixture()

      assert {:ok, %User{two_factor_reminder_dismissed_at: ~U[2026-10-08 09:30:15Z]}} =
               TwoFactor.dismiss_reminder(user, ~U[2026-10-08 09:30:15.123456Z])

      assert Repo.reload!(user).two_factor_reminder_dismissed_at == ~U[2026-10-08 09:30:15Z]
      assert Repo.reload!(other).two_factor_reminder_dismissed_at == nil
      assert Repo.reload!(other).updated_at == other.updated_at
    end

    test "defaults to now and can be repeated", %{user: user} do
      before = DateTime.utc_now(:second)

      assert {:ok, %User{two_factor_reminder_dismissed_at: first}} =
               Accounts.dismiss_two_factor_reminder(user)

      assert DateTime.compare(first, before) != :lt
      assert {:ok, %User{}} = Accounts.dismiss_two_factor_reminder(user)
      refute user |> Repo.reload!() |> Accounts.show_two_factor_reminder?()
    end
  end

  describe "begin_enrollment/1" do
    test "stores an unconfirmed record that does not enable two-factor", %{user: user} do
      assert {:ok, %{secret: secret, otpauth_uri: uri}} =
               Accounts.begin_two_factor_enrollment(user)

      assert byte_size(secret) == 20
      assert uri =~ "otpauth://totp/Stride:"
      assert uri =~ "issuer=Stride"
      assert uri =~ "secret=#{Base.encode32(secret, padding: false)}"

      assert %UserTotp{confirmed_at: nil, secret: ^secret} = TwoFactor.get_user_totp(user)
      refute Accounts.two_factor_enabled?(user)
    end

    test "stores the secret encrypted, never in plain text", %{user: user} do
      {:ok, %{secret: secret}} = Accounts.begin_two_factor_enrollment(user)

      %{rows: [[stored]]} =
        Repo.query!("SELECT secret FROM user_totps WHERE user_id = $1", [user.id])

      refute stored == secret
      assert :binary.match(stored, secret) == :nomatch
      assert Encryption.decrypt(stored) == {:ok, secret}
    end

    test "keeps the secret and code hashes out of inspect output (logs)", %{user: user} do
      {:ok, %{secret: secret}} = Accounts.begin_two_factor_enrollment(user)
      inspected = inspect(TwoFactor.get_user_totp(user))

      refute inspected =~ inspect(secret)
      refute inspected =~ "recovery_code_hashes:"
      refute inspected =~ "secret:"
    end

    test "starting again replaces the unconfirmed secret", %{user: user} do
      {:ok, %{secret: first}} = Accounts.begin_two_factor_enrollment(user)
      {:ok, %{secret: second}} = Accounts.begin_two_factor_enrollment(user)

      refute first == second
      assert %UserTotp{secret: ^second} = TwoFactor.get_user_totp(user)
      assert Repo.aggregate(UserTotp, :count) == 1
      assert Accounts.confirm_two_factor_enrollment(user, code(first)) == {:error, :invalid_code}
    end

    test "refuses while two-factor is already enabled", %{user: user} do
      enroll(user)

      assert Accounts.begin_two_factor_enrollment(user) == {:error, :already_enabled}
    end
  end

  describe "confirm_enrollment/2" do
    test "accepts a valid current code, enables two-factor and returns ten codes",
         %{user: user} do
      {:ok, %{secret: secret}} = Accounts.begin_two_factor_enrollment(user)

      assert {:ok, codes} = Accounts.confirm_two_factor_enrollment(user, code(secret))

      assert length(codes) == 10
      assert length(Enum.uniq(codes)) == 10
      assert Enum.all?(codes, &(&1 =~ ~r/\A[0-9a-z]{5}-[0-9a-z]{5}\z/))
      assert Accounts.two_factor_enabled?(user)
      assert "two_factor_enabled" in audit_actions(user)
    end

    test "stores recovery codes only as hashes", %{user: user} do
      %{recovery_codes: codes} = enroll(user)
      %UserTotp{recovery_code_hashes: hashes} = TwoFactor.get_user_totp(user)

      assert length(hashes) == 10
      assert Enum.all?(hashes, &(byte_size(&1) == 32))

      for code <- codes do
        refute code in hashes
        normalized = "#{user.id}:" <> String.replace(code, "-", "")
        assert Encryption.hmac(normalized) in hashes
        # keyed, not a plain digest anyone with the table could recompute
        refute :crypto.hash(:sha256, normalized) in hashes
      end
    end

    test "rejects a wrong code and keeps two-factor off", %{user: user} do
      {:ok, %{secret: secret}} = Accounts.begin_two_factor_enrollment(user)
      wrong = if code(secret) == "000000", do: "111111", else: "000000"

      assert Accounts.confirm_two_factor_enrollment(user, wrong) == {:error, :invalid_code}
      refute Accounts.two_factor_enabled?(user)
    end

    test "rejects malformed codes", %{user: user} do
      Accounts.begin_two_factor_enrollment(user)

      for bad <- ["", "12345", "1234567", "abcdef", nil] do
        assert Accounts.confirm_two_factor_enrollment(user, bad) == {:error, :invalid_code}
      end
    end

    test "accepts surrounding whitespace in the code", %{user: user} do
      {:ok, %{secret: secret}} = Accounts.begin_two_factor_enrollment(user)
      <<a::binary-3, b::binary-3>> = code(secret)

      assert {:ok, _codes} = Accounts.confirm_two_factor_enrollment(user, " #{a} #{b} ")
    end

    test "accepts the code from one step either side for clock drift", %{user: user} do
      {:ok, %{secret: secret}} = Accounts.begin_two_factor_enrollment(user)
      away_from_step_boundary()

      assert {:ok, _codes} = Accounts.confirm_two_factor_enrollment(user, code(secret, -1))
    end

    test "rejects a code from two steps away", %{user: user} do
      {:ok, %{secret: secret}} = Accounts.begin_two_factor_enrollment(user)

      assert Accounts.confirm_two_factor_enrollment(user, code(secret, -2)) ==
               {:error, :invalid_code}
    end

    test "needs an enrollment in progress", %{user: user} do
      assert Accounts.confirm_two_factor_enrollment(user, "123456") == {:error, :not_enrolling}

      %{secret: secret} = enroll(user)

      assert Accounts.confirm_two_factor_enrollment(user, code(secret, 1)) ==
               {:error, :not_enrolling}
    end
  end

  describe "cancel_enrollment/1" do
    test "removes an enrollment in progress", %{user: user} do
      Accounts.begin_two_factor_enrollment(user)

      assert Accounts.cancel_two_factor_enrollment(user) == :ok
      assert TwoFactor.get_user_totp(user) == nil
    end

    test "leaves enabled two-factor alone", %{user: user} do
      enroll(user)

      assert Accounts.cancel_two_factor_enrollment(user) == :ok
      assert Accounts.two_factor_enabled?(user)
    end
  end

  describe "verify_code/2" do
    test "says why a code was refused", %{user: user} do
      assert TwoFactor.verify_code(user, "123456") == {:error, :not_enabled}

      %{secret: secret} = enroll(user)
      next = code(secret, 1)

      assert TwoFactor.verify_code(user, "not a code") == {:error, :invalid_code}
      assert TwoFactor.verify_code(user, next) == :ok
      assert TwoFactor.verify_code(user, next) == {:error, :invalid_code}
    end
  end

  describe "valid_code?/2" do
    test "accepts a fresh code and rejects the same code twice (replay)", %{user: user} do
      %{secret: secret} = enroll(user)
      next = code(secret, 1)

      assert Accounts.valid_two_factor_code?(user, next)
      refute Accounts.valid_two_factor_code?(user, next)
    end

    test "rejects the code already used to confirm enrollment", %{user: user} do
      {:ok, %{secret: secret}} = Accounts.begin_two_factor_enrollment(user)
      first = code(secret)
      {:ok, _codes} = Accounts.confirm_two_factor_enrollment(user, first)

      refute Accounts.valid_two_factor_code?(user, first)
    end

    test "records the step of the accepted code", %{user: user} do
      %{secret: secret} = enroll(user)
      step = div(System.os_time(:second), 30) + 1

      assert Accounts.valid_two_factor_code?(user, code(secret, 1))
      assert TwoFactor.get_user_totp(user).last_used_step >= step
    end

    test "rejects a wrong code", %{user: user} do
      %{secret: secret} = enroll(user)
      wrong = if code(secret, 1) == "000000", do: "111111", else: "000000"

      refute Accounts.valid_two_factor_code?(user, wrong)
    end

    test "is false without confirmed two-factor", %{user: user} do
      refute Accounts.valid_two_factor_code?(user, "123456")

      {:ok, %{secret: secret}} = Accounts.begin_two_factor_enrollment(user)
      refute Accounts.valid_two_factor_code?(user, code(secret))
    end
  end

  describe "consume_recovery_code/2" do
    test "works once per code and fails the second time", %{user: user} do
      %{recovery_codes: [first | _rest]} = enroll(user)

      assert Accounts.consume_recovery_code(user, first) == :ok
      assert Accounts.consume_recovery_code(user, first) == {:error, :invalid_code}
      assert length(TwoFactor.get_user_totp(user).recovery_code_hashes) == 9
    end

    test "ignores spaces, dashes and letter case", %{user: user} do
      %{recovery_codes: [_first, second | _rest]} = enroll(user)
      sloppy = " " <> (second |> String.upcase() |> String.replace("-", " ")) <> " "

      assert Accounts.consume_recovery_code(user, sloppy) == :ok
    end

    test "rejects unknown and malformed codes", %{user: user} do
      enroll(user)

      assert Accounts.consume_recovery_code(user, "aaaaa-aaaaa") == {:error, :invalid_code}
      assert Accounts.consume_recovery_code(user, "") == {:error, :invalid_code}
      assert Accounts.consume_recovery_code(user, nil) == {:error, :invalid_code}
    end

    test "rejects codes without confirmed two-factor", %{user: user} do
      assert Accounts.consume_recovery_code(user, "aaaaa-aaaaa") == {:error, :invalid_code}
    end

    test "does not accept another user's code", %{user: user} do
      %{recovery_codes: [code | _rest]} = enroll(user)
      other = user_fixture()
      enroll(other)

      assert Accounts.consume_recovery_code(other, code) == {:error, :invalid_code}
    end
  end

  describe "regenerate_recovery_codes/2" do
    test "needs a current code and invalidates every previous code", %{user: user} do
      %{secret: secret, recovery_codes: old_codes} = enroll(user)

      assert {:ok, new_codes} = Accounts.regenerate_recovery_codes(user, code(secret, 1))

      assert length(new_codes) == 10
      assert new_codes |> MapSet.new() |> MapSet.disjoint?(MapSet.new(old_codes))

      for old <- old_codes do
        assert Accounts.consume_recovery_code(user, old) == {:error, :invalid_code}
      end

      assert Accounts.consume_recovery_code(user, hd(new_codes)) == :ok
      assert "recovery_codes_regenerated" in audit_actions(user)
    end

    test "rejects a wrong or reused code and keeps the old codes", %{user: user} do
      {:ok, %{secret: secret}} = Accounts.begin_two_factor_enrollment(user)
      first = code(secret)
      {:ok, [recovery | _]} = Accounts.confirm_two_factor_enrollment(user, first)

      assert Accounts.regenerate_recovery_codes(user, first) == {:error, :invalid_code}
      assert Accounts.regenerate_recovery_codes(user, recovery) == {:error, :invalid_code}
      assert Accounts.consume_recovery_code(user, recovery) == :ok
      refute "recovery_codes_regenerated" in audit_actions(user)
    end

    test "needs two-factor to be enabled", %{user: user} do
      assert Accounts.regenerate_recovery_codes(user, "123456") == {:error, :not_enabled}
    end
  end

  describe "disable/2" do
    test "turns two-factor off with a current code", %{user: user} do
      %{secret: secret} = enroll(user)

      assert Accounts.disable_two_factor(user, code(secret, 1)) == :ok
      refute Accounts.two_factor_enabled?(user)
      assert TwoFactor.get_user_totp(user) == nil

      [event] = AuditLog.list_events(action: "two_factor_disabled", actor_user_id: user.id)
      assert event.metadata["method"] == "totp"
    end

    test "turns two-factor off with an unused recovery code", %{user: user} do
      %{recovery_codes: [recovery | _]} = enroll(user)

      assert Accounts.disable_two_factor(user, recovery) == :ok
      refute Accounts.two_factor_enabled?(user)

      [event] = AuditLog.list_events(action: "two_factor_disabled", actor_user_id: user.id)
      assert event.metadata["method"] == "recovery_code"
    end

    test "rejects a used recovery code a second time", %{user: user} do
      %{recovery_codes: [recovery | _]} = enroll(user)
      assert Accounts.consume_recovery_code(user, recovery) == :ok

      assert Accounts.disable_two_factor(user, recovery) == {:error, :invalid_code}
      assert Accounts.two_factor_enabled?(user)
    end

    test "rejects a wrong code and keeps two-factor on", %{user: user} do
      %{secret: secret} = enroll(user)
      wrong = if code(secret, 1) == "000000", do: "111111", else: "000000"

      assert Accounts.disable_two_factor(user, wrong) == {:error, :invalid_code}
      assert Accounts.two_factor_enabled?(user)
      refute "two_factor_disabled" in audit_actions(user)
    end

    test "needs two-factor to be enabled", %{user: user} do
      assert Accounts.disable_two_factor(user, "123456") == {:error, :not_enabled}

      Accounts.begin_two_factor_enrollment(user)
      assert Accounts.disable_two_factor(user, "123456") == {:error, :not_enabled}
    end

    test "lets the user enroll again afterwards", %{user: user} do
      %{secret: secret} = enroll(user)
      :ok = Accounts.disable_two_factor(user, code(secret, 1))

      assert {:ok, %{secret: new_secret}} = Accounts.begin_two_factor_enrollment(user)
      refute new_secret == secret
    end
  end

  test "deleting the user deletes their two-factor record", %{user: user} do
    enroll(user)

    Repo.delete!(user)

    assert Repo.aggregate(UserTotp, :count) == 0
  end
end
