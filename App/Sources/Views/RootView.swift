import SwiftUI
import SwiftwardenCore

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            switch model.phase {
            case .loggedOut: LoginView()
            case .locked: UnlockView()
            case .unlocked: MainView()
            }
        }
        .overlay(alignment: .bottom) {
            if let t = model.toast {
                ToastView(text: t.text).padding(.bottom, 24).transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: model.toast)
        .alert("Error", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }
}
