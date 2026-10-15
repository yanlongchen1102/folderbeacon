# FolderBeacon

FolderBeacon is a context-aware folder navigator for macOS. It appears alongside compatible Open and Save dialogs so you can search for a folder and jump to it quickly.

## Features

- Search a local index of selected folders
- Favorites, recent folders, and open Finder windows
- Global keyboard shortcut
- English and Simplified Chinese interface
- Signed in-app updates through Sparkle in official builds

## Requirements

- macOS 14 or later
- Xcode capable of opening the project format
- Accessibility permission for detecting and navigating Open/Save dialogs
- Automation (Apple Events) permission for reading open Finder windows

Folder indexing and search happen locally.

## Build

1. Clone the repository.
2. Open `FolderBeacon-Mac.xcodeproj` in Xcode.
3. Select your own development team and bundle identifier if code signing is required.
4. Build and run the `FolderBeacon-Mac` scheme.

The only package dependency is [Sparkle](https://github.com/sparkle-project/Sparkle), pinned by `Package.resolved`.

Command-line builds can disable signing:

```sh
xcodebuild -project FolderBeacon-Mac.xcodeproj \
  -scheme FolderBeacon-Mac -configuration Debug \
  CODE_SIGNING_ALLOWED=NO build
```

## Analytics

Anonymous usage analytics are **off by default** and require explicit opt-in during onboarding or in General settings. Open-source builds also have no PostHog key, so they cannot submit analytics without an explicit build-time configuration.

Official builds can supply the public ingestion key without committing it:

```sh
xcodebuild ... FOLDERBEACON_POSTHOG_KEY='phc_...'
```

See [PRIVACY.md](PRIVACY.md) for the exact events and properties. Never put a PostHog personal API key in this setting.

## Contributing and security

See [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request. Please report vulnerabilities according to [SECURITY.md](SECURITY.md), not in a public issue.

Release maintainers can find the distribution process in [RELEASING.md](RELEASING.md).

## License

FolderBeacon is available under the [MIT License](LICENSE).
