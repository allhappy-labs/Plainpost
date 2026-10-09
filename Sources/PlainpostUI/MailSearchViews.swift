import SwiftUI
import PlainpostCore

struct MailSearchTip: Equatable {
    let insertion: String
    let description: String
    let systemImage: String
    let tint: Color

    static let reference: [MailSearchTip] = MailSearchFieldRegistry.all.compactMap { field in
        guard let insertion = field.examples.first else { return nil }
        return MailSearchTip(
            insertion: insertion,
            description: field.description,
            systemImage: symbol(for: field.name),
            tint: tint(for: field.name)
        )
    }

    private static func symbol(for field: String) -> String {
        switch field {
        case "from", "to", "cc", "bcc", "participants": "person.2"
        case "subject": "textformat"
        case "filename", "has", "with": "paperclip"
        case "is": "checkmark.circle"
        case "in", "mailbox": "tray"
        default: "calendar"
        }
    }

    private static func tint(for field: String) -> Color {
        switch field {
        case "from", "to", "cc", "bcc", "participants": MailDesign.accentBlue
        case "filename", "has", "with": .green
        case "in", "mailbox": .orange
        case "since", "after", "before", "on", "date": .red
        default: MailDesign.secondaryText
        }
    }
}

struct MailSearchTextRun: Equatable, Identifiable {
    let text: String
    let isHighlighted: Bool

    var id: String { "\(isHighlighted):\(text.utf8.count):\(text)" }
}

struct MailSearchEditableToken: Equatable, Identifiable {
    let text: String
    let sourceRange: MailSearchTextRange

    var id: String { "\(sourceRange.location):\(sourceRange.length):\(text)" }
}

struct MailSearchResultAccessibility: Equatable {
    let label: String
    let value: String
}

enum MailSearchScopeSelection {
    static func isAll(_ scope: MailSearchSelectionScope) -> Bool {
        scope.accountIDs.isEmpty && scope.mailboxIDs.isEmpty
    }

    static func reset(_: MailSearchSelectionScope) -> MailSearchSelectionScope {
        MailSearchSelectionScope()
    }

    static func togglingAccount(
        _ accountID: AccountID,
        in scope: MailSearchSelectionScope
    ) -> MailSearchSelectionScope {
        var accountIDs = scope.accountIDs
        if let index = accountIDs.firstIndex(of: accountID) {
            accountIDs.remove(at: index)
        } else {
            accountIDs.append(accountID)
        }
        return MailSearchSelectionScope(
            accountIDs: accountIDs,
            mailboxIDs: scope.mailboxIDs
        )
    }

    static func togglingMailbox(
        _ mailboxID: MailboxID,
        in scope: MailSearchSelectionScope
    ) -> MailSearchSelectionScope {
        var mailboxIDs = scope.mailboxIDs
        if let index = mailboxIDs.firstIndex(of: mailboxID) {
            mailboxIDs.remove(at: index)
        } else {
            mailboxIDs.append(mailboxID)
        }
        return MailSearchSelectionScope(
            accountIDs: scope.accountIDs,
            mailboxIDs: mailboxIDs
        )
    }
}

enum MailSearchEffectiveScope {
    static func isExactlyOneAccount(
        _ scope: MailSearchSelectionScope,
        mailboxes: [MailSearchMailbox]
    ) -> Bool {
        var accountIDs = Set(scope.accountIDs)
        let owners = Dictionary(
            mailboxes.map { ($0.id, $0.accountID) },
            uniquingKeysWith: { current, _ in current }
        )
        for mailboxID in scope.mailboxIDs {
            guard let owner = owners[mailboxID] else { return false }
            accountIDs.insert(owner)
        }
        return accountIDs.count == 1
    }
}

enum MailSearchSuggestionNavigator {
    static func move(
        from selectedID: String?,
        command: MailSearchKeyboardCommand,
        ids: [String]
    ) -> String? {
        guard !ids.isEmpty else { return nil }
        let movesBackward = command == .up || command == .cycleBackward
        guard let selectedID, let index = ids.firstIndex(of: selectedID) else {
            return movesBackward ? ids.last : ids.first
        }
        if movesBackward {
            return ids[(index - 1 + ids.count) % ids.count]
        }
        return ids[(index + 1) % ids.count]
    }
}

enum MailSearchReturnOrigin {
    case queryField
    case results
}

enum MailSearchReturnAction: Equatable {
    case applySuggestion(MailSearchSuggestionItem)
    case openResult(MailSearchHit)
    case submitSearch
}

enum MailSearchPresentation {
    static let examples = MailSearchTip.reference

    private static let suggestionOrder: [MailSearchSuggestionKind] = [
        .recent, .people, .fields, .filters,
    ]

    static func accountAccessibilityLabel(_ account: MailSearchAccount) -> String {
        "Search \(account.displayName), \(account.email)"
    }

    static func mailboxAccessibilityLabel(
        _ mailbox: MailSearchMailbox,
        accounts: [MailSearchAccount]
    ) -> String {
        guard let account = accounts.first(where: { $0.id == mailbox.accountID }) else {
            return "Search mailbox \(mailbox.displayName)"
        }
        return "Search mailbox \(mailbox.displayName), \(account.displayName) account"
    }

    static func mailboxDisplayLabel(
        _ mailbox: MailSearchMailbox,
        accounts: [MailSearchAccount]
    ) -> String {
        let configuredName = accounts.first(where: { $0.id == mailbox.accountID })?
            .displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let accountName = configuredName.flatMap { $0.isEmpty ? nil : $0 }
            ?? mailbox.accountID.rawValue
        return "\(accountName) — \(mailbox.displayName)"
    }

    static func scopeAccessibilityValue(
        _ scope: MailSearchSelectionScope,
        accounts: [MailSearchAccount],
        mailboxes: [MailSearchMailbox]
    ) -> String {
        let accountNames = scope.accountIDs.map { accountID in
            accounts.first(where: { $0.id == accountID })?.displayName ?? accountID.rawValue
        }
        let mailboxNames = scope.mailboxIDs.map { mailboxID in
            guard let mailbox = mailboxes.first(where: { $0.id == mailboxID }) else {
                return mailboxID.rawValue
            }
            return mailboxDisplayLabel(mailbox, accounts: accounts)
        }
        if accountNames.isEmpty, mailboxNames.isEmpty { return "All accounts and mailboxes" }
        if accountNames.isEmpty { return "Mailboxes " + mailboxNames.joined(separator: ", ") }
        if mailboxNames.isEmpty { return "Accounts " + accountNames.joined(separator: ", ") }
        return "Accounts \(accountNames.joined(separator: ", ")); mailboxes \(mailboxNames.joined(separator: ", "))"
    }

