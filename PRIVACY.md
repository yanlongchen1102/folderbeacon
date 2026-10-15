# Privacy

FolderBeacon indexes folder names and paths locally to provide search. It needs macOS Accessibility permission to detect and navigate compatible Open/Save dialogs, and Automation permission to read folders shown in Finder windows. This data is not sent by analytics.

## Optional analytics

Anonymous analytics are off by default. A user must enable **Send anonymous usage data** during onboarding or in Settings → General. Disabling it immediately stops future events. If an open-source build has no PostHog ingestion key, no events are sent even when the setting is enabled.

When enabled in an official build, FolderBeacon sends the following to PostHog's US endpoint:

- A random installation UUID stored in UserDefaults; it is not derived from hardware or an account
- One fixed event name: panel opened/closed, menu opened, search/settings/getting-started/updates selected, search used, folder selected, open in Finder, or copy path
- For relevant panel events, an allowlisted app category (`chrome`, `safari`, `firefox`, `edge`, `finder`, `xcode`, or `vscode`); every other app is reported as `other`
- A debug-build flag when applicable

FolderBeacon does **not** send folder names, file paths, search text, window titles, account details, hardware identifiers, or unknown application bundle identifiers. Person-profile processing and IP geolocation are disabled in the event payload.

Events are sent best-effort over HTTPS and are not queued to disk. PostHog may process network metadata as part of delivering the request; consult [PostHog's privacy information](https://posthog.com/privacy).

To reset the anonymous installation identifier, disable analytics and remove FolderBeacon's preferences. Merely disabling analytics retains the identifier locally so re-enabling does not create duplicate installations.

Questions can be opened as a GitHub issue. Security-sensitive concerns should follow [SECURITY.md](SECURITY.md).
