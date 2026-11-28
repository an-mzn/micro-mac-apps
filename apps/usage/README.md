# Usage

Usage is a native macOS menu bar app and widget for tracking remaining Codex and Claude Code allowance across accounts. It shows the last successful reading for each profile.

[MIT licence](LICENSE) · [Build from source](#build-from-source) · [Contributing](#contributing)

## Install and connect

Build **Usage.app** using the instructions below, then open it from `dist/` or move it to Applications. Look for the refresh icon in the menu bar. The app runs without a Dock icon. The local build uses your Apple Development certificate and is unnotarized. The package targets macOS 14 or later.

1. Open **Settings → Accounts** and choose **Add Codex Account…**. Enter a label such as Personal.
2. Choose **Open Verification Page**, sign in to the intended ChatGPT account or workspace, and enter the one-time code shown in the app. If your browser already has another account open, use the account chooser or a separate browser profile. The app reads the account context from Codex before adding the profile.
3. Repeat with a different label for the second account or workspace. Device code authorization must be enabled for the account and allowed by its workspace. If necessary, enable it in ChatGPT security settings.

The app checks for the CLI bundled in ChatGPT, then checks absolute PATH entries, Homebrew, and common user install locations. Choose a different executable in **Settings…**. The minimum verified CLI is **codex-cli 0.171.0-alpha.13.2** (bundled with ChatGPT on the test Mac). Other builds need the documented stdio handshake with `codexHome`, account reads, and ChatGPT device-code login. Older builds were not tested. [Codex App Server documentation](https://developers.openai.com/codex/app-server)

The **Codex executable** setting is the path to the Codex command-line program (`codex`) that the app launches in the background to sign in and read allowance. Automatic discovery is the recommended setting. Choose a binary only if the app cannot find your Codex installation or you want to use another supported version.

## Connect Claude Code

Usage can show Claude Code’s 5-hour and weekly subscription limits alongside
Codex accounts. Claude supplies these readings through its
[status line](https://code.claude.com/docs/en/statusline) after a response.
Usage reads the latest saved snapshot locally, so limits can remain stale
until Claude Code reports new figures.

Install `jq` (for example, `brew install jq`). In the Claude Code settings for
the account or configuration you want to track, set the status line command.
Use absolute paths:

```json
{
  "statusLine": {
    "type": "command",
    "command": "/bin/bash '/absolute/path/to/scripts/claude-statusline.sh' '/absolute/path/to/claude-personal.json'"
  }
}
```

If you already use a custom status line, call this helper from it with the same
JSON input and discard the helper’s output. After Claude reports limits, open
**Usage → Settings → Accounts → Add Claude Account…**, give it a label, and
select the generated JSON. Use a separate Claude Code configuration and
snapshot path for each account. The snapshot contains only the reported
percentages and reset timestamps. **Refresh All** rereads the file, and removing
the account from Usage leaves your Claude Code settings and file in place.

## Refresh and settings

Cached readings appear immediately in the menu and widget. Background refresh defaults to 15 minutes. Settings offers intervals from 5 to 120 minutes. An expired reset can make a profile eligible sooner, and opening the menu checks for due readings. Reset times never change the displayed percentage without a successful read. The scheduler uses a single one-shot timer with tolerance, backs off failed requests, adds a delay after wake, and pauses automatic reads in Low Power Mode. Refresh runs with at most two active operations and at most one operation per profile. The small widget shows the first account. The medium and large widgets show up to three accounts. Widgets use cached readings and refresh when displayed data changes.

Use **Refresh All** for an immediate shared refresh from the menu or Settings. The menu row shows the last-refreshed time. When an automatic refresh is due, the app refreshes eligible accounts together. Account labels can be renamed from **Settings → Accounts** or the account submenu; each account’s email and workspace context are available from its **Details…** action. Individual failures leave the other accounts usable, and the menu labels cached readings as stale. If a read requires sign-in, use **Reauthenticate…** from account actions. **Settings…** can show a single window or the 5-hour and weekly windows together when Codex returns both for the same bucket. **Most allowance available** shows the account with the highest remaining percentage, comparing each account’s 5-hour reading or its weekly reading if the 5-hour window is absent. An asterisk marks a stale reading. Launch at login is off by default and uses macOS Login Items.

## Profile storage and removal

Codex stores each profile’s authentication inside its own private `CODEX_HOME` at `~/Library/Application Support/Codex Usage/Profiles/<UUID>/`. The app explicitly sets that home for every App Server process, uses Codex’s file credential store, and excludes inherited credential environment variables. The Codex process may also initialize its own runtime state and diagnostics in that home. The tracker’s `settings.json` stores labels, documented account context, preferences, and the latest successful allowance for each profile. It never stores credentials in that file. The app sends no prompts or transcript requests and uses the documented Account API.

**Remove…** in a profile submenu asks for confirmation, cancels and reaps any active refresh, then removes the validated profile directory and its cached reading. To uninstall, turn off launch at login if enabled, quit the menu bar app, and move it to the Trash. Delete `~/Library/Application Support/Codex Usage` if you also want to discard all tracker profiles and cached readings.

## Build from source

Install Xcode and XcodeGen (`brew install xcodegen`). In **Xcode → Settings → Accounts**, sign in with your Apple Account, select your team, then use **Manage Certificates** to create an **Apple Development** certificate. A free Personal Team is sufficient for a local build.

Clone the repository and build Usage:

```sh
git clone https://github.com/an-mzn/micro-mac-apps.git
cd micro-mac-apps/apps/usage
security find-identity -v -p codesigning
USAGE_SIGNING_IDENTITY='<SHA-1 shown next to your Apple Development certificate>' ./build.sh
open dist/Usage.app
```

The script writes the signed app and its WidgetKit extension to `dist/Usage.app`. Pass an output directory as the first argument to build elsewhere. It reads the certificate’s team ID and configures the same team-prefixed macOS app group in the app and widget. No source edits are needed. Profile authentication stays under `~/Library/Application Support/Codex Usage/Profiles/<UUID>/`; the shared group holds cached settings and allowance data.

Eight Release tests passed. The fixtures cover concurrent profiles with the same email, nullable and differing windows, automatic 5-hour and weekly comparison, independent failures, unchanged cache writes, stale eligibility, a single Codex-managed token refresh on an authentication error, malformed output, process exit, timeout, cancellation, removal, path validation, and per-process environment isolation. The fixture CLI requires Python 3 from the installed Xcode command-line tools. Neither the runtime app nor its packaging needs Python.

The packaged Release build was exercised in the actual macOS menu bar. The three-profile fixture displayed account context, reset times, low allowance, loading, offline, timeout, stale data, and an independently successful account. Removing a profile while its refresh was blocked reaped its child and left the other two profiles in the menu. The installed CLI also returned a genuine device challenge from a clean tracker home and accepted cancellation. The packaged app displayed that challenge and reaped the child after the menu’s Cancel Sign-In action.

Two-account authentication still needs an interactive check. Connect both accounts, compare each menu reading with that account’s own Codex usage view, then reauthenticate and remove one tracker profile while checking that the other tracker profile and the regular ChatGPT Desktop login still work. Login Items registration and older macOS releases were not exercised.

## Release performance

Apple M5 Pro, arm64, 64 GB RAM, macOS 27.2.1. CPU and RSS were sampled with `ps`, kernel wakeup and disk-write counters were read with `proc_pid_rusage`, and the process tree and combined RSS were sampled every 100 ms. Combined RSS can count shared pages more than once.

| Scenario | Observation |
| --- | --- |
| Idle, no profiles, menu closed | 0.0% sampled CPU, 72.2 MiB RSS and 16.2 MiB physical footprint at the end of the sample, zero children |
| Idle, three cached profiles, menu closed | 0.0% sampled CPU, 74.7 MiB RSS and 16.9 MiB physical footprint at the end of the sample, zero children |
| Three-profile fixture refresh | 7.94 s of observed child activity, two children maximum, 119 MiB peak combined RSS, zero children afterward. The fixture deliberately held each child for four seconds. |
| Fixture timeout | 25.12 s of observed child activity, zero children afterward |
| Removal during a blocked refresh | One child before confirmation, zero afterward |
| Idle scheduling and writes | Over the 10-second cached sample, 0 package-idle wakeups, 8 interrupt wakeups, 0 kernel-reported disk-write bytes, and no child. Opening the fresh cached menu left settings untouched until the manual refresh. |

The steady-state observations are short samples. The timer, backoff, and request rules account for expected behavior over a full day. The fixture makes no network requests. The app had no connection row in the idle `nettop` sample. Authenticated refresh latency, child memory and network traffic, and long-run sleep and Low Power Mode behavior remain unmeasured.


## Contributing

Open an issue or submit a pull request against `main`. For bug reports, include the macOS version, the account provider, and steps to reproduce. Remove account identifiers, credentials, and sign-in codes from screenshots and logs before posting.

From `apps/usage`, run `swift test` for the core tests. The project uses XcodeGen. Edit `project.yml` for project configuration changes and regenerate the Xcode project with `xcodegen generate`.

## Licence

Usage’s original source code and documentation are available under the [MIT licence](LICENSE). See [third-party asset notices](NOTICE.md) for the bundled provider logos. Other apps in this repository have their own licensing terms.
