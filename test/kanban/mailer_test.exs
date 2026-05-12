defmodule Kanban.MailerTest do
  use ExUnit.Case, async: true

  describe "production mailer config" do
    # Source-level check: the prod SMTP block is guarded by `config_env() == :prod`,
    # so an Application.get_env/2 assertion would silently pass in test env regardless
    # of whether :verify_none is present. Reading the source catches re-introductions
    # in any environment.
    test "config/runtime.exs does not disable SMTP TLS certificate verification" do
      source = "../../config/runtime.exs" |> Path.expand(__DIR__) |> File.read!()

      refute source =~ ":verify_none",
             "config/runtime.exs must not contain :verify_none — SMTP TLS certificate verification must be enabled in production (see W388)"
    end
  end
end
