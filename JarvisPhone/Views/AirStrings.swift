import AVFoundation
import Combine
import SwiftUI
import Vision

// The capture queue owns the camera and Vision request. Preview and observations
// both use a mirrored portrait image, so the cursor follows the visible fingertip.
private final class AirHandCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "jarvis.air-strings.camera", qos: .userInitiated)
    private let request = VNDetectHumanHandPoseRequest()
    private var configured = false
    private var lastFrame = -Double.infinity
    var onHand: ((CGPoint?, Double, Double) -> Void)?
    var onError: ((String) -> Void)?
    override init() { super.init(); request.maximumHandCount = 1 }
    func start() {
        queue.async {
            do {
                if !self.configured {
                    self.session.beginConfiguration()
                    defer { self.session.commitConfiguration() }
                    self.session.sessionPreset = .vga640x480
                    guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
                        throw NSError(domain: "AirStrings", code: 1)
                    }
                    let input = try AVCaptureDeviceInput(device: device)
                    guard self.session.canAddInput(input) else { throw NSError(domain: "AirStrings", code: 2) }
                    self.session.addInput(input)
                    let output = AVCaptureVideoDataOutput()
                    output.alwaysDiscardsLateVideoFrames = true
                    output.setSampleBufferDelegate(self, queue: self.queue)
                    guard self.session.canAddOutput(output) else {
                        self.session.removeInput(input)
                        throw NSError(domain: "AirStrings", code: 3)
                    }
                    self.session.addOutput(output)
                    if let connection = output.connection(with: .video) {
                        if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
                        connection.automaticallyAdjustsVideoMirroring = false
                        if connection.isVideoMirroringSupported { connection.isVideoMirrored = true }
                    }
                    self.configured = true
                }
                if !self.session.isRunning { self.session.startRunning() }
            } catch { self.onError?("A câmera frontal não abriu. Confira a permissão nos Ajustes.") }
        }
    }
    func stop() { queue.async { if self.session.isRunning { self.session.stopRunning() } } }
    func captureOutput(_ output: AVCaptureOutput, didOutput buffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let time = ProcessInfo.processInfo.systemUptime
        guard time - lastFrame >= 1.0 / 24 else { return }
        lastFrame = time
        do {
            try VNImageRequestHandler(cmSampleBuffer: buffer, orientation: .up).perform([request])
            guard let hand = request.results?.first else { onHand?(nil, 1, time); return }
            let joints = try hand.recognizedPoints(.all)
            guard let index = joints[.indexTip], let thumb = joints[.thumbTip],
                  let wrist = joints[.wrist], let knuckle = joints[.middleMCP],
                  [index, thumb, wrist, knuckle].allSatisfy({ $0.confidence >= 0.55 }) else {
                onHand?(nil, 1, time); return
            }
            func point(_ p: VNRecognizedPoint) -> CGPoint { CGPoint(x: p.location.x, y: 1 - p.location.y) }
            let scale = AirStringBoard.distance(point(wrist), point(knuckle))
            guard scale > 0.055 else { onHand?(nil, 1, time); return }
            let ratio = AirStringBoard.distance(point(index), point(thumb)) / scale
            onHand?(point(index), ratio, time)
        } catch { onHand?(nil, 1, time) }
    }
}

private final class AirPreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    override func layoutSubviews() {
        super.layoutSubviews()
        if let connection = preview.connection {
            if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
            connection.automaticallyAdjustsVideoMirroring = false
            if connection.isVideoMirroringSupported { connection.isVideoMirrored = true }
        }
    }
}
private struct AirPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> AirPreviewView {
        let view = AirPreviewView()
        view.backgroundColor = .black
        view.preview.session = session
        view.preview.videoGravity = .resizeAspect
        return view
    }
    func updateUIView(_ view: AirPreviewView, context: Context) { view.setNeedsLayout() }
}

