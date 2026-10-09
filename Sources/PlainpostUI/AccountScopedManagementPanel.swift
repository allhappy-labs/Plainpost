import SwiftUI
import PlainpostCore

public enum AccountManagementSelection: Equatable, Sendable {
    case allAccounts
    case account(AccountID)
}

public typealias MailRuleAccountSelection = AccountManagementSelection

struct AccountScopedManagementPanel<
    ListContent: View,
    EditorContent: View,
    Confirmation: View
>: View {
    @Binding var selection: AccountManagementSelection
    let accounts: [Account]
    let itemTitle: String
    let addAccessibilityLabel: String
    let add: () -> Void
    let isConfirmationPresented: Binding<Bool>
    /// Whether the editor should be on screen, derived by the caller from its own selected-item
    /// state (e.g. `draft != nil`). Setting it to `false` — including an iOS back swipe, which
    /// SwiftUI reports through this binding — must clear that selection, or the next unrelated
    /// state change that re-derives the same `true` value would silently re-push the editor.
    let isEditorPresented: Binding<Bool>
    let listContent: (@escaping () -> Void) -> ListContent
    let editorContent: () -> EditorContent
    let confirmation: () -> Confirmation

    init(
        selection: Binding<AccountManagementSelection>,
        accounts: [Account],
        itemTitle: String,
        addAccessibilityLabel: String,
        add: @escaping () -> Void,
        isConfirmationPresented: Binding<Bool>,
        isEditorPresented: Binding<Bool>,
        @ViewBuilder listContent: @escaping (@escaping () -> Void) -> ListContent,
        @ViewBuilder editorContent: @escaping () -> EditorContent,
        @ViewBuilder confirmation: @escaping () -> Confirmation
    ) {
        _selection = selection
        self.accounts = accounts
        self.itemTitle = itemTitle
        self.addAccessibilityLabel = addAccessibilityLabel
        self.add = add
        self.isConfirmationPresented = isConfirmationPresented
        self.isEditorPresented = isEditorPresented
        self.listContent = listContent
        self.editorContent = editorContent
        self.confirmation = confirmation
    }

    var body: some View {
        #if os(iOS)
        Group {
            Picker("Account", selection: accountSelection) {
                Text("All Accounts").tag("all")
                ForEach(accounts, id: \.id) { account in
                    Text(account.displayName.isEmpty ? account.email.rawValue : account.displayName)
                        .tag(account.id.rawValue)
                }
            }

            listContent {}

            Button {
                add()
            } label: {
                Label(addAccessibilityLabel, systemImage: "plus")
            }
        }
        .navigationDestination(isPresented: isEditorPresented) {
            editorContent()
        }
        .sheet(isPresented: isConfirmationPresented) {
            confirmation()
        }
        #else
        HStack(spacing: 0) {
            listPane
                .frame(width: 240, alignment: .topLeading)

            Divider()

            editorContent()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minHeight: 470)
        .background(MailDesign.panel)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(MailDesign.stroke))
        .sheet(isPresented: isConfirmationPresented) {
            confirmation()
        }
        #endif
    }

    private var listPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Account", selection: accountSelection) {
                Text("All Accounts").tag("all")
                ForEach(accounts, id: \.id) { account in
                    Text(account.displayName.isEmpty ? account.email.rawValue : account.displayName)
                        .tag(account.id.rawValue)
                }
            }
            .labelsHidden()

            HStack {
                Text(itemTitle).font(.headline)
                Spacer()
                Button {
                    add()
                } label: {
                    Label(addAccessibilityLabel, systemImage: "plus")
                }
                .labelStyle(.iconOnly)
                .accessibilityLabel(addAccessibilityLabel)
            }

            listContent {}
        }
        .padding(16)
    }

    private var accountSelection: Binding<String> {
        Binding(
            get: {
                switch selection {
                case .allAccounts: "all"
                case .account(let id): id.rawValue
                }
            },
            set: { raw in
                selection = raw == "all" ? .allAccounts : .account(AccountID(raw))
            }
        )
    }
}
