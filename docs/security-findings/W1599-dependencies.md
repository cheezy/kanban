# Security Findings — Dependencies & Supply-Chain (W1599)

> Domain 8 of the comprehensive security review (G309). Audit-tool driven,
> re-run against the post-rebase tree.
>
> **Verdict: clean.** 0 findings. No vulnerable, retired, or dangerously-outdated
> dependencies.

## Audit results (post-rebase working tree)

| Tool | Result |
|------|--------|
| `mix deps.audit` (mix_audit CVE DB) | **No vulnerabilities found.** |
| `mix hex.audit` | **No retired or security-advisory packages found.** |
| `mix hex.outdated` (baseline W1591) | **All 35 dependencies up-to-date** (current == latest). |

No defect filed — this is a documented clean bill.

## Native / precompiled supply-chain vectors (informational)

These deps ship or download native code and are the meaningful supply-chain
surface. All are current, widely used, and audited clean:

- **`bcrypt_elixir ~> 3.0`** (resolved 3.3.2) — C NIF for password hashing.
- **`mdex ~> 0.8`** (resolved 0.13.3) — Rust-based markdown (comrak) via
  `rustler_precompiled`, which downloads a precompiled NIF at build time.
- **`chromic_pdf ~> 1.17`** (resolved 1.17.1) — drives a system Chrome/Chromium
  for server-side PDF generation (see the secrets/deploy domain W1598 for the
  Dockerfile Chrome-pinning note, W1429).

`rustler_precompiled` fetches a prebuilt binary keyed by a checksum in `mix.lock`;
the lockfile hashes pin the resolved artifacts. Recommendation for ongoing
hygiene (not a defect): keep running `mix deps.audit` / `mix hex.audit` on every
dependency change (already codified in AGENTS.md and the after_doing gate), and
periodically review the precompiled-NIF checksums.

## Note

The plug 1.20.1 → 1.20.2 retirement (fixed in prior work) is resolved — `hex.audit`
reports no retired packages, confirming the lockfile carries plug 1.20.2.