@MainActor private final class AirInstrument: ObservableObject {
    @Published var board = AirStringBoard()
    @Published var finger: CGPoint?
    @Published var message = "Puxe uma corda e solte. Use a câmera para tocar no ar."
    @Published var cameraEnabled = false
    @Published var instrument = StudioInstrument.harp
    @Published var volume: Float = 0.55
    let camera = AirHandCamera()
    let player = InstrumentPlayer()
    private var active = false
    private var lastSeen = -Double.infinity
    init() {
        board.preset()
        camera.onHand = { [weak self] point, ratio, time in
            Task { @MainActor in self?.consume(point, ratio: ratio, time: time) }
        }
        camera.onError = { [weak self] text in
            Task { @MainActor in self?.message = text; self?.cameraEnabled = false }
        }
    }
    func activate() {
        active = true
        if !player.configure(instrument) { message = player.error ?? "O som não iniciou." }
        if cameraEnabled { camera.start() }
    }
    func pause() { active = false; board.resetGesture(); finger = nil; camera.stop(); player.stop() }
    func enableCamera() async {
        let allowed = await AVCaptureDevice.requestAccess(for: .video)
        guard active, !Task.isCancelled else { return }
        guard allowed else { message = "Permita a câmera nos Ajustes para tocar com a mão."; return }
        cameraEnabled = true; camera.start()
        message = "Mostre uma mão inteira, com boa iluminação."
    }
    func disableCamera() { cameraEnabled = false; camera.stop(); board.resetGesture(); finger = nil }
    func switchMode(_ mode: AirStringBoard.Mode) {
        board.mode = mode; player.silence()
        message = mode == .create ? "Abra os dedos, faça pinça, estique e solte para criar." : "Faça pinça sobre a corda, puxe para o lado e solte."
    }
    func setInstrument() {
        if !player.configure(instrument) { message = player.error ?? "O timbre não carregou." }
    }
    private func consume(_ point: CGPoint?, ratio: Double, time: Double) {
        guard active, cameraEnabled else { return }
        guard let point else {
            if time - lastSeen > 0.18 { finger = nil; board.resetGesture(); message = "Mostre a mão inteira para retomar." }
            return
        }
        lastSeen = time
        let smooth = finger.map { CGPoint(x:$0.x+(point.x-$0.x)*0.65,y:$0.y+(point.y-$0.y)*0.65) } ?? point
        finger = smooth
        let notes = board.consume(point: smooth, pinchRatio: ratio, time: time)
        message = board.mode == .play ? (board.held != nil ? "Corda presa · abra a pinça para tocar" : "Faça pinça sobre a corda, puxe e solte") : board.anchor != nil
            ? "Estique a corda e solte a pinça" : "Abra os dedos, faça pinça, estique e solte"
        sound(notes)
    }
    func sound(_ notes: [AirStringBoard.Pluck]) {
        for note in notes {
            if !player.play(note.note, instrument: instrument, velocity: note.velocity, duration: 1600, volume: volume) {
                message = player.error ?? "Não consegui iniciar o som."
            }
        }
    }
    func touch(_ point: CGPoint, begin: Bool) {
        if begin { board.resetGesture(); board.beginPull(point) }
        board.dragPull(point)
    }
    func releaseTouch() { sound(board.endPull(time: ProcessInfo.processInfo.systemUptime)) }
}