    static func tipAccessibilityLabel(_ tip: MailSearchTip) -> String {
        "Insert \(tip.insertion)"
    }

    static func resultAccountDisplayName(
        _ accountID: AccountID,
        accountDisplayNames: [AccountID: String]
    ) -> String {
        guard let displayName = accountDisplayNames[accountID]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !displayName.isEmpty else {
            return accountID.rawValue
        }
        return displayName
    }

    static func resultAccountAccessibilityLabel(
        _ accountID: AccountID,
        accountDisplayNames: [AccountID: String]
    ) -> String {
        "account \(resultAccountDisplayName(accountID, accountDisplayNames: accountDisplayNames))"
    }

    static func orderedSuggestionSections(
        _ sections: [MailSearchSuggestionSection]
    ) -> [MailSearchSuggestionSection] {
        suggestionOrder.compactMap { kind in
            sections.first { $0.kind == kind && !$0.items.isEmpty }
        }
    }

    static func suggestionForReturn(
        sections: [MailSearchSuggestionSection],
        selectedID: String?,
        isVisible: Bool
    ) -> MailSearchSuggestionItem? {
        guard isVisible, let selectedID else { return nil }
        return sections.lazy.flatMap(\.items).first { $0.id == selectedID }
    }

    static func actionForReturn(
        sections: [MailSearchSuggestionSection],
        selectedID: String?,
        isVisible: Bool,
        hit: MailSearchHit?,
        origin: MailSearchReturnOrigin
    ) -> MailSearchReturnAction {
        if let suggestion = suggestionForReturn(
            sections: sections, selectedID: selectedID, isVisible: isVisible
        ) {
            return .applySuggestion(suggestion)
        }
        if case .results = origin, let hit { return .openResult(hit) }
        return .submitSearch
    }

    static func showsAskMail(in state: MailSearchViewState) -> Bool {
        switch state {
        case .initial, .empty: true
        case .suggesting, .searching, .results, .invalid, .rebuilding, .unavailable: false
        }
    }

    static func showsRetainedLoading(in state: MailSearchViewState) -> Bool {
        if case .searching(retainingResults: true) = state { return true }
        return false
    }

    static func highlightedRuns(for snippet: MailSearchSnippet) -> [MailSearchTextRun] {
        let source = snippet.text as NSString
        var cursor = 0
        var runs: [MailSearchTextRun] = []
        for value in snippet.highlights {
            guard value.location >= cursor,
                  value.length > 0,
                  value.location <= source.length,
                  value.length <= source.length - value.location else {
                return [MailSearchTextRun(text: snippet.text, isHighlighted: false)]
            }
            let range = NSRange(location: value.location, length: value.length)
            guard source.rangeOfComposedCharacterSequences(for: range) == range else {
                return [MailSearchTextRun(text: snippet.text, isHighlighted: false)]
            }
            if value.location > cursor {
                runs.append(MailSearchTextRun(
                    text: source.substring(with: NSRange(
                        location: cursor,
                        length: value.location - cursor
                    )),
                    isHighlighted: false
                ))
            }
            runs.append(MailSearchTextRun(
                text: source.substring(with: range),
                isHighlighted: true
            ))
            cursor = value.location + value.length
        }
        if cursor < source.length {
            runs.append(MailSearchTextRun(
                text: source.substring(from: cursor),
                isHighlighted: false
            ))
        }
        if runs.isEmpty {
            return [MailSearchTextRun(text: snippet.text, isHighlighted: false)]
        }
        return runs
    }

    static func editableTokens(in query: String) -> [MailSearchEditableToken] {
        guard let tokens = try? MailSearchQueryParser().parse(query).tokens else { return [] }
        let source = query as NSString
        var result: [MailSearchEditableToken] = []
        var index = 0
        while index + 2 < tokens.count {
            let field = tokens[index]
            let colon = tokens[index + 1]
            guard field.kind == .filter,
                  colon.kind == .filter,
                  colon.text == ":" else {
                index += 1
                continue
            }
            let value = tokens[index + 2]
            let valueEndIndex: Int
            if value.kind == .grouping, value.text == "(" {
                var depth = 0
                var cursor = index + 2
                var closingIndex: Int?
                while cursor < tokens.count {
                    if tokens[cursor].kind == .grouping {
                        if tokens[cursor].text == "(" {
                            depth += 1
                        } else if tokens[cursor].text == ")" {
                            depth -= 1
                            if depth == 0 {
                                closingIndex = cursor
                                break
                            }
                        }
                    }
                    cursor += 1
                }
                guard let closingIndex else {
                    index += 1
                    continue
                }
                valueEndIndex = closingIndex
            } else if value.kind == .text || value.kind == .phrase {
                valueEndIndex = index + 2
            } else {
                index += 1
                continue
            }
            let lastValue = tokens[valueEndIndex]
            let end = lastValue.sourceRange.location + lastValue.sourceRange.length
            let range = MailSearchTextRange(
                location: field.sourceRange.location,
                length: end - field.sourceRange.location
            )
            guard range.location >= 0,
                  range.length > 0,
                  range.location <= source.length,
                  range.length <= source.length - range.location else {
                index += 1
                continue
            }
            let nsRange = NSRange(location: range.location, length: range.length)
            guard source.rangeOfComposedCharacterSequences(for: nsRange) == nsRange else {
                index += 1
                continue
            }
            result.append(MailSearchEditableToken(
                text: source.substring(with: nsRange),
                sourceRange: range
            ))
            index = valueEndIndex + 1
        }
        return result
    }

