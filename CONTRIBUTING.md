# Contributing

Thanks for contributing to FolderBeacon.

1. Search existing issues before opening a new one.
2. Create a focused branch from the default branch.
3. Do not commit credentials, signing certificates, provisioning profiles, analytics keys, or generated build products.
4. Keep user-facing text localized in both `en.lproj` and `zh-Hans.lproj`.
5. Build the app with Xcode and manually test affected Open/Save-dialog behavior.
6. Open a pull request describing the change and how it was tested.

For command-line verification:

```sh
xcodebuild -project FolderBeacon-Mac.xcodeproj -scheme FolderBeacon-Mac \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

By contributing, you agree that your contribution is licensed under the repository's MIT License.
