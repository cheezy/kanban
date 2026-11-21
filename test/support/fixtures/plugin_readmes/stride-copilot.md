## Installation

**From the Stride Copilot marketplace** (recommended):

```bash
copilot plugin marketplace add cheezy/stride-copilot-marketplace
copilot plugin install stride-copilot
```

**Directly from the repository** (alternative):

```bash
copilot plugin install https://github.com/cheezy/stride-copilot
```

### Plugin Management

```bash
copilot plugin list                        # View installed plugins
copilot plugin update stride-copilot       # Update to latest version
copilot plugin uninstall stride-copilot    # Remove plugin
```

Once per session, `stride-workflow` Step 0 runs `hooks/check-plugin-current.sh`
(PowerShell: `hooks/check-plugin-current.ps1`) to tell you when your installed
copy has fallen behind. It compares the `version` in this plugin's `plugin.json`
with the `stride-copilot` entry of the published stride-copilot-marketplace
catalog. When yours is lower it prints one line naming both versions and
`copilot plugin update stride-copilot`; when yours is current, or either version
cannot be read, it prints nothing. It never blocks the workflow, sends no
credentials, and is skipped when the plugin root cannot be located.

### Migrating from v1.x (copy-based installation)

If you previously installed by copying the `.github/` directory into your project:

1. Remove the copied `.github/skills/stride-*` and `.github/agents/` files from your project
2. Install via the plugin command above
3. The plugin system handles discovery automatically — no manual file copying needed
