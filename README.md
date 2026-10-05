# BlaziumLauncher

Desktop player for [Blazium Games](https://blazium.games). It installs and plays store games. It is not [BlaziumHub](https://github.com/blazium-games/blazium-hub), which installs editors.

## Install

Download the latest Windows setup from [Releases](https://github.com/blazium-games/games_launcher/releases). Windows 10 or 11, 64-bit. The program is `BlaziumLauncher.exe` at `{autopf}\Blazium\Games`. Shared tools (`blazium-cli`, `chauffeur`, `crash_reporter`) live in `{autopf}\Blazium`, next to `Engine` (BlaziumHub). A Linux package is not in the current release. macOS is not supported.

## Platform

- Docs: [docs.blazium.games](https://docs.blazium.games) and the map [llms.txt](https://docs.blazium.games/llms.txt)
- Skills: `npm install @blazium-games/skills`, or Cursor Settings > Plugins > `blazium-games/games_skill`. Index: [SKILL_TREE.md](https://github.com/blazium-games/games_skill/blob/master/SKILL_TREE.md)
- MCP: [developer server](https://docs.blazium.games/docs/mcp) at `https://mcp.blazium.games/mcp`, and [player server](https://docs.blazium.games/docs/mcp/player) at `https://mcp.blazium.games/player`
- CLI: `npm install -g @blazium-games/cli` (`chauffeur`), guide at [docs.blazium.games/docs/cli](https://docs.blazium.games/docs/cli)
- Launcher: BlaziumLauncher at `{autopf}\Blazium\Games` on Windows. Shared tools are in `{autopf}\Blazium`. Setup from [Releases](https://github.com/blazium-games/games_launcher/releases), guide at [desktop app](https://docs.blazium.games/docs/storefront/desktop-app)
- Support: [blazium-games/support](https://github.com/blazium-games/support/issues). Status: [status.blazium.games](https://status.blazium.games)

## This repo

Library, friends, and game chat on `irc.blazium.online`. It does not replace a BlaziumHub install. When `blazium-cli` is already installed, this installer leaves BlaziumHub's `blazium://` handler and `hub_remote.json` alone. Either installer can download the other into the same `{autopf}\Blazium` root.

| URI | Action |
|-----|--------|
| `blazium://install/<uuid>` | Open that game's install page |
| `blazium://game/<uuid>` | Open the game |
| `blazium://buy/<uuid>` | Open the store page. Does not install. |
| `blazium://hub` and `blazium://install?version=` | Hub and the editor. Not this app. |

Export templates are not in this repo. The installer is how you run it.

## License

Licensed under the MIT License — see [LICENSE](LICENSE).
