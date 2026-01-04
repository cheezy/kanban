# Windows Setup Guide for Stride AI Agents

## Overview

Stride AI agents can run on Windows using three approaches:

1. **WSL2 (Windows Subsystem for Linux)** - Recommended
2. **PowerShell** with Windows-native tools
3. **Git Bash** (MinGW)

Each approach has different tradeoffs for compatibility, performance, and ease of setup.

## Quick Recommendation

**For most users: Use WSL2**
- Best compatibility with Unix-based documentation
- All bash examples work as-is
- Native Linux environment
- Best performance for git operations
- Access to full Unix toolchain

**For PowerShell users:**
- Native Windows integration
- No virtualization overhead
- Requires PowerShell equivalents for all hooks
- More complex hook configuration

**For Git Bash users:**
- Lightweight alternative to WSL2
- Most bash examples work
- Some Unix commands not available
- Limited compared to WSL2

---

## Option 1: WSL2 Setup (Recommended)

### Prerequisites

- Windows 10 version 2004+ or Windows 11
- Administrator access to install WSL2

### Installation Steps

1. **Enable WSL2:**

Open PowerShell as Administrator and run:

```powershell
wsl --install
```

This installs WSL2 and Ubuntu by default.

2. **Restart your computer** when prompted.

3. **Set up Ubuntu:**

After restart, Ubuntu will open automatically. Create a username and password.

4. **Update packages:**

```bash
sudo apt update && sudo apt upgrade -y
```

5. **Install Elixir and Erlang:**

```bash
# Add Erlang Solutions repository
wget https://packages.erlang-solutions.com/erlang-solutions_2.0_all.deb
sudo dpkg -i erlang-solutions_2.0_all.deb
sudo apt update

# Install Erlang and Elixir
sudo apt install -y esl-erlang elixir
```

6. **Install Git:**

```bash
sudo apt install -y git
```

7. **Clone your project:**

```bash
cd ~
git clone <your-repo-url>
cd <your-project>
```

8. **Set up environment variables:**

Add to `~/.bashrc`:

```bash
export STRIDE_API_TOKEN="stride_abc123def456..."
export STRIDE_API_URL="https://www.stridelikeaboss.com"
```

Reload:
```bash
source ~/.bashrc
```

9. **Install project dependencies:**

```bash
mix deps.get
```

10. **Configure `.stride.md`:**

Use Unix/Linux bash examples from the documentation. All hook examples work as-is in WSL2.

### WSL2 Tips

- **Access Windows files:** Your Windows drives are mounted at `/mnt/c`, `/mnt/d`, etc.
- **Access WSL files from Windows:** Use `\\wsl$\Ubuntu\home\<username>` in File Explorer
- **Performance:** Keep project files in WSL filesystem (~/...) for best git performance
- **VS Code integration:** Install "Remote - WSL" extension for seamless editing

---

## Option 2: PowerShell Setup

### Prerequisites

- Windows 10 or Windows 11
- PowerShell 5.1+ (included with Windows)
- Elixir and Erlang installed on Windows

### Installation Steps

1. **Install Elixir:**