    static func resultAccessibility(
        for hit: MailSearchHit,
        showsAccount: Bool,
        accountDisplayNames: [AccountID: String],
        mailboxDisplayNames: [MailboxID: String],
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> MailSearchResultAccessibility {
        let label: String
        var parts: [String]
        switch hit {
        case .conversation(let conversation):
            label = conversation.subject.isEmpty ? "No subject" : conversation.subject
            parts = [joinedNames(conversation.participants)]
            if let date = conversation.latestActivity {
                parts.append("latest activity \(resultDate(date, calendar: calendar, locale: locale))")
            }
            parts.append(count(conversation.matchingMessageCount, singular: "matching message", plural: "matching messages"))
            parts.append(count(conversation.totalMessageCount, singular: "total message", plural: "total messages"))
            if conversation.unreadMessageCount > 0 {
                parts.append("\(conversation.unreadMessageCount) unread")
            } else {
                parts.append("read")
            }
            if conversation.hasAttachments { parts.append("has attachments") }
            if conversation.hasDocuments { parts.append("has documents") }
        case .message(let message):
            label = message.subject.isEmpty ? "No subject" : message.subject
            let sender = message.senderDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            parts = [sender?.isEmpty == false ? sender! : message.sender.rawValue]
            if !message.recipients.isEmpty {
                parts.append("to \(joinedNames(message.recipients.map(\.rawValue)))")
            }
            if let date = message.sentAt {
                parts.append("sent \(resultDate(date, calendar: calendar, locale: locale))")
            }
            if !message.mailboxIDs.isEmpty {
                let names = message.mailboxIDs.map {
                    mailboxDisplayNames[$0] ?? $0.rawValue
                }
                let prefix = names.count == 1 ? "mailbox" : "mailboxes"
                parts.append("\(prefix) \(joinedNames(names))")
            }
            parts.append(message.isUnread ? "unread" : "read")
            if message.isFlagged { parts.append("flagged") }
            if message.isDelegated { parts.append("delegated") }
            if message.hasAttachments { parts.append("has attachments") }
            if message.hasDocuments { parts.append("has documents") }
        }

        if showsAccount {
            let accountID: AccountID = switch hit {
            case .conversation(let conversation): conversation.accountID
            case .message(let message): message.accountID
            }
            parts.append(resultAccountAccessibilityLabel(
                accountID,
                accountDisplayNames: accountDisplayNames
            ))
        }
        let snippet = switch hit {
        case .conversation(let conversation): conversation.snippet.text
        case .message(let message): message.snippet.text
        }
        if !snippet.isEmpty { parts.append("snippet \(snippet)") }
        return MailSearchResultAccessibility(
            label: label,
            value: parts.filter { !$0.isEmpty }.joined(separator: ", ")
        )
    }

    private static func resultDate(
        _ date: Date,
        calendar: Calendar,
        locale: Locale
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("dMMMy")
        return formatter.string(from: date)
    }

    private static func count(_ value: Int, singular: String, plural: String) -> String {
        "\(value) \(value == 1 ? singular : plural)"
    }

    private static func joinedNames(_ names: [String]) -> String {
        switch names.count {
        case 0: "Conversation"
        case 1: names[0]
        case 2: "\(names[0]) and \(names[1])"
        default: "\(names.dropLast().joined(separator: ", ")), and \(names.last!)"
        }
    }

    static func tipColumns(_ tips: [MailSearchTip], count requestedCount: Int) -> [[MailSearchTip]] {
        guard !tips.isEmpty else { return [] }
        let columnCount = min(tips.count, max(1, requestedCount))
        let baseCount = tips.count / columnCount
        let remainder = tips.count % columnCount
        var nextIndex = 0

        return (0..<columnCount).map { columnIndex in
            let itemCount = baseCount + (columnIndex < remainder ? 1 : 0)
            defer { nextIndex += itemCount }
            return Array(tips[nextIndex..<(nextIndex + itemCount)])
        }
    }
}

struct MailSearchResultCountPresentation: Equatable {
    let label: String
    let showsLoadingFooter: Bool

    static func loaded(_ loadedCount: Int) -> MailSearchResultCountPresentation {
        let safeLoadedCount = max(0, loadedCount)
        return MailSearchResultCountPresentation(
            label: safeLoadedCount == 1
                ? "1 loaded result"
                : "\(safeLoadedCount) loaded results",
            showsLoadingFooter: false
        )
    }
}

public struct MailSearchWorkspace: View {
    @ObservedObject private var viewModel: MailSearchViewModel
    private let close: () -> Void
    private let openResult: (MessageID) -> Void
    private let askMail: (() -> Void)?
    private let rebuildIndex: (() -> Void)?
    private let forceSearchFocusAppearance: Bool

    @State private var focusGeneration = 0
    @State private var insertionRequest: MailSearchInsertionRequest?
    @State private var searchIsFocused = false
    @State private var selectedSuggestionID: String?
    @State private var suggestionsDismissed = false

    public init(
        viewModel: MailSearchViewModel,
        close: @escaping () -> Void,
        openResult: @escaping (MessageID) -> Void,
        askMail: (() -> Void)? = nil,
        rebuildIndex: (() -> Void)? = nil,
        forceSearchFocusAppearance: Bool = false
    ) {
        self.viewModel = viewModel
        self.close = close
        self.openResult = openResult
        self.askMail = askMail
        self.rebuildIndex = rebuildIndex
        self.forceSearchFocusAppearance = forceSearchFocusAppearance
    }

    public var body: some View {
        VStack(spacing: 0) {
            searchHeader
            ZStack(alignment: .top) {
                workspaceContent
                if showsSuggestionPopover {
                    MailSearchSuggestionPopover(
                        sections: orderedSuggestions,
                        selectedID: selectedSuggestionID,
                        select: applySuggestion
                    )
                    .padding(.horizontal, searchSuggestionInset)
                    .padding(.top, 2)
                    .zIndex(4)
                }
            }
        }
        .background(MailDesign.background)
        .foregroundStyle(MailDesign.primaryText)
        .onAppear {
            focusGeneration &+= 1
            viewModel.prepareInitialSearchSuggestions()
        }
        .onChange(of: viewModel.query) { _, _ in
            suggestionsDismissed = false
            selectedSuggestionID = nil
        }
        .onChange(of: viewModel.suggestions) { _, _ in
            selectedSuggestionID = nil
        }
        .onKeyPress(.escape) {
            close()
            return .handled
        }
        #if os(macOS)
        .onExitCommand(perform: close)
        .focusSection()
        #endif
        .accessibilityElement(children: .contain)
    }

    private var searchHeader: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 16) {
                Button(action: close) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .background(MailDesign.control.opacity(0.82), in: Circle())
                        .overlay(Circle().stroke(MailDesign.stroke))
                }
                .buttonStyle(.plain)
                .contentShape(Circle())
                .help("Back to mail (Esc)")
                .accessibilityLabel("Back to mail")

                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(showsSearchFocus ? MailDesign.accentBlue : MailDesign.secondaryText)
                        .accessibilityHidden(true)

