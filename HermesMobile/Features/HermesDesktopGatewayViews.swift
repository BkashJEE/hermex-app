import SwiftUI

struct HermesDesktopGatewaySetupView: View {
    @Bindable var account: HermesDesktopGatewayAccount
    @Environment(\.dismiss) private var dismiss
    @State private var serverURLString = ""
    @State private var token = ""

    private var canConnect: Bool {
        !serverURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !account.isConnecting
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://desktop.your-tailnet.ts.net", text: $serverURLString)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .textContentType(.URL)

                    SecureField("Gateway token (optional)", text: $token)
                        .textContentType(.password)
                } header: {
                    Text("Hermes Desktop gateway")
                } footer: {
                    Text("Enter the HTTPS or Tailscale address that reaches Hermes Desktop. The app discovers the served token when possible; paste it only as a fallback. It is stored only in this iPhone's Keychain.")
                }

                Section {
                    LabeledContent("Transport", value: "Native WebSocket")
                    LabeledContent("Endpoint", value: "/api/ws")
                    LabeledContent("Agent hosting", value: "Hermes Desktop")
                } header: {
                    Text("Connection")
                }

                if let error = account.lastErrorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        Task {
                            if await account.configure(serverURLString: serverURLString, token: token) {
                                dismiss()
                            }
                        }
                    } label: {
                        HStack {
                            if account.isConnecting {
                                ProgressView()
                            }
                            Text(account.isConnecting ? "Verifying gateway…" : "Connect to Hermes Desktop")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(!canConnect)
                }
            }
            .navigationTitle("Connect")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(account.isConnecting)
    }
}

private struct HermesDesktopConversationRoute: Hashable {
    let profileName: String
    let profileDisplayName: String
    let storedSessionID: String?
    let title: String?
}

private enum HermesGatewayRunSheet: String, Identifiable {
    case approvals
    case memory
    case preview
    case skills

    var id: String { rawValue }
}

struct HermesDesktopGatewayRootView: View {
    let configuration: HermesDesktopGatewayConfiguration
    let onForget: () -> Void

    @State private var client: HermesDesktopGatewayClient
    @State private var path: [HermesDesktopConversationRoute] = []
    @AppStorage(HeaderLogoColor.storageKey) private var accentColorHex = HeaderLogoColor.defaultHex

    init(configuration: HermesDesktopGatewayConfiguration, onForget: @escaping () -> Void) {
        self.configuration = configuration
        self.onForget = onForget
        _client = State(initialValue: HermesDesktopGatewayClient(configuration: configuration))
    }

    var body: some View {
        NavigationStack(path: $path) {
            HermesDesktopGatewayRosterView(
                client: client,
                serverURL: configuration.serverURL,
                onOpenProfile: openProfile,
                onForget: onForget
            )
            .navigationDestination(for: HermesDesktopConversationRoute.self) { route in
                HermesDesktopGatewayChatView(
                    client: client,
                    profileName: route.profileName,
                    profileDisplayName: route.profileDisplayName,
                    storedSessionID: route.storedSessionID,
                    initialTitle: route.title
                )
            }
        }
        .tint(HeaderLogoColor.color(for: accentColorHex))
        .onDisappear {
            client.disconnect()
        }
    }

    private func openProfile(_ profile: HermesDesktopGatewayProfile, newRun: Bool) {
        let session = newRun ? nil : profile.lastSession
        path.append(
            HermesDesktopConversationRoute(
                profileName: profile.name,
                profileDisplayName: profile.displayName,
                storedSessionID: session?.resolvedID ?? session?.id,
                title: session?.title
            )
        )
    }
}

private struct HermesDesktopGatewayRosterView: View {
    @Bindable var client: HermesDesktopGatewayClient
    let serverURL: URL
    let onOpenProfile: (HermesDesktopGatewayProfile, Bool) -> Void
    let onForget: () -> Void

