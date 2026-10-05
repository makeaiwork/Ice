//
//  HotkeyAction.swift
//  Ice
//

enum HotkeyAction: String, Codable, CaseIterable {
    // Menu Bar Sections
    case toggleHiddenSection = "ToggleHiddenSection"
    case toggleAlwaysHiddenSection = "ToggleAlwaysHiddenSection"

    // Menu Bar Items
    case searchMenuBarItems = "SearchMenuBarItems"

    // Other
    case enableIceBar = "EnableIceBar"
    case showSectionDividers = "ShowSectionDividers"
    case toggleApplicationMenus = "ToggleApplicationMenus"

    @MainActor
    func perform(appState: AppState) async {
        if #available(macOS 27.0, *) {
            switch self {
            case .toggleHiddenSection: appState.nativeMenuBar.toggle()
            case .toggleAlwaysHiddenSection: appState.nativeMenuBar.toggle(alwaysHidden: true)
            case .searchMenuBarItems:
                appState.navigationState.settingsNavigationIdentifier = .menuBarLayout
                appState.appDelegate?.openSettingsWindow()
            case .showSectionDividers:
                appState.settingsManager.advancedSettingsManager.showSectionDividers.toggle()
            default: break
            }
            return
        }
        switch self {
        case .toggleHiddenSection:
            guard let section = appState.menuBarManager.section(withName: .hidden) else {
                return
            }
            section.toggle()
            // Prevent the section from automatically rehiding after mouse movement.
            if !section.isHidden {
                appState.preventShowOnHover()
            }
        case .toggleAlwaysHiddenSection:
            guard let section = appState.menuBarManager.section(withName: .alwaysHidden) else {
                return
            }
            section.toggle()
            // Prevent the section from automatically rehiding after mouse movement.
            if !section.isHidden {
                appState.preventShowOnHover()
            }
        case .searchMenuBarItems:
            await appState.menuBarManager.searchPanel.toggle()
        case .enableIceBar:
            appState.settingsManager.generalSettingsManager.useIceBar.toggle()
        case .showSectionDividers:
            appState.settingsManager.advancedSettingsManager.showSectionDividers.toggle()
        case .toggleApplicationMenus:
            appState.menuBarManager.toggleApplicationMenus()
        }
    }
}
