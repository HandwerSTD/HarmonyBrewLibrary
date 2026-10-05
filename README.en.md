# BrewLibrary

<p align="center"><img src="docs/icon/icon_1024.png" width="120" alt="BrewLibrary"></p>

BrewLibrary is a **HarmonyOS PC (2in1)** app for browsing Homebrew packages: it presents Homebrew formulae and casks in a desktop layout, with chart-based discovery, offline search, package details and local install status.

- Device type: 2in1 (PC) only, minimum window 1080 × 608
- Compile target: HarmonyOS 6.1.0 (API 23), hvigor model 5.0.0
- Version: 1.1.0
- Stack: ArkTS / ArkUI (Stage model), two entry modules: `products/pc_acl` (full build, requests `CUSTOM_SANDBOX` and `READ_WRITE_USER_FILE`) and `products/pc_normal` (no restricted permissions)

> 中文说明见 [README.md](README.md)。

## Features

| Tab | Description |
| --- | --- |
| **Discover** | Six recommendation boards. Board members and figures are computed on device; the page shows an empty state when the catalog is unavailable |
| **Formulae** | Formulae catalog: category chips, list and detail page |
| **Casks** | Casks catalog, sharing components and the detail page with formulae |
| **Search** | On-device search engine (dependency-free pure functions + lexicon scoring), works offline |
| **Me** | Locally installed / outdated packages, data-source switching with connectivity status, optional section toggles |

> The two entry builds differ only in the local-package section: `pc_acl` shows the three local-package blocks on the **Me** page and reads the Homebrew install records on the device; `pc_normal` requests neither `CUSTOM_SANDBOX` nor `READ_WRITE_USER_FILE`, its `PcAbility` injects `StorageKey.BREW_CLI_ENABLED = false` into `AppStorage`, so the **Me** page shows an "Enable local package management" card instead (tapping it hands `https://gitcode.com/handwer/HarmonyBrewLibrary` to the system browser) and local-package queries return an empty set silently. Every other tab behaves the same in both builds.

## Data sources

| Source | Usage |
| --- | --- |
| `formulae.brew.sh/api` (upstream) | Live package details, per-token index |
| `harmonybrew.atomgit.com` (Harmonybrew mirror) | Normalized full catalog + stats snapshot |
| The on-device `brew` command (`features/pcnative` + `BrewInstalledLoader`) | Installed / outdated packages on the **Me** page (available in `pc_acl` only) |

The two dialects are abstracted by `features/brewcommon/src/main/ets/service/source/BrewSourceAdapter.ets` (`UpstreamAdapter` / `HarmonybrewAdapter`); the source URL and probe result can be inspected and switched on the **Me** page. The taxonomy and board algorithms are project-specific, not official API fields — see `docs/brew-marketplace-content-plan.md` and `docs/brew-discover-algo.md`.

## Project layout

```
AppScope/                 App-level resources (layered icon, app name, permission strings)
common/                   Shared UI primitives and utils (@ohos/common)
features/
  pcui/                   Home shell: side bar + HdsTabs + page containers
  commonbusiness/         Shared business capabilities (enums, state, components)
  brewcommon/             Data layer: HTTP, source adapters, catalog sync, search engine, models
  brewdiscover/           Discover page
  brewformulae/           Formulae page
  brewcasks/              Casks page
  brewdetail/             Package detail page (shared by formula / cask)
  brewsearch/             Search page
  mine/                   Me page
products/pc_acl/          entry module (full build): PcAbility, splash, main page
products/pc_normal/       entry module (no restricted permissions): PcAbility, splash, main page
docs/                     Design docs and handover notes
hmosword-build/
  brew-mockgen/           Curated-list and board-algorithm checks (Python)
  brew-search/            Executable check for the search engine (Node)
keys/                     Local signing material (git-ignored, not in the repo)
```

## Requirements

- DevEco Studio 6.x (HarmonyOS 6.1.0 / API 23 SDK)
- A 2in1 (PC) device or the DevEco previewer
- Node 24+: only for the search engine check script
- Python 3: only for validating the curated list / board algorithm invariants

## Build and run

```bash
devecocli build --product default    # produces pc_acl (full build HAP)
devecocli build --product pc_normal  # produces pc_normal (no restricted permissions HAP)
devecocli build --modules pc_acl     # entry module pc_acl only
devecocli run --module pc_normal     # build + install + launch (device required; --module is required with two entry modules)
```

The root `build-profile.json5` defines two products: `default` maps to module `pc_acl`, `pc_normal` maps to module `pc_normal`.

`devecocli` is the DevEco CLI (it wraps hvigor / ohpm / hdc). Opening the project in DevEco Studio and pressing Run works as well; the repo does not ship an `hvigorw` wrapper script.

> **Signing**: product `default` uses the `default` and `release` signing configs; product `pc_normal` uses the `normal_debug` and `normal_release` signing configs, where `normal_debug` points to profile `keys/brewdebugDebug.p7b` and `normal_release` to profile `keys/brewreleaseRelease.p7b`. The certificate and keystore of all four configs live under `./keys/` as `.cer` / `.p12` files. `keys/` holds local signing material and is **not** committed (it is git-ignored), so after cloning you must either use DevEco Studio's automatic signing or supply your own certificates and update those configs — otherwise no signed HAP can be produced.

## Development checks

```bash
# Validate the curated token list (tokens.json: structure + still upstream?)
python3 hmosword-build/brew-mockgen/generate.py            # zero requests when .brewgen/cache hits
python3 hmosword-build/brew-mockgen/generate.py --refresh  # ignore cache, re-fetch
python3 hmosword-build/brew-mockgen/generate.py --local    # structure only, no network

python3 hmosword-build/brew-mockgen/check_algo.py --fetch --data .brewgen/analytics   # board algorithm invariants

node hmosword-build/brew-search/check_engine.mjs           # executable check for the search engine
devecocli check lint                                       # ArkTS lint
```

hypium-based unit tests live in `features/*/src/ohosTest/` and require a connected device.
The app ships **no** bundled brew data snapshot (removed 2026-10): all data comes from the on-device catalog (aggregation endpoints) and live single-package requests, so there is no "regenerate the data" step in this repo. The authoritative implementation of the board algorithm is `hmosword-build/brew-mockgen/check_algo.py` plus `docs/brew-discover-algo.md`; when you change the normalization rules in `BrewApiMapper.ets`, only the taxonomy has to stay in sync — with `classify()` in `generate.py` and `BrewTaxonomy.ets` on the device.

## Documentation

All design docs are written in Chinese.

| Document | Content |
| --- | --- |
| [docs/brew-api-design.md](docs/brew-api-design.md) | Data layer design: sources, normalization, caching, error taxonomy |
| [docs/brew-discover-algo.md](docs/brew-discover-algo.md) | Discover board algorithms (authoritative) |
| [docs/brew-catalog-fullsync-spec.md](docs/brew-catalog-fullsync-spec.md) | Full catalog sync specification |
| [docs/brew-marketplace-content-plan.md](docs/brew-marketplace-content-plan.md) | Content and taxonomy planning |
| [docs/hds-titlebar-blur.md](docs/hds-titlebar-blur.md) | Title bar blur behavior |
| [docs/brew-handover.md](docs/brew-handover.md) | Handover: environment, commands, scripts, caveats |

## License

Apache License 2.0, see [LICENSE](LICENSE); open source compliance statement in [OAT.xml](OAT.xml).