                    MailSearchTextField(
                        text: $viewModel.query,
                        focusGeneration: focusGeneration,
                        insertionRequest: insertionRequest,
                        onSubmit: { submit(origin: searchFieldReturnOrigin) },
                        onCommand: handleKeyboardCommand,
                        onSelectionChange: viewModel.updateTextSelection,
                        onFocusChange: { isFocused in
                            searchIsFocused = isFocused
                            if isFocused {
                                viewModel.prepareInitialSearchSuggestions()
                            }
                        }
                    )

                    if !viewModel.query.isEmpty {
                        Button(action: clearSearch) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(MailDesign.secondaryText)
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.plain)
                        .help("Clear search")
                        .accessibilityLabel("Clear search")
                    }

                    accountMenu
                }
                .padding(.horizontal, 14)
                .frame(height: 52)
                .background(MailDesign.control.opacity(showsSearchFocus ? 0.72 : 0.46), in: RoundedRectangle(cornerRadius: 11))
                .overlay {
                    RoundedRectangle(cornerRadius: 11)
                        .stroke(
                            showsSearchFocus ? MailDesign.accentBlue : MailDesign.stroke,
                            lineWidth: showsSearchFocus ? 2 : 1
                        )
                }

                #if !os(iOS)
                Picker("Result type", selection: $viewModel.mode) {
                    Text("Conversations").tag(MailSearchMode.conversations)
                    Text("Messages").tag(MailSearchMode.messages)
                }
                .pickerStyle(.segmented)
                .frame(width: 250)
                .accessibilityLabel("Search result type")
                .accessibilityValue(viewModel.mode == .conversations ? "Conversations" : "Messages")
                #endif
            }
            #if os(iOS)
            Picker("Result type", selection: $viewModel.mode) {
                Text("Conversations").tag(MailSearchMode.conversations)
                Text("Messages").tag(MailSearchMode.messages)
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Search result type")
            .accessibilityValue(viewModel.mode == .conversations ? "Conversations" : "Messages")
            #endif

            if !viewModel.scope.accountIDs.isEmpty || !viewModel.scope.mailboxIDs.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(viewModel.scope.accountIDs, id: \.self) { accountID in
                            MailSearchRemovableChip(
                                label: accountName(accountID),
                                systemImage: "person.crop.circle",
                                remove: { removeAccount(accountID) }
                            )
                        }
                        ForEach(viewModel.scope.mailboxIDs, id: \.self) { mailboxID in
                            MailSearchRemovableChip(
                                label: mailboxName(mailboxID),
                                systemImage: "tray",
                                remove: { removeMailbox(mailboxID) }
                            )
                        }
                    }
                    .padding(.leading, searchChipLeadingInset)
                }
                .scrollIndicators(.hidden)
                .accessibilityLabel("Search scope")
            }

            let tokens = MailSearchPresentation.editableTokens(in: viewModel.query)
            if !tokens.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        Text("Filters")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(MailDesign.secondaryText)
                        ForEach(tokens) { token in
                            MailSearchRemovableChip(
                                label: token.text,
                                systemImage: "line.3.horizontal.decrease.circle",
                                remove: { removeToken(token) }
                            )
                        }
                    }
                    .padding(.leading, searchChipLeadingInset)
                }
                .scrollIndicators(.hidden)
                .accessibilityLabel("Editable search filters")
            }
        }
        .padding(.horizontal, searchContentInset)
        .padding(.top, 20)
        .padding(.bottom, 14)
    }

    private var searchContentInset: CGFloat {
        #if os(iOS)
        16
        #else
        24
        #endif
    }

    private var searchSuggestionInset: CGFloat {
        #if os(iOS)
        16
        #else
        86
        #endif
    }

    private var searchChipLeadingInset: CGFloat {
        #if os(iOS)
        0
        #else
        60
        #endif
    }

    private var accountMenu: some View {
        Menu {
            Button {
                viewModel.scope = MailSearchScopeSelection.reset(viewModel.scope)
                focusGeneration &+= 1
            } label: {
                if MailSearchScopeSelection.isAll(viewModel.scope) {
                    Label("All accounts and mailboxes", systemImage: "checkmark")
                } else {
                    Text("All accounts and mailboxes")
                }
            }

            if !viewModel.accounts.isEmpty {
                Section("Accounts") {
                    ForEach(viewModel.accounts) { account in
                        Button {
                            toggleAccount(account.id)
                            focusGeneration &+= 1
                        } label: {
                            if viewModel.scope.accountIDs.contains(account.id) {
                                Label(account.displayName, systemImage: "checkmark")
                            } else {
                                Text(account.displayName)
                            }
                        }
                        .accessibilityLabel(Text(MailSearchPresentation.accountAccessibilityLabel(account)))
                    }
                }
            }

            if !viewModel.mailboxes.isEmpty {
                Section("Mailboxes") {
                    ForEach(viewModel.mailboxes) { mailbox in
                        Button {
                            toggleMailbox(mailbox.id)
                            focusGeneration &+= 1
                        } label: {
                            if viewModel.scope.mailboxIDs.contains(mailbox.id) {
                                Label(
                                    MailSearchPresentation.mailboxDisplayLabel(
                                        mailbox,
                                        accounts: viewModel.accounts
                                    ),
                                    systemImage: "checkmark"
                                )
                            } else {
                                Text(MailSearchPresentation.mailboxDisplayLabel(
                                    mailbox,
                                    accounts: viewModel.accounts
                                ))
                            }
                        }
                        .accessibilityLabel(Text(MailSearchPresentation.mailboxAccessibilityLabel(
                            mailbox,
                            accounts: viewModel.accounts
                        )))
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text("Scope")
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .accessibilityHidden(true)
            }
            .font(.callout.weight(.semibold))
            .foregroundStyle(MailDesign.primaryText)
            .padding(.horizontal, 9)
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .help("Choose accounts and mailboxes to search")
        .accessibilityLabel("Search scope")
        .accessibilityValue(scopeLabel)
    }

    private var showsSearchFocus: Bool {
        searchIsFocused || forceSearchFocusAppearance
    }

    private var scopeLabel: String {
        MailSearchPresentation.scopeAccessibilityValue(
            viewModel.scope,
            accounts: viewModel.accounts,
            mailboxes: viewModel.mailboxes
        )
    }

    private var orderedSuggestions: [MailSearchSuggestionSection] {
        MailSearchPresentation.orderedSuggestionSections(viewModel.suggestions)
    }

    private var suggestionIDs: [String] {
        orderedSuggestions.flatMap { $0.items.map(\.id) }
    }

    private var showsSuggestionPopover: Bool {
        showsSearchFocus && !suggestionsDismissed && !suggestionIDs.isEmpty
    }

    @ViewBuilder
    private var workspaceContent: some View {
        switch viewModel.state {
        case .initial:
            MailSearchTips(insert: requestInsertion, askMail: askMail)
        case .suggesting:
            MailSearchTips(insert: requestInsertion, askMail: nil)
        case .searching(let retainingResults):
            if retainingResults {
                resultList
            } else {
                MailSearchCenteredState {
                    ProgressView("Searching mail")
                        .controlSize(.regular)
                }
            }
        case .results:
            resultList
        case .rebuilding:
            MailSearchCenteredState {
                MailSearchActionState(
                    title: "Search index is rebuilding",
                    detail: "Mail is retained. Search will be available after the local index is ready.",
                    systemImage: "arrow.triangle.2.circlepath",
                    primaryTitle: "Retry",
                    primaryAction: viewModel.retry,
                    secondaryTitle: rebuildIndex == nil ? nil : "Rebuild Index",
                    secondaryAction: rebuildIndex
                )
            }
        case .empty:
            MailSearchEmptyState(insert: requestInsertion, askMail: askMail)
        case .invalid(let message):
            MailSearchCenteredState {
                MailSearchInlineError(message: message)
            }
        case .unavailable:
            if viewModel.rows.isEmpty {
                MailSearchCenteredState {
                    MailSearchActionState(
                        title: "Search is unavailable",
                        detail: "Your query is still here. Retry or rebuild the local index; mail is retained.",
                        systemImage: "exclamationmark.magnifyingglass",
                        primaryTitle: "Retry",
                        primaryAction: viewModel.retry,
                        secondaryTitle: rebuildIndex == nil ? nil : "Rebuild Index",
                        secondaryAction: rebuildIndex
                    )
                }
            } else {
                VStack(spacing: 12) {
                    resultList
                    MailSearchPageError(retry: viewModel.retry)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 16)
                }
            }
        }
    }

    private var resultList: some View {
        let hasMore: Bool = {
            if case .results(let value) = viewModel.state { return value }
            return false
        }()
        return MailSearchResultList(
            results: viewModel.rows,
            countPresentation: .loaded(viewModel.rows.count),
            isReplacing: MailSearchPresentation.showsRetainedLoading(in: viewModel.state),
            hasMore: hasMore,
            showsAccount: !MailSearchEffectiveScope.isExactlyOneAccount(
                viewModel.scope,
                mailboxes: viewModel.mailboxes
            ),
            accountDisplayNames: Dictionary(
                viewModel.accounts.map { ($0.id, $0.displayName) },
                uniquingKeysWith: { current, _ in current }
            ),
            mailboxDisplayNames: Dictionary(
                viewModel.mailboxes.map { ($0.id, $0.displayName) },
                uniquingKeysWith: { current, _ in current }
            ),
            selection: $viewModel.selectedHitID,
            loadMore: viewModel.loadNextPageIfNeeded,
            open: { openResult(viewModel.messageToOpen(for: $0)) },
            submit: { submit(origin: .results) }
        )
    }

    private func requestInsertion(_ insertion: String) {
        requestInsertion(insertion, replacementRange: nil)
    }

    private func requestInsertion(
        _ insertion: String,
        replacementRange: MailSearchTextRange?
    ) {
        insertionRequest = MailSearchInsertionRequest(
            id: UUID(),
            text: insertion,
            replacementRange: replacementRange
        )
        focusGeneration &+= 1
    }

    private var searchFieldReturnOrigin: MailSearchReturnOrigin {
        #if os(iOS)
        .queryField
        #else
        .results
        #endif
    }

    private func submit(origin: MailSearchReturnOrigin) {
        switch MailSearchPresentation.actionForReturn(
            sections: orderedSuggestions,
            selectedID: selectedSuggestionID,
            isVisible: showsSuggestionPopover,
            hit: viewModel.hitToOpenOnReturn(),
            origin: origin
        ) {
        case .applySuggestion(let suggestion):
            applySuggestion(suggestion)
        case .openResult(let hit):
            openResult(viewModel.messageToOpen(for: hit))
        case .submitSearch:
            viewModel.submit()
        }
    }

    private func handleKeyboardCommand(_ command: MailSearchKeyboardCommand) -> Bool {
        if showsSuggestionPopover {
            switch command {
            case .up, .down, .cycleForward, .cycleBackward:
                selectedSuggestionID = MailSearchSuggestionNavigator.move(
                    from: selectedSuggestionID,
                    command: command,
                    ids: suggestionIDs
                )
                return true
            case .dismiss:
                suggestionsDismissed = true
                selectedSuggestionID = nil
                return true
            }
        }
        switch command {
        case .up:
            return viewModel.moveResultSelection(.up)
        case .down:
            return viewModel.moveResultSelection(.down)
        case .cycleForward, .cycleBackward, .dismiss:
            return false
        }
    }

    private func applySuggestion(_ suggestion: MailSearchSuggestionItem) {
        guard let current = viewModel.validatedSuggestionForApplication(suggestion) else {
            selectedSuggestionID = nil
            return
        }
        requestInsertion(current.insertion, replacementRange: current.replacementRange)
        selectedSuggestionID = nil
        suggestionsDismissed = true
    }

    private func clearSearch() {
        viewModel.query = ""
        selectedSuggestionID = nil
        suggestionsDismissed = true
        focusGeneration &+= 1
    }

    private func toggleAccount(_ accountID: AccountID) {
        viewModel.scope = MailSearchScopeSelection.togglingAccount(
            accountID,
            in: viewModel.scope
        )
    }

    private func toggleMailbox(_ mailboxID: MailboxID) {
        viewModel.scope = MailSearchScopeSelection.togglingMailbox(
            mailboxID,
            in: viewModel.scope
        )
    }

    private func removeAccount(_ accountID: AccountID) {
        viewModel.scope = MailSearchSelectionScope(
            accountIDs: viewModel.scope.accountIDs.filter { $0 != accountID },
            mailboxIDs: viewModel.scope.mailboxIDs
        )
        focusGeneration &+= 1
    }

    private func removeMailbox(_ mailboxID: MailboxID) {
        viewModel.scope = MailSearchSelectionScope(
            accountIDs: viewModel.scope.accountIDs,
            mailboxIDs: viewModel.scope.mailboxIDs.filter { $0 != mailboxID }
        )
        focusGeneration &+= 1
    }

    private func removeToken(_ token: MailSearchEditableToken) {
        requestInsertion("", replacementRange: token.sourceRange)
    }

    private func accountName(_ accountID: AccountID) -> String {
        viewModel.accounts.first(where: { $0.id == accountID })?.displayName
            ?? accountID.rawValue
    }

    private func mailboxName(_ mailboxID: MailboxID) -> String {
        guard let mailbox = viewModel.mailboxes.first(where: { $0.id == mailboxID }) else {
            return mailboxID.rawValue
        }
        return MailSearchPresentation.mailboxDisplayLabel(
            mailbox,
            accounts: viewModel.accounts
        )
    }
}

private struct MailSearchCenteredState<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(32)
    }
}

