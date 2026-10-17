import SwiftUI
import SwiftwardenCore
import UniformTypeIdentifiers

struct SendListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let q = model.search.lowercased()
        let items = model.sends.filter { q.isEmpty || ($0.name ?? "").lowercased().contains(q) }
            .sorted { ($0.name ?? "").localizedStandardCompare($1.name ?? "") == .orderedAscending }
        List(selection: $model.selectedSendId) {
            ForEach(items) { s in
                HStack(spacing: 10) {
                    Image(systemName: s.type == 0 ? "text.alignleft" : "doc.fill")
                        .foregroundStyle(.white).frame(width: 32, height: 32)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.indigo.gradient))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.name ?? "").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text(status(s)).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if s.password != nil { Image(systemName: "key.fill").foregroundStyle(.secondary).font(.caption) }
                }
                .padding(.vertical, 5)
                .tag(s.id)
                .contextMenu {
                    Button("Copy Link") { model.copy(model.service?.sendLink(s), "link", sensitive: false) }
                    Button("Delete", role: .destructive) { delete(s) }
                }
            }
        }
        .overlay { if items.isEmpty { ContentUnavailableView("No Sends", systemImage: "paperplane") } }
        .navigationTitle("Send")
        .navigationSubtitle("\(items.count) Items")
        .toolbar {
            Menu {
                Button { model.selectedSendId = "new-0" } label: { Label("Text", systemImage: "text.alignleft") }
                Button { model.selectedSendId = "new-1" } label: { Label("File", systemImage: "doc") }
            } label: { Image(systemName: "plus") }
        }
    }

    func status(_ s: Send) -> String {
        if s.disabled { return "Disabled" }
        if let d = Dates.parse(s.expirationDate), d < Date() { return "Expired" }
        if let m = s.maxAccessCount, (s.accessCount ?? 0) >= m { return "Max access count reached" }
        return "Deletes " + (Dates.parse(s.deletionDate)?.formatted(date: .abbreviated, time: .omitted) ?? "")
    }

    func delete(_ s: Send) {
        model.run("Delete send") {
            try await model.service?.deleteSend(s.id)
            model.sends.removeAll { $0.id == s.id }
        }
    }
}

struct SendDetailContainer: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        if let id = model.selectedSendId {
            if id.hasPrefix("new-") {
                SendEditView(send: newSend(Int(id.dropFirst(4)) ?? 0)).id(id)
            } else if let s = model.sends.first(where: { $0.id == id }) {
                SendEditView(send: s).id(id + (s.revisionDate ?? ""))
            }
        } else {
            ContentUnavailableView("No Send Selected", systemImage: "paperplane")
        }
    }

    func newSend(_ type: Int) -> Send {
        var s = Send(type: type)
        if type == 1 { s.file = SendFile() }
        s.deletionDate = Dates.string(Date().addingTimeInterval(7 * 86400))
        return s
    }
}

struct SendEditView: View {
    @Environment(AppModel.self) private var model
    @State var send: Send
    @State private var newPassword = ""
    @State private var fileURL: URL?
    @State private var pickFile = false
    @State private var saving = false
    @State private var hasExpiry = false

    var isNew: Bool { send.id.isEmpty }

    func b(_ kp: WritableKeyPath<Send, String?>) -> Binding<String> {
        Binding(get: { send[keyPath: kp] ?? "" }, set: { send[keyPath: kp] = $0.isEmpty ? nil : $0 })
    }

    func date(_ kp: WritableKeyPath<Send, String?>, _ def: Date) -> Binding<Date> {
        Binding(get: { Dates.parse(send[keyPath: kp]) ?? def }, set: { send[keyPath: kp] = Dates.string($0) })
    }

