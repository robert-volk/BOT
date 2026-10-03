import SwiftUI

struct TranscriptView: View {
    let theme: Theme
    @EnvironmentObject var engine: ConversationEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        if engine.turns.isEmpty {
                            Text("Your conversation will appear here.")
                                .foregroundStyle(.secondary)
                                .padding(.top, 60)
                        }
                        ForEach(engine.turns) { turn in
                            bubble(turn).id(turn.id)
                        }
                    }
                    .padding()
                }
                .onAppear { if let last = engine.turns.last { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
            .navigationTitle("Conversation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .tint(theme.accent)
    }

    private func bubble(_ turn: ChatTurn) -> some View {
        let mine = turn.role == .user
        return HStack {
            if mine { Spacer(minLength: 40) }
            Text(turn.text)
                .font(theme.font(16))
                .foregroundStyle(mine ? Color.white : theme.text)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(mine ? theme.accent : theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            if !mine { Spacer(minLength: 40) }
        }
    }
}