Download and install from [elixir-lang.org/install.html#windows](https://elixir-lang.org/install.html#windows)

Or use Chocolatey:

```powershell
choco install elixir
```

2. **Install Git for Windows:**

Download from [git-scm.com](https://git-scm.com/download/win)

3. **Set environment variables:**

```powershell
$env:STRIDE_API_TOKEN = "stride_abc123def456..."
$env:STRIDE_API_URL = "https://www.stridelikeaboss.com"
```

To make permanent, add to PowerShell profile:

```powershell
notepad $PROFILE
```

Add these lines:
```powershell
$env:STRIDE_API_TOKEN = "stride_abc123def456..."
$env:STRIDE_API_URL = "https://www.stridelikeaboss.com"
```

4. **Configure `.stride.md` with PowerShell hooks:**

See [PowerShell Hook Examples](#powershell-hook-examples) below.

### PowerShell Hook Examples

#### before_doing

```powershell
git pull origin main
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
mix deps.get
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
```

#### after_doing

```powershell
# Run tests with timeout (120 seconds)
$job = Start-Job -ScriptBlock { mix test }
$completed = Wait-Job $job -Timeout 120
if (-not $completed) {
    Stop-Job $job
    Remove-Job $job
    Write-Error "Tests timed out after 120 seconds"
    exit 1
}
$result = Receive-Job $job
Remove-Job $job
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

# Build project
mix compile --warnings-as-errors
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
```

#### before_review

```powershell
# Create branch name from task info
$branchName = "task-$env:TASK_IDENTIFIER-$($env:TASK_TITLE.ToLower() -replace ' ', '-' -replace '[^a-z0-9\-]', '')"
git checkout -b $branchName origin/main
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

git add .
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

git commit -m "$env:TASK_TITLE"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

git push -u origin $branchName
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
```

### PowerShell Limitations

- No native `timeout` command (use `Start-Job`/`Wait-Job` pattern)
- No `tr` command (use PowerShell string operators: `.ToLower()`, `-replace`)
- Different syntax for pipes and error handling
- Exit codes work differently (`$LASTEXITCODE` vs `$?`)

---

## Option 3: Git Bash Setup

### Prerequisites

- Git for Windows (includes Git Bash)

### Installation Steps

1. **Install Git for Windows:**

Download from [git-scm.com](https://git-scm.com/download/win)

Make sure to select "Use Git and optional Unix tools from the Command Prompt" during installation.

2. **Install Elixir:**

Download from [elixir-lang.org/install.html#windows](https://elixir-lang.org/install.html#windows)

3. **Open Git Bash** and configure environment variables:

Add to `~/.bashrc`:

```bash
export STRIDE_API_TOKEN="stride_abc123def456..."
export STRIDE_API_URL="https://www.stridelikeaboss.com"
```

Reload:
```bash
source ~/.bashrc
```

4. **Configure `.stride.md`:**

Most Unix/Linux bash examples work, but with some limitations (see below).

### Git Bash Limitations

- `timeout` command may not be available (install via additional packages or use alternative approaches)
- Some Unix utilities require separate installation
- Performance slower than WSL2 for git operations
- Not a full Linux environment

### Workarounds for Missing Commands

If `timeout` is not available:

```bash
# Simple alternative without timeout enforcement
mix test
```

Or install timeout via additional packages (more complex).

---

## Common Issues & Troubleshooting

### Issue: "mix: command not found"

**Cause:** Elixir not in PATH

**Solution:**

**WSL2:**
```bash
which mix  # Check if installed
# If not found, reinstall Elixir
```

**PowerShell:**
```powershell
# Add Elixir to PATH if not already there
$env:Path += ";C:\Program Files\Elixir\bin"
```

### Issue: "git: command not found"

**WSL2:**
```bash
sudo apt install git
```

**PowerShell/Git Bash:**
Reinstall Git for Windows and ensure "Add to PATH" is selected.

### Issue: Hook fails with "Permission denied"

**WSL2/Git Bash:**
Make sure hook scripts are executable (shouldn't be needed for `.stride.md`, but if you use separate files):
```bash
chmod +x .stride_hooks/*
```

**PowerShell:**
Set execution policy:
```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

### Issue: Line ending problems (CRLF vs LF)

**All platforms:**

Configure git to handle line endings:

```bash
git config --global core.autocrlf input
```

This ensures files are checked out with LF endings even on Windows.

### Issue: Environment variables not persisting

**WSL2/Git Bash:**
Add variables to `~/.bashrc` and run `source ~/.bashrc`

**PowerShell:**
Add variables to PowerShell profile (`$PROFILE`)

### Issue: Slow git operations in WSL2

**Solution:**
Keep project files in WSL filesystem (`~/projects`) not in `/mnt/c/...`

File operations on mounted Windows drives are slower.

---

## Platform Comparison

| Feature | WSL2 | PowerShell | Git Bash |
|---------|------|------------|----------|
| Setup complexity | Medium | Low | Low |
| Documentation compatibility | ✓ Excellent | ⚠️ Requires translation | ⚠️ Most examples work |
| Performance | ✓ Excellent | ✓ Good | ⚠️ Fair |
| Unix tools available | ✓ All | ✗ Limited | ⚠️ Some |
| Windows integration | ⚠️ Good | ✓ Excellent | ✓ Good |
| Hook configuration | ✓ Use bash examples | ⚠️ Requires PowerShell versions | ⚠️ Some workarounds needed |
| Recommended for | Most users | PowerShell experts | Lightweight alternative |

---

## Next Steps

After choosing and setting up your platform:

1. **Follow the main getting started guide:** [GETTING-STARTED-WITH-AI.md](GETTING-STARTED-WITH-AI.md)
2. **Configure hooks:** See [AGENT-HOOK-EXECUTION-GUIDE.md](AGENT-HOOK-EXECUTION-GUIDE.md)
3. **Read workflow documentation:** [AI-WORKFLOW.md](AI-WORKFLOW.md)
4. **Review API documentation:** [docs/api/README.md](api/README.md)

---

## Additional Resources

- **WSL2 Documentation:** [docs.microsoft.com/windows/wsl](https://docs.microsoft.com/en-us/windows/wsl/)
- **PowerShell Documentation:** [docs.microsoft.com/powershell](https://docs.microsoft.com/en-us/powershell/)
- **Git Bash:** Included with [Git for Windows](https://git-scm.com/download/win)
- **Elixir on Windows:** [elixir-lang.org/install.html#windows](https://elixir-lang.org/install.html#windows)

---

## Contributing

Found an issue with Windows setup? Have a better workaround? Please submit feedback via the About page or create an issue in the repository.

---

**Remember:** WSL2 provides the smoothest experience for following Unix-based documentation. If you're comfortable with PowerShell, the native Windows approach works well but requires translating hook examples.