private struct MailSearchRemovableChip: View {
    let label: String
    let systemImage: String
    let remove: () -> Void

    var body: some View {
        Button(action: remove) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .accessibilityHidden(true)
                Text(label)
                    .lineLimit(1)
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .accessibilityHidden(true)
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(MailDesign.selectionSoft, in: Capsule())
            .overlay(Capsule().stroke(MailDesign.strokeStrong))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove \(label)")
    }
}

private struct MailSearchSuggestionPopover: View {
    let sections: [MailSearchSuggestionSection]
    let selectedID: String?
    let select: (MailSearchSuggestionItem) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(sections, id: \.kind.rawValue) { section in
                    Text(title(for: section.kind))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(MailDesign.secondaryText)
                        .padding(.horizontal, 12)
                        .padding(.top, 9)
                        .accessibilityAddTraits(.isHeader)

                    ForEach(section.items) { item in
                        Button { select(item) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: symbol(for: section.kind))
                                    .frame(width: 20)
                                    .foregroundStyle(MailDesign.accentBlue)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title)
                                        .font(.callout.weight(.semibold))
                                        .foregroundStyle(MailDesign.primaryText)
                                        .lineLimit(1)
                                    Text(item.detail)
                                        .font(.caption)
                                        .foregroundStyle(MailDesign.secondaryText)
                                        .lineLimit(1)
                                }
                                Spacer()
                                #if os(macOS)
                                if selectedID == item.id {
                                    Text("Return")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(MailDesign.secondaryText)
                                }
                                #endif
                            }
                            .padding(.horizontal, 12)
                            .frame(minHeight: 44)
                            .background(
                                selectedID == item.id ? MailDesign.selectionSoft : Color.clear,
                                in: RoundedRectangle(cornerRadius: MailDesign.Radius.control)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(item.title), \(item.detail)")
                        .accessibilityAddTraits(selectedID == item.id ? .isSelected : [])
                    }
                }
            }
            .padding(8)
        }
        #if os(iOS)
        // Keep live suggestions from swallowing most of the result area on
        // iPhone while the keyboard is open. The list remains scrollable when
        // there are more matches than fit in this compact panel.
        .frame(maxWidth: 720, maxHeight: 144)
        #else
        .frame(maxWidth: 720, maxHeight: 390)
        #endif
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: MailDesign.Radius.panel))
        .overlay(RoundedRectangle(cornerRadius: MailDesign.Radius.panel).stroke(MailDesign.strokeStrong))
        .shadow(color: .black.opacity(0.18), radius: 22, y: 12)
        .accessibilityLabel("Search suggestions")
    }

    private func title(for kind: MailSearchSuggestionKind) -> String {
        switch kind {
        case .recent: "Recent"
        case .people: "People"
        case .fields: "Fields"
        case .filters: "Filters"
        }
    }

    private func symbol(for kind: MailSearchSuggestionKind) -> String {
        switch kind {
        case .recent: "clock.arrow.circlepath"
        case .people: "person.crop.circle"
        case .fields: "textformat"
        case .filters: "line.3.horizontal.decrease.circle"
        }
    }
}

