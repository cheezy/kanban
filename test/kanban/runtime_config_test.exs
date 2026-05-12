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
    test "Repo config enforces verify_peer TLS to Postgres",
         %{runtime_source: source} do
      assert source =~ "verify: :verify_peer",
             "config/runtime.exs must enable Postgres TLS verification with :verify_peer (see W394)"
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
