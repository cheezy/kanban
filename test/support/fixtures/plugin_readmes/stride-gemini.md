## Installation

Install directly from GitHub using the Gemini CLI:

```bash
gemini extensions install https://github.com/cheezy/stride-gemini
```

The repo ships a [`gemini-extension.json`](gemini-extension.json) manifest at its root, so the command above installs it as a first-class Gemini CLI extension (`GEMINI.md` is loaded as the extension context file).

Or clone manually and copy files into your project:

```bash
git clone https://github.com/cheezy/stride-gemini.git

# Copy skills and agents into your project
cp -r stride-gemini/skills/ your-project/skills/
cp -r stride-gemini/agents/ your-project/agents/
cp stride-gemini/GEMINI.md your-project/GEMINI.md
```

Gemini CLI automatically discovers skills in `skills/` and custom agents in `agents/` at the project root.