private struct MailSearchActionState: View {
    let title: String
    let detail: String
    let systemImage: String
    let primaryTitle: String
    let primaryAction: () -> Void
    let secondaryTitle: String?
    let secondaryAction: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(detail)
        } actions: {
            HStack {
                Button(primaryTitle, action: primaryAction)
                if let secondaryTitle, let secondaryAction {
                    Button(secondaryTitle, action: secondaryAction)
                }
            }
        }
    }
}

private struct MailSearchEmptyState: View {
    let insert: (String) -> Void
    let askMail: (() -> Void)?

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(MailDesign.secondaryText)
                    .accessibilityHidden(true)
                Text("No matching emails")
                    .font(.title2.weight(.semibold))
                Text("Change a clause or try a narrower field from the shared search syntax.")
                    .font(.callout)
                    .foregroundStyle(MailDesign.secondaryText)
                    .multilineTextAlignment(.center)
                MailSearchExampleButtons(insert: insert)
                if let askMail {
                    Button("Try Ask Mail", systemImage: "sparkles", action: askMail)
                        .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: 700)
            .padding(40)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct MailSearchExampleButtons: View {
    let insert: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Try a field or filter")
                .font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 10)], spacing: 10) {
                ForEach(MailSearchPresentation.examples.prefix(8), id: \.insertion) { tip in
                    Button { insert(tip.insertion) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: tip.systemImage)
                                .foregroundStyle(tip.tint)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tip.insertion)
                                    .font(.callout.weight(.semibold))
                                    .foregroundStyle(MailDesign.primaryText)
                                Text(tip.description)
                                    .font(.caption)
                                    .foregroundStyle(MailDesign.secondaryText)
                                    #if os(macOS)
                                    .lineLimit(1)
                                    #endif
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 11)
                        .frame(minHeight: 48)
                        .background(MailDesign.control.opacity(0.55), in: RoundedRectangle(cornerRadius: MailDesign.Radius.control))
                        .overlay(RoundedRectangle(cornerRadius: MailDesign.Radius.control).stroke(MailDesign.stroke))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(MailSearchPresentation.tipAccessibilityLabel(tip))
                    .accessibilityHint(tip.description)
                }
            }
        }
    }
}

struct MailSearchTips: View {
    let insert: (String) -> Void
    let askMail: (() -> Void)?

    var body: some View {
        GeometryReader { proxy in
            let columnCount = Self.tipColumnCount(for: proxy.size.width)
            let columns = MailSearchPresentation.tipColumns(
                MailSearchTip.reference,
                count: columnCount
            )
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 34) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Search your mail")
                            .font(.title2.weight(.semibold))
                        Text("Use plain words, phrases, or local field filters. Conversations are grouped by default.")
                            .font(.callout)
                            .foregroundStyle(MailDesign.secondaryText)
                    }

