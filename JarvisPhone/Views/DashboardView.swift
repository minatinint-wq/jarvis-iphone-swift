import SwiftUI
import MediaPlayer
import UIKit

struct DashboardView: View {
    @ObservedObject var controller: PhoneController
    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label("CONTROLE DO IPHONE", systemImage: "iphone")
                                .font(.caption.monospaced()).foregroundStyle(.cyan)
                            Spacer()
                            Text(controller.battery.map { "\($0)%" } ?? "—")
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Text("Às suas ordens.").font(.largeTitle.bold())
                        Text(controller.message)
                            .foregroundStyle(controller.isError ? Color.orange : Color.white.opacity(0.8))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("commandResult")
                        if controller.isBusy {
                            ProgressView("Executando…").font(.caption)
                        }
                    }
                    .padding(22)
                    .background(.cyan.opacity(0.07), in: RoundedRectangle(cornerRadius: 24))
                    .overlay(RoundedRectangle(cornerRadius: 24).stroke(.cyan.opacity(0.25)))

                    Button { controller.sheet = .setup } label: {
                        Label("Configurar controles do sistema", systemImage: "square.stack.3d.up")
                            .font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                    }

                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(PhoneAction.allCases) { action in
                            Button {
                                Task { await controller.run(action) }
                            } label: {
                                VStack(alignment: .leading, spacing: 10) {
                                    Image(systemName: action.symbol).font(.title2).foregroundStyle(.cyan)
                                    Text(action.title).font(.headline).foregroundStyle(.white)
                                    Text(action.subtitle).font(.caption).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 0)
                                }
                                .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
                                .padding(16)
                                .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 18))
                                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.08)))
                            }
                            .buttonStyle(.plain)
                            .disabled(controller.isBusy)
                            .accessibilityIdentifier(action.rawValue)
                        }
                    }

                    if !controller.history.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Últimas ações").font(.headline)
                            ForEach(Array(controller.history.prefix(5).enumerated()), id: \.offset) { _, value in
                                Text(value).font(.footnote).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 4)
                    }
                }.padding(18)
            }
            .background(Color(red: 0.018, green: 0.035, blue: 0.055))
            .navigationTitle("J.A.R.V.I.S.")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { controller.sheet = .notes } label: { Image(systemName: "note.text") }
                        .accessibilityLabel("Minhas notas")
                }
            }
            .sheet(item: $controller.sheet) { sheet in
                switch sheet {
                case .volume:
                    ControlPanel(title: "Volume do iPhone") {
                        SystemVolumeView().frame(height: 44)
                        Text("Ajuste o volume de mídia pela barra do sistema.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                case .brightness:
                    ControlPanel(title: "Brilho da tela") {
                        Slider(value: $controller.brightness, in: 0...100, step: 1)
                            .onChange(of: controller.brightness) { _, value in
                                UIScreen.main.brightness = CGFloat(value / 100)
                            }
                        Text("\(Int(controller.brightness))%")
                            .font(.largeTitle.monospacedDigit())
                    }
                case .camera:
                    CameraCapture { image in
                        controller.sheet = nil
                        Task { await controller.savePhoto(image) }
                    } onCancel: { controller.sheet = nil }
                        .ignoresSafeArea()
                case .reminder: ReminderEditor(controller: controller)
                case .note: NoteEditor(controller: controller)
                case .notes: NotesView(controller: controller)
                case .setup: SetupView()
                }
            }
        }
    }
}

struct ControlPanel<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) { content(); Spacer() }.padding(28)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Pronto") { dismiss() } } }
        }.presentationDetents([.medium])
    }
}

struct SystemVolumeView: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView { MPVolumeView(frame: .zero) }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

struct SetupView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Controles do sistema") {
                    Text("Importe JARVIS Sistema uma vez para usar reunião, economia de bateria, música, bloqueio de tela e volume por comando.")
                    if let file = Bundle.main.url(forResource: "JARVIS Sistema", withExtension: "shortcut") {
                        ShareLink(item: file) {
                            Label("Compartilhar arquivo de instalação", systemImage: "square.and.arrow.up")
                        }
                    }
                    Text("Salve o arquivo em Arquivos, abra-o e toque em Adicionar Atalho. Mantenha o nome JARVIS Sistema.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("No app Atalhos") {
                    Text("Crie um atalho, toque em Adicionar Ação e procure JARVIS XLV. Escolha Executar ação no iPhone e selecione a ação desejada.")
                    Text("As ações ficam disponíveis em Atalhos depois de instalar e abrir este app. Não é preciso configurar a Siri.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Permissões") {
                    Text("Câmera, Fotos, Localização e Lembretes são solicitados quando você usa cada função.")
                }
                Section("Jarvis") {
                    Text("Os controles locais já estão preparados. A conexão com o Jarvis será configurada depois.")
                }
            }
            .navigationTitle("Configuração")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Pronto") { dismiss() } } }
        }
    }
}
