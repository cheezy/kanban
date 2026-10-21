defmodule Kanban.SSO.DomainVerificationTest do
  use Kanban.DataCase, async: true

  import Kanban.OrganizationsFixtures
  import Kanban.SSOFixtures

  alias Kanban.SSO.DomainVerification
  alias Kanban.SSO.OrganizationDomain
  alias Kanban.SSO.TxtResolver

  defmodule FoundResolver do
    @behaviour Kanban.SSO.TxtResolver
    @impl true
    def lookup_txt(name) do
      send(self(), {:looked_up, name})
      {:ok, ["v=spf1 -all", "  " <> Process.get(:expected_record) <> " "]}
    end
  end

  defmodule EmptyResolver do
    @behaviour Kanban.SSO.TxtResolver
    @impl true
    def lookup_txt(_name), do: {:ok, ["stride-verification=someone-elses-token"]}
  end

  defmodule FailingResolver do
    @behaviour Kanban.SSO.TxtResolver
    @impl true
    def lookup_txt(_name), do: {:error, :timeout}
  end

  setup do
    organization = organization_fixture()
    %{domain: domain_fixture(organization, "acme.example")}
  end

  describe "record_name/1 and record_value/1" do
    test "name the dedicated label and the token value", %{domain: domain} do
      assert DomainVerification.record_name(domain) == "_stride-verification.acme.example"
      assert DomainVerification.record_name("acme.example") == "_stride-verification.acme.example"

      assert DomainVerification.record_value(domain) ==
               "stride-verification=" <> domain.verification_token
    end
  end

  describe "check/2" do
    test "succeeds with a stub resolver returning the token", %{domain: domain} do
      Process.put(:expected_record, DomainVerification.record_value(domain))

      assert :ok = DomainVerification.check(domain, resolver: FoundResolver)
      assert_received {:looked_up, "_stride-verification.acme.example"}
    end

    test "fails when no record holds the token", %{domain: domain} do
      assert {:error, :record_not_found} =
               DomainVerification.check(domain, resolver: EmptyResolver)
    end

    test "fails when the lookup fails", %{domain: domain} do
      assert {:error, :record_not_found} =
               DomainVerification.check(domain, resolver: FailingResolver)
    end

    test "uses the configured resolver when none is given" do
      organization = organization_fixture()
      domain = domain_fixture(organization)

      assert :ok = DomainVerification.check(domain)

      assert {:error, :record_not_found} =
               DomainVerification.check(%{domain | verification_token: "x"})
    end
  end

  describe "email_domain/1" do
    test "returns the normalized domain after the last @" do
      assert {:ok, "example.com"} = DomainVerification.email_domain("Pat@Example.COM")
      assert {:ok, "example.com"} = DomainVerification.email_domain(" pat+tag@example.com ")
      assert {:ok, "example.com"} = DomainVerification.email_domain("\"a@b\"@example.com")
    end

    test "refuses anything that is not an address on a valid domain" do
      assert :error = DomainVerification.email_domain("no-at-sign")
      assert :error = DomainVerification.email_domain("@example.com")
      assert :error = DomainVerification.email_domain("pat@localhost")
      assert :error = DomainVerification.email_domain("pat@exa mple.com")
      assert :error = DomainVerification.email_domain(nil)
    end
  end

  describe "normalize_email/1" do
    test "trims, lowercases and drops the trailing dots email_domain/1 ignores" do
      assert DomainVerification.normalize_email(" Pat@Example.COM.. ") == "pat@example.com"
      assert DomainVerification.normalize_email("pat+tag@example.com") == "pat+tag@example.com"
    end
  end

  describe "OrganizationDomain.normalize/1" do
    test "trims, lowercases and drops a trailing dot" do
      assert {:ok, "example.com"} = OrganizationDomain.normalize("  Example.COM. ")

      assert {:ok, "xn--bcher-kva.example"} =
               OrganizationDomain.normalize("xn--bcher-kva.example")
    end

    test "refuses invalid hostnames" do
      for bad <- [
            "",
            "example",
            "-bad.example",
            "bad-.example",
            "a..b",
            "1.2.3.4",
            "bücher.de",
            42
          ] do
        assert OrganizationDomain.normalize(bad) == :error, inspect(bad)
      end
    end
  end

  describe "TxtResolver.lookup_txt/2" do
    test "joins each record's chunks without a separator" do
      assert TxtResolver.join_chunks([[~c"stride-verification=", ~c"abc"], [~c"v=spf1"]]) ==
               ["stride-verification=abc", "v=spf1"]

      assert TxtResolver.join_chunks([]) == []
    end

    test "returns an empty list when nothing answers" do
      # A closed local port answers nothing within the timeout, so the system
      # resolver path runs without touching the network.
      assert {:ok, []} =
               TxtResolver.lookup_txt("_stride-verification.acme.example",
                 nameservers: [{{127, 0, 0, 1}, 9}],
                 timeout: 50
               )
    end
  end
end
