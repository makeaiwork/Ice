# Repository Guidelines

## Project Structure & Module Organization

Ice is a macOS 14+ menu bar manager written in Swift using SwiftUI and AppKit. `Ice.xcodeproj` contains the application target and shared `Ice` scheme; Swift package dependencies are pinned in its workspace’s `Package.resolved`.

- `Ice/Main/`: app entry point, shared state, and navigation.
- `Ice/MenuBar/`: item management, sections, appearance, search, and spacing.
- `Ice/Settings/`: settings panes and persistence managers.
- `Ice/UI/`: reusable views, controls, and the Ice Bar.
- `Ice/Events/`, `Hotkeys/`, `Permissions/`, and `Utilities/`: supporting behavior.
- `Ice/Assets.xcassets/` and `Ice/Resources/`: bundled assets; root `Resources/` holds design and demonstration files.

## Build, Test, and Development Commands

Use a recent Xcode compatible with the project, which was last upgraded with Xcode 16.4. The target uses Swift 5 language mode.

- `open Ice.xcodeproj`: open Xcode; select the `Ice` scheme and run with Command-R. Configure your local development signing team if needed.
- `xcodebuild -resolvePackageDependencies -project Ice.xcodeproj -scheme Ice`: resolve package dependencies.
- `xcodebuild -project Ice.xcodeproj -scheme Ice -configuration Debug -derivedDataPath build CODE_SIGNING_ALLOWED=NO build`: compile without signing for a local build check.
- `swiftlint lint --strict`: run the lint gate used by CI. Install SwiftLint separately; Xcode’s build phase warns if it is missing.

## Coding Style & Naming Conventions

Follow `.swiftlint.yml`: four-space indentation, no tabs, trailing commas in multiline collections, and the existing filename/`Ice` comment header. Use `UpperCamelCase` for types and `lowerCamelCase` for members. Match filenames to their principal type, such as `MenuBarItemManager.swift`. Follow nearby `// MARK:` organization and keep UI state isolation consistent with existing `@MainActor` managers.

## Testing Guidelines

This checkout has no automated test target, test framework, or coverage threshold. Validate changes with a build, strict lint, and focused manual checks. For affected features, exercise hiding/rehiding, item arrangement, hotkeys, appearance, and settings persistence after relaunch. Check Accessibility permission and Screen Recording permission where applicable. Record macOS version, reproduction steps, and results in the PR.

## Commit & Pull Request Guidelines

History favors short imperative subjects, such as `Fix possible retain cycle` or `Rework menus and pickers`; follow that style. Keep commits focused. PRs should explain the behavior change, link related issues, describe validation, and include screenshots or recordings for UI changes. Follow `CODE_OF_CONDUCT.md` and exclude personal signing changes, build products, and Xcode user data.
