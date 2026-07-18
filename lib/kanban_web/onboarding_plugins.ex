defmodule KanbanWeb.OnboardingPlugins.Agent do
  @moduledoc """
  One agent's plugin-install metadata for the onboarding picker.

  See `KanbanWeb.OnboardingPlugins` for how the registry is assembled and why
  the ideation fields are optional (Pi has no ideation port).
  """

  @enforce_keys [:key, :label, :workflow_command, :workflow_url, :uses_marketplace]
  defstruct [
    :key,
    :label,
    :workflow_command,
    :workflow_url,
    :uses_marketplace,
    :ideation_command,
    :ideation_url,
    :note
  ]

  @type t :: %__MODULE__{
          key: String.t(),
          label: String.t(),
          workflow_command: String.t(),
          workflow_url: String.t(),
          uses_marketplace: boolean(),
          ideation_command: String.t() | nil,
          ideation_url: String.t() | nil,
          note: String.t() | nil
        }
end

defmodule KanbanWeb.OnboardingPlugins do
  @moduledoc """
  Static, presentational registry of the agents Stride supports, used by the
  post-registration onboarding picker to show each agent's plugin-install
  instructions.

  This is the single source of truth the picker renders, so the install
  commands live in one tested place instead of being scattered through the
  confirmation LiveView template. It holds no runtime state and touches no
  database — the command and URL strings are literal constants that mirror
  `KanbanWeb.API.Agent.SetupDocs` and `docs/AI-WORKFLOW.md` so the onboarding
  page and the onboarding API never disagree.

  Each `t:KanbanWeb.OnboardingPlugins.Agent.t/0` carries two install recipes: the
  **workflow** plugin (the task lifecycle — claim/hook/complete) and, where one
  exists, the **ideation** plugin (turning a fuzzy idea into a requirements doc).
  Two facts are non-uniform and are captured explicitly rather than assumed:

    * **Only Claude Code installs through a marketplace** (`uses_marketplace`);
      the other five install directly from a repo/URL or a setup script.
    * **Pi has no ideation port yet** — only five ideation ports exist
      (Claude Code, Copilot, Gemini, Codex, OpenCode). Pi's `ideation_command`
      and `ideation_url` are therefore `nil`, and its `note` says so. The
      consuming template must treat the ideation fields as optional and skip the
      ideation row when they are `nil` rather than render a broken link.

  Command strings are intentionally NOT translated — they are literal shell/CLI
  input. The consuming template surfaces the human-facing `label` and `note`
  through gettext; this module stays translation-free.
  """

  alias KanbanWeb.OnboardingPlugins.Agent

  @agents [
    %Agent{
      key: "claude_code",
      label: "Claude Code",
      workflow_command:
        "/plugin marketplace add cheezy/stride-marketplace\n/plugin install stride@stride-marketplace",
      workflow_url: "https://github.com/cheezy/stride-marketplace",
      uses_marketplace: true,
      ideation_command:
        "/plugin marketplace add cheezy/stride-marketplace\n/plugin install stride-ideation@stride-marketplace",
      ideation_url: "https://github.com/cheezy/stride-ideation",
      note: "Installs through the Stride marketplace."
    },
    %Agent{
      key: "copilot",
      label: "Copilot",
      workflow_command: "copilot plugin install https://github.com/cheezy/stride-copilot",
      workflow_url: "https://github.com/cheezy/stride-copilot",
      uses_marketplace: false,
      ideation_command:
        "copilot plugin install https://github.com/cheezy/stride-copilot-ideation",
      ideation_url: "https://github.com/cheezy/stride-copilot-ideation",
      note: "Installs directly from the plugin repo."
    },
    %Agent{
      key: "gemini",
      label: "Gemini",
      workflow_command: "gemini extensions install https://github.com/cheezy/stride-gemini",
      workflow_url: "https://github.com/cheezy/stride-gemini",
      uses_marketplace: false,
      ideation_command:
        "gemini extensions install https://github.com/cheezy/stride-gemini-ideation",
      ideation_url: "https://github.com/cheezy/stride-gemini-ideation",
      note: "Installs as a Gemini CLI extension."
    },
    %Agent{
      key: "codex",
      label: "Codex",
      workflow_command:
        "curl -fsSL https://raw.githubusercontent.com/cheezy/stride-codex/main/install.sh | bash",
      workflow_url: "https://github.com/cheezy/stride-codex",
      uses_marketplace: false,
      ideation_command:
        "curl -fsSL https://raw.githubusercontent.com/cheezy/stride-codex-ideation/main/install.sh | bash",
      ideation_url: "https://github.com/cheezy/stride-codex-ideation",
      note: "Installs globally via the setup script."
    },
    %Agent{
      key: "opencode",
      label: "OpenCode",
      workflow_command: ~s(Add to opencode.json: {"plugin": ["github:cheezy/stride-opencode"]}),
      workflow_url: "https://github.com/cheezy/stride-opencode",
      uses_marketplace: false,
      ideation_command:
        "git clone https://github.com/cheezy/stride-opencode-ideation.git\n./stride-opencode-ideation/install.sh",
      ideation_url: "https://github.com/cheezy/stride-opencode-ideation",
      note: "Add the plugin entry to opencode.json."
    },
    %Agent{
      key: "pi",
      label: "Pi",
      workflow_command:
        "curl -fsSL https://raw.githubusercontent.com/cheezy/stride-pi/main/install.sh | bash",
      workflow_url: "https://github.com/cheezy/stride-pi",
      uses_marketplace: false,
      ideation_command: nil,
      ideation_url: nil,
      note: "Installs from its own repo (no marketplace). Pi has no separate ideation plugin yet."
    }
  ]

  @doc """
  Returns every supported agent in a stable display order:
  Claude Code, Copilot, Gemini, Codex, OpenCode, Pi.
  """
  @spec agents() :: [Agent.t()]
  def agents, do: @agents

  @doc """
  Looks an agent up by its stable string `key`.

  Returns the matching `t:KanbanWeb.OnboardingPlugins.Agent.t/0`, or `nil` when
  the key is unknown or not a string. Keys are strings (not atoms) so the picker
  can pass a `phx-value` straight through without `String.to_atom/1` on
  user-controlled input.
  """
  @spec get(term()) :: Agent.t() | nil
  def get(key) when is_binary(key), do: Enum.find(@agents, &(&1.key == key))
  def get(_key), do: nil
end
