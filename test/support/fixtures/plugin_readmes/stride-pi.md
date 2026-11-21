## Installation

### One-liner (recommended)

Install globally so skills are available to every project Pi opens:

```bash
curl -fsSL https://raw.githubusercontent.com/cheezy/stride-pi/main/install.sh | bash
```

Or install into the current project only:

```bash
curl -fsSL https://raw.githubusercontent.com/cheezy/stride-pi/main/install.sh | bash -s -- --project
```

### Manual installation

```bash
git clone https://github.com/cheezy/stride-pi.git

# Copy skills to Pi's auto-discovery root
cp -R stride-pi/skills/. ~/.pi/agent/skills/
cp stride-pi/AGENTS.md ~/.pi/agent/AGENTS.md
```

Pi discovers skills in `~/.pi/agent/skills/` (global) or `.pi/skills/` (project) and walks up parent directories looking for `AGENTS.md` to concatenate as always-active context. See Pi's README for the full auto-discovery rules.

### Update check

When the hook-bridge extension is installed, `stride-workflow` runs `extensions/hook-bridge/check-plugin-current.ts` once per session, in Step 0. It compares your installed version with the `version` in `package.json` on the `main` branch. If yours is older, it prints a single line with both numbers and the command that brings the install up to date: the one-liner above (with `--project` for a project install), or `git pull` when Pi runs this repository directly. In every other case it prints nothing, and it never holds up the session.

- **Where your version comes from.** `install.sh` writes it to `extensions/hook-bridge/.stride-pi-version` when it installs the extensions; a checkout that Pi runs directly uses its own `package.json`. The manual installation above copies neither file, and neither does an install with `--no-extensions` (which also removes a record left by an earlier full install), so in both cases the check stays silent.
- **Between releases.** The one-liner installs whatever is on `main`, and `main` changes its version number only when a release is cut. An install taken between two releases carries the last release's number, so the check counts it as current until the next release raises the number on `main`, however many commits land in the meantime.
- **What it sends.** A single unauthenticated GET to `raw.githubusercontent.com`, given 3 seconds to answer. Your Stride token is never part of the request.
- **Node.js.** The check runs as `node <file>.ts`, which needs Node.js 22.18 or newer. On an older Node the command fails, and Step 0 ignores the failure.
