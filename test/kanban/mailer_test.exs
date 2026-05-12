defmodule Kanban.MailerTest do
  use ExUnit.Case, async: true

  describe "production mailer config" do
    # Source-level check: the prod SMTP block is guarded by `config_env() == :prod`,
    # so an Application.get_env/2 assertion would silently pass in test env regardless
    # of whether :verify_none is present. Reading the source catches re-introductions
    # in any environment.
    #
    # Note: a `:verify_none` may legitimately appear elsewhere in runtime.exs (e.g.,
    # the Postgres ssl_opts branch for Fly's internal self-signed cert — see W394
    # follow-up). The assertion below intentionally scopes itself to the Swoosh SMTP
    # config block so it catches a re-introduction of the W388 defect without
    # false-positiving on unrelated TLS configuration.
    test "Swoosh SMTP config does not disable TLS certificate verification (W388)" do
      source = "../../config/runtime.exs" |> Path.expand(__DIR__) |> File.read!()

      smtp_block = extract_smtp_block(source)

      refute smtp_block =~ ":verify_none",
             "config/runtime.exs SMTP block must not contain :verify_none — outgoing email TLS must be verified in production (see W388)"
    end

    # Returns the contents of the `config :kanban, Kanban.Mailer, ...` block.
    # The block starts at the `config :kanban, Kanban.Mailer,` line and ends at
    # the next blank line OR the next top-level `config` invocation. Falls
    # through to the whole source if the marker is not found so the assertion
    # still trips on any unscoped re-introduction.
    defp extract_smtp_block(source) do
      case Regex.run(
             ~r/config\s+:kanban,\s+Kanban\.Mailer,(?:.*?\n)(?:\s+.*?\n)+/s,
             source
           ) do
        [match | _] -> match
        nil -> source
      end
    end
  end
end
