defmodule Kanban.AuditLog.SignedExport.Readme do
  @moduledoc """
  The `README.txt` inside a signed audit export
  (`Kanban.AuditLog.SignedExport`): what the archive holds and the three
  commands that verify it.

  The text is English and is not translated. It is written for whoever is
  handed the archive, an auditor for example, not for the signed-in org-admin,
  and it must read the same whoever downloaded it.

  The README is not signed; only `manifest.json` is. It says so, and tells the
  reader to check the host in the key URL before trusting the key.

  The Python example it points to lives in `docs/audit-log-signed-exports.md`.
  """

  @python_doc "docs/audit-log-signed-exports.md"
  @python_doc_url "https://github.com/cheezy/kanban/blob/main/docs/audit-log-signed-exports.md"

  @doc """
  The name of the export file inside the archive: `audit_log.csv` or
  `audit_log.json`.
  """
  @spec file_name(:csv | :json) :: String.t()
  def file_name(format) when format in [:csv, :json], do: "audit_log.#{format}"

  @doc """
  The README for an export of `format` signed with the key `key_id`.
  `keys_url` is the absolute URL of this instance's published signing keys;
  the first command fetches the PEM of `key_id` from it.
  """
  @spec text(%{
          required(:format) => :csv | :json,
          required(:key_id) => String.t(),
          required(:keys_url) => String.t(),
          optional(atom()) => term()
        }) :: String.t()
  def text(%{format: format, key_id: key_id, keys_url: keys_url}) do
    file = file_name(format)
    query = URI.encode_query([{"format", "pem"}, {"kid", key_id}])

    """
    Stride signed audit log export
    ==============================

    This archive holds:

      #{file}
          The exported audit events.
      manifest.json
          What the export is: the Stride instance, the Organization, who made
          it and when, the filters, the row count, and the size and SHA-256
          of #{file}.
      manifest.json.sig
          The Ed25519 signature over the exact bytes of manifest.json,
          as 64 raw bytes.
      README.txt
          This file.

    How to verify
    -------------

    The commands need OpenSSL 3.0 or later. Check with "openssl version".
    The openssl that ships with macOS is LibreSSL, which cannot check Ed25519
    signatures. On a Mac, install OpenSSL 3 (for example
    "brew install openssl@3") and run it by its full path.

    1. Get the public key named by key_id in manifest.json, or use the
       one you recorded earlier. This export was signed with the key
       #{key_id}.

    curl -fsS "#{keys_url}?#{query}" -o stride-audit.pem

    2. Check the signature on the manifest. It prints
       "Signature Verified Successfully".

    openssl pkeyutl -verify -pubin -inkey stride-audit.pem -rawin -in manifest.json -sigfile manifest.json.sig

    3. Check the file against the manifest. The result must equal file.sha256
       in manifest.json. "openssl dgst -sha256 #{file}" and
       "sha256sum #{file}" give the same value.

    shasum -a 256 #{file}

    The URL in step 1 is quoted because some shells, such as zsh on macOS,
    treat "?" as a wildcard.

    Only manifest.json is signed. This README is not, so compare the
    host in step 1 with the Stride instance you expect before trusting the
    key it returns.

    Python
    ------

    To automate the check, Stride's documentation has a short Python example
    that uses the "cryptography" package and works on any system:

      #{@python_doc} in the Stride repository
      #{@python_doc_url}

    What the signature proves
    -------------------------

    It proves that this Stride instance produced these exact bytes at the
    time in generated_at, for the Organization and filters in the manifest,
    as long as the key has not been revoked. It does not prove that the
    export is complete beyond what the manifest says: a filtered or
    truncated export says so in "filters" and "truncated".
    """
  end
end
