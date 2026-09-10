import SwiftUI
import AppKit
import UniformTypeIdentifiers

// This SDK ships @State as a macro that only Xcode can expand, so all view state
// lives in AppModel and is reached through the @ObservedObject projection.
struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Mode", selection: $model.mode) {
                ForEach(Mode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(model.isWorking)

            Text(model.mode.hint)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Group {
                if model.queue.isEmpty {
                    DropZone(icon: model.mode.icon,
                             title: "Drop one or several PDFs here",
                             subtitle: "or click to choose",
                             highlighted: model.dropTargeted) { model.chooseFiles() }
                } else {
                    QueueList(model: model)
                }
            }
            .frame(maxHeight: .infinity)
            .disabled(model.isWorking)

            LimitRow(model: model)
            StatusPanel(model: model)
            ActionBar(model: model)
        }
        .padding(18)
        .frame(minWidth: 520, minHeight: 520)
        .onDrop(of: [.fileURL], isTargeted: Binding(
            get: { model.dropTargeted },
            set: { model.dropTargeted = $0 && !model.isBusy }
        )) { providers in
            guard !model.isBusy else { return false }
            FileDrop.load(providers) { urls in model.handle(urls) }
            return true
        }
    }
}

struct DropZone: View {
    let icon: String
    let title: String
    let subtitle: String
    let highlighted: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(highlighted ? Color.accentColor : Color.secondary)
                Text(title)
                    .font(.title3.weight(.medium))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(highlighted ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(highlighted ? Color.accentColor : Color.secondary.opacity(0.45),
                              style: StrokeStyle(lineWidth: highlighted ? 2 : 1.5, dash: [7, 5]))
        )
    }
}

struct QueueList: View {
    @ObservedObject var model: AppModel

    private var totalPages: Int { model.queue.reduce(0) { $0 + $1.pages } }
    private var totalBytes: Int { model.queue.reduce(0) { $0 + $1.bytes } }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("\(AppModel.plural(model.queue.count, "file", "files")) · \(AppModel.plural(totalPages, "page", "pages")) · \(AppModel.formatSize(totalBytes))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                if model.mode.showsOrder {
                    Text("Order = page order")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            List {
                ForEach(model.queue) { item in
                    HStack(spacing: 8) {
                        Image(systemName: "line.3.horizontal")
                            .foregroundStyle(.tertiary)
                            .font(.caption)
                        Image(systemName: "doc.richtext")
                            .foregroundStyle(.red)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.url.lastPathComponent)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text("\(AppModel.plural(item.pages, "page", "pages")) · \(AppModel.formatSize(item.bytes))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        Button { model.removeFromQueue(item) } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Remove from the list")
                        .accessibilityLabel("Remove “\(item.url.lastPathComponent)” from the list")
                    }
                    .padding(.vertical, 2)
                }
                .onMove { source, destination in
                    model.queue.move(fromOffsets: source, toOffset: destination)
                }
                .onInsert(of: [.fileURL]) { index, providers in
                    FileDrop.load(providers) { urls in model.handle(urls, at: index) }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(model.dropTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
                                  lineWidth: model.dropTargeted ? 2 : 1)
            )
        }
    }
}

/// Always on screen: the two-step contract is "files land in the list, this button starts the job".
struct ActionBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            if !model.queue.isEmpty {
                Button { model.chooseFiles() } label: { Label("Add…", systemImage: "plus") }
                    .help("Add more PDFs")
                Button("Clear") { model.clearQueue() }
                    .help("Remove every file from the list")
            }
            Spacer()
            Button { model.run() } label: {
                Text(model.mode.actionTitle).frame(minWidth: 90)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!model.canRun)
            .help(model.mode.runHelp)
        }
        .disabled(model.isWorking)
    }
}

struct LimitRow: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let isSplit = model.mode == .split
        let range = AppModel.limitRange
        let stepperValue = Binding<Double>(
            get: { model.activeLimitMB },
            set: { value in
                model.setLimit(min(max(value, range.lowerBound), range.upperBound))
                model.syncLimitText()
            }
        )
        let accessibilityName = isSplit ? "Size limit per page, in megabytes" : "Size limit for the final file, in megabytes"
        return HStack(spacing: 8) {
            Text(isSplit ? "No more than" : "Final file no more than")
            TextField("", text: $model.limitText)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 62)
                .onSubmit { model.syncLimitText() }
                .accessibilityLabel(accessibilityName)
                .help("From 0.1 to 2000 MB")
            Stepper("", value: stepperValue, in: range, step: isSplit ? 0.5 : 1)
                .labelsHidden()
                .accessibilityLabel(accessibilityName)
            Text(isSplit ? "MB per page" : "MB")
            Spacer()
        }
        .disabled(model.isWorking)
    }
}

struct StatusPanel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            if model.isWorking {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: model.progress)
                    Text("\(model.progressLabel) \(Int(model.progress * 100))%")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            } else if let status = model.status {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: status.kind.symbol)
                        .foregroundStyle(status.kind.color)
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 8) {
                        // Short reports take the room they need; only a long batch report scrolls.
                        if status.text.count > 400 || status.text.filter({ $0 == "\n" }).count >= 5 {
                            ScrollView { message(status.text) }
                                .frame(height: 120)
                        } else {
                            message(status.text)
                        }
                        if !status.actions.isEmpty {
                            HStack {
                                ForEach(status.actions) { action in
                                    Button(action.title) { action.run() }
                                }
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(status.kind.color.opacity(0.12)))
            } else {
                Text(" ").font(.callout)
            }
        }
        .frame(minHeight: 46, alignment: .topLeading)
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum FileDrop {
    /// Finder hands file drags over as promises; resolve them, keeping the original order.
    static func load(_ providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
        let identifier = UTType.fileURL.identifier
        let group = DispatchGroup()
        let collected = Locked([(Int, URL)]())
        for (index, provider) in providers.enumerated() where provider.hasItemConformingToTypeIdentifier(identifier) {
            group.enter()
            provider.loadItem(forTypeIdentifier: identifier, options: nil) { item, _ in
                defer { group.leave() }
                var url: URL?
                if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                else if let direct = item as? URL { url = direct }
                else if let string = item as? String { url = URL(string: string) }
                if let url { collected.update { $0.append((index, url)) } }
            }
        }
        // Always report back, even with nothing resolved, so the window can say so.
        group.notify(queue: .main) {
            completion(collected.value.sorted { $0.0 < $1.0 }.map(\.1))
        }
    }
}
