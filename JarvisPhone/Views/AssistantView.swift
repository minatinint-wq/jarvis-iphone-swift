import SwiftUI
import AVFoundation
import VisionKit
import WebKit

private enum ConsoleColor {
    static let background = Color(red: 0.047, green: 0.053, blue: 0.061)
    static let panel = Color(red: 0.091, green: 0.100, blue: 0.109)
    static let inset = Color(red: 0.067, green: 0.073, blue: 0.081)
    static let border = Color.white.opacity(0.13)
    static let gold = Color(red: 0.93, green: 0.77, blue: 0.49)
    static let cyan = Color(red: 0.47, green: 0.87, blue: 0.90)
    static let red = Color(red: 1.0, green: 0.55, blue: 0.48)
    static let muted = Color(red: 0.72, green: 0.74, blue: 0.75)
}

private enum VoiceState {
    case waiting, ready, listening, processing, speaking

    var title: String {
        switch self {
        case .waiting: return "Aguardando o PC"
        case .ready: return "Pronto para ouvir"
        case .listening: return "Ouvindo você"
        case .processing: return "Processando pedido"
        case .speaking: return "Jarvis está falando"
        }
    }

    var accent: Color {
        switch self {
        case .waiting: return ConsoleColor.muted
        case .ready, .processing: return ConsoleColor.gold
        case .listening: return ConsoleColor.red
        case .speaking: return ConsoleColor.cyan
        }
    }

    var symbol: String {
        switch self {
        case .waiting: return "arrow.triangle.2.circlepath"
        case .ready: return "mic.fill"
        case .listening: return "stop.fill"
        case .processing: return "hourglass"
        case .speaking: return "waveform"
        }
    }
}

@MainActor struct AssistantView: View {
    @ObservedObject var model: RemoteAssistant
    @State private var scanning = false
    @State private var camera = false
    @State private var pairing = false
    @State private var manualPairing = false
    @State private var localExpanded = false
    @State private var historyExpanded = false
    @State private var code = ""
    @State private var draft = ""
    @State private var preview: UIImage?
    @State private var expanded: UIImage?
    @FocusState private var field: Input?
    @Environment(\.dynamicTypeSize) private var typeSize
    private enum Input: Hashable { case command, code }

    private var voiceState: VoiceState {
        if model.recording { return .listening }
        if model.isSpeaking { return .speaking }
        if model.busy { return .processing }
        return model.ready ? .ready : .waiting
    }

