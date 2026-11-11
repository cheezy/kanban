defmodule Kanban.AuditLog.SignedExport.ReadmeTest do
  use ExUnit.Case, async: true

  alias Kanban.AuditLog.SignedExport.Readme

  @keys_url "https://stride.test/.well-known/stride-audit-signing-keys"
  @key_id "k1-0123456789abcdef"

  defp text(format), do: Readme.text(%{format: format, key_id: @key_id, keys_url: @keys_url})

  describe "file_name/1" do
    test "names the export file after its format" do
      assert Readme.file_name(:csv) == "audit_log.csv"
      assert Readme.file_name(:json) == "audit_log.json"
    end
  end

  describe "text/1" do
    test "gives the three commands, each on a line of its own" do
      lines = :csv |> text() |> String.split("\n")

      assert ~s(curl -fsS "#{@keys_url}?format=pem&kid=#{@key_id}" -o stride-audit.pem) in lines

      assert ("openssl pkeyutl -verify -pubin -inkey stride-audit.pem -rawin " <>
                "-in manifest.json -sigfile manifest.json.sig") in lines

      assert "shasum -a 256 audit_log.csv" in lines
    end

    test "names the JSON file for a JSON export and never the CSV one" do
      readme = text(:json)

      assert "shasum -a 256 audit_log.json" in String.split(readme, "\n")
      assert readme =~ "openssl dgst -sha256 audit_log.json"
      assert readme =~ "sha256sum audit_log.json"
      refute readme =~ "audit_log.csv"
    end

    test "states the OpenSSL 3 requirement, the LibreSSL note and the quoted URL" do
      readme = text(:csv)

      assert readme =~ "OpenSSL 3.0 or later"
      assert readme =~ ~s("openssl version")
      assert readme =~ "LibreSSL, which cannot check Ed25519"
      assert readme =~ ~s("brew install openssl@3")
      assert readme =~ ~s(treat "?" as a wildcard)
    end

    test "says where the Python alternative is and what the signature proves" do
      readme = text(:csv)

      assert readme =~ ~s("cryptography" package)
      assert readme =~ "docs/audit-log-signed-exports.md in the Stride repository"
      assert readme =~ "Only manifest.json is signed"
      assert readme =~ "It does not prove that the"
      assert readme =~ "file.sha256"
    end

    test "escapes a key id in the URL's query" do
      readme = Readme.text(%{format: :csv, key_id: "k1 &x=y", keys_url: @keys_url})

      assert readme =~ ~s("#{@keys_url}?format=pem&kid=k1+%26x%3Dy")
    end

    test "is plain text ending in a newline" do
      readme = text(:csv)

      assert String.printable?(readme)
      assert String.ends_with?(readme, "truncated\".\n")
    end
  end
end