                    HStack(alignment: .top, spacing: 34) {
                        ForEach(columns.indices, id: \.self) { columnIndex in
                            VStack(alignment: .leading, spacing: 18) {
                                ForEach(columns[columnIndex].indices, id: \.self) { tipIndex in
                                    let tip = columns[columnIndex][tipIndex]
                                    MailSearchTipButton(tip: tip) {
                                        insert(tip.insertion)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    }

                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "person.2.badge.gearshape")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(MailDesign.accentTeal)
                            .frame(width: 20)
                            .accessibilityHidden(true)
                        Text("Combine keywords for better results. For example, from:alex has:attachment")
                            .font(.callout)
                            .foregroundStyle(MailDesign.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)

                    if let askMail {
                        askMailLayout {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Need a synthesized answer?")
                                    .font(.callout.weight(.semibold))
                                Text("Ask Mail is separate from deterministic local search.")
                                    .font(.caption)
                                    .foregroundStyle(MailDesign.secondaryText)
                            }
                            #if os(macOS)
                            Spacer()
                            #endif
                            Button("Try Ask Mail", systemImage: "sparkles", action: askMail)
                                .buttonStyle(.borderedProminent)
                        }
                        .padding(16)
                        .background(MailDesign.panel, in: RoundedRectangle(cornerRadius: MailDesign.Radius.panel))
                        .overlay(RoundedRectangle(cornerRadius: MailDesign.Radius.panel).stroke(MailDesign.stroke))
                    }
                }
                .padding(.horizontal, contentInset)
                .padding(.top, 30)
                .padding(.bottom, 48)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    static func tipColumnCount(for width: CGFloat) -> Int {
        #if os(iOS)
        1
        #else
        width >= 1_100 ? 4 : 2
        #endif
    }

    private var contentInset: CGFloat {
        #if os(iOS)
        16
        #else
        84
        #endif
    }

    private var askMailLayout: AnyLayout {
        #if os(iOS)
        AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
        #else
        AnyLayout(HStackLayout())
        #endif
    }
}

private struct MailSearchTipButton: View {
    let tip: MailSearchTip
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: tip.systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tip.tint)
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(tip.insertion)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(MailDesign.primaryText)
                    Text(tip.description)
                        .font(.callout)
                        .foregroundStyle(MailDesign.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(MailSearchPresentation.tipAccessibilityLabel(tip)))
        .accessibilityHint(tip.description)
    }
}

struct MailSearchResultList: View {
    let results: [MailSearchHit]
    let countPresentation: MailSearchResultCountPresentation
    let isReplacing: Bool
    let hasMore: Bool
    let showsAccount: Bool
    let accountDisplayNames: [AccountID: String]
    let mailboxDisplayNames: [MailboxID: String]
    @Binding var selection: String?
    let loadMore: (String) -> Void
    let open: (MailSearchHit) -> Void
    let submit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(countPresentation.label)
                    .font(.headline)
                if isReplacing {
                    ProgressView()
                        .controlSize(.small)
                    Text("Updating results")
                        .font(.caption)
                        .foregroundStyle(MailDesign.secondaryText)
                        .accessibilityLabel("Updating search results. Previous results remain visible.")
                }
                Spacer()
                #if os(macOS)
                Text("Return opens selected email")
                    .font(.caption)
                    .foregroundStyle(MailDesign.secondaryText)
                #endif
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 12)

            List(selection: $selection) {
                ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                    MailSearchResultRow(
                        result: result,
                        showsAccount: showsAccount,
                        accountDisplayNames: accountDisplayNames,
                        mailboxDisplayNames: mailboxDisplayNames,
                        selected: selection == result.id,
                        position: index + 1,
                        loadedCount: results.count
                    )
                    .tag(result.id)
                    .listRowInsets(EdgeInsets(top: 3, leading: 18, bottom: 3, trailing: 18))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .onTapGesture(count: Self.openTapCount) { open(result) }
                    #if os(iOS)
                    .accessibilityAction { open(result) }
                    #endif
                    .onAppear { loadMore(result.id) }
                }

                if hasMore || countPresentation.showsLoadingFooter {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading more results")
                            .font(.caption)
                            .foregroundStyle(MailDesign.secondaryText)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .onAppear {
                        if let last = results.last { loadMore(last.id) }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .onKeyPress(.return) {
                submit()
                return .handled
            }
        }
    }

    private static var openTapCount: Int {
        #if os(iOS)
        1
        #else
        2
        #endif
    }
}

private struct MailSearchResultRow: View {
    let result: MailSearchHit
    let showsAccount: Bool
    let accountDisplayNames: [AccountID: String]
    let mailboxDisplayNames: [MailboxID: String]
    let selected: Bool
    let position: Int
    let loadedCount: Int

