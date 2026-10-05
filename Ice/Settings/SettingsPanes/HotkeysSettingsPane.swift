//
//  HotkeysSettingsPane.swift
//  Ice
//

import SwiftUI

struct HotkeysSettingsPane: View {
    @EnvironmentObject var appState: AppState

    private var hotkeySettingsManager: HotkeySettingsManager {
        appState.settingsManager.hotkeySettingsManager
    }

    var body: some View {
        IceForm {
            IceSection("Menu Bar Sections") {
                hotkeyRecorder(forSection: .hidden)
                hotkeyRecorder(forSection: .alwaysHidden)
            }
            IceSection("Menu Bar Items") {
                hotkeyRecorder(forAction: .searchMenuBarItems)
            }
            if #unavailable(macOS 27.0) {
                IceSection("Other") {
                    hotkeyRecorder(forAction: .enableIceBar)
                    hotkeyRecorder(forAction: .toggleApplicationMenus)
                    hotkeyRecorder(forAction: .showSectionDividers)
                }
            }
        }
    }

    @ViewBuilder
    private func hotkeyRecorder(forAction action: HotkeyAction) -> some View {
        if let hotkey = hotkeySettingsManager.hotkey(withAction: action) {
            HotkeyRecorder(hotkey: hotkey) {
                switch action {
                case .toggleHiddenSection:
                    Text("Toggle the hidden section")
                case .toggleAlwaysHiddenSection:
                    Text("Toggle the always-hidden section")
                case .searchMenuBarItems:
                    Text("Search menu bar items")
                case .enableIceBar:
                    Text("Enable the Ice Bar")
                case .showSectionDividers:
                    Text("Show section dividers")
                case .toggleApplicationMenus:
                    Text("Toggle application menus")
                }
            }
        }
    }

    private func isSectionEnabled(_ name: MenuBarSection.Name) -> Bool {
        if #available(macOS 27.0, *) {
            return name == .hidden || (name == .alwaysHidden && appState.settingsManager.advancedSettingsManager.enableAlwaysHiddenSection)
        }
        return appState.menuBarManager.section(withName: name)?.isEnabled == true
    }

    @ViewBuilder
    private func hotkeyRecorder(forSection name: MenuBarSection.Name) -> some View {
        if isSectionEnabled(name) {
            if case .hidden = name {
                hotkeyRecorder(forAction: .toggleHiddenSection)
            } else if case .alwaysHidden = name {
                hotkeyRecorder(forAction: .toggleAlwaysHiddenSection)
            }
        }
    }
}
