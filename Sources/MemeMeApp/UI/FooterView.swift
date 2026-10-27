import MemeMeCore
import SwiftUI

/// Footer under the strip: focus line + legend, or one quiet library or update line.
struct FooterView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(Theme.separator)
                .frame(height: 1)
                .padding(.bottom, 10)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var content: some View {
        switch model.footer {
        case .legend:
            legend
        case .libraryOffer:
            libraryOffer
        case .indexing(let count):
            indexing(count: count)
        case .added(let batch):
            added(batch)
        case .update(let manifest):
            updateOffer(manifest)
        }
    }

    // MARK: Legend

    private var legend: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                focusLine
                    .frame(maxWidth: .infinity, alignment: .leading)
                if focusedItem != nil && !model.showSetupCard {
                    Button("More like this") {
                        model.moreLikeFocused()
                    }
                    .buttonStyle(PanelCapsuleButtonStyle(fontSize: 11))
                    .help("Search with this result (Tab)")
                }
            }
            .frame(minHeight: 20)
            Text("↵ copy · 1–9 pick · drag into chat · esc")
                .font(.system(size: 11))
                .foregroundColor(Theme.mutedText)
                .lineLimit(1)
        }
    }

    private var focusedItem: LibraryItem? {
        let results = model.results
        guard model.focusedIndex >= 0, model.focusedIndex < results.count else { return nil }
        return results[model.focusedIndex].item
    }

    @ViewBuilder
    private var focusLine: some View {
        if let item = focusedItem {
            (Text(verbatim: "↵ copies “\(item.displayName)”").foregroundColor(Theme.text)
                + Text(verbatim: " · \(item.provenance)").foregroundColor(Theme.mutedText))
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
        } else {
            Text(" ")
                .font(.system(size: 12))
                .accessibilityHidden(true)
        }
    }

    // MARK: Library lines

    private var libraryOffer: some View {
        HStack(spacing: 8) {
            (Text("Search memes you already saved? ").foregroundColor(Theme.text)
                + Text("Downloads · Desktop · Screenshots").foregroundColor(Theme.mutedText))
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Find my memes") {
                model.findMyMemes()
            }
            .buttonStyle(PanelFilledButtonStyle(fontSize: 12, cornerRadius: 7))
            Button("Not now") {
                model.dismissLibraryOffer()
            }
            .buttonStyle(PanelLinkButtonStyle(fontSize: 12, color: Theme.softText))
        }
    }

    private func indexing(count: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            (Text(verbatim: "Finding your memes… \(count.formatted())").foregroundColor(Theme.text)
                + Text(" · newest first").foregroundColor(Theme.mutedText))
                .font(.system(size: 12))
                .lineLimit(1)
            ProgressView()
                .progressViewStyle(.linear)
                .controlSize(.small)
                .tint(Theme.accent)
                .frame(maxWidth: .infinity)
        }
    }

    private func added(_ batch: IndexBatch) -> some View {
        HStack(spacing: 8) {
            addedSummary(batch)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Review") {
                // "mine" lists your own memes, newest month first.
                model.queryText = "mine"
            }
            .buttonStyle(PanelLinkButtonStyle(fontSize: 12))
            .help("Show your memes, newest first")
            Button("Undo") {
                model.undoAddedBatch()
            }
            .buttonStyle(PanelLinkButtonStyle(fontSize: 12))
        }
    }

    /// "Added 312 from Downloads, Desktop · 1,140 skipped (photos, documents)"
    private func addedSummary(_ batch: IndexBatch) -> Text {
        var main = "Added \(batch.addedIDs.count.formatted())"
        if !batch.sources.isEmpty {
            main += " from " + batch.sources.joined(separator: ", ")
        }
        var summary = Text(main).foregroundColor(Theme.text)
        if batch.skipped > 0 {
            summary = summary + Text(verbatim: " · \(batch.skipped.formatted()) skipped (photos, documents)")
                .foregroundColor(Theme.mutedText)
        }
        return summary
    }

    // MARK: Update line

    private func updateOffer(_ manifest: UpdateManifest) -> some View {
        HStack(spacing: 8) {
            updateSummary(manifest)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Update") {
                model.installUpdate()
            }
            .buttonStyle(PanelFilledButtonStyle(fontSize: 12, cornerRadius: 7))
            .help("Install the update and restart MemeMe")
            Button("Not now") {
                model.dismissUpdateOffer()
            }
            .buttonStyle(PanelLinkButtonStyle(fontSize: 12, color: Theme.softText))
        }
    }

    /// "MemeMe 1.0 (58) is ready · <first release note>"
    private func updateSummary(_ manifest: UpdateManifest) -> Text {
        let summary = Text(verbatim: "MemeMe \(manifest.displayVersion) is ready").foregroundColor(Theme.text)
        let firstNote = manifest.notes
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
        guard let note = firstNote else { return summary }
        return summary + Text(verbatim: " · \(note)").foregroundColor(Theme.mutedText)
    }
}
