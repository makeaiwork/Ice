//
//  NativeMenuBarLayoutView.swift
//  Ice
//

import SwiftUI
import UniformTypeIdentifiers

struct NativeMenuBarLayoutView: View {
    @ObservedObject var controller: NativeMenuBarController
    @State private var search = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Arrange your menu bar apps").font(.title2)
                Text("Cards follow the menu bar from left to right. Drop on the left or right half of a card to place an app before or after it. All icons from one app move together. Icons briefly appear while Ice arranges them.")
                HStack {
                    Button(controller.isHidden ? "Show Hidden" : "Hide Hidden") { controller.toggle() }
                    Button("Show All") { controller.setHidden(false, alwaysHidden: true) }
                }
                if controller.isReordering {
                    HStack {
                        ProgressView("Arranging menu bar icons…")
                        Button("Cancel (Esc)") { controller.cancelReorder() }
                            .keyboardShortcut(.cancelAction)
                    }
                }
                if let message = controller.orderingMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                }
                TextField("Find an app", text: $search).textFieldStyle(.roundedBorder)
                if let message = controller.migrationMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                }
                if let message = controller.message {
                    Label(message, systemImage: "exclamationmark.triangle")
                }
                if controller.isLoading {
                    ProgressView("Reading menu bar apps…")
                } else {
                    ForEach(NativeMenuBarSection.allCases, id: \.self) { section in
                        sectionView(section)
                    }
                }
                Text("Clock, Control Center and shared system controls stay managed by macOS. Unrecognized app icons and some system indicators, including Focus, may also disappear while hiding is active. Show All restores them.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { controller.refreshApplications() }
    }

    private func sectionView(_ section: NativeMenuBarSection) -> some View {
        let applications = controller.sectionItems(section).filter {
            search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)
        }
        return VStack(alignment: .leading, spacing: 8) {
            Text("\(section.title) · \(applications.count)").font(.headline)
            if applications.isEmpty {
                Text("Drop apps here").foregroundStyle(.secondary).padding(.vertical, 8)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 155), alignment: .leading)], alignment: .leading, spacing: 8) {
                    ForEach(applications) { application in
                        NativeMenuBarApplicationCard(controller: controller, application: application, section: section)
                            .disabled(controller.isReordering)
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
        .padding(12)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
        .dropDestination(for: String.self) { ids, _ in
            guard !controller.isReordering else { return false }
            let matches = controller.applications.filter { ids.contains($0.id) }
            for application in matches { controller.move(application, to: section) }
            return !matches.isEmpty
        }
    }
}

private struct NativeMenuBarApplicationCard: View {
    @ObservedObject var controller: NativeMenuBarController
    let application: NativeMenuBarApplication
    let section: NativeMenuBarSection
    @State private var width: CGFloat = 155
    @State private var insertionBefore: Bool?

    var body: some View {
        HStack(spacing: 6) {
            if let icon = NSRunningApplication(processIdentifier: application.ownerPID)?.icon {
                Image(nsImage: icon).resizable().scaledToFit().frame(width: 20, height: 20)
            }
            Text(application.title).lineLimit(1)
            Spacer(minLength: 0)
            Menu {
                ForEach(NativeMenuBarSection.allCases, id: \.self) { destination in
                    Button("Move to \(destination.title)") { controller.move(application, to: destination) }
                        .disabled(destination == section)
                }
                Divider()
                Button("Move Left") { moveBy(-1) }.disabled(neighbor(-1) == nil || !controller.isRunning(application))
                Button("Move Right") { moveBy(1) }.disabled(neighbor(1) == nil || !controller.isRunning(application))
                if !controller.isRunning(application) {
                    Divider()
                    Button("Forget saved assignment") { controller.forget(application) }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        .background(GeometryReader { geometry in
            Color.clear.onAppear { width = geometry.size.width }
                .onChange(of: geometry.size.width) { _, value in width = value }
        })
        .overlay(alignment: insertionBefore == false ? .trailing : .leading) {
            if insertionBefore != nil { RoundedRectangle(cornerRadius: 2).fill(Color.accentColor).frame(width: 3) }
        }
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onDrag { NSItemProvider(object: application.id as NSString) }
        .onDrop(of: [UTType.text], delegate: NativeMenuBarCardDrop(
            controller: controller, target: application, section: section,
            width: width, insertionBefore: $insertionBefore
        ))
        .help(controller.isRunning(application) ? "Drop on the left or right half to change the menu bar order." : "Open this app to change its menu bar position.")
    }

    private func neighbor(_ offset: Int) -> NativeMenuBarApplication? {
        let apps = controller.sectionItems(section).filter { controller.isRunning($0) }
        guard let index = apps.firstIndex(where: { $0.id == application.id }), apps.indices.contains(index + offset) else { return nil }
        return apps[index + offset]
    }

    private func moveBy(_ offset: Int) {
        guard let target = neighbor(offset) else { return }
        controller.reorder(application.id, relativeTo: target, before: offset < 0, section: section)
    }
}

private struct NativeMenuBarCardDrop: DropDelegate {
    let controller: NativeMenuBarController
    let target: NativeMenuBarApplication
    let section: NativeMenuBarSection
    let width: CGFloat
    @Binding var insertionBefore: Bool?

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [UTType.text]) }

    func dropEntered(info: DropInfo) { insertionBefore = info.location.x < width / 2 }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        insertionBefore = info.location.x < width / 2
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) { insertionBefore = nil }

    func performDrop(info: DropInfo) -> Bool {
        insertionBefore = nil
        let providers = info.itemProviders(for: [UTType.text])
        guard providers.count == 1, let provider = providers.first else { return false }
        let before = info.location.x < width / 2
        _ = provider.loadObject(ofClass: NSString.self) { value, _ in
            guard let id = value as? String else { return }
            Task { @MainActor in
                guard id != target.id, !controller.isReordering,
                      controller.applications.contains(where: { $0.id == id }) else { return }
                controller.reorder(id, relativeTo: target, before: before, section: section)
            }
        }
        return true
    }
}