    var body: some View {
        Group {
            switch result {
            case .conversation(let conversation):
                conversationRow(conversation)
            case .message(let message):
                messageRow(message)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? MailDesign.selectionSoft : Color.clear, in: RoundedRectangle(cornerRadius: MailDesign.Radius.row))
        .overlay {
            RoundedRectangle(cornerRadius: MailDesign.Radius.row)
                .stroke(selected ? MailDesign.strokeStrong : MailDesign.stroke.opacity(0.42))
        }
        .contentShape(RoundedRectangle(cornerRadius: MailDesign.Radius.row))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility.label)
        .accessibilityValue(accessibility.value)
        #if os(iOS)
        .accessibilityHint("Result \(position) of \(loadedCount) loaded. Opens this email.")
        #else
        .accessibilityHint("Result \(position) of \(loadedCount) loaded. Return opens this email.")
        #endif
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func conversationRow(_ hit: MailConversationSearchHit) -> some View {
        // The best match's sender, as the iPhone list uses (MobileSearchScreen); `participants`
        // is sorted and mixes in recipients, so it is only the fallback for conversations that
        // don't carry the sender. Ledger Task 19.
        let avatarAddress = hit.bestMatchSender?.rawValue ?? hit.participants.first ?? "Conversation"
        let avatarName = hit.bestMatchSenderDisplayName ?? hit.participants.first
        return HStack(spacing: 14) {
            unreadIndicator(hit.unreadMessageCount > 0)
            MailSenderAvatar(
                sender: avatarAddress,
                displayName: avatarName,
                size: 40
            )
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(hit.participants.isEmpty ? "Conversation" : hit.participants.joined(separator: ", "))
                        .font(.callout.weight(hit.unreadMessageCount > 0 ? .semibold : .medium))
                        .lineLimit(1)
                    accountBadge
                    Spacer(minLength: 12)
                    dateLabel(hit.latestActivity)
                }
                Text(hit.subject.isEmpty ? "(No subject)" : hit.subject)
                    .font(.callout.weight(hit.unreadMessageCount > 0 ? .semibold : .regular))
                    .lineLimit(1)
                MailSearchHighlightedText(snippet: hit.snippet)
                    .font(.callout)
                    .foregroundStyle(MailDesign.secondaryText)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    MailSearchMetadataBadge(
                        label: "\(hit.matchingMessageCount) \(hit.matchingMessageCount == 1 ? "match" : "matches")",
                        systemImage: "magnifyingglass"
                    )
                    MailSearchMetadataBadge(
                        label: "\(hit.totalMessageCount) \(hit.totalMessageCount == 1 ? "message" : "messages")",
                        systemImage: "bubble.left.and.bubble.right"
                    )
                    if hit.unreadMessageCount > 0 {
                        MailSearchMetadataBadge(label: "\(hit.unreadMessageCount) unread", systemImage: "envelope.badge")
                    }
                    attachmentBadges(attachments: hit.hasAttachments, documents: hit.hasDocuments)
                }
            }
        }
    }

    private func messageRow(_ hit: MailMessageSearchHit) -> some View {
        HStack(spacing: 14) {
            unreadIndicator(hit.isUnread)
            MailSenderAvatar(
                sender: hit.sender.rawValue,
                displayName: hit.senderDisplayName,
                size: 40
            )
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(messageSenderName(hit))
                        .font(.callout.weight(hit.isUnread ? .semibold : .medium))
                        .lineLimit(1)
                    if !hit.recipients.isEmpty {
                        Text("to \(hit.recipients.map(\.rawValue).joined(separator: ", "))")
                            .font(.caption)
                            .foregroundStyle(MailDesign.secondaryText)
                            .lineLimit(1)
                    }
                    accountBadge
                    Spacer(minLength: 12)
                    dateLabel(hit.sentAt)
                }
                Text(hit.subject.isEmpty ? "(No subject)" : hit.subject)
                    .font(.callout.weight(hit.isUnread ? .semibold : .regular))
                    .lineLimit(1)
                MailSearchHighlightedText(snippet: hit.snippet)
                    .font(.callout)
                    .foregroundStyle(MailDesign.secondaryText)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    MailSearchMetadataBadge(label: hit.isUnread ? "Unread" : "Read", systemImage: hit.isUnread ? "envelope.badge" : "envelope.open")
                    if hit.isFlagged {
                        MailSearchMetadataBadge(label: "Flagged", systemImage: "flag.fill")
                    }
                    if hit.isDelegated {
                        MailSearchMetadataBadge(label: "Delegated", systemImage: "arrow.right.circle")
                    }
                    attachmentBadges(attachments: hit.hasAttachments, documents: hit.hasDocuments)
                }
            }
        }
    }

    private func unreadIndicator(_ unread: Bool) -> some View {
        Circle()
            .fill(unread ? MailDesign.unread : Color.clear)
            .frame(width: 7, height: 7)
            .overlay(Circle().stroke(unread ? Color.clear : MailDesign.strokeStrong))
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var accountBadge: some View {
        if showsAccount {
            Text(accountDisplayName)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(selected ? MailDesign.primaryText : MailDesign.accentBlue)
                .padding(.horizontal, 6)
                .frame(height: 18)
                .background(MailDesign.selectionSoft, in: Capsule())
        }
    }

    @ViewBuilder
    private func dateLabel(_ date: Date?) -> some View {
        if let date {
            Text(date, format: .dateTime.day().month(.abbreviated).year())
                .font(.caption)
                .foregroundStyle(MailDesign.secondaryText)
        }
    }

    @ViewBuilder
    private func attachmentBadges(attachments: Bool, documents: Bool) -> some View {
        if attachments {
            MailSearchMetadataBadge(label: "Attachment", systemImage: "paperclip")
        }
        if documents {
            MailSearchMetadataBadge(label: "Document", systemImage: "doc.text")
        }
    }

    private func messageSenderName(_ hit: MailMessageSearchHit) -> String {
        let value = hit.senderDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value! : hit.sender.rawValue
    }

    private var accessibility: MailSearchResultAccessibility {
        MailSearchPresentation.resultAccessibility(
            for: result,
            showsAccount: showsAccount,
            accountDisplayNames: accountDisplayNames,
            mailboxDisplayNames: mailboxDisplayNames
        )
    }

    private var accountDisplayName: String {
        MailSearchPresentation.resultAccountDisplayName(
            accountID,
            accountDisplayNames: accountDisplayNames
        )
    }

    private var accountID: AccountID {
        switch result {
        case .message(let hit): hit.accountID
        case .conversation(let hit): hit.accountID
        }
    }
}

private struct MailSearchHighlightedText: View {
    let snippet: MailSearchSnippet

    var body: some View {
        Text(attributedText)
            .accessibilityLabel(snippet.text)
    }

    private var attributedText: AttributedString {
        MailSearchPresentation.highlightedRuns(for: snippet).reduce(into: AttributedString()) {
            value, run in
            var segment = AttributedString(run.text)
            if run.isHighlighted {
                segment.inlinePresentationIntent = .stronglyEmphasized
            }
            value.append(segment)
        }
    }
}

private struct MailSearchMetadataBadge: View {
    let label: String
    let systemImage: String

    var body: some View {
        Label(label, systemImage: systemImage)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(MailDesign.secondaryText)
            .labelStyle(.titleAndIcon)
    }
}

struct MailSearchInlineError: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text("Check your search")
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(MailDesign.secondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(22)
        .background(MailDesign.panel, in: RoundedRectangle(cornerRadius: MailDesign.Radius.panel))
        .overlay(RoundedRectangle(cornerRadius: MailDesign.Radius.panel).stroke(MailDesign.stroke))
        .accessibilityElement(children: .combine)
    }
}

private struct MailSearchPageError: View {
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text("More results couldn’t be loaded.")
                .font(.callout)
            Spacer()
            Button("Retry", action: retry)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 46)
        .background(MailDesign.panel, in: RoundedRectangle(cornerRadius: MailDesign.Radius.control))
        .overlay(RoundedRectangle(cornerRadius: MailDesign.Radius.control).stroke(MailDesign.stroke))
        .accessibilityElement(children: .contain)
    }
}
