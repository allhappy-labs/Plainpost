import SwiftUI

/// Move to…: the message's own account's folders; choosing one moves it there.
struct MoveToFolderSheet: View {
    let folders: [MailFolderRef]
    let choose: (MailFolderRef) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(folders, id: \.path) { folder in
                Button {
                    choose(folder)
                    dismiss()
                } label: {
                    Label(folder.name, systemImage: MailboxFolder.systemImage(for: folder.role))
                }
                .accessibilityIdentifier("move.folder.\(folder.path)")
            }
            .overlay {
                if folders.isEmpty {
                    ContentUnavailableView("No other folders", systemImage: "folder",
                                           description: Text("This account has no folder to move it to."))
                }
            }
            .navigationTitle("Move to")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
