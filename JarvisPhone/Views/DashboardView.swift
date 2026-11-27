import SwiftUI
import MediaPlayer
import UIKit

struct DashboardView: View {
    @ObservedObject var controller: PhoneController
    var onClose:(()->Void)? = nil
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
                        Text("Seu iPhone, sob comando.").font(.title.bold())
                        Text("Jarvis \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—") · revisão \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—")")
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
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
            .navigationTitle("Ajustes do Jarvis")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let onClose { ToolbarItem(placement:.cancellationAction) { Button("Fechar",action:onClose) } }
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
                Section("Voz do Jarvis") {
                    Text("As respostas usam Jarvis UCM PT-BR. Confirmações frequentes já estão no iPhone; respostas novas usam a ponte para gerar essa mesma voz em streaming.")
                    Text("Nas automações, use Falar com a voz do Jarvis no lugar de Falar Texto. Para falar com a tela bloqueada, deixe a escuta do Jarvis ativa. A ação Falar Texto do próprio Atalhos tem uma voz separada.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Controles do sistema") {
                    Text("Importe a revisão 14 do JARVIS Sistema para Wallet, Wi-Fi, Bluetooth, dados móveis, rotação, concentração, economia e mídia. Se o atalho já existir, substitua essa versão e mantenha o nome exato.")
                    if let file = Bundle.main.url(forResource: "JARVIS Sistema", withExtension: "shortcut") {
                        ShareLink(item: file) {
                            Label("Compartilhar arquivo de instalação", systemImage: "square.and.arrow.up")
                        }
                    }
                    Text("Salve o arquivo em Arquivos, abra-o e toque em Adicionar Atalho. Mantenha o nome JARVIS Sistema.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Verificar a instalação") {
                    Text("Os atalhos antigos JARVIS+CONTROLE+iPhone e JARVIS+Executar+Comando não substituem JARVIS Sistema. Não precisa apagá-los.")
                    Button("Testar JARVIS Sistema") { Task { await PhoneController.shared.run(.shortcutCheck) } }
                    Text("O teste abre Atalhos e volta ao Jarvis. A confirmação aparece em Meu iPhone somente quando a revisão 14 responde. Se não voltar, confira a importação e o nome do atalho.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Rotinas sem abrir o Jarvis") {
                    Text("No Atalhos → Automação → +, escolha o evento e Executar Imediatamente quando disponível. Cada gatilho precisa ser configurado uma vez no seu iPhone.")
                    Label("Ao parar o despertador", systemImage: "alarm")
                    Text("Adicione Resumo local do iPhone (JARVIS XLV) e depois Falar com a voz do Jarvis usando o resultado. Ele consulta hora, bateria e passos já autorizados, sem depender da ponte.")
                    Label("Bateria abaixo de 20%", systemImage: "battery.25percent")
                    Text("Adicione Texto: economizar → Executar Atalho: JARVIS Sistema. Passe o Texto como entrada.")
                    Label("Ao conectar ao carregador", systemImage: "bolt.fill")
                    Text("Use Resumo local do iPhone → Falar com a voz do Jarvis. Para um aviso mais discreto, use Mostrar Notificação no lugar da fala.")
                    Label("Ao conectar seus fones", systemImage: "headphones")
                    Text("Escolha o dispositivo Bluetooth específico. Para retomar a mídia do iPhone, passe o Texto continuar ao JARVIS Sistema. Isso não escolhe um dispositivo Spotify remoto.")
                    Label("Etiqueta NFC na mesa", systemImage: "wave.3.right")
                    Text("Leia uma etiqueta na criação do gatilho e passe reuniao ao JARVIS Sistema. Ela ativa Não Perturbe e silencia a mídia. Use encerrar_reuniao para sair.")
                    Text("O iOS pode exigir desbloqueio para algumas ações. Gatilhos de NFC não são pagamentos e não transformam uma etiqueta em cartão bancário.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Comandos de voz") {
                    Text("Jarvis, pagar • ligue o Wi-Fi • desligue o Bluetooth • trave a rotação • economizar bateria • resumo do iPhone • anote: comprar pilhas.")
                    Text("Wallet abre a carteira. O cartão, a confirmação e a autenticação continuam no Wallet. Desligar Wi-Fi ou dados pode interromper integrações; desligar Bluetooth pode desconectar os fones.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("No app Atalhos") {
                    Text("Em Adicionar Ação, procure JARVIS XLV. Os controles aparecem pelo nome. Use Executar ação no iPhone para fornecer uma ação e porcentagem na mesma chamada.")
                    Text("As ações ficam disponíveis em Atalhos depois de instalar e abrir este app. Não é preciso configurar a Siri.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Permissões") {
                    Text("Câmera, Fotos, Localização e Lembretes são solicitados quando você usa cada função.")
                }
                Section("Jarvis") {
                    Text("Ações locais e automações funcionam no iPhone. A ponte fornece apenas as integrações que precisam dela. A máscara física ainda não está montada e não é requisito para estes controles.")
                }
            }
            .navigationTitle("Configuração")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Pronto") { dismiss() } } }
        }
    }
}
