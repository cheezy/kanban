## Adding the marketplace

Register this marketplace with the Codex CLI:

```bash
codex plugin marketplace add cheezy/stride-codex-marketplace
```

Then install a plugin from it:

```bash
codex plugin install stride-codex
```

### Managing the marketplace and plugins

```bash
codex plugin marketplace list          # View registered marketplaces
codex plugin list                      # View installed plugins
codex plugin update stride-codex       # Update a plugin to the latest version
codex plugin uninstall stride-codex    # Remove a plugin
```