@MainActor struct AirStrings: View {
    @StateObject private var model = AirInstrument()
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var touchStart: CGPoint?
    @State private var touchEnd: CGPoint?
    @State private var showKeys = false
    @State private var touching = false
    private let tones: [StudioInstrument] = [.harp, .guitar, .piano, .bass, .strings, .flute]
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("HARPA NO AR").font(.caption.weight(.black)).tracking(3).foregroundStyle(.cyan)
                    Text(model.board.held != nil ? "Puxe. Solte. Sinta o som." : "O instrumento acompanha sua mão.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Harpa pronta") { model.board.preset(); model.player.silence() }.font(.caption)
            }
            HStack {
                Picker("Modo", selection: Binding(get: { model.board.mode }, set: { model.switchMode($0) })) {
                    ForEach(AirStringBoard.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                Picker("Timbre", selection: $model.instrument) {
                    ForEach(tones) { Text($0.rawValue).tag($0) }
                }.onChange(of: model.instrument) { _, _ in model.setInstrument() }
            }
            GeometryReader { geometry in
                let width = min(geometry.size.width, geometry.size.height * 3 / 4)
                let size = CGSize(width: width, height: width * 4 / 3)
                ZStack {
                    Color(red: 0.02, green: 0.035, blue: 0.06)
                    if model.cameraEnabled { AirPreview(session: model.camera.session).opacity(0.65) }
                    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || phase != .active)) { _ in
                        Canvas { context, canvasSize in
                            draw(&context, size: canvasSize, time: ProcessInfo.processInfo.systemUptime)
                        }
                    }.allowsHitTesting(false)
                    VStack {
                        HStack {
                            Text("\(model.board.strings.count)/12 cordas").font(.caption.monospacedDigit())
                            Spacer()
                            if model.board.anchor != nil { Text("CRIANDO").font(.caption.bold()).foregroundStyle(.orange) }
                        }
                        Spacer()
                        if model.board.strings.isEmpty {
                            Text("Crie suas próprias cordas")
                                .font(.title3.weight(.semibold))
                            Text("Arraste na tela ou abra a câmera e use a pinça.")
                                .font(.subheadline).multilineTextAlignment(.center)
                        }
                        Spacer()
                    }.padding(14).allowsHitTesting(false)
                }
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    func normalized(_ p: CGPoint) -> CGPoint {
                        CGPoint(x: min(1, max(0, p.x / size.width)), y: min(1, max(0, p.y / size.height)))
                    }
                    if model.board.mode == .create {
                        touchStart = normalized(value.startLocation); touchEnd = normalized(value.location)
                    } else { model.touch(normalized(value.location), begin: !touching); touching = true }
                }.onEnded { _ in
                    if model.board.mode == .create, let start = touchStart, let end = touchEnd { _ = model.board.add(from: start, to: end) }
                    if touching { model.releaseTouch() }; touching = false
                    touchStart = nil; touchEnd = nil
                })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Text(model.message).font(.footnote).foregroundStyle(.secondary).frame(minHeight: 32)
            HStack(spacing: 16) {
                Button { if model.cameraEnabled { model.disableCamera() } else { Task { await model.enableCamera() } } } label: {
                    Label(model.cameraEnabled ? "Parar câmera" : "Usar mão", systemImage: "hand.draw")
                }
                Spacer()
                Button { model.board.undo(); model.player.silence() } label: { Image(systemName: "arrow.uturn.backward") }
                    .accessibilityLabel("Remover última corda").disabled(model.board.strings.isEmpty)
                Button { model.board.clear(); model.player.silence() } label: { Image(systemName: "trash") }
                    .accessibilityLabel("Limpar cordas").disabled(model.board.strings.isEmpty)
            }.buttonStyle(.bordered)
            HStack {
                Image(systemName: "speaker.wave.2")
                Slider(value: $model.volume, in: 0...1).accessibilityLabel("Volume dos instrumentos")
                Button("Teclas e bateria") { showKeys = true }
            }.font(.caption)
        }
        .padding(.horizontal, 14).padding(.bottom, 10)
        .background(Color(red: 0.025, green: 0.035, blue: 0.05))
        .onAppear { model.activate() }
        .onDisappear { model.pause() }
        .onChange(of: phase) { _, value in if value == .active && !showKeys { model.activate() } else { model.pause() } }
        .sheet(isPresented: $showKeys, onDismiss: { if phase == .active { model.activate() } }) {
            VStack {
                HStack { Text("Teclas e bateria").font(.headline); Spacer(); Button("Fechar") { showKeys = false } }.padding()
                OfflineInstruments()
            }.onAppear { model.pause() }
        }
    }
    private func draw(_ context: inout GraphicsContext, size: CGSize, time: Double) {
        func pixel(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * size.width, y: p.y * size.height) }
        let palette: [Color] = [.cyan, .orange, .mint, .pink, .purple]
        for (index, string) in model.board.strings.enumerated() {
            let a = pixel(string.start), b = pixel(string.end)
            let age = time - string.lastHit
            let color = palette[index % palette.count]
            var path = Path()
            for step in 0...48 {
                let t = Double(step) / 48
                let offset = model.board.offset(index:index,position:t,time:time,reducedMotion:reduceMotion)
                let p = CGPoint(x: a.x + (b.x - a.x) * t + offset.x * size.width, y: a.y + (b.y - a.y) * t + offset.y * size.height)
                if step == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            context.stroke(path, with: .color(color.opacity(0.09)), lineWidth: 14)
            context.stroke(path, with: .color(color.opacity(0.20)), lineWidth: 6)
            context.stroke(path, with: .color(color.opacity(0.90)), lineWidth: model.board.held?.index == index ? 3 : 1.6)
            for endpoint in [a, b] { context.fill(Path(ellipseIn: CGRect(x: endpoint.x - 3, y: endpoint.y - 3, width: 6, height: 6)), with: .color(color)) }
            context.draw(Text(string.label).font(.caption2.weight(.semibold)).foregroundColor(color), at: CGPoint(x: a.x + 8, y: max(10, a.y - 12)), anchor: .leading)
            if !reduceMotion && (0...0.7).contains(age) {
                let hit = string.hitPosition
                for particle in 0..<10 {
                    let direction = Double(particle) * 2.399
                    let radius = age * Double(15 + particle * 6)
                    let x = a.x + (b.x - a.x) * hit + cos(direction) * radius
                    let y = a.y + (b.y - a.y) * hit + sin(direction) * radius
                    context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 2.5, height: 2.5)), with: .color(color.opacity(max(0, 0.8 - age))))
                }
            }
        }
        if let a = touchStart ?? model.board.anchor, let b = touchEnd ?? model.finger {
            var path = Path(); path.move(to: pixel(a)); path.addLine(to: pixel(b))
            context.stroke(path, with: .color(.orange), style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
        }
        if let finger = model.finger {
            let p = pixel(finger)
            context.stroke(Path(ellipseIn: CGRect(x: p.x - 8, y: p.y - 8, width: 16, height: 16)), with: .color(.mint), lineWidth: 2)
        }
    }
}