    @State private var profiles: [HermesDesktopGatewayProfile] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showsNewRunPicker = false
    @State private var showsAppearance = false
    @State private var eventObserverID: UUID?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Color(.systemBackground).ignoresSafeArea()

            Group {
                if isLoading && profiles.isEmpty {
                    ProgressView("Loading Hermes agents…")
                } else if let errorMessage, profiles.isEmpty {
                    ContentUnavailableView {
                        Label("Gateway unavailable", systemImage: "network.slash")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Retry") { Task { await connectAndLoad() } }
                    }
                } else {
                    profileList
                }
            }

            if !profiles.isEmpty {
                Button {
                    showsNewRunPicker = true
                } label: {
                    Label("New run", systemImage: "plus")
                        .font(.headline)
                        .padding(.horizontal, 18)
                        .frame(minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .clipShape(Capsule())
                .padding(20)
                .accessibilityHint("Choose an agent and start a new Hermes session.")
            }
        }
        .navigationTitle("Hermes")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                HermesGatewayConnectionLabel(state: client.state)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        Task { await connectAndLoad() }
                    } label: {
                        Label("Refresh agents", systemImage: "arrow.clockwise")
                    }
                    Button {
                        showsAppearance = true
                    } label: {
                        Label("Appearance", systemImage: "paintpalette")
                    }
                    Button(role: .destructive) {
                        client.disconnect()
                        onForget()
                    } label: {
                        Label("Forget gateway", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .frame(width: 44, height: 44)
                }
            }
        }
        .confirmationDialog("Start a new run", isPresented: $showsNewRunPicker, titleVisibility: .visible) {
            ForEach(profiles) { profile in
                Button(profile.displayName) { onOpenProfile(profile, true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Choose which Hermes agent should own the new session.")
        }
        .sheet(isPresented: $showsAppearance) {
            HermesGatewayAppearanceSheet()
        }
        .task {
            installEventObserverIfNeeded()
            await connectAndLoad()
        }
        .onDisappear {
            if let eventObserverID {
                client.removeEventObserver(eventObserverID)
                self.eventObserverID = nil
            }
        }
    }

    private var profileList: some View {
        List {
            if let errorMessage {
                Section {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Button("Retry") { Task { await connectAndLoad() } }
                            .font(.footnote.weight(.semibold))
                    }
                }
            }

            Section("Agents") {
                ForEach(profiles) { profile in
                    Button {
                        onOpenProfile(profile, false)
                    } label: {
                        HermesGatewayProfileRow(profile: profile)
                    }
                    .buttonStyle(.plain)
                }
            }

            Section {
                LabeledContent("Gateway", value: serverURL.host ?? serverURL.absoluteString)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.plain)
        .refreshable { await connectAndLoad() }
    }

    private func installEventObserverIfNeeded() {
        guard eventObserverID == nil else { return }
        eventObserverID = client.observeEvents { event in
            guard ["sessions.changed", "session.title", "message.complete", "approval.request"].contains(event.type) else {
                return
            }
            Task { await loadProfiles() }
        }
    }

    private func connectAndLoad() async {
        isLoading = profiles.isEmpty
        errorMessage = nil
        do {
            try await client.connect()
            await loadProfiles()
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    private func loadProfiles() async {
        do {
            profiles = try await client.listProfiles(includeSessions: true)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

private struct HermesGatewayAppearanceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppTheme.storageKey) private var appThemeRawValue = AppTheme.system.rawValue
    @AppStorage(HeaderLogoColor.storageKey) private var colorHex = HeaderLogoColor.defaultHex

    private var customColor: Binding<Color> {
        Binding(
            get: { HeaderLogoColor.color(for: colorHex) },
            set: { color in
                if let hex = HeaderLogoColor.hexString(from: color) {
                    colorHex = hex
                }
            }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Mode") {
                    Picker("Theme", selection: $appThemeRawValue) {
                        ForEach(AppTheme.allCases) { theme in
                            Text(theme.title).tag(theme.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Accent color") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 44))], spacing: 12) {
                        ForEach(HeaderLogoColor.presets) { preset in
                            Button {
                                colorHex = preset.hex
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(preset.color)
                                        .frame(width: 44, height: 44)
                                        .overlay(Circle().stroke(.primary.opacity(0.18), lineWidth: 1))
                                    if HeaderLogoColor.normalizedHex(colorHex) == preset.hex {
                                        Image(systemName: "checkmark")
                                            .font(.caption.bold())
                                            .foregroundStyle(preset.hex == "#FFFFFF" ? .black : .white)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(preset.name)
                        }
                    }

                    ColorPicker("Custom color", selection: customColor, supportsOpacity: false)

                    LabeledContent(
                        "Selected",
                        value: HeaderLogoColor.normalizedHex(colorHex) ?? HeaderLogoColor.defaultHex
                    )
                    .font(.footnote.monospaced())
                }
            }
            .navigationTitle("Appearance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct HermesGatewayProfileRow: View {
    let profile: HermesDesktopGatewayProfile

    private var latestSession: HermesDesktopGatewaySessionSummary? { profile.lastSession }

    private var isWorking: Bool {
        guard let lastActive = profile.workerSession?.lastActive else { return false }
        return Date().timeIntervalSince1970 - lastActive < 300
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.16))
                Text(initials)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(profile.displayName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(profile.name)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.secondary.opacity(0.12), in: Capsule())

                    Spacer(minLength: 4)

                    if isWorking {
                        Label("Working", systemImage: "circle.fill")
                            .labelStyle(.titleAndIcon)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.green)
                    } else if let time = latestSession?.lastActive ?? latestSession?.startedAt {
                        Text(relativeTime(time))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                Text(lastLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .frame(minHeight: 58)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(profile.displayName), \(lastLine)")
    }

    private var initials: String {
        profile.displayName
            .split(separator: " ")
            .prefix(2)
            .compactMap(\.first)
            .map(String.init)
            .joined()
            .uppercased()
    }

    private var lastLine: String {
        if let preview = latestSession?.preview.trimmingCharacters(in: .whitespacesAndNewlines), !preview.isEmpty {
            return preview
        }
        let description = profile.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !description.isEmpty {
            return description
        }
        if let model = profile.model, !model.isEmpty {
            return "Ready · \(model)"
        }
        return "Ready for a new run"
    }

    private func relativeTime(_ timestamp: Double) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: Date(timeIntervalSince1970: timestamp), relativeTo: Date())
    }
}

private struct HermesDesktopGatewayChatView: View {
    @Bindable var client: HermesDesktopGatewayClient
    @State private var model: HermesDesktopGatewayChatViewModel
    @State private var activeSheet: HermesGatewayRunSheet?

    init(
        client: HermesDesktopGatewayClient,
        profileName: String,
        profileDisplayName: String,
        storedSessionID: String?,
        initialTitle: String?
    ) {
        self.client = client
        _model = State(
            initialValue: HermesDesktopGatewayChatViewModel(
                client: client,
                profileName: profileName,
                profileDisplayName: profileDisplayName,
                storedSessionID: storedSessionID,
                initialTitle: initialTitle
            )
        )
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if model.isLoading {
                        ProgressView("Opening \(model.profileDisplayName)…")
                            .frame(maxWidth: .infinity)
                            .padding(.top, 80)
                    }

                    ForEach(model.messages) { message in
                        HermesGatewayMessageRow(message: message)
                            .id(message.id)
                    }

                    if let tool = model.activeTool {
                        HermesGatewayToolRow(tool: tool)
                            .id("active-tool")
                    }

                    if let error = model.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .padding(.vertical, 8)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: model.messages.count) {
                scrollToBottom(proxy)
            }
            .onChange(of: model.messages.last?.content) {
                scrollToBottom(proxy)
            }
        }
        .background(Color(.systemBackground))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(model.title)
                        .font(.headline)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Text(model.modelName ?? model.profileName)
                        Text("·")
                        HermesGatewayConnectionLabel(state: client.state, compact: true)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if model.pendingApproval != nil {
                        Button {
                            activeSheet = .approvals
                        } label: {
                            Label("Approval", systemImage: "exclamationmark.shield")
                        }
                    }
                    if model.previewText != nil {
                        Button {
                            activeSheet = .preview
                        } label: {
                            Label("Preview", systemImage: "doc.text.magnifyingglass")
                        }
                    }
                    Button {
                        activeSheet = .skills
                    } label: {
                        Label("Skills", systemImage: "sparkles")
                    }
                    Button {
                        activeSheet = .memory
                    } label: {
                        Label("Memory", systemImage: "brain.head.profile")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Run details")
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .approvals:
                HermesGatewayApprovalSheet(
                    approval: model.pendingApproval,
                    isResponding: model.isRespondingToApproval,
                    onRespond: { choice in Task { await model.respondToApproval(choice: choice) } }
                )
            case .preview:
                HermesGatewayPreviewSheet(text: model.previewText ?? "No preview is available.")
            case .skills:
                HermesGatewaySkillsSheet(client: client, profileName: model.profileName)
            case .memory:
                HermesGatewayMemorySheet(client: client)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 8) {
                if let approval = model.pendingApproval {
                    HermesGatewayApprovalCard(
                        approval: approval,
                        isResponding: model.isRespondingToApproval,
                        onRespond: { choice in Task { await model.respondToApproval(choice: choice) } }
                    )
                }

                if let queuedText = model.queuedText {
                    HermesGatewayQueuedMessageRow(
                        text: queuedText,
                        onRetry: { Task { await model.retryQueuedMessage() } },
                        onRemove: model.removeQueuedMessage
                    )
                }

                if model.isRunning || model.pendingOutgoingText != nil {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(model.activeTool?.summary ?? (model.pendingOutgoingText == nil ? "Hermes is working" : "Waiting for gateway"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        if model.isRunning {
                            Button("Stop") { Task { await model.stop() } }
                                .font(.caption.weight(.semibold))
                        }
                    }
                    .padding(.horizontal, 14)
                }

                HermesGatewayComposer(
                    text: $model.draft,
                    isEnabled: model.canSend,
                    isInputEnabled: !model.isLoading && model.queuedText == nil,
                    placeholder: model.isRunning ? "Steer \(model.profileDisplayName) while it works" : "Message \(model.profileDisplayName)",
                    onSend: { Task { await model.sendDraft() } }
                )
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 8)
            .background(.bar)
        }
        .task { await model.start() }
        .onDisappear { model.stopObserving() }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard let id = model.messages.last?.id else { return }
        withAnimation(.easeOut(duration: 0.16)) {
            proxy.scrollTo(id, anchor: .bottom)
        }
    }
}

private struct HermesGatewayMessageRow: View {
    let message: HermesDesktopGatewayMessage

    var body: some View {
        HStack {
            if message.role == "user" { Spacer(minLength: 52) }
            Text(message.content)
                .font(.body)
                .textSelection(.enabled)
                .padding(.horizontal, message.role == "user" ? 14 : 0)
                .padding(.vertical, message.role == "user" ? 10 : 0)
                .background(message.role == "user" ? Color(.secondarySystemBackground) : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .frame(maxWidth: .infinity, alignment: message.role == "user" ? .trailing : .leading)
            if message.role != "user" { Spacer(minLength: 0) }
        }
        .accessibilityLabel(message.role == "user" ? "You: \(message.content)" : "Hermes: \(message.content)")
    }
}

private struct HermesGatewayToolActivity: Equatable {
    let name: String
    let summary: String
    let isRunning: Bool
}

private struct HermesGatewayToolRow: View {
    let tool: HermesGatewayToolActivity

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: tool.isRunning ? "gearshape.2" : "checkmark.circle")
                .foregroundStyle(tool.isRunning ? Color.accentColor : .green)
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.name)
                    .font(.caption.monospaced().weight(.semibold))
                Text(tool.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if tool.isRunning { ProgressView().controlSize(.small) }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct HermesGatewayApprovalCard: View {
    let approval: HermesDesktopGatewayApproval
    let isResponding: Bool
    let onRespond: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Needs approval", systemImage: "exclamationmark.shield.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.yellow)

            if !approval.command.isEmpty {
                Text(approval.command)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            }

            Text(approval.description)
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button("Deny", role: .destructive) { onRespond("deny") }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                Button("Allow once") { onRespond("once") }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .disabled(isResponding)

            if approval.choices.contains("session") {
                Button("Allow for this run") { onRespond("session") }
                    .font(.footnote.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .disabled(isResponding)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.yellow.opacity(0.45), lineWidth: 1)
        }
    }
}

private struct HermesGatewayApprovalSheet: View {
    @Environment(\.dismiss) private var dismiss
    let approval: HermesDesktopGatewayApproval?
    let isResponding: Bool
    let onRespond: (String) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if let approval {
                    ScrollView {
                        HermesGatewayApprovalCard(
                            approval: approval,
                            isResponding: isResponding,
                            onRespond: onRespond
                        )
                        .padding(16)
                    }
                } else {
                    ContentUnavailableView(
                        "No pending approval",
                        systemImage: "checkmark.shield",
                        description: Text("This run has no tool request waiting for you.")
                    )
                }
            }
            .navigationTitle("Approval")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct HermesGatewayPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let text: String

    var body: some View {
        NavigationStack {
            ScrollView([.horizontal, .vertical]) {
                Text(text)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .navigationTitle("Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct HermesGatewaySkillsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var client: HermesDesktopGatewayClient
    let profileName: String
    @State private var groups: [HermesDesktopGatewaySkillGroup] = []
    @State private var errorMessage: String?
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading skills…")
                } else if let errorMessage {
                    ContentUnavailableView {
                        Label("Skills unavailable", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Retry") { Task { await load() } }
                    }
                } else {
                    List(groups) { group in
                        Section(group.category.capitalized) {
                            ForEach(group.skills, id: \.self) { skill in
                                Label(skill, systemImage: "sparkle")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Skills · \(profileName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            groups = try await client.listSkills(profile: profileName)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

private struct HermesGatewayMemorySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var client: HermesDesktopGatewayClient
    @State private var summary: HermesDesktopGatewayLearningSummary?
    @State private var errorMessage: String?
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading memory summary…")
                } else if let errorMessage {
                    ContentUnavailableView {
                        Label("Memory unavailable", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Retry") { Task { await load() } }
                    }
                } else if let summary {
                    List {
                        Section("Learning map") {
                            LabeledContent("Items", value: "\(summary.count)")
                            ForEach(summary.legend, id: \.self) { line in
                                Text(line)
                            }
                        }
                        if !summary.summary.isEmpty {
                            Section("Summary") {
                                ForEach(summary.summary, id: \.self) { line in
                                    Text(line)
                                }
                            }
                        }
                    }
                } else {
                    ContentUnavailableView("No memory yet", systemImage: "brain.head.profile")
                }
            }
            .navigationTitle("Memory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            summary = try await client.learningSummary()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

private struct HermesGatewayQueuedMessageRow: View {
    let text: String
    let onRetry: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Waiting to send", systemImage: "clock.arrow.circlepath")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.yellow)
            Text(text)
                .font(.footnote)
                .lineLimit(2)
            HStack {
                Button("Retry", action: onRetry)
                    .buttonStyle(.borderedProminent)
                Button("Remove", role: .destructive, action: onRemove)
                    .buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct HermesGatewayComposer: View {
    @Binding var text: String
    let isEnabled: Bool
    let isInputEnabled: Bool
    let placeholder: String
    let onSend: () -> Void
    @State private var voiceInput = ComposerVoiceInputController()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if voiceInput.isListening || voiceInput.isRequestingPermission || voiceInput.errorMessage != nil {
                Label {
                    Text(voiceStatusText)
                        .lineLimit(2)
                } icon: {
                    Image(systemName: voiceInput.errorMessage == nil ? "waveform" : "exclamationmark.triangle")
                }
                .font(.caption)
                .foregroundStyle(voiceInput.errorMessage == nil ? Color.accentColor : .red)
                .padding(.horizontal, 12)
            }

            HStack(alignment: .bottom, spacing: 8) {
                TextField(placeholder, text: $text, axis: .vertical)
                    .lineLimit(1...6)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
                    .submitLabel(.send)
                    .disabled(!isInputEnabled)
                    .onSubmit {
                        if isEnabled { submit() }
                    }

                Button {
                    Task {
                        await voiceInput.toggle(currentDraft: text) { transcript in
                            text = transcript
                        }
                    }
                } label: {
                    Image(systemName: voiceInput.isListening ? "stop.fill" : "mic.fill")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.bordered)
                .clipShape(Circle())
                .disabled(!isInputEnabled || voiceInput.isRequestingPermission)
                .accessibilityLabel(voiceInput.isListening ? "Stop dictation" : "Start dictation")

                Button(action: submit) {
                    Image(systemName: "arrow.up")
                        .font(.headline.weight(.bold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.borderedProminent)
                .clipShape(Circle())
                .disabled(!isEnabled)
                .accessibilityLabel("Send")
            }
        }
        .onDisappear { voiceInput.stopKeepingTranscript() }
    }

    private var voiceStatusText: String {
        if let errorMessage = voiceInput.errorMessage { return errorMessage }
        if voiceInput.isRequestingPermission { return "Requesting voice permissions…" }
        return "Listening…"
    }

    private func submit() {
        voiceInput.stopBeforeSubmittingDraft()
        onSend()
    }
}

private struct HermesGatewayConnectionLabel: View {
    let state: HermesDesktopGatewayClient.ConnectionState
    var compact = false

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: compact ? 6 : 8, height: compact ? 6 : 8)
            Text(label)
                .font(compact ? .caption2 : .caption)
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Gateway \(label)")
    }

    private var label: String {
        switch state {
        case .disconnected: "Offline"
        case .connecting: "Connecting"
        case .connected: "Connected"
        case .degraded: "Degraded"
        }
    }

    private var color: Color {
        switch state {
        case .connected: .green
        case .connecting: .yellow
        case .degraded: .orange
        case .disconnected: .secondary
        }
    }
}

@MainActor
@Observable
private final class HermesDesktopGatewayChatViewModel {
    let profileName: String
    let profileDisplayName: String

    private(set) var messages: [HermesDesktopGatewayMessage] = []
    private(set) var title: String
    private(set) var modelName: String?
    private(set) var isLoading = true
    private(set) var isRunning = false
    private(set) var isRespondingToApproval = false
    private(set) var pendingOutgoingText: String?
    private(set) var queuedText: String?
    private(set) var activeTool: HermesGatewayToolActivity?
    private(set) var pendingApproval: HermesDesktopGatewayApproval?
    private(set) var previewText: String?
    private(set) var errorMessage: String?
    var draft = ""

    var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && pendingOutgoingText == nil
            && queuedText == nil
            && !isLoading
    }

    private let client: HermesDesktopGatewayClient
    private let initialStoredSessionID: String?
    private var runtimeSessionID: String?
    private var storedSessionID: String?
    private var eventObserverID: UUID?
    private var streamingMessageID: String?

    init(
        client: HermesDesktopGatewayClient,
        profileName: String,
        profileDisplayName: String,
        storedSessionID: String?,
        initialTitle: String?
    ) {
        self.client = client
        self.profileName = profileName
        self.profileDisplayName = profileDisplayName
        self.initialStoredSessionID = storedSessionID
        self.storedSessionID = storedSessionID
        self.title = initialTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? initialTitle!
            : profileDisplayName
    }

    func start() async {
        guard runtimeSessionID == nil else { return }
        errorMessage = nil
        isLoading = true
        installEventObserver()

        do {
            try await client.connect()
            let snapshot: HermesDesktopGatewaySessionSnapshot
            if let initialStoredSessionID {
                snapshot = try await client.resumeSession(
                    storedSessionID: initialStoredSessionID,
                    profile: profileName
                )
            } else {
                snapshot = try await client.createSession(profile: profileName)
            }
            apply(snapshot)
            await refreshPendingApprovals()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func stopObserving() {
        if let eventObserverID {
            client.removeEventObserver(eventObserverID)
            self.eventObserverID = nil
        }
    }

    func sendDraft() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        await send(text)
    }

    func retryQueuedMessage() async {
        guard let queuedText else { return }
        self.queuedText = nil
        do {
            try await client.connect()
            if runtimeSessionID == nil { await start() }
            await send(queuedText)
        } catch {
            self.queuedText = queuedText
            errorMessage = error.localizedDescription
        }
    }

    func removeQueuedMessage() {
        queuedText = nil
    }

    func stop() async {
        guard let runtimeSessionID else { return }
        do {
            try await client.interrupt(sessionID: runtimeSessionID)
            isRunning = false
            activeTool = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func respondToApproval(choice: String) async {
        guard let runtimeSessionID, let pendingApproval else { return }
        isRespondingToApproval = true
        defer { isRespondingToApproval = false }
        do {
            let resolved = try await client.respondToApproval(
                sessionID: runtimeSessionID,
                requestID: pendingApproval.id,
                choice: choice
            )
            if resolved > 0 { self.pendingApproval = nil }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func send(_ text: String) async {
        guard let runtimeSessionID else {
            queuedText = text
            return
        }

        guard client.state == .connected else {
            queuedText = text
            return
        }

        errorMessage = nil
        if isRunning {
            do {
                let accepted = try await client.steer(sessionID: runtimeSessionID, text: text)
                if accepted {
                    appendConfirmedUserMessage(text)
                } else {
                    queuedText = text
                }
            } catch {
                queuedText = text
                errorMessage = error.localizedDescription
            }
            return
        }

        pendingOutgoingText = text
        do {
            try await client.submitPrompt(sessionID: runtimeSessionID, text: text)
            confirmPendingOutgoingMessage()
        } catch {
            if pendingOutgoingText == text { pendingOutgoingText = nil }
            queuedText = text
            errorMessage = error.localizedDescription
        }
    }

    private func installEventObserver() {
        guard eventObserverID == nil else { return }
        eventObserverID = client.observeEvents { [weak self] event in
            self?.handle(event)
        }
    }

    private func handle(_ event: HermesDesktopGatewayEvent) {
        guard event.sessionID == nil || event.sessionID == runtimeSessionID else { return }

        switch event.type {
        case "message.start":
            confirmPendingOutgoingMessage()
            isRunning = true
            activeTool = nil
        case "message.delta":
            appendAssistantDelta(event.payload["text"]?.gatewayViewString ?? "")
        case "message.interim":
            sealAssistantMessage(event.payload["text"]?.gatewayViewString)
        case "message.complete":
            confirmPendingOutgoingMessage()
            sealAssistantMessage(
                event.payload["text"]?.gatewayViewString
                    ?? event.payload["rendered"]?.gatewayViewString
            )
            isRunning = false
            activeTool = nil
            Task { await refreshPendingApprovals() }
        case "tool.start", "tool.progress":
            isRunning = true
            activeTool = HermesGatewayToolActivity(
                name: event.payload["name"]?.gatewayViewString ?? "tool",
                summary: toolSummary(event.payload),
                isRunning: true
            )
        case "tool.complete":
            activeTool = HermesGatewayToolActivity(
                name: event.payload["name"]?.gatewayViewString ?? activeTool?.name ?? "tool",
                summary: event.payload["error"]?.gatewayViewString ?? "Completed",
                isRunning: false
            )
            if let preview = event.payload["inline_diff"]?.gatewayViewString?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !preview.isEmpty {
                previewText = preview
            }
        case "approval.request":
            Task { await refreshPendingApprovals() }
        case "session.info":
            if let running = event.payload["running"]?.gatewayViewBool { isRunning = running }
            if let model = event.payload["model"]?.gatewayViewString { modelName = model }
        case "session.title":
            if let nextTitle = event.payload["title"]?.gatewayViewString,
               !nextTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                title = nextTitle
            }
        case "error":
            errorMessage = event.payload["message"]?.gatewayViewString
                ?? event.payload["error"]?.gatewayViewString
                ?? "Hermes reported an error."
            isRunning = false
        default:
            break
        }
    }

    private func apply(_ snapshot: HermesDesktopGatewaySessionSnapshot) {
        runtimeSessionID = snapshot.runtimeSessionID
        storedSessionID = snapshot.storedSessionID ?? storedSessionID
        messages = snapshot.messages
        modelName = snapshot.model
        isRunning = snapshot.isRunning
        if let title = snapshot.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.title = title
        }
    }

    private func appendConfirmedUserMessage(_ text: String) {
        messages.append(
            HermesDesktopGatewayMessage(
                id: "mobile-user-\(UUID().uuidString)",
                role: "user",
                content: text,
                timestamp: Date().timeIntervalSince1970
            )
        )
    }

    private func confirmPendingOutgoingMessage() {
        guard let pendingOutgoingText else { return }
        appendConfirmedUserMessage(pendingOutgoingText)
        self.pendingOutgoingText = nil
    }

    private func appendAssistantDelta(_ delta: String) {
        guard !delta.isEmpty else { return }
        if let streamingMessageID,
           let index = messages.firstIndex(where: { $0.id == streamingMessageID }) {
            messages[index].content += delta
            return
        }

        let id = "mobile-assistant-\(UUID().uuidString)"
        streamingMessageID = id
        messages.append(
            HermesDesktopGatewayMessage(
                id: id,
                role: "assistant",
                content: delta,
                timestamp: Date().timeIntervalSince1970
            )
        )
    }

    private func sealAssistantMessage(_ finalText: String?) {
        let cleaned = finalText?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let streamingMessageID,
           let index = messages.firstIndex(where: { $0.id == streamingMessageID }) {
            if let cleaned, !cleaned.isEmpty {
                messages[index].content = cleaned
            }
        } else if let cleaned, !cleaned.isEmpty {
            messages.append(
                HermesDesktopGatewayMessage(
                    id: "mobile-assistant-\(UUID().uuidString)",
                    role: "assistant",
                    content: cleaned,
                    timestamp: Date().timeIntervalSince1970
                )
            )
        }
        streamingMessageID = nil
    }

    private func refreshPendingApprovals() async {
        guard let runtimeSessionID else { return }
        do {
            pendingApproval = try await client.pendingApprovals(sessionID: runtimeSessionID).first
        } catch {
            if let gatewayError = error as? HermesDesktopGatewayError,
               case .rpc(let code, _) = gatewayError,
               code == 4009 {
                pendingApproval = nil
                return
            }
        }
    }

    private func toolSummary(_ payload: [String: JSONValue]) -> String {
        payload["description"]?.gatewayViewString
            ?? payload["command"]?.gatewayViewString
            ?? payload["status"]?.gatewayViewString
            ?? "Running"
    }
}

private extension JSONValue {
    var gatewayViewString: String? {
        switch self {
        case .string(let value): value
        case .number(let value): value.formatted()
        case .bool(let value): value ? "true" : "false"
        default: nil
        }
    }

    var gatewayViewBool: Bool? {
        switch self {
        case .bool(let value): value
        case .number(let value): value != 0
        case .string(let value):
            switch value.lowercased() {
            case "true", "1", "yes", "on": true
            case "false", "0", "no", "off": false
            default: nil
            }
        default: nil
        }
    }
}