    private var canCompose: Bool { !model.busy && !model.recording }
    private var remoteAvailable: Bool { model.ready && canCompose }
    private var command: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        header
                        if model.paired {
                            voicePanel
                            composer.id("composer")
                            if let photo = preview { photoConfirmation(photo) }
                            if let art = model.artwork { generatedImage(art) }
                            if let line = model.lines.last { latestMessage(line) }
                            toolsPanel
                            shortcuts
                            if !model.lines.isEmpty { history }
                            if let image = model.display {
                                DisclosureGroup("Visor do PC") {
                                    Image(uiImage: image).resizable().scaledToFit()
                                        .accessibilityLabel("Imagem do visor do computador")
                                }
                                .modifier(ConsoleCard())
                            }
                        } else {
                            pairingPanel
                            DisclosureGroup("Usar neste iPhone", isExpanded: $localExpanded) {
                                VStack(alignment: .leading, spacing: 12) {
                                    wakeControl
                                    composer.id("composer")
                                    toolsPanel
                                    if let line = model.lines.last { latestMessage(line) }
                                }
                                .padding(.top, 12)
                            }
                            .modifier(ConsoleCard())
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                    .frame(maxWidth: 620)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: field) { _, target in
                    if target == .command { proxy.scrollTo("composer", anchor: .center) }
                }
            }
            .background(ConsoleColor.background.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .tint(ConsoleColor.gold)
            .sheet(isPresented: $scanning) { scannerSheet }
            .sheet(isPresented: Binding(get: { expanded != nil }, set: { if !$0 { expanded = nil } })) {
                if let image = expanded {
                    NavigationStack {
                        Image(uiImage: image).resizable().scaledToFit().padding()
                            .accessibilityLabel("Imagem gerada pelo Jarvis")
                            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fechar") { expanded = nil } } }
                    }
                }
            }
            .fullScreenCover(isPresented: $camera) {
                CameraCapture(onCapture: { photo in camera = false; preview = photo }, onCancel: { camera = false })
                    .ignoresSafeArea()
            }
            .fullScreenCover(isPresented: Binding(get: { model.studioMode != nil }, set: { if !$0 { model.studioMode = nil } })) {
                if let mode = model.studioMode {
                    VStack(spacing: 0) {
                        HStack {
                            Text(["sketch": model.localStudio ? "Desenho na tela" : "Desenho no ar", "music": "Instrumentos", "libras": "Libras"][mode] ?? "Estúdio")
                                .font(.headline)
                            Spacer()
                            if model.localStudio && model.ready { Button("Estúdio completo") { model.openStudio(mode) } }
                            Button("Fechar") { model.studioMode = nil }
                        }.padding()
                        if model.localStudio && mode == "sketch" {
                            OfflineSketch()
                        } else if model.localStudio && mode == "music" {
                            OfflineInstruments()
                        } else {
                            StudioWeb(mode: mode, origin: model.origin) { text in
                                model.studioMode = nil
                                Task { await model.say(text) }
                            }
                        }
                    }.preferredColorScheme(.dark)
                }
            }
            .onChange(of: model.cameraRequested) { _, requested in
                if requested { model.cameraRequested = false; Task { await openCamera() } }
            }
            .onChange(of: model.paired) { _, paired in
                field = nil
                code = ""
                manualPairing = false
                if !paired { draft = ""; preview = nil; expanded = nil; historyExpanded = false }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("JARVIS").font(.title2.weight(.black)).tracking(2)
            Text("XLV").font(.caption.monospaced().weight(.bold)).foregroundStyle(ConsoleColor.gold)
                .accessibilityHidden(true)
            Spacer(minLength: 4)
            if model.paired {
                Menu {
                    if !model.ready { Button("Reconectar ao PC", action: reconnect) }
                    Button("Desconectar deste PC", role: .destructive) { model.logout() }
                } label: {
                    HStack(spacing: 6) {
                        Circle().fill(model.ready ? ConsoleColor.cyan : ConsoleColor.muted).frame(width: 7, height: 7)
                        Text(model.ready ? "PC online" : "PC offline").font(.footnote.weight(.semibold))
                        Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                    }
                    .padding(.horizontal, 9).frame(minHeight: 44).contentShape(Rectangle())
                }
                .foregroundStyle(.white)
                .accessibilityHint("Opções de conexão com o computador")
            }
        }
        .frame(minHeight: 44)
    }

    private var pairingPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            MaskDisplay(accent: ConsoleColor.gold, active: false)
            Text("Conectar ao PC").font(.title.bold()).accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("pairingTitle")
            Text("Abra o painel Jarvis Remoto no computador e leia o QR code com o iPhone.")
                .font(.body).foregroundStyle(ConsoleColor.muted)
            if !model.message.isEmpty && model.message != "Conecte ao seu Jarvis." {
                Text(model.message).font(.callout).accessibilityIdentifier("assistantStatus")
            }
            Button {
                Task { await openScanner() }
            } label: {
                actionLabel(pairing ? "Conectando…" : "Ler QR do meu PC", symbol: "qrcode.viewfinder")
            }
            .buttonStyle(ConsoleAction(color: ConsoleColor.gold)).disabled(pairing)
            DisclosureGroup("Usar código de conexão", isExpanded: $manualPairing) {
                VStack(alignment: .leading, spacing: 10) {
                    SecureField("Código do painel do PC", text: $code)
                        .focused($field, equals: .code).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(.body.monospaced()).textFieldStyle(.plain)
                        .padding(12).background(ConsoleColor.inset, in: RoundedRectangle(cornerRadius: 10))
                        .submitLabel(.go).onSubmit { if !code.isEmpty { pair(code) } }
                    Button("Conectar ao meu Jarvis") { pair(code) }
                        .buttonStyle(.bordered).controlSize(.large)
                        .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pairing)
                }
                .padding(.top, 8)
            }
            .font(.body.weight(.medium))
            .padding(.vertical, 6)
        }
        .modifier(ConsoleCard())
    }

    private var voicePanel: some View {
        VStack(spacing: 10) {
            MaskDisplay(accent: voiceState.accent, active: model.recording || model.busy || model.isSpeaking)
            VStack(spacing: 5) {
                Text(voiceState.title)
                    .font(.title2.bold()).multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                if !model.message.isEmpty && model.message != model.lines.last?.text &&
                    !["Jarvis está falando.", "Ouvindo…", "Aguardando o Jarvis…"].contains(model.message) {
                    Text(model.message).font(.callout).foregroundStyle(ConsoleColor.muted)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine).accessibilityIdentifier("assistantStatus")
            Button {
                field = nil
                switch voiceState {
                case .waiting: reconnect()
                case .listening: Task { await model.sendRecording() }
                case .ready, .speaking:
                    if model.ready { model.startListening() } else { reconnect() }
                case .processing: break
                }
            } label: {
                actionLabel(voiceButtonTitle, symbol: voiceState.symbol)
            }
            .buttonStyle(ConsoleAction(color: voiceState.accent))
            .disabled(model.busy && !model.recording)
            .padding(.top, 4)
            Divider().overlay(ConsoleColor.border).padding(.top, 4)
            wakeControl
        }
        .modifier(ConsoleCard())
    }

    private var wakeControl: some View {
        Toggle(isOn: Binding(get: { model.wakeEnabled }, set: { model.setWakeEnabled($0) })) {
            VStack(alignment: .leading, spacing: 3) {
                Label("Ativar com “Oi, Jarvis”", systemImage: "waveform")
                    .font(.subheadline.weight(.medium))
                Text("Inicie a escuta com o app aberto").font(.footnote).foregroundStyle(ConsoleColor.muted)
            }
        }
        .tint(ConsoleColor.cyan).frame(minHeight: 44)
        .accessibilityHint("Permite iniciar pedidos locais por voz")
    }

    private var voiceButtonTitle: String {
        switch voiceState {
        case .ready: return "Falar com o Jarvis"
        case .listening: return "Terminar e enviar"
        case .processing: return "Aguardando resposta"
        case .speaking:
            if model.busy { return "Reproduzindo resposta" }
            return model.ready ? "Falar com o Jarvis" : "Reconectar ao PC"
        case .waiting: return "Reconectar ao PC"
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 7) {
                TextField("Escreva um pedido…", text: $draft, axis: .vertical)
                    .lineLimit(1...5).focused($field, equals: .command)
                    .padding(.leading, 14).padding(.vertical, 12)
                    .disabled(!canCompose)
                Button {
                    let value = command
                    guard !value.isEmpty, value.count <= 2000, canCompose else { return }
                    draft = ""; field = nil
                    Task { await model.say(value) }
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.borderless).accessibilityLabel("Enviar pedido")
                .disabled(command.isEmpty || command.count > 2000 || !canCompose)
            }
            .background(ConsoleColor.panel, in: RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(ConsoleColor.border) }
            if command.count > 2000 {
                Text("Reduza o pedido para até 2.000 caracteres.").font(.footnote).foregroundStyle(ConsoleColor.red)
            } else if !model.ready {
                Text("Sem internet, peça a hora, consulte a bateria ou controle a lanterna.")
                    .font(.footnote).foregroundStyle(ConsoleColor.muted)
            }
        }
    }

    private var toolsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Ferramentas")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 9), count: typeSize.isAccessibilitySize ? 1 : 2), spacing: 9) {
                if model.paired {
                    tool("Câmera", symbol: "camera.viewfinder", color: ConsoleColor.cyan, enabled: model.cameraAvailable) {
                        Task { await openCamera() }
                    }
                }
                tool(model.ready ? "Desenho no ar" : "Desenho na tela", symbol: "pencil.tip", color: ConsoleColor.gold, requiresPC: false) { model.openStudio("sketch") }
                tool("Instrumentos", symbol: "pianokeys", color: ConsoleColor.gold, requiresPC: false) { model.openStudio("music") }
                if model.paired {
                    tool("Libras", symbol: "hand.raised.fingers.spread", color: ConsoleColor.cyan) { model.openStudio("libras") }
                }
            }
        }
    }

    private func tool(_ title: String, symbol: String, color: Color, enabled: Bool = true, requiresPC: Bool = true,
                      action: @escaping () -> Void) -> some View {
        let available = enabled && canCompose && (!requiresPC || model.ready)
        return Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: symbol).font(.title3.weight(.medium)).foregroundStyle(color)
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 55, alignment: .topLeading)
            .padding(13)
            .background(ConsoleColor.panel, in: RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(ConsoleColor.border) }
        }
        .buttonStyle(.plain)
        .opacity(available ? 1 : 0.65)
        .disabled(!available)
    }

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Atalhos")
            VStack(spacing: 0) {
                shortcut("Gerar imagem", symbol: "photo") { draft = "Gere uma imagem de "; field = .command }
                Divider().overlay(ConsoleColor.border)
                shortcut("Último e-mail", symbol: "envelope") { Task { await model.say("Leia meu último e-mail") } }
                Divider().overlay(ConsoleColor.border)
                shortcut("Minha agenda", symbol: "calendar") { Task { await model.say("Quais são meus eventos de hoje?") } }
            }
            .padding(.horizontal, 14)
            .background(ConsoleColor.panel, in: RoundedRectangle(cornerRadius: 14))
            .disabled(!remoteAvailable)
        }
    }

    private func shortcut(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).frame(width: 22).foregroundStyle(ConsoleColor.gold)
                Text(title).foregroundStyle(.white)
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(ConsoleColor.muted)
            }
            .frame(minHeight: 46).contentShape(Rectangle()).opacity(remoteAvailable ? 1 : 0.65)
        }.buttonStyle(.plain)
    }

    private func latestMessage(_ line: RemoteAssistant.Line) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(line.user ? "Seu pedido" : "Resposta do Jarvis")
            Text(line.text).font(.body).lineLimit(5).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(ConsoleCard())
    }

    private var history: some View {
        DisclosureGroup(isExpanded: $historyExpanded) {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(model.lines) { line in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(line.user ? "Você" : "Jarvis").font(.footnote.weight(.semibold))
                            .foregroundStyle(line.user ? ConsoleColor.gold : ConsoleColor.cyan)
                        Text(line.text).textSelection(.enabled)
                    }
                }
            }
            .padding(.top, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Histórico", systemImage: "clock.arrow.circlepath").font(.headline)
        }
        .modifier(ConsoleCard())
    }

    private func photoConfirmation(_ photo: UIImage) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(uiImage: photo).resizable().scaledToFit().frame(maxHeight: 180)
                .accessibilityLabel("Foto capturada para análise")
            Text("Enviar esta foto para análise pela NVIDIA?").font(.headline)
            HStack {
                Button("Enviar foto") { preview = nil; Task { await model.analyze(photo) } }
                    .buttonStyle(.borderedProminent).disabled(!remoteAvailable || !model.cameraAvailable)
                Button("Descartar") { preview = nil }.buttonStyle(.bordered)
            }.controlSize(.large)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(ConsoleCard())
    }

    private func generatedImage(_ art: UIImage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Imagem gerada")
            Button { expanded = art } label: {
                Image(uiImage: art).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 14))
            }.accessibilityLabel("Ampliar imagem gerada pelo Jarvis")
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.headline).accessibilityAddTraits(.isHeader)
    }

    private func actionLabel(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol).font(.body.weight(.bold))
            .frame(maxWidth: .infinity, minHeight: 48).contentShape(Rectangle())
    }

    private var scannerSheet: some View {
        NavigationStack {
            QRReader(accept: { value in scanning = false; pair(value) }, failure: {
                scanning = false
                scannerFallback("Não consegui abrir o leitor. Cole o código do painel do PC.")
            })
            .navigationTitle("Ler QR do PC").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Fechar") { scanning = false } } }
        }
    }

    private func reconnect() { model.drop(); model.connect() }

    private func pair(_ value: String) {
        guard !pairing, !model.paired else { return }
        field = nil
        pairing = true
        Task {
            await model.pair(value)
            pairing = false
        }
    }

    private func scannerFallback(_ message: String) {
        model.message = message
        manualPairing = true
    }

    @MainActor private func openScanner() async {
        guard DataScannerViewController.isSupported else {
            scannerFallback("Cole o código que aparece ao lado do QR no computador."); return
        }
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            scannerFallback("Autorize a câmera em Ajustes ou cole o código do painel do PC."); return
        }
        guard DataScannerViewController.isAvailable else {
            scannerFallback("Leitor indisponível. Cole o código do painel do PC."); return
        }
        scanning = true
    }

    @MainActor private func openCamera() async {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            model.message = "A câmera não está disponível neste aparelho."; return
        }
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            model.message = "Autorize a câmera em Ajustes."; return
        }
        camera = true
    }
}

