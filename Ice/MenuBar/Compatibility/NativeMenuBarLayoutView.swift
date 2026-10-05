//
//  NativeMenuBarLayoutView.swift
//  Ice
//

import SwiftUI

struct NativeMenuBarLayoutView: View {
    @ObservedObject var controller: NativeMenuBarController

    var body: some View {
        IceForm(alignment: .leading, spacing: 20) {
            Text("Arrange your menu bar items").font(.title2)
            Text("Hold Command and drag items in the menu bar. Place items to hide to the left of the │ divider; keep visible items and the Ice button to its right.")
            if let message = controller.message {
                Label(message, systemImage: "exclamationmark.triangle")
            }
            if controller.isLoading {
                ProgressView("Reading menu bar items…")
            } else {
                ForEach(MenuBarSection.Name.allCases, id: \.self) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(section.displayString) Section").font(.headline)
                        let items = controller.sectionItems(section)
                        if items.isEmpty {
                            Text("No items").foregroundStyle(.secondary)
                        } else {
                            ForEach(items) { item in
                                HStack {
                                    if let icon = NSRunningApplication(processIdentifier: item.ownerPID)?.icon {
                                        Image(nsImage: icon).resizable().scaledToFit().frame(width: 20, height: 20)
                                    }
                                    Text(item.title).lineLimit(1)
                                }
                            }
                        }
                    }
                }
            }
        }
        .onAppear { controller.beginEditing() }
        .onDisappear { controller.endEditing() }
    }
}
