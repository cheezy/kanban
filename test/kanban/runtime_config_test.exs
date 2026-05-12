defmodule Kanban.RuntimeConfigTest do
  use ExUnit.Case, async: true

  # Source-level checks: the production runtime config is guarded by
  # `config_env() == :prod`, so an Application.get_env/2 assertion would silently
  # pass in test env regardless of whether the security-relevant directives are
  # present. Reading the source catches re-introductions of insecure settings
  # in any environment.

  setup do
    runtime_source = "../../config/runtime.exs" |> Path.expand(__DIR__) |> File.read!()
    prod_source = "../../config/prod.exs" |> Path.expand(__DIR__) |> File.read!()
    %{runtime_source: runtime_source, prod_source: prod_source}
  end

  describe "production database TLS (W394)" do
    test "Repo TLS is wired through a DATABASE_SSL env-driven setting",
         %{runtime_source: source} do
      # Current Postgrex API: a single `ssl:` key takes either `false`
      # (plaintext) or a keyword list (TLS handshake options). We pick the
      # value at runtime based on DATABASE_SSL.
      assert source =~ "ssl: ssl_setting",
             "config/runtime.exs must wire the ssl_setting variable into the prod Repo (see W394 post-deploy fix)"

      refute source =~ "ssl_opts:",
             "config/runtime.exs must NOT use the deprecated `ssl_opts:` key — pass options under `ssl:` instead"
    end

    test "DATABASE_SSL switch supports disable / verify_none / verify_peer",
         %{runtime_source: source} do
      # Three documented modes: TLS-off (default, fits Fly internal Postgres
      # where the cert is unparseable by OTP's PKIX decoder), encrypted-only,
      # and full chain validation for public-internet Postgres providers.
      assert source =~ "DATABASE_SSL",
             "config/runtime.exs must read DATABASE_SSL to select the TLS mode"

      assert source =~ ~s("disable"),
             "the disable branch must exist (it is the default for Fly internal Postgres)"

      assert source =~ "verify: :verify_none",
             "the verify_none branch must call out verify: :verify_none"

      assert source =~ "verify: :verify_peer",
             "the verify_peer branch must call out verify: :verify_peer"
    end

    test "Repo config does not leave ssl: true commented out",
         %{runtime_source: source} do
      refute source =~ ~r/^\s*#\s*ssl:\s*true/m,
             "Remove the `# ssl: true,` comment in favor of the active ssl: configuration"
    end
  end

  describe "production HTTPS + HSTS enforcement (W394)" do
    # force_ssl lives in config/prod.exs so Sobelow's static analysis can detect
    # it (Sobelow does not trace through config_env() == :prod branches in
    # runtime.exs). The compile-time setting is sufficient — runtime variables
    # are not needed for any of the force_ssl options.
    test "Endpoint prod config sets force_ssl with HSTS",
         %{prod_source: source} do
      assert source =~ "force_ssl:",
             "config/prod.exs must enable force_ssl on the prod Endpoint (see W394)"

      assert source =~ "hsts: true",
             "force_ssl must set hsts: true so browsers upgrade subsequent visits"
    end

    test "force_ssl respects x_forwarded_proto for upstream-terminated TLS",
         %{prod_source: source} do
      assert source =~ "rewrite_on:" and source =~ ":x_forwarded_proto",
             "force_ssl must include rewrite_on: [:x_forwarded_proto] to avoid infinite redirects behind a load balancer"
    end
  end
end
