import SwiftUI

/// The card for writing a note on the page. It sits in a popover, which macOS draws as glass.
struct NoteEditor: View {
    @State private var text: String
    @FocusState private var focused: Bool
    let onChange: (String) -> Void
    let onDelete: () -> Void

    init(text: String, onChange: @escaping (String) -> Void, onDelete: @escaping () -> Void) {
        _text = State(initialValue: text)
        self.onChange = onChange
        self.onDelete = onDelete
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Write a note…")
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $text)
                    .scrollContentBackground(.hidden)
                    .focused($focused)
            }
            .font(.system(size: 13))
            .frame(width: 260, height: 120)

            Button("Delete Note", role: .destructive, action: onDelete)
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .font(.system(size: 12))
        }
        .padding(14)
        .onAppear { focused = true }
        .onChange(of: text) { _, newValue in onChange(newValue) }
    }
}
