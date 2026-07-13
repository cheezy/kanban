defmodule Kanban.RateLimitTest do
  # async: false because the limiter is toggled on globally here; the broad
  # suite runs with it disabled (config/test.exs).
  use ExUnit.Case, async: false

  alias Kanban.RateLimit

  setup do
    original = Application.get_env(:kanban, Kanban.RateLimit)
    # Enable with the module defaults (no surface overrides) so the thresholds
    # asserted below match @default_limits.
    Application.put_env(:kanban, Kanban.RateLimit, enabled: true)
    on_exit(fn -> Application.put_env(:kanban, Kanban.RateLimit, original) end)
    :ok
  end

  # Each test uses a unique IP/identity so the shared ETS bucket store does not
  # bleed state between tests (the limiter is started once for the whole app).
  defp unique_ip, do: {10, :rand.uniform(255), :rand.uniform(255), :rand.uniform(255)}
  defp unique_email, do: "u#{System.unique_integer([:positive])}@example.com"

  describe "check/2 (per-submission surfaces)" do
    test "allows submissions up to the IP+identity limit, then denies" do
      ip = unique_ip()
      email = unique_email()
      # :reset default id_limit is 3
      assert :ok = RateLimit.check(:reset, ip: ip, identity: email)
      assert :ok = RateLimit.check(:reset, ip: ip, identity: email)
      assert :ok = RateLimit.check(:reset, ip: ip, identity: email)
      assert {:error, {:rate_limited, retry}} = RateLimit.check(:reset, ip: ip, identity: email)
      assert is_integer(retry) and retry > 0
    end

    test "different identities on the same IP are limited independently (up to the IP ceiling)" do
      ip = unique_ip()
      # Two different emails each get their own id-limit of 3; the IP ceiling
      # (15) is high enough not to interfere here.
      for _ <- 1..3, do: assert(:ok = RateLimit.check(:reset, ip: ip, identity: unique_email()))
      # A brand-new identity on that IP is still allowed.
      assert :ok = RateLimit.check(:reset, ip: ip, identity: unique_email())
    end

    test "the IP-only ceiling denies once exceeded even for fresh identities" do
      ip = unique_ip()
      # :reset ip_limit is 15. Spend the ceiling across many identities (each
      # under its own id_limit of 3).
      for _ <- 1..15, do: RateLimit.check(:reset, ip: ip, identity: unique_email())

      assert {:error, {:rate_limited, _}} =
               RateLimit.check(:reset, ip: ip, identity: unique_email())
    end
  end

  describe "peek/2 + record_failure/2 (login / api_token)" do
    test "peek does not consume the budget" do
      ip = unique_ip()
      email = unique_email()
      # Peeking many times never denies on its own.
      for _ <- 1..50, do: assert(:ok = RateLimit.peek(:login, ip: ip, identity: email))
    end

    test "recorded failures eventually cause peek to deny" do
      ip = unique_ip()
      email = unique_email()
      # login id_limit is 10; record failures until the budget is spent.
      for _ <- 1..11, do: RateLimit.record_failure(:login, ip: ip, identity: email)
      assert {:error, {:rate_limited, _}} = RateLimit.peek(:login, ip: ip, identity: email)
    end

    test "a fresh IP/identity is not blocked" do
      assert :ok = RateLimit.peek(:login, ip: unique_ip(), identity: unique_email())
    end
  end

  describe "api_token (IP-only, no identity)" do
    test "denies after the IP failure budget is exceeded" do
      ip = unique_ip()
      # api_token ip_limit is 20.
      for _ <- 1..21, do: RateLimit.record_failure(:api_token, ip: ip)
      assert {:error, {:rate_limited, _}} = RateLimit.peek(:api_token, ip: ip)
    end

    test "separate IPs have independent budgets" do
      for _ <- 1..21, do: RateLimit.record_failure(:api_token, ip: unique_ip())
      assert :ok = RateLimit.peek(:api_token, ip: unique_ip())
    end
  end

  describe "input normalization" do
    test "identity is case- and whitespace-insensitive" do
      ip = unique_ip()
      RateLimit.check(:reset, ip: ip, identity: "Foo@Example.com")
      RateLimit.check(:reset, ip: ip, identity: "  foo@example.com ")
      RateLimit.check(:reset, ip: ip, identity: "FOO@EXAMPLE.COM")
      # Three submissions to the SAME normalized identity exhaust id_limit (3).
      assert {:error, {:rate_limited, _}} =
               RateLimit.check(:reset, ip: ip, identity: "foo@example.com")
    end

    test "accepts a string IP as well as a tuple" do
      assert :ok = RateLimit.check(:issue, ip: "203.0.113.7", identity: unique_email())
    end

    test "a nil/blank identity falls back to the IP-only ceiling without crashing" do
      assert :ok = RateLimit.check(:issue, ip: unique_ip(), identity: nil)
      assert :ok = RateLimit.check(:issue, ip: unique_ip(), identity: "   ")
    end
  end
end
