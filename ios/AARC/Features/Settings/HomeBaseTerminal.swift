import SwiftUI

/// Settings → Developer → Home Base terminal.
///
/// A direct line to the agent on the mini, styled like the terminal it
/// mirrors. Founder, 2026-10-13: "i need a way to talk right to you, similar
/// experience as claude code remote control... so i can ask you to do shit,
/// like today."
///
/// Transport is the agent thread on the proxy: this view posts his lines and
/// polls for the agent's. Nothing clever on purpose: it has to work from a
/// gym on a bad signal, which rules out anything that needs a socket to stay
/// up.
@MainActor
struct HomeBaseTerminal: View {
    @State private var messages: [AIClient.AgentMessage] = []
    @State private var draft = ""
    @State private var sending = false
    @State private var error: String?
    @State private var lastId = 0
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(messages) { m in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.role == "agent" ? "home base" : "you")
                                    .font(.system(.caption2, design: .monospaced).bold())
                                    .foregroundStyle(m.role == "agent" ? .green : .cyan)
                                Text(m.text)
                                    .font(.system(.footnote, design: .monospaced))
                                    .textSelection(.enabled)
                                    .foregroundStyle(.white)
                            }
                            .id(m.id)
                        }
                        if let error {
                            Text(error).font(.system(.caption2, design: .monospaced)).foregroundStyle(.orange)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color.black)
                .onChange(of: messages.count) { _, _ in
                    if let last = messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            HStack(spacing: 8) {
                Text(">").font(.system(.body, design: .monospaced)).foregroundStyle(.green)
                TextField("say it", text: $draft, axis: .vertical)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1...4)
                    .autocorrectionDisabled()
                    .onSubmit(send)
                Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .disabled(sending || draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(10)
            .background(.ultraThinMaterial)
        }
        .navigationTitle("Home Base")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await refresh()
            pollTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(4))
                    await refresh()
                }
            }
        }
        .onDisappear { pollTask?.cancel() }
    }

    private func refresh() async {
        do {
            let new = try await AIClient.shared.agentThread(since: lastId)
            if !new.isEmpty {
                messages.append(contentsOf: new)
                lastId = new.last!.id
                error = nil
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        sending = true
        draft = ""
        Task {
            defer { sending = false }
            do { _ = try await AIClient.shared.agentSend(text); await refresh() }
            catch { self.error = "send failed: \(error.localizedDescription)" }
        }
    }
}