    var body: some View {
        Form {
            if !isNew {
                Section {
                    LabeledContent("Link") {
                        HStack {
                            Text(model.service?.sendLink(send) ?? "").lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                            Button { model.copy(model.service?.sendLink(send), "link", sensitive: false) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless)
                        }
                    }
                    LabeledContent("Access count", value: "\(send.accessCount ?? 0)")
                }
            }
            Section(send.type == 0 ? "Text Send" : "File Send") {
                TextField("Name", text: b(\.name))
                if send.type == 0 {
                    TextField("Text", text: Binding(get: { send.text?.text ?? "" }, set: { send.text = SendText(text: $0, hidden: send.text?.hidden ?? false) }), axis: .vertical)
                        .lineLimit(3 ... 10)
                    Toggle("Hide text by default", isOn: Binding(get: { send.text?.hidden ?? false }, set: { send.text?.hidden = $0 }))
                } else if isNew {
                    HStack {
                        Text(fileURL?.lastPathComponent ?? "No file chosen").foregroundStyle(.secondary)
                        Spacer()
                        Button("Choose File…") { pickFile = true }
                    }
                } else {
                    LabeledContent("File", value: (send.file?.fileName ?? "") + " (" + (send.file?.sizeName ?? "") + ")")
                }
            }
            Section("Options") {
                DatePicker("Deletion date", selection: date(\.deletionDate, Date().addingTimeInterval(7 * 86400)), in: Date()..., displayedComponents: [.date, .hourAndMinute])
                Toggle("Expires", isOn: $hasExpiry)
                if hasExpiry {
                    DatePicker("Expiration date", selection: date(\.expirationDate, Date().addingTimeInterval(86400)), in: Date()..., displayedComponents: [.date, .hourAndMinute])
                }
                TextField("Maximum access count", value: $send.maxAccessCount, format: .number)
                SecureField(send.password != nil ? "New password (leave empty to keep)" : "Password (optional)", text: $newPassword)
                if send.password != nil && !isNew {
                    Button("Remove Password") {
                        model.run("Remove password") {
                            try await model.service?.removeSendPassword(send.id)
                            send.password = nil
                            await model.sync()
                        }
                    }
                }
                TextField("Private notes", text: b(\.notes), axis: .vertical)
                Toggle("Hide my email address from recipients", isOn: Binding(get: { send.hideEmail ?? false }, set: { send.hideEmail = $0 }))
                Toggle("Deactivate this Send", isOn: $send.disabled)
            }
        }
        .formStyle(.grouped)
        .onAppear { hasExpiry = send.expirationDate != nil }
        .onChange(of: hasExpiry) { _, v in if !v { send.expirationDate = nil } }
        .fileImporter(isPresented: $pickFile, allowedContentTypes: [.item]) { r in fileURL = try? r.get() }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if !isNew {
                    Button(role: .destructive) {
                        model.run("Delete") {
                            try await model.service?.deleteSend(send.id)
                            model.sends.removeAll { $0.id == send.id }
                            model.selectedSendId = nil
                        }
                    } label: { Image(systemName: "trash") }
                }
                Button { save() } label: { if saving { ProgressView().controlSize(.small) } else { Text("Save") } }
                    .buttonStyle(.borderedProminent)
                    .disabled((send.name ?? "").isEmpty || saving || (isNew && send.type == 1 && fileURL == nil))
            }
        }
    }

    func save() {
        saving = true
        var data: Data?
        if let u = fileURL {
            let ok = u.startAccessingSecurityScopedResource()
            data = try? Data(contentsOf: u)
            if ok { u.stopAccessingSecurityScopedResource() }
            send.file = SendFile(fileName: u.lastPathComponent)
        }
        let s = send, pw = newPassword, d = data
        model.run("Save send") {
            defer { saving = false }
            guard let saved = try await model.service?.saveSend(s, newPassword: pw, fileData: d) else { return }
            if let i = model.sends.firstIndex(where: { $0.id == saved.id }) { model.sends[i] = saved } else { model.sends.append(saved) }
            model.selectedSendId = saved.id
            if s.id.isEmpty { model.copy(model.service?.sendLink(saved), "Send link", sensitive: false) }
        }
    }
}
