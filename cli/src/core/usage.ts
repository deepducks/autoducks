// Preserved verbatim as the help/usage contract (design "Global CLI shape").
export const USAGE = `autoducks <command> [options]

Commands:
  install            Install (or update) .autoducks + .github files; runs setup on fresh install
  update             Alias for \`install\`
  setup              Run setup checks and launch the wizard
  wizard             Choose which autos to enable and pick recommended/custom settings
  config             Open the visual configuration editor (TUI)
  plugin <sub>       Manage plugins: list | install | uninstall | install-recommended
  version            Print the CLI version and the pinned autoducks version
  help [command]     Show help

Global options:
  --repo OWNER/REPO  Target repository (default: current git repo, via \`gh repo view\`)
  --version <tag>    Pin/select an autoducks release tag (install/update)
  --no-input         Non-interactive; fail instead of prompting (CI-friendly)
  --yes              Accept recommended defaults for any prompt
  -h, --help         Show help`;
