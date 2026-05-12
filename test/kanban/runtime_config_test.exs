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
    test "Repo config sets an ssl: option in the prod block (no plaintext)",
         %{runtime_source: source} do
      assert source =~ "ssl: ssl_opts",
             "config/runtime.exs must wire the Repo through an ssl_opts list so production connections are always encrypted (see W394)"
    end

    test "ssl_opts switch supports both :verify_peer and :verify_none paths",
         %{runtime_source: source} do
      # Operators serving public-internet Postgres set DATABASE_SSL_VERIFY=peer
      # for chain validation; Fly's internal 6PN uses the verify_none default
      # because the cert is self-signed and the network is the trust boundary.
      assert source =~ "DATABASE_SSL_VERIFY",
             "config/runtime.exs must read DATABASE_SSL_VERIFY to choose between verify_peer and verify_none"

      assert source =~ "verify: :verify_peer",
             "the peer branch must call out verify: :verify_peer"

      assert source =~ "verify: :verify_none",
             "the none branch must call out verify: :verify_none (default for Fly internal Postgres)"
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
