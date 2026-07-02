# Privacy Policy

Last updated: July 1, 2026

TRAE FLOW is a macOS utility for monitoring AI coding sessions from the macOS
menu bar. This policy explains what information the app handles and how it is
used.

## Data Collection

TRAE FLOW does not sell personal information and does not use advertising
tracking.

The app is designed to process session information locally on your Mac. TRAE
FLOW does not send your coding session content to the developer.

TRAE FLOW may offer optional anonymous usage telemetry. The first-run
onboarding includes a preselected consent checkbox for helping improve TRAE
FLOW, and returning users may see a one-time Settings prompt. Telemetry is not
uploaded until consent is confirmed, and it can be disabled in Settings at any
time. When enabled, TRAE FLOW may send a small allowlist of product usage
events, such as app launches, Hook installation results, client type categories,
and coarse session lifecycle buckets, to help improve the app.

Anonymous telemetry does not include prompts, responses, code, diffs, terminal
output, project paths, file paths, repository names, usernames, hostnames, SSH
targets, IP addresses, raw hook payloads, diagnostic contents, secrets, tokens,
or API keys.

## Data Processed Locally

To provide its core features, TRAE FLOW may process information on your Mac
such as:

- AI coding session status, events, prompts, responses, approvals, questions,
  errors, and completion notifications.
- Project, terminal, tmux, IDE, SSH, and session identifiers used to show the
  right session and jump back to the right workspace.
- Configuration files for supported local tools, including TRAE, TRAE CN,
  TRAE WORK, and TRAE WORK CN.
- User-configured custom areas (local HTML directories or remote URLs loaded in
  the Flow Island left panel), music playback status from system media, and
  temporary file shelf data managed through AirDrop.
- User preferences such as display mode, sounds, shortcuts, mascot settings,
  feature panel settings, and integration settings.

This information is used to display session state, install or update local
integrations you enable, route notifications, and return focus to related
terminal or IDE windows.

## Permissions

TRAE FLOW may request macOS permissions needed for its features, including:

- File access to user-selected folders or tool configuration locations.
- Apple Events or Accessibility access for window focus and terminal jump-back
  behavior.
- Local network permissions for hook and bridge communication between supported
  tools and the app.

You can manage these permissions in macOS System Settings.

## Diagnostics

TRAE FLOW may let you export diagnostics for troubleshooting. Diagnostic
exports are user-initiated, saved to a location you choose, and are intended to
redact secrets where possible. Review diagnostic files before sharing them in a
GitHub issue or support request.

## Third-Party Services

TRAE FLOW can work with third-party developer tools and services that you
install or configure separately. Those tools, remote hosts, Apple services,
GitHub, and any AI providers you use have their own privacy practices. This
policy only covers TRAE FLOW itself.

If optional anonymous telemetry is enabled, TRAE FLOW may use Alibaba Cloud
Simple Log Service to store product usage events. See
`docs/telemetry.md` for the current event and field allowlist.

## Contact

For privacy questions or support, open an issue at:

https://github.com/ccsonicc333/trae-flow/issues
