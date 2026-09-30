import AppKit
import SwiftUI

struct CodeReviewSidebar: View {
    let coordinator: CodeReviewCoordinator
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Changes").font(.headline)
                    Text(coordinator.summary.label).font(.system(.caption, design: .monospaced))
                }
                Spacer()
                ReviewCircleButton(symbol: "arrow.clockwise", title: "Refresh changes") {
                    coordinator.refresh(directory: coordinator.root)
                }
                ReviewCircleButton(symbol: "xmark", title: "Close review", action: onClose)
            }
            .buttonStyle(.plain)
            .padding(Theme.Spacing.lg)
            if let root = coordinator.root {
                Text((root as NSString).abbreviatingWithTildeInPath)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, Theme.Spacing.lg)
            }
            GeometryReader { proxy in
                VStack(spacing: 0) {
                    fileList.frame(height: coordinator.filesHeight(available: proxy.size.height))
                    ZStack {
                        Rectangle().fill(.clear)
                        Divider()
                    }
                    .frame(height: 14)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                    }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            coordinator.dragFilesHeight(by: value.translation.height, available: proxy.size.height)
                        }
                        .onEnded { _ in coordinator.endFilesDrag() })
                    diffContent.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var fileList: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(coordinator.summary.files) { file in
                        Button { coordinator.select(file) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(file.path).lineLimit(1).truncationMode(.middle)
                                    Text(file.scope.rawValue.capitalized).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(file.binary ? "Binary" : "+\(file.added) −\(file.removed)")
                                    .font(.system(.caption, design: .monospaced))
                            }
                            .padding(.horizontal, Theme.Spacing.lg).padding(.vertical, Theme.Spacing.sm)
                            .background(coordinator.selected?.id == file.id ? Color.primary.opacity(0.08) : .clear)
                        }.buttonStyle(.plain)
                    }
                }
            }
            if coordinator.summary.files.isEmpty {
                Text(coordinator.root == nil ? "This pane is not in a local Git repository." : "No changes")
                    .font(.callout).foregroundStyle(.secondary).padding()
            }
            if coordinator.summary.isLimited {
                Text("Large repository: totals or file list are limited.")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
            }
        }
        .clipped()
    }

    private var diffContent: some View {
        VStack(spacing: 0) {
            if let selected = coordinator.selected {
                HStack {
                    Text(selected.path).font(.caption).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    ReviewCircleButton(symbol: selected.scope == .staged ? "minus" : "plus",
                        title: selected.scope == .staged ? "Unstage file" : "Stage file") { coordinator.changeIndex() }
                        .disabled(coordinator.isChangingIndex)
                }.padding(Theme.Spacing.md)
            }
            if let error = coordinator.error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).padding()
            }
            if coordinator.isLoading { ProgressView().padding() }
            if let document = coordinator.document {
                if document.isLimited {
                    Text("Diff exceeds the 4.375 MB or 50,000-line limit; showing a bounded preview.")
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                }
                if document.isLarge && !coordinator.expandedLargeDiff {
                    HStack {
                        Text("Large diff (\(document.rows.count) lines)").font(.caption)
                        Spacer()
                        ReviewCircleButton(symbol: "arrow.up.left.and.arrow.down.right", title: "Show large diff") {
                            coordinator.expandLargeDiff()
                        }
                    }.padding()
                } else { DiffTable(document: document) }
            } else if !coordinator.isLoading {
                Text("Select a file to inspect its diff.").font(.callout).foregroundStyle(.secondary).padding()
            }
            Spacer(minLength: 0)
        }
    }
}

private struct ReviewCircleButton: View {
    let symbol: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary).frame(width: 28, height: 28).contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .accessibilityLabel(title).help(title)
    }
}

private struct DiffTable: NSViewRepresentable {
    let document: GitDiffDocument
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.headerView = nil
        table.rowHeight = 20
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.gridStyleMask = []
        table.columnAutoresizingStyle = .noColumnAutoresizing
        for (name, width) in [("old", 24.0), ("new", 24.0), ("text", 40_000.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(name))
            column.minWidth = 0
            column.width = width
            column.resizingMask = []
            table.addTableColumn(column)
        }
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.documentView = table
        context.coordinator.table = table
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard context.coordinator.document?.id != document.id else { return }
        context.coordinator.document = document
        let maximum = document.rows.reduce(into: (old: 0, new: 0)) { maximum, row in
            maximum.old = max(maximum.old, row.oldLine ?? 0)
            maximum.new = max(maximum.new, row.newLine ?? 0)
        }
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        for (column, line) in zip(context.coordinator.table?.tableColumns.prefix(2) ?? [], [maximum.old, maximum.new]) {
            column.isHidden = line == 0
            column.width = (String(line) as NSString).size(withAttributes: [.font: font]).width + 10
        }
        context.coordinator.table?.tableColumns.last?.width = CGFloat(max(360, min(20_000, document.maximumRowBytes) * 8))
        context.coordinator.table?.reloadData()
    }
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var document: GitDiffDocument?
        weak var table: NSTableView?
        func numberOfRows(in tableView: NSTableView) -> Int { document?.rows.count ?? 0 }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let document, document.rows.indices.contains(row), let identifier = tableColumn?.identifier else { return nil }
            let field = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField
                ?? NSTextField(labelWithString: "")
            field.identifier = identifier
            field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            field.lineBreakMode = .byClipping
            field.alignment = identifier.rawValue == "text" ? .left : .right
            field.textColor = .labelColor
            let entry = document.rows[row]
            switch identifier.rawValue {
            case "old": field.stringValue = entry.oldLine.map(String.init) ?? ""; field.textColor = .secondaryLabelColor
            case "new": field.stringValue = entry.newLine.map(String.init) ?? ""; field.textColor = .secondaryLabelColor
            default:
                field.stringValue = document.text(at: row)
                if entry.kind == .added { field.textColor = .systemGreen }
                if entry.kind == .removed { field.textColor = .systemRed }
            }
            return field
        }
    }
}