private struct ConsoleCard: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(16)
            .background(ConsoleColor.panel, in: RoundedRectangle(cornerRadius: 20))
            .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(ConsoleColor.border) }
    }
}

private struct ConsoleAction: ButtonStyle {
    let color: Color
    @Environment(\.isEnabled) private var enabled

    init(color: Color) { self.color = color }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(ConsoleColor.background)
            .background(color.opacity(configuration.isPressed ? 0.82 : 1), in: RoundedRectangle(cornerRadius: 12))
            .opacity(enabled ? 1 : 0.68)
    }
}

private struct MaskDisplay: View {
    let accent: Color
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(accent: Color, active: Bool) {
        self.accent = accent
        self.active = active
    }

    var body: some View {
        ZStack {
            RadialGradient(colors: [accent.opacity(0.16), ConsoleColor.inset], center: .center, startRadius: 12, endRadius: 120)
            TimelineView(.animation(minimumInterval: 1.0 / 18, paused: !active || reduceMotion)) { moment in
                Canvas { context, size in
                    let center = CGPoint(x: size.width / 2, y: size.height / 2)
                    let r = min(size.height * 0.43, size.width * 0.35)
                    let bounds = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
                    let pulse = active && !reduceMotion ? (sin(moment.date.timeIntervalSinceReferenceDate * 4) + 1) / 2 : 0.4
                    context.stroke(Path(ellipseIn: bounds), with: .color(accent.opacity(0.2)), lineWidth: 0.75)
                    context.stroke(Path(ellipseIn: bounds.insetBy(dx: 7, dy: 7)), with: .color(accent.opacity(0.13)), lineWidth: 0.5)
                    for start in [-72.0, 18.0, 108.0, 198.0] {
                        var arc = Path()
                        arc.addArc(center: center, radius: r + 3, startAngle: .degrees(start),
                                   endAngle: .degrees(start + 32), clockwise: false)
                        context.stroke(arc, with: .color(accent.opacity(0.44 + pulse * 0.4)), lineWidth: 1.5)
                    }
                    var marks = Path()
                    for index in 0..<48 {
                        let angle = CGFloat(index) * .pi / 24
                        let dx = cos(angle), dy = sin(angle)
                        let inner = r + 6, outer = inner + (index.isMultiple(of: 4) ? 4 : 1.5)
                        marks.move(to: CGPoint(x: center.x + dx * inner, y: center.y + dy * inner))
                        marks.addLine(to: CGPoint(x: center.x + dx * outer, y: center.y + dy * outer))
                    }
                    context.stroke(marks, with: .color(accent.opacity(0.30)), lineWidth: 0.7)
                    var rails = Path()
                    for direction: CGFloat in [-1, 1] {
                        let edge = direction < 0 ? CGFloat(10) : size.width - 10
                        rails.move(to: CGPoint(x: edge, y: center.y))
                        rails.addLine(to: CGPoint(x: center.x + direction * (r + 14), y: center.y))
                        for index in 0..<3 {
                            let x = edge - direction * CGFloat(index * 5)
                            rails.move(to: CGPoint(x: x, y: center.y - 3))
                            rails.addLine(to: CGPoint(x: x, y: center.y + 3))
                        }
                    }
                    context.stroke(rails, with: .color(accent.opacity(0.33)), lineWidth: 0.75)
                }
            }
            Image("AssistantMask").resizable().scaledToFit().padding(.vertical, 14)
                .shadow(color: .black.opacity(0.75), radius: 6, y: 4)
        }
        .frame(height: 167)
        .clipShape(RoundedRectangle(cornerRadius: 13))
        .accessibilityHidden(true)
    }
}


