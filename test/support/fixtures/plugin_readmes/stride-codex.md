## Installation

### One-liner (recommended)

Install globally so skills and agents are available in all projects:

```bash
curl -fsSL https://raw.githubusercontent.com/cheezy/stride-codex/main/install.sh | bash
```

Or install into the current project only:

```bash
curl -fsSL https://raw.githubusercontent.com/cheezy/stride-codex/main/install.sh | bash -s -- --project
```

### Windows (PowerShell)

Requires PowerShell 5.1+ or PowerShell Core 7+ and Git for Windows on `PATH`.

Install globally so skills and agents are available in all projects:

```powershell
irm https://raw.githubusercontent.com/cheezy/stride-codex/main/install.ps1 | iex
```

Or install into the current project only (the scriptblock wrapper is required to pass `-Project` through `irm | iex`):

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/cheezy/stride-codex/main/install.ps1))) -Project
```

Download and run manually if you prefer:

```powershell
irm https://raw.githubusercontent.com/cheezy/stride-codex/main/install.ps1 -OutFile install.ps1
.\install.ps1            # global install
.\install.ps1 -Project   # project-local install
.\install.ps1 -Help      # print usage and exit
```

### Manual installation

```bash
git clone https://github.com/cheezy/stride-codex.git

# Copy skills, agents and the hook surface
cp -r stride-codex/skills/ .agents/skills/
cp -r stride-codex/agents/ .agents/agents/
cp stride-codex/AGENTS.md AGENTS.md

# The hook surface. Only the runtime files; the test script stays in the
# repo. -p preserves the executable bit on the scripts.
mkdir -p .agents/hooks
cp -p stride-codex/hooks/stride-hook.sh .agents/hooks/stride-hook.sh
cp -p stride-codex/hooks/stride-stop-gate.sh .agents/hooks/stride-stop-gate.sh
cp stride-codex/hooks/hooks.json .agents/hooks/hooks.json

# The Step 0 update check, and the version record it reads in a loose copy
cp -p stride-codex/hooks/check-plugin-current.sh .agents/hooks/check-plugin-current.sh
jq -r .version stride-codex/.codex-plugin/plugin.json > .agents/hooks/stride-codex.version
```

For Windows manual installation, use `Copy-Item`:

```powershell
git clone https://github.com/cheezy/stride-codex.git

# Copy skills, agents and the hook surface
Copy-Item -Recurse stride-codex\skills\* .agents\skills\
Copy-Item -Recurse stride-codex\agents\*.md .agents\agents\
Copy-Item stride-codex\AGENTS.md .\AGENTS.md

# The hook surface. Only the runtime files; the test script stays in the repo.
New-Item -ItemType Directory -Force -Path .agents\hooks | Out-Null
Copy-Item stride-codex\hooks\stride-hook.sh .agents\hooks\stride-hook.sh
Copy-Item stride-codex\hooks\stride-stop-gate.sh .agents\hooks\stride-stop-gate.sh
Copy-Item stride-codex\hooks\hooks.json .agents\hooks\hooks.json

# The Step 0 update check, and the version record it reads in a loose copy
Copy-Item stride-codex\hooks\check-plugin-current.sh .agents\hooks\check-plugin-current.sh
(Get-Content -Raw stride-codex\.codex-plugin\plugin.json | ConvertFrom-Json).version | Set-Content -NoNewline .agents\hooks\stride-codex.version
```

Codex CLI discovers skills in `.agents/skills/` or `.codex/skills/` and agents in `.agents/agents/` automatically. **Hooks are the exception — `.agents/hooks/` is not a scanned location.** A `.agents/` install is a loose tree, not a plugin bundle, so the copied `hooks/hooks.json` is not picked up on its own and the handler must be registered once by hand; see [The Stride hook surface](#the-stride-hook-surface).

### Staying current

Codex runs whichever copy of the skills and agents is installed, and the Stride server cannot tell one release from another, so a fix shipped after you installed does nothing until you update. Step 0 of `stride-workflow` checks once per session: `hooks/check-plugin-current.sh` compares the installed version with the one [stride-codex-marketplace](https://github.com/cheezy/stride-codex-marketplace) publishes and prints one line when yours is older. That line says how to update: `codex plugin update stride-codex` for a plugin install, or re-running the installer for an `.agents/` copy. It is advice, never a block. The script reads a plugin install's `.codex-plugin/plugin.json`, or for an `.agents/` copy the `hooks/stride-codex.version` record the installers write. With neither, or with no network, it stays silent. The fetch is anonymous, HTTPS only and capped at three seconds.
