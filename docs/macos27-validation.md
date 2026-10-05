# macOS 27 visibility repair

## Cause and implementation

On macOS 27.0.1 (26A434), requesting a large `NSStatusItem` spacer did not
remove third-party icons from the MenuBarAgent-hosted menu bar. Accessibility
permission was granted; the earlier finite-spacer adaptation still failed.

The macOS 27 path now uses a runtime-checked MenuBarClientCore visibility
assertion with an application allowlist. The Objective-C bridge is adapted
from [teddychan/ice-2](https://github.com/teddychan/ice-2/tree/main/Ice/MenuBar/Native)
under GPL-3.0; upstream credits [fif7y/pelmet](https://github.com/fif7y/pelmet).
Earlier macOS versions retain the existing implementation.

Section membership is saved by bundle identifier in `NativeMenuBarSectionsV1`.
Initial migration reads the old Hidden and, when enabled, Always-Hidden dividers.
It requires two matching snapshots with hosted, rendered geometry on the main
display. Apps whose icons straddle a divider or lack reliable geometry remain
visible. Recognized new or unassigned apps are allowed;
unknown bundle identifiers may still be hidden by the system allowlist.
Recognized identifiers are retained for the session so an unrelated app exit
does not replace the assertion. Layout supports section menus, drag-and-drop,
search, and forgetting saved assignments for apps that are not running.

An active assertion is retained until its successor activates. Stale callbacks
are ignored; activation failures or a five-second timeout release assertions
and restore visibility. Ice, shared system hosts and supported system items
are excluded from hiding. Assertions are released on termination and sleep.

## Validation on 2026-10-06

- Xcode 27.0 (27A266a), macOS 27.0.1 (26A434): Release build succeeded.
- `./script/test_native_menu_bar.sh`: 84 checks passed, covering section policy,
  protected/unknown apps, stable allowlists, input guards, rehide timing,
  assertion replacement, stale callbacks, missing API, failures, restoration,
  and actual timeout expiry using an injected short deadline.
  Order checks cover physical ordering, partial snapshots, newly discovered
  apps, stale identities, and verification of contiguous multi-icon groups.
  Follow-up checks cover cancellation, elapsed-time limits, closed-app drops,
  and legacy section classification with invalid or missing divider geometry.
- `./script/test_build_and_run.sh`: five stubbed checks passed under `/bin/bash`,
  including empty signing arguments, Debug/Release signing, Run ordering,
  and stopping on a failed build. Release also built with the real script.
- Installed `/Applications/Ice.app`: confirmed native hiding, reveal by clicking
  Ice, Smart automatic rehide, and persisted sections after restart through
  the live application and MenuBarAgent accessibility trees.
- With icons hidden, sent SIGKILL to the verified installed Ice process:
  hidden third-party icons returned without restarting MenuBarAgent. Relaunched
  Ice and checked reveal and Smart rehide again.
- Layout visually checked: Visible/Hidden cards render without overlap.
- Developer ID signature verified deeply and strictly on the release product,
  installed app and app extracted from the ZIP. Hardened runtime is enabled;
  `get-task-allow` is absent. The ZIP is signed but not notarized.
- SwiftLint is not installed, so the strict lint gate was not run.
- Multi-display behavior, sleep/wake, timed/hover modes, and macOS 14–26 were
  not manually exercised during this repair. Long-held modifiers and dragging
  are covered by production-policy tests, not live gesture automation.

## Review fixes and idle work

Visibility requests no longer expire after one second of held input. Every
synchronization path uses the same input guard; deferred intent is retried on
mouse release. Reveal can proceed during a drag, modifiers alone do not block
hotkeys, and superseded pending assertions cannot override the latest request.
Unsupported native-path hotkeys are not registered. Sleep clears transition
state while preserving the requested visibility for wake.

Full accessibility discovery runs initially, on process changes and when Layout
opens, with a 30-second fallback while Layout is open. Window scanning in the
idle tick is limited to timed rehide when needed. Appearance geometry has a
two-second fallback plus event refreshes, and identical geometry is not
republished. Wallpaper capture falls back every 30 seconds; animated wallpaper
can therefore lag between refreshes.

Two short ten-sample `ps` observations averaged 3.77% CPU before and 0.0% at
the tool's displayed precision after the fixes. These are idle snapshots with
uncontrolled background activity, not an Energy Impact or battery benchmark.
Raw samples are in `build/distribution/review-cpu-{before,after}.json`.

## Distribution and limits

Build a signed release with:

```sh
ICE_BUILD_CONFIGURATION=Release \
ICE_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
./script/build_and_run.sh --build-only
```

The output is `build/native-derived/Build/Products/Release/Ice.app`.
Release signing keeps hardened runtime and disables debug entitlement injection.
Verify with `codesign --verify --deep --strict --all-architectures` and inspect
entitlements before distribution. Signing does not imply notarization.

This uses private macOS API and needs revalidation after OS updates. Visibility
is per application, shared across displays; individual icons from one app
cannot belong to different sections. Clock and Control Center remain under
macOS control. Some system indicators (including Focus) may disappear while
hiding is active. The old Ice Bar and per-icon search remain unavailable on this native path;
search opens the application layout instead.

## Appearance follow-up

The original appearance editor and configuration are restored on macOS 27.
The native overlay reads MenuBarAgent geometry, converts display coordinates
for its AppKit panel, and uses ScreenCaptureKit to capture only the wallpaper
strip needed by rounded and split shapes. Tint, gradient, shadow, border,
end caps and dynamic appearance retain the existing renderer. Reset removes
unused panels; system auto-hide, fullscreen and Command-drag suppress overlays.
A context-menu entry opens the appearance editor.

Live checks on the same machine confirmed the editor controls, saved Split
and Border settings after restart, an on-screen 3840-by-35 overlay, successful
wallpaper capture with the existing permission, and changing item geometry when
hiding/revealing apps. The automation interface captures MenuBarAgent separately
from Ice's overlay, so it does not provide a composited screenshot of the final
menu bar. Visual matching of wallpaper edges, external displays, fullscreen,
and dynamic light/dark transitions still needs manual acceptance.

## Ordering from Layout

Cards follow observed left-to-right menu bar order. Drop on the leading or
trailing half of another card to insert before or after it; a blue edge marks
the insertion side. The card menu also offers Move Left / Move Right. Moving
to a section background changes membership without imposing a physical slot.

The native mover uses bounded coordinate-based Command-drags, following
[pelmet's macOS 27 findings](https://github.com/fif7y/pelmet/blob/3f757c96a4a5bec2737ebb1fe3f2d3bd429afaf3/Packages/PelmetEngine/Sources/PelmetEngine/ItemMover.swift).
It reads fresh hosted AX geometry before each move and verifies the result,
including contiguity and internal order for apps with several icons. All source
and target icons must be available on the main display; ambiguous, overflowed
or missing geometry is refused. No MenuBarAgent preference file is rewritten
and the host is not restarted.

During an explicit move, visibility assertions are temporarily released and
automatic rehide is paused. A short input tap protects each drag; every exit
releases the mouse, restores modifier flags and cursor position, and removes
the tap. Esc (inside or outside Ice) and the Cancel button cancel the operation.
A 15-second budget stops further movement; AX reads check task cancellation
between requests, so an in-flight AX call can delay completion. The previous
requested visibility resumes afterward. Failed moves
report an error and refresh the actual layout rather than saving a fictitious
successful order. A partially completed multi-icon move may remain partial.

`NativeMenuBarObservedOrderV1` remembers observed order for unavailable apps;
it does not trigger background rearrangement. The system persists successful
physical moves. Closed apps must be launched before changing their position.
Dropping onto another section's card still updates membership when either app
is closed; it does not attempt a physical drag in that case.

Live checks on 2026-10-06 verified Amphetamine before and after Docker through
the card menu, fresh AX adjacency, restored hidden state, and observed order
after relaunch. Multi-icon moves, external displays and overflow recovery have
not been manually verified. Automated card-drag attempts did not produce a
drop, but the user subsequently confirmed that dragging cards works and changes
the real menu bar order in the installed build. SwiftLint remains unavailable.

## Second review follow-up

Legacy import retries up to five times after the initial read and removes its
temporary dividers after a five-second deadline. Missing, overflowed, inverted
or off-screen divider geometry cannot be saved as a successful import. Failure
leaves unassigned apps visible with an explanation in Layout. Existing legacy
preferred positions are preserved when removing temporary items. Explicit user
section edits stop the import and take precedence over it.

The installed signed build was checked by starting Move Right and immediately
pressing Esc: the cancellation message appeared, cards stayed usable, the
observed order was unchanged and hidden state resumed. Cancellation during an
active mouse-down, forced termination during a drag, fresh-profile migration,
and the 15-second deadline have not been exercised live. The latter two logic
paths are covered by standalone tests without changing the user's saved sections.