private struct QRReader: UIViewControllerRepresentable {
    var accept:(String)->Void
    var failure:()->Void
    final class Coordinator:NSObject, DataScannerViewControllerDelegate {
        let accept:(String)->Void
        init(_ a:@escaping(String)->Void){accept=a}
        func dataScanner(_ dataScanner:DataScannerViewController,didAdd addedItems:[RecognizedItem],allItems:[RecognizedItem]){
            for case let .barcode(code) in addedItems { if let s=code.payloadStringValue,PhoneMedia.pairingCode(s) != nil {dataScanner.stopScanning();accept(s);return} }
        }
        func dataScanner(_ dataScanner:DataScannerViewController,didTapOn item:RecognizedItem){if case .barcode(let b)=item,let s=b.payloadStringValue,PhoneMedia.pairingCode(s) != nil {accept(s)}}
    }
    func makeCoordinator()->Coordinator{Coordinator(accept)}
    final class Host:UIViewController {
        let scanner=DataScannerViewController(recognizedDataTypes:[.barcode(symbologies:[.qr])],recognizesMultipleItems:false,isHighlightingEnabled:true)
        var failure:(()->Void)?
        override func viewDidLoad(){super.viewDidLoad();addChild(scanner);scanner.view.frame=view.bounds;scanner.view.autoresizingMask=[.flexibleWidth,.flexibleHeight];view.addSubview(scanner.view);scanner.didMove(toParent:self)}
        override func viewDidAppear(_ animated:Bool){super.viewDidAppear(animated);do{try scanner.startScanning()}catch{failure?()}}
        override func viewWillDisappear(_ animated:Bool){scanner.stopScanning();super.viewWillDisappear(animated)}
    }
    func makeUIViewController(context:Context)->Host{let h=Host();h.scanner.delegate=context.coordinator;h.failure=failure;return h}
    func updateUIViewController(_ host:Host,context:Context){}
}
private struct StudioWeb:UIViewRepresentable {
    let mode:String,origin:String
    var submit:(String)->Void
    final class Delegate:NSObject, WKNavigationDelegate,WKScriptMessageHandler{
        let origin:String;let submit:(String)->Void
        init(_ origin:String,_ submit:@escaping(String)->Void){self.origin=origin;self.submit=submit}
        func userContentController(_ controller:WKUserContentController,didReceive message:WKScriptMessage){
            guard message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.protocol=="https",message.frameInfo.securityOrigin.host==URL(string:origin)?.host,
                  let text=message.body as? String,!text.isEmpty,text.count<=1200 else{return};submit(text)
        }
        func webView(_ v:WKWebView,decidePolicyFor nav:WKNavigationAction,decisionHandler:@escaping(WKNavigationActionPolicy)->Void){
            let u=nav.request.url;decisionHandler(u?.scheme=="https" && u?.host==URL(string:origin)?.host && u?.path.hasPrefix("/studio/")==true ? .allow:.cancel)
        }
    }
    func makeCoordinator()->Delegate{Delegate(origin,submit)}
    func makeUIView(context:Context)->WKWebView{
        let cfg=WKWebViewConfiguration();cfg.websiteDataStore = .nonPersistent();cfg.allowsInlineMediaPlayback=true
        cfg.userContentController.add(context.coordinator,name:"jarvisSubmit")
        let v=WKWebView(frame:.zero,configuration:cfg);v.navigationDelegate=context.coordinator
        if let token=PairingStore.read(),let base=URL(string:origin),let domain=base.host,let url=URL(string:origin+"/studio/index.html?mode="+mode),
           let cookie=HTTPCookie(properties:[.domain:domain,.path:"/",.name:"__Host-jarvis",.value:token,.secure:"TRUE",HTTPCookiePropertyKey("HttpOnly"):"TRUE"]){
            cfg.websiteDataStore.httpCookieStore.setCookie(cookie){v.load(URLRequest(url:url))}
        };return v
    }
    func updateUIView(_ v:WKWebView,context:Context){}
    static func dismantleUIView(_ v:WKWebView,coordinator:Delegate){v.configuration.userContentController.removeScriptMessageHandler(forName:"jarvisSubmit");v.stopLoading()}
}
