# Signed Audit Log Exports

This document is for two readers. Auditors and anyone else who receives a
signed audit log export use the first half to check it without trusting
whoever handed it over. Operators running Stride use the second half to set
up the signing key, rotate it and revoke it.

An org-admin downloads a signed export from the Organization audit log at
`/org/audit` with **Export signed (.zip)**; see
[The Organization audit log](organizations.md#the-organization-audit-log).
The button exports the events that match the page's current filters as CSV. A
signed JSON export is requested by URL, with
`/org/audit/export?signed=true&format=json` and the same filter parameters. A
signed export counts towards the same 10 exports an hour and the same 50,000
events per download as an unsigned one.

The `signed` parameter takes exactly `true` or `false`. `signed=false`, like
leaving the parameter out, gives an ordinary unsigned export. Any other value,
such as `yes`, `1`, `TRUE`, an empty value or a value with spaces, is refused
with a message and is not counted, and so is a `signed` parameter given more
than once, such as `signed=true&signed=false`. A request whose `signed`
parameter asks for a signature therefore never gets an unsigned file without
saying so. A misspelt parameter name, such as `sigend=true`, is not a `signed`
parameter at all and gives an unsigned export, so check that what you
downloaded is a zip.

The same key also signs the audit batches Stride streams to an HTTPS
destination, and receivers check those against the same published keys. This
document covers exports only.

## What the zip holds

The zip, named `org_audit_log_<date>_signed.zip`, holds exactly four files:

| File | What it is |
|---|---|
| `audit_log.csv` or `audit_log.json` | The exported events, byte for byte what an unsigned export of the same events holds, newest first |
| `manifest.json` | What the export is: the instance, the Organization, who made it and when, the filters, the row count, and the size and SHA-256 of the events file |
| `manifest.json.sig` | The Ed25519 signature over the exact bytes of `manifest.json`, as 64 raw bytes |
| `README.txt` | The three commands that verify the export, and what the signature proves |

The zip does not hold a public key. Take the key from the instance that made
the export, or from a copy you recorded earlier, as
[Verifying with OpenSSL 3](#verifying-with-openssl-3) describes.

### The manifest

`manifest.json` holds these fields, in this order:

| Field | Meaning |
|---|---|
| `schema` | The manifest format, `stride.audit-export.v1` |
| `instance` | The host name of the Stride instance that made the export |
| `organization` | The Organization's `id` and `name` |
| `generated_at` | When the export was made, in UTC to the second, such as `2026-11-09T15:20:04Z` |
| `generated_by` | The `user_id` and `email` of the org-admin who made it |
| `filters` | The filters the export used: always the three keys `action`, `from` and `to`, each `null` when it was not set. `from` and `to` are dates, `YYYY-MM-DD`. An `action` that no event of the Organization holds is not applied, as on `/org/audit`, so it is recorded as `null` |
| `file` | The events file: its `name` (`audit_log.csv` or `audit_log.json`), its `format` (`csv` or `json`), its size in `bytes`, and its `sha256` as 64 lowercase hex characters |
| `rows` | The number of events in the file |
| `oldest_event` | The `id` and `inserted_at` of the oldest event in the file, which is its last row. `null` when the file has no events |
| `newest_event` | The `id` and `inserted_at` of the newest event in the file, which is its first row. `null` when the file has no events |
| `truncated` | `true` when more events matched the filters than one download holds. The file then holds the newest 50,000 of them and the older ones are not in it. `false` when the file holds every matching event |
| `key_id` | The id of the key that signed the manifest, such as `k1-` and 16 hex characters |

The rows run newest first, so `newest_event` names the first row and
`oldest_event` the last. `inserted_at` carries microseconds, exactly as the
row in the file does; `generated_at` stops at the second.

## What a signature proves

A signature that verifies proves that this Stride instance produced these
exact bytes at the time in `generated_at`, for the Organization and the
filters in the manifest, as long as the key that signed it has not been
revoked and is the instance's own key. Only a key whose fingerprint you
compared with one recorded outside Stride is known to be the instance's; see
[Checking the key itself](#checking-the-key-itself).

It does not prove:

- **That the export is complete beyond what the manifest says.** A filtered
  export says so in `filters`, and an export cut at the row limit says so in
  `truncated`.
- **That nothing happened to the events before they were exported.** That
  depends on the audit log being append-only in the database; see
  [Audit Log Ownership Hardening](audit-log-hardening.md).
- **Anything about the export itself.** Making an export records an
  `org_audit_log_exported` event that carries the file's SHA-256, so it is
  recorded after the file is built. A signed file can never hold its own
  export event; that event appears in the next export. The event records that
  a signed file was issued, not that it was received: it is written before the
  first byte is sent, and it stays when the download is cancelled.
- **Anything about `README.txt`.** Only `manifest.json` is signed. Compare the
  host in the README's first command with the instance you expect before you
  trust the key it fetches.

An event written while a long export was being built can be missing from it
even when its time falls inside the exported range. The manifest does not
record that. Export the same range again later if you need it.

## Verifying with OpenSSL 3

The commands need **OpenSSL 3.0 or later**. Check with `openssl version`.

**On macOS, the `openssl` that ships with the system is LibreSSL, which cannot
check Ed25519 signatures** or load Ed25519 keys; it fails with "unable to load
Public Key". Install OpenSSL 3, for example with `brew install openssl@3`, and
run it by its full path, `$(brew --prefix openssl@3)/bin/openssl`. That is
`/opt/homebrew/opt/openssl@3/bin/openssl` on Apple silicon and
`/usr/local/opt/openssl@3/bin/openssl` on Intel Macs. Replace `openssl` in the
commands below with that path.

Unzip the export, then run the three commands in the folder that holds its
files:

1. **Get the public key named by `key_id` in `manifest.json`**, or use the one
   you recorded earlier. Replace `<stride host>` with the host you expect the
   Organization's Stride to be on, and `<key_id>` with the manifest's
   `key_id`. Do not take the host from the zip: neither `README.txt` nor the
   manifest is checked yet, and a key fetched from a host someone else chose
   verifies whatever they signed:

   ```bash
   curl -fsS "https://<stride host>/.well-known/stride-audit-signing-keys?format=pem&kid=<key_id>" -o stride-audit.pem
   ```

   The URL is quoted because some shells, such as zsh on macOS, treat `?` as
   a wildcard: without the quotes zsh stops with "no matches found". In bash
   an unquoted `&` ends the command there instead, so curl runs in the
   background without `kid` and gets a `404`. Keep the quotes in every shell.

2. **Check the signature on the manifest.** It prints
   `Signature Verified Successfully`, and anything else means the manifest was
   not signed by that key or has changed:

   ```bash
   openssl pkeyutl -verify -pubin -inkey stride-audit.pem -rawin -in manifest.json -sigfile manifest.json.sig
   ```

3. **Check the file against the manifest.** The result must equal
   `file.sha256` in `manifest.json`. `openssl dgst -sha256 audit_log.csv` and
   `sha256sum audit_log.csv` give the same value:

   ```bash
   shasum -a 256 audit_log.csv
   ```

   For a JSON export, run the same command on `audit_log.json`.

These are the commands in the zip's `README.txt`. Once the signature and the
file both check, also check that the manifest's `instance` is the host you
fetched the key from. It holds the host name only, without a port.

### Checking the key itself

The signature proves only that the key you fetched signed the manifest. **The
result counts only once you have also compared that key's fingerprint with one
recorded outside Stride**, using the one-line command in
[Key id and fingerprint](#key-id-and-fingerprint). The org-admin sees the
current key's **Key ID** and **Fingerprint (SHA-256)** in the **Signing key**
panel on `/org/audit`, and should record the fingerprint somewhere outside
Stride, and give it to whoever verifies exports, when the key is set up. A key
that signed an older export is in the key set as a previous key; compare it
with the fingerprint recorded while it was current.

## Verifying with Python

This script does what steps 2 and 3 and the fingerprint check do, for
automation or for a system without OpenSSL 3. It uses the `cryptography`
package, which `pip install cryptography` installs. Fetch `stride-audit.pem` as
in step 1 first, set `EXPECTED_FINGERPRINT` to the fingerprint you recorded
outside Stride, then run the script with `python3 verify.py` in the folder
where you unzipped the export:

```python
import hashlib
import json
import sys

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
from cryptography.hazmat.primitives.serialization import (
    Encoding,
    PublicFormat,
    load_pem_public_key,
)

# The key's fingerprint, as recorded outside Stride: 64 hex characters.
EXPECTED_FINGERPRINT = ""

expected = EXPECTED_FINGERPRINT.strip().lower()
if len(expected) != 64:
    sys.exit("FAILED: set EXPECTED_FINGERPRINT to the fingerprint recorded outside Stride")

# Run in the folder where you unzipped the export, next to stride-audit.pem.
manifest_bytes = open("manifest.json", "rb").read()
signature = open("manifest.json.sig", "rb").read()
public_key = load_pem_public_key(open("stride-audit.pem", "rb").read())
if not isinstance(public_key, Ed25519PublicKey):
    sys.exit("FAILED: stride-audit.pem is not an Ed25519 public key")

raw_key = public_key.public_bytes(Encoding.Raw, PublicFormat.Raw)
if hashlib.sha256(raw_key).hexdigest() != expected:
    sys.exit("FAILED: stride-audit.pem is not the key whose fingerprint you recorded")

try:
    public_key.verify(signature, manifest_bytes)
except InvalidSignature:
    sys.exit("FAILED: manifest.json was not signed by this key")

manifest = json.loads(manifest_bytes)
digest = hashlib.sha256(open(manifest["file"]["name"], "rb").read()).hexdigest()
if digest != manifest["file"]["sha256"]:
    sys.exit("FAILED: " + manifest["file"]["name"] + " does not match the manifest")

print("OK: signed by", manifest["key_id"], "- file matches the manifest")
```

It exits with status 1 and a `FAILED` line when a check fails, including
when `EXPECTED_FINGERPRINT` is empty or is not 64 hex characters; case and
surrounding spaces do not matter. A missing file stops it with a Python error
and status 1 instead. It never prints the fetched key's fingerprint, so a value
for `EXPECTED_FINGERPRINT` can only come from your own record. The script checks
the key before the signature, and verifies the bytes of `manifest.json` before
it parses them, so a changed manifest never reaches the SHA-256 check. It does
not check the manifest's `instance`; compare that with the host you fetched the
key from yourself.

## The key endpoint

Each Stride instance publishes its signing keys at
`/.well-known/stride-audit-signing-keys`. The endpoint is public: it needs no
sign-in and sets no cookie.

Without parameters it returns a JSON Web Key Set with a list of revoked keys:

```json
{
  "keys": [
    {"kty": "OKP", "crv": "Ed25519", "x": "<public key>", "kid": "<key_id>", "use": "sig", "alg": "EdDSA"}
  ],
  "revoked": [
    {"kid": "<key_id>", "revoked_at": "2026-11-11"}
  ]
}
```

- **`keys`** lists the current key first, then every previous key, which still
  verifies what it signed before a rotation. Each entry has `kty` `OKP`,
  `crv` `Ed25519`, `use` `sig`, `alg` `EdDSA`, the key id in `kid`, and in `x`
  the 32 raw public-key bytes as base64url without padding.
- **`revoked`** lists each revoked key by `kid`, with the date the operator
  gave in `revoked_at`, or `null` when they gave none. A revoked key is never
  in `keys`: nothing it signed proves anything.

`?format=pem&kid=<key_id>` returns that one key as a PEM public key, with the
content type `application/x-pem-file`. That is the request step 1 makes.

A `?format=pem` request returns `404` when `kid` is missing, is not a key id,
names a key the instance does not publish, or names a revoked key. Any
`format` other than `pem` also returns `404`. Without `format`, `kid` is
ignored and the whole key set is returned. A query string that cannot be
decoded, such as one with invalid UTF-8, is refused with `400` before any of
this. A malformed percent escape such as `%ZZ` is not refused: it is read as
the literal text `%ZZ`, so `?kid=%ZZ` returns the whole key set and
`?format=pem&kid=%ZZ` returns `404`.

Both successful responses are sent with `Cache-Control: public, max-age=3600`,
so a verifier or proxy may keep a copy for up to an hour. A rotation or a
revocation can therefore take an hour to reach someone who fetched the keys
just before it. The `404` is never cached.

## Key id and fingerprint

Both are computed over the key's 32 raw public-key bytes, the bytes that `x`
holds in base64url:

- **The fingerprint** is the SHA-256 of those bytes, as 64 lowercase hex
  characters.
- **The key id** is `k1-` followed by the first 16 characters of the
  fingerprint.

This one line reproduces both from the PEM that step 1 fetched. It needs
OpenSSL 3, and runs in bash or zsh:

```bash
openssl pkey -pubin -in stride-audit.pem -outform DER -out stride-audit.der && fp=$(tail -c 32 stride-audit.der | shasum -a 256 | cut -d' ' -f1) && echo "fingerprint: $fp" && echo "key id:      k1-${fp:0:16}"
```

The DER form of an Ed25519 public key is a fixed 12-byte prefix followed by
the 32 key bytes, so `tail -c 32` keeps the key. The line prints nothing but
openssl's error when the PEM cannot be loaded, for example by LibreSSL, so it
never shows a fingerprint for a key it did not read. The key id it prints must
equal the manifest's `key_id`, and the fingerprint must equal the one you
recorded.

## Setting up the signing key

The rest of this document is for operators. One Ed25519 key per instance
signs every export, and three environment variables configure it:

| Variable | Holds | Format |
|---|---|---|
| `AUDIT_SIGNING_KEY` | The current private key | Either the PEM that `openssl genpkey -algorithm ed25519` writes (`-----BEGIN PRIVATE KEY-----`), or the standard base64 of the 32-byte seed. A PEM pasted on one line may use a literal `\n` for each line break |
| `AUDIT_SIGNING_KEYS_PREVIOUS` | Public keys that signed earlier exports and still verify them | Comma-separated. Each entry is the 32 raw public-key bytes as base64url, which is exactly the key's `x` in the key set |
| `AUDIT_SIGNING_KEYS_REVOKED` | Public keys that must no longer verify anything | Comma-separated, in the same format as `AUDIT_SIGNING_KEYS_PREVIOUS`. Each entry may be followed by a colon and the date it was revoked, `YYYY-MM-DD`, which the key set shows as `revoked_at` |

A blank value counts as unset. Stride refuses to boot, naming the variable but
never printing its value, when a value cannot be read, when one key is in both
lists, when `AUDIT_SIGNING_KEY` holds a key from either list, or when the
key in `AUDIT_SIGNING_KEY` is in `AUDIT_SIGNING_KEYS_REVOKED`. These checks
cover a key set in `AUDIT_SIGNING_KEY` only: a development or test key that
Stride generated and that is listed as revoked does not stop the boot, it
turns signing off.

When `AUDIT_SIGNING_KEY` is unset:

- **In production**, signing is off and the app still boots, with a warning
  that tells you to generate a key. **Export signed (.zip)** is disabled on
  `/org/audit` with "Signed exports are not set up on this server.", and a
  signed export requested by URL is refused with the same message and is not
  counted. The key set publishes only the previous keys, so exports signed
  before still verify. Streamed batches are sent with their HMAC only.
- **In development**, Stride generates a key the first time it needs one and
  keeps it in `tmp/audit_signing_key.pem`, readable only by its owner, so it
  survives restarts. `tmp/` is ignored by git.
- **In tests**, each test run uses a new random key that is never written to
  disk.

Setting `AUDIT_SIGNING_KEY` in development or tests uses it instead.

**Keep the private key in the environment and nowhere else.** Stride never
stores the production key in the database or writes it to disk; only the
development key is kept on disk. Keep it out of logs and crash dumps too: do
not print it, do not echo it in a deploy script, and do not leave the file you
generated it into once the secret is set. Never commit it.

- **Load it from the file or from standard input** with your platform's import
  command, never by pasting the PEM as a command-line argument, where it lands
  in shell history and the process list.
- **Keep crash dumps from carrying it.** The running app holds the key in
  memory, and an Erlang crash dump holds that memory. Turn crash dumps off with
  `ERL_CRASH_DUMP_BYTES=0`, or point `ERL_CRASH_DUMP` at a path only the app's
  user can read and treat any dump written there as holding the key.

To turn signing on:

1. **Generate a key** on a machine you trust:

   ```bash
   openssl genpkey -algorithm ed25519 -out audit-signing-key.pem
   ```

2. **Set `AUDIT_SIGNING_KEY`** to the contents of that file, loading it into
   your platform's secret store from the file or from standard input, then
   delete the file.
3. **Deploy**, and open `/org/audit` as an org-admin. Record the **Fingerprint
   (SHA-256)** from the **Signing key** panel somewhere outside Stride, and
   give it to whoever will verify exports.

## Rotating the key

Rotate to replace a key that has not leaked, for example on a schedule.
**A rotated key keeps verifying what it signed, so rotation is never the fix
for a leaked key**; for that, follow
[Revoking a leaked key](#revoking-a-leaked-key).

1. **Generate the new key:**

   ```bash
   openssl genpkey -algorithm ed25519 -out audit-signing-key.pem
   ```

2. **Add the current public key to `AUDIT_SIGNING_KEYS_PREVIOUS`.** Fetch the
   key set with
   `curl -fsS "https://<stride host>/.well-known/stride-audit-signing-keys"`,
   and copy `x` from the entry whose `kid` is the key id on `/org/audit`.
   Append it to the variable, after a comma if it already holds keys.
3. **Set `AUDIT_SIGNING_KEY`** to the new key, then delete the file.
4. **Deploy** both changes together. Stride now signs with the new key.
5. **Check the key set.** It lists the new key first and the old key after it.
   Record the new fingerprint from `/org/audit` outside Stride and give it to
   whoever verifies exports.

Exports signed with the old key still verify: step 1 of
[Verifying with OpenSSL 3](#verifying-with-openssl-3) fetches its PEM by
`kid`, as before. Its entry also stays in the key set.

## Revoking a leaked key

Revoke a key when its private key may have leaked. A leaked key lets anyone
sign exports and streamed batches that verify as this instance's, for every
Organization on it. **A leaked key goes in `AUDIT_SIGNING_KEYS_REVOKED`, never
in `AUDIT_SIGNING_KEYS_PREVIOUS`**, because a previous key still verifies.

1. **Copy the leaked key's `x` and `kid`** from the key set now. Once the key
   is revoked it leaves `keys`.
2. **Find out which key leaked.** If its `kid` is the **Key ID** on
   `/org/audit`, the current key leaked: follow every step. If it is a
   previous key, the current key is unaffected: skip step 3, and in step 4
   leave `AUDIT_SIGNING_KEY` as it is.
3. **Generate a new key** to replace the leaked current key:

   ```bash
   openssl genpkey -algorithm ed25519 -out audit-signing-key.pem
   ```

4. **Change the variables together, as one change.** Stride checks them as a
   set when it boots, and refuses to start with any change half made: with a
   key in both lists, or with the key in `AUDIT_SIGNING_KEY` revoked. If your
   platform restarts the app on each secret it sets, set them all in one
   command or one release:
   - add the leaked key to `AUDIT_SIGNING_KEYS_REVOKED`, followed by a colon
     and today's date, for example `<public key>:2026-11-11`;
   - remove it from `AUDIT_SIGNING_KEYS_PREVIOUS` if it is there, and never
     add it there;
   - when the current key leaked, set `AUDIT_SIGNING_KEY` to the new key,
     loading it from the file, then delete the file.
5. **Deploy once.** Check that the key set no longer lists the leaked key in
   `keys`, lists its `kid` under `revoked`, and that its PEM by `kid` returns
   `404`.
6. **Re-export.** Every export signed with the leaked key now proves nothing.
   Ask the org-admins to download again the exports they need, which the
   current key now signs.
7. **Tell every receiver the leaked `kid`**: auditors who hold its exports,
   and anyone who verifies streamed batches. Anything it signed proves
   nothing, and a receiver that fetched the key set in the last hour should
   fetch it again. Streamed batches also carry an HMAC with the destination's
   own secret, which remains a separate proof for batches already received.
8. **Record the new fingerprint**, when the current key changed, from
   `/org/audit` outside Stride and give it to whoever verifies exports.
