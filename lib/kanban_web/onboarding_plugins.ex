defmodule KanbanWeb.OnboardingPlugins.Agent do
  @moduledoc """
  One agent's plugin-install metadata for the onboarding picker.

  See `KanbanWeb.OnboardingPlugins` for how the registry is assembled and why
  the ideation fields are optional (Pi has no ideation port).
  """

  @enforce_keys [:key, :label, :integration, :workflow_url, :uses_marketplace]
  defstruct [
    :key,
    :label,
    :integration,
    :workflow_url,
    :uses_marketplace,
    :ideation_command,
    :ideation_url,
    :note,
    workflow_steps: []
  ]

  @typedoc """
  One block of the workflow install: a translated title and the command to
  copy, taken from the install steps of `KanbanWeb.Integrations`.
  """
  @type step :: %{title: String.t(), command: String.t()}

  @type t :: %__MODULE__{
          key: String.t(),
          label: String.t(),
          integration: String.t(),
          workflow_steps: [step()],
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

  The picker renders this list, so the agent data lives in one tested place
  instead of being scattered through the confirmation LiveView template. It
  holds no runtime state and touches no database.

  Each `t:KanbanWeb.OnboardingPlugins.Agent.t/0` carries two install recipes: the
  **workflow** plugin (the task lifecycle — claim/hook/complete) and, where one
  exists, the **ideation** plugin (turning a fuzzy idea into a requirements doc).

  The workflow install is not written here. It is read from the install steps
  of the agent's runtime in `KanbanWeb.Integrations` (the `/integrations`
  pages), whose commands are checked against each plugin's README, so the
  onboarding page and those pages cannot disagree. `@install_blocks` picks
  which of a runtime's steps the picker shows, as a list of blocks; the steps
  in one block are joined into one command to copy. Where a runtime offers a
  choice, the picker shows one path:

    * **Claude Code, Copilot and Codex install through a marketplace**
      (`uses_marketplace`). Codex's marketplace install needs no extra step,
      unlike its setup script, which leaves the hook to register by hand.
    * **OpenCode takes two blocks**: the `opencode.json` plugin entry, then
      copying the skills, subagents and commands into the project.
    * **Gemini and Pi** install from their own repository.

  Facts the Integrations catalog does not hold stay here:

    * **Pi has no ideation port yet** — only five ideation ports exist
      (Claude Code, Copilot, Gemini, Codex, OpenCode). Pi's `ideation_command`
      and `ideation_url` are therefore `nil`, and its `note` says so. The
      consuming template must treat the ideation fields as optional and skip the
      ideation row when they are `nil` rather than render a broken link.

  Command strings are intentionally NOT translated — they are literal shell/CLI
  input. The step titles come translated from `KanbanWeb.Integrations`, which is
  why `agents/0` builds the list at call time. The consuming template surfaces
  the human-facing `label` and `note` through gettext.
  """

  alias KanbanWeb.Integrations
  alias KanbanWeb.OnboardingPlugins.Agent

  @agents [
    %Agent{
      key: "claude_code",
      label: "Claude Code",
      integration: "claude-code",
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
      integration: "github-copilot",
      workflow_url: "https://github.com/cheezy/stride-copilot-marketplace",
      uses_marketplace: true,
      ideation_command:
        "copilot plugin install https://github.com/cheezy/stride-copilot-ideation",
      ideation_url: "https://github.com/cheezy/stride-copilot-ideation",
      note: "Installs through the Stride marketplace for Copilot."
    },
    %Agent{
      key: "gemini",
      label: "Gemini",
      integration: "gemini-cli",
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
      integration: "codex",
      workflow_url: "https://github.com/cheezy/stride-codex-marketplace",
      uses_marketplace: true,
      ideation_command:
        "curl -fsSL https://raw.githubusercontent.com/cheezy/stride-codex-ideation/main/install.sh | bash",
      ideation_url: "https://github.com/cheezy/stride-codex-ideation",
      note: "Installs through the Stride marketplace for Codex."
    },
    %Agent{
      key: "opencode",
      label: "OpenCode",
      integration: "opencode",
      workflow_url: "https://github.com/cheezy/stride-opencode",
      uses_marketplace: false,
      ideation_command:
        "git clone https://github.com/cheezy/stride-opencode-ideation.git\n./stride-opencode-ideation/install.sh",
      ideation_url: "https://github.com/cheezy/stride-opencode-ideation",
      note: "Add the plugin entry to opencode.json, then copy the skills into the project."
    },
    %Agent{
      key: "pi",
      label: "Pi",
      integration: "pi",
      workflow_url: "https://github.com/cheezy/stride-pi",
      uses_marketplace: false,
      ideation_command: nil,
      ideation_url: nil,
      note: "Installs from its own repo (no marketplace). Pi has no separate ideation plugin yet."
    }
  ]

  # Which of each runtime's KanbanWeb.Integrations install steps the picker
  # shows, by position: one inner list per block, its steps joined into one
  # command. Codex's 3 and 4 are its marketplace add and install.
  @install_blocks %{
    "claude_code" => [[0]],
    "copilot" => [[0]],
    "gemini" => [[0]],
    "codex" => [[3, 4]],
    "opencode" => [[0], [1]],
    "pi" => [[0]]
  }

  @doc """
  Returns every supported agent in a stable display order:
  Claude Code, Copilot, Gemini, Codex, OpenCode, Pi.

  Each agent's `workflow_steps` are read from its runtime in
  `KanbanWeb.Integrations`, with titles in the current locale.
  """
  @spec agents() :: [Agent.t()]
  def agents, do: Enum.map(@agents, &with_workflow_steps/1)

  @doc """
  Looks an agent up by its stable string `key`.

  Returns the matching `t:KanbanWeb.OnboardingPlugins.Agent.t/0`, or `nil` when
  the key is unknown or not a string. Keys are strings (not atoms) so the picker
  can pass a `phx-value` straight through without `String.to_atom/1` on
  user-controlled input.
  """
  @spec get(term()) :: Agent.t() | nil
  def get(key) when is_binary(key) do
    case Enum.find(@agents, &(&1.key == key)) do
      nil -> nil
      agent -> with_workflow_steps(agent)
    end
  end

  def get(_key), do: nil

  defp with_workflow_steps(%Agent{key: key, integration: slug} = agent) do
    {:ok, runtime} = Integrations.fetch(slug)

    blocks = Map.fetch!(@install_blocks, key)
    %{agent | workflow_steps: Enum.map(blocks, &install_block(runtime.install, &1))}
  end

  # One block: the title of its first step and its steps' commands, one per line.
  defp install_block(install, positions) do
    [first | _] = picked = Enum.map(positions, &Enum.fetch!(install, &1))
    %{title: first.title, command: Enum.map_join(picked, "\n", & &1.command)}
  end
end
