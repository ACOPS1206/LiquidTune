// SPDX-License-Identifier: Apache-2.0
import SwiftUI

struct SettingsScreen: View {
    let importFiles: () -> Void

    @Environment(LibraryModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var form: FormRoute?
    @State private var disconnect: ServerProfile?

    private struct FormRoute: Identifiable {
        let id = UUID()
        var profile: ServerProfile? = nil
    }

    var body: some View {
        @Bindable var settings = model
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Appearance", selection: $settings.appearance) {
                        ForEach(LibraryModel.Appearance.allCases) { appearance in
                            Text(appearance.rawValue).tag(appearance)
                        }
                    }
                    Toggle("Artwork colors in player", isOn: $settings.dynamicColor)
                    Toggle("Audio visualization", isOn: $settings.visualizer)
                }
                Section("Music sources") {
                    Button("Import audio files", systemImage: "square.and.arrow.down", action: importFiles)
                    ForEach(model.servers) { profile in
                        Button {
                            form = FormRoute(profile: profile)
                        } label: {
                            Label {
                                VStack(alignment: .leading) {
                                    Text(profile.name).foregroundStyle(.primary)
                                    Text(profile.kind.rawValue).font(.caption).foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "music.note.house")
                            }
                        }
                        .swipeActions {
                            Button("Remove", systemImage: "trash", role: .destructive) { disconnect = profile }
                        }
                        .contextMenu {
                            Button("Reconnect", systemImage: "arrow.clockwise") { form = FormRoute(profile: profile) }
                            Button("Remove source", systemImage: "trash", role: .destructive) { disconnect = profile }
                        }
                    }
                    Button("Add music server", systemImage: "plus") { form = FormRoute() }
                }
                Section("About") {
                    LabeledContent("LiquidTune", value: appVersion)
                    Link(destination: URL(string: "https://github.com/LineageOS/android_packages_apps_Twelve")!) {
                        Label("Original project · LineageOS Twelve", systemImage: "arrow.up.right")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }.buttonStyle(.glassProminent)
                }
            }
        }
        .sheet(item: $form) { route in
            ServerForm(profile: route.profile)
        }
        .confirmationDialog("Remove this music source?", isPresented: Binding(get: { disconnect != nil }, set: { if !$0 { disconnect = nil } }),
                            titleVisibility: .visible, presenting: disconnect) { profile in
            Button("Remove source", role: .destructive) { Task { await model.disconnect(profile.id) } }
        } message: { profile in
            Text(profile.name)
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }
}

private struct ServerForm: View {
    let profile: ServerProfile?
    @Environment(LibraryModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var kind: ServerKind
    @State private var title: String
    @State private var address: String
    @State private var username: String
    @State private var password = ""
    @State private var error: String?
    @State private var working = false

    init(profile: ServerProfile?) {
        self.profile = profile
        _kind = State(initialValue: profile?.kind ?? .jellyfin)
        _title = State(initialValue: profile?.name ?? "")
        _address = State(initialValue: profile?.baseURL.absoluteString ?? "")
        _username = State(initialValue: profile?.username ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    Picker("Service", selection: $kind) {
                        ForEach(ServerKind.allCases) { provider in
                            Text(provider.rawValue).tag(provider)
                        }
                    }
                    .disabled(profile != nil)
                    TextField("Name (optional)", text: $title)
                    TextField("Server URL", text: $address, prompt: Text("https://music.example.com"))
                        .textContentType(.URL).keyboardType(.URL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .disabled(profile != nil)
                }
                Section("Sign in") {
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .disabled(profile != nil)
                    SecureField("Password", text: $password).textContentType(.password)
                }
                if let error {
                    Text(error).foregroundStyle(.red)
                }
                if working {
                    ProgressView("Connecting")
                }
            }
            .disabled(working)
            .navigationTitle(profile == nil ? "Add music server" : "Reconnect")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }.disabled(working)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect", systemImage: "checkmark", action: connect)
                        .buttonStyle(.glassProminent)
                        .disabled(working || address.isEmpty || username.isEmpty)
                }
            }
        }
        .interactiveDismissDisabled(working)
    }

    private func connect() {
        working = true
        error = nil
        Task {
            defer { working = false }
            do {
                try await model.connect(kind: kind, address: address, username: username,
                                        password: password, name: title, replacing: profile?.id)
                password = ""
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
