//
//  RemoveSidebarToggle.swift
//  Ice
//

import SwiftUI

extension View {
    /// Removes the sidebar toggle button from the toolbar.
    @ViewBuilder
    func removeSidebarToggle() -> some View {
        if #available(macOS 27.0, *) {
            // An empty toolbar item becomes a visible glass capsule on macOS 27.
            toolbar(removing: .sidebarToggle)
        } else {
            toolbar(removing: .sidebarToggle)
                .toolbar {
                    Color.clear
                }
        }
    }
}
