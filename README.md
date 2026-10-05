# Blazium Games launcher

Desktop player for [Blazium Games](https://blazium.games): library, friends, and game chat. It is not [Blazium Hub](https://github.com/blazium-games/blazium-hub). Hub installs editors. This app installs and plays store games.

Chat uses `irc.blazium.online` (port 6697). The website Chat tab uses the websocket on port 8000.

## Blazium Games

[Blazium Games](https://blazium.games) is the store, operated by Divine Games, Inc. A game on that store does not have to be made with the Blazium engine. Upload builds with [chauffeur](https://github.com/blazium-games/games_cli) (`npm install -g @blazium-games/cli`). Docs are at [docs.blazium.games](https://docs.blazium.games).

## Blazium Engine

[Blazium Engine](https://blazium.app) is a separate product. Its Hub, `blazium-cli`, and editor installs stay under `{autopf}\Blazium` and `/opt/blazium`. This launcher does not replace them.

## Community

- Store: [https://blazium.games/](https://blazium.games/)
- Docs: [docs.blazium.games](https://docs.blazium.games)
- Engine: [https://blazium.app/](https://blazium.app/)

## What it opens

| Scene | Role |
|-------|------|
| `scenes/boot.tscn` | Session and single-instance check |
| `scenes/main.tscn` | Library and installed games |
| `scenes/friends_window.tscn` | Friends |
| `scenes/chat_window.tscn` | Game chat |

## URI scheme

Consumer links go to this launcher on port **39220**. Editor links stay on Hub.

| URI | Action |
|-----|--------|
| `blazium://install/<uuid>` | Open that game's install page in the launcher |
| `blazium://game/<uuid>` | Open the game |
| `blazium://buy/<uuid>` | Open the store page. Does not install. |
| `blazium://friends`, `blazium://chat`, `blazium://library`, `blazium://wallet` | Open that window |
| `blazium://hub` and `blazium://install?version=` | Hub and the editor. Not this app. |

When `blazium-cli` is already installed, the OS handler and `hub_remote.json` stay pointed at Hub. This installer only writes `launcher_remote.json`. `/NOCLI` is the silent default and registers this launcher for `blazium://` only when the CLI is absent. `/INSTALLCLI` points the handler at `blazium-cli.exe handle-uri "%1"` using a binary copied from an existing Hub install or a packager-supplied directory.

### Launcher remote secret

CLI and this app share port **39220** and `launcher_remote.json`. A valid token is not rotated. Single-instance lock is port **39219**.

- Windows: `%APPDATA%\blazium\launcher_remote.json`
- Linux: `~/.config/blazium/launcher_remote.json`

Uninstall removes the launcher tree, that file, and a protocol command this installer created. It does not delete `hub_remote.json`, the `BLAZIUM` environment variable, or Hub's protocol command.

## Develop

Open this folder in the games host editor (the private `games_module` build). Run `scenes/boot.tscn`. Export templates are not in git. `templates/` and `export/` stay local.

## Packaging

- **Windows:** Inno Setup — [`packaging/windows/blazium-games.iss`](packaging/windows/blazium-games.iss). AppId `{B1A21E00-6A4E-4C3A-9F10-6A7E1A0C4D21}`. Root `{autopf}\Blazium Games`. Bundles `BlaziumGames.exe` and `chauffeur.exe`.
- **Linux:** nfpm — [`packaging/linux/nfpm.yaml`](packaging/linux/nfpm.yaml). Root `/opt/blazium-games`.

CI (`.github/workflows/cicd.yml`) exports with `template_release` binaries from a `templates-*` release of `blazium-games/games_module`. That checkout uses the `GAMES_MODULE_READ_TOKEN` secret. Signing and Spaces upload use the same secret names as Hub (`PRODUCTION_ENV`, `GPG_PRIVATE_KEY`, `ES_USERNAME`, `ES_PASSWORD`, `CREDENTIAL_ID`, `ES_TOTP_SECRET`, `DO_ACCESS_KEY`, `DO_SECRET_KEY`, `DO_SPACE_NAME`, `DO_SPACE_REGION`). A missing signing or Spaces secret still publishes the unsigned installer and names the missing secret. Templates and engine binaries are not committed.

## License

Licensed under the MIT License — see [LICENSE](LICENSE).
