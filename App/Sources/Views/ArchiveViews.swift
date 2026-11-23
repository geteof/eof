import EOFCore
import SwiftUI

/// One compress or extract run: what it is doing, how far it got, and how it ended.
final class ArchiveJob: ObservableObject {
    @Published private(set) var title: String?
    @Published private(set) var progress: Progress?
    @Published private(set) var outcome: Outcome?

    enum Outcome {
        case created(URL)
        case failed(Error)
    }

    var isRunning: Bool { title != nil }

    /// Runs `work` off the main thread. `determinate` work gets a progress bar and a Cancel button.
    func run(_ title: String, determinate: Bool, work: @escaping (Progress?) throws -> URL) {
        guard !isRunning else { return }
        let progress = determinate ? Progress(totalUnitCount: 1) : nil
        self.title = title
        self.progress = progress
        outcome = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try work(progress) }
            DispatchQueue.main.async {
                self.title = nil
                self.progress = nil
                switch result {
                case .success(let url):
                    self.outcome = .created(url)
                case .failure(let error):
                    // A cancelled run ends quietly.
                    if (error as? CocoaError)?.code != .userCancelled { self.outcome = .failed(error) }
                }
            }
        }
    }

    func cancel() {
        progress?.cancel()
    }

    func clearOutcome() {
        outcome = nil
    }
}

/// The card shown over a page while an archive is being written or unpacked.
struct ArchiveJobCard: View {
    @ObservedObject var job: ArchiveJob

    var body: some View {
        if let title = job.title {
            VStack(spacing: 14) {
                if let progress = job.progress {
                    ProgressView(progress)
                        .progressViewStyle(.linear)
                        .labelsHidden()
                        .frame(width: 200)
                } else {
                    ProgressView()
                }
                Text(verbatim: title)
                    .font(.footnote)
                if job.progress != nil {
                    Button("Cancel", role: .cancel) { job.cancel() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            .padding(22)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        }
    }
}

/// A short message at the bottom of a page that goes away by itself.
struct Toast: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label {
            Text(verbatim: text)
                .lineLimit(2)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.green)
        }
        .font(.footnote.weight(.medium))
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
        .padding(.bottom, 14)
        .padding(.horizontal, 20)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
