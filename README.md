# ProjectAtlas Desktop

Source code of **ProjectAtlas Desktop** — a Windows companion app for
[ProjectAtlas](https://github.com/styler-ai/ProjectAtlas), the local code map
(SQLite) for AI coding agents. Atlas indexes folders, files, and symbols so
agents read exactly the right places instead of searching broadly, saving a
lot of tokens and time.

The desktop app shows how many tokens ProjectAtlas has saved in your local
projects — what, when, where, and by what means — and connects projects to
the AI tools Claude Code, Codex, and OpenCode at the click of a button.

## Credits

This repository is a fork of
[styler-ai/ProjectAtlas](https://github.com/styler-ai/ProjectAtlas). All props
for ProjectAtlas itself go to the original creator — the desktop app in
`crates/projectatlas-desktop` is the main addition here.

This is my second project, so please be lenient :) Contributions and feedback
are welcome.

## Downloads

Finished installers and update manifests live in
[projectatlas-desktop-releases](https://github.com/einzigTimo/projectatlas-desktop-releases).

## Building the desktop app

Prerequisites: Rust toolchain (see `rust-toolchain.toml`), `cargo tauri`
(Tauri CLI), Windows.

A local build without publishing:

```powershell
pwsh ./.github/scripts/invoke-desktop-release.ps1 -Version <version> -AllowUnsigned
```

See the script header in
[`.github/scripts/invoke-desktop-release.ps1`](.github/scripts/invoke-desktop-release.ps1)
for the full release flow.

## Repository layout

- `crates/projectatlas-desktop` — the Tauri desktop app (this fork's addition)
- `crates/*` — ProjectAtlas CLI, core, database, and services (upstream)
- `docs/`, `openspec/` — documentation and specs (upstream)

## License

MIT — see [LICENSE](LICENSE). Original work © Shaun Tyler
(styler-ai/ProjectAtlas).
