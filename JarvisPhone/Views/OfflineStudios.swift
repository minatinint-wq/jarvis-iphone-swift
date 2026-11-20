import AVFoundation
import PencilKit
import SwiftUI
import UIKit

@MainActor private final class SketchDocument: NSObject, ObservableObject, PKCanvasViewDelegate {
    let canvas = PKCanvasView()
    @Published var error: String?
    private var saveJob: Task<Void, Never>?
    private var file: URL?
    private var dirty = false

    override init() {
        super.init()
        canvas.drawingPolicy = .anyInput
        canvas.backgroundColor = .white
        canvas.overrideUserInterfaceStyle = .light
        canvas.isOpaque = true
        canvas.isScrollEnabled = false
        canvas.tool = PKInkingTool(.pen, color: .black, width: 5)
        do {
            let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                          appropriateFor: nil, create: true)
            let url = directory.appendingPathComponent("Desenho.pkdrawing")
            if FileManager.default.fileExists(atPath: url.path) {
                canvas.drawing = try PKDrawing(data: Data(contentsOf: url))
            }
            file = url
        } catch { self.error = "Não consegui abrir o desenho salvo neste iPhone." }
        canvas.delegate = self
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        dirty = true
        saveJob?.cancel()
        saveJob = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            if !Task.isCancelled { self?.save() }
        }
    }

    func save() {
        guard dirty, let file else { return }
        do {
            try canvas.drawing.dataRepresentation().write(to: file, options: [.atomic, .completeFileProtection])
            dirty = false
            error = nil
        } catch { self.error = "Não consegui salvar as últimas alterações neste iPhone." }
    }
}

private struct DrawingSurface: UIViewRepresentable {
    let canvas: PKCanvasView
    func makeUIView(context: Context) -> PKCanvasView { canvas }
    func updateUIView(_ view: PKCanvasView, context: Context) {}
}

@MainActor struct OfflineSketch: View {
    @StateObject private var document = SketchDocument()
    @State private var color = Color.black
    @State private var erasing = false
    @State private var confirmClear = false
    @Environment(\.scenePhase) private var phase

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                ColorPicker("Cor", selection: $color, supportsOpacity: false)
                    .fixedSize()
                    .onChange(of: color) { _, shade in
                        erasing = false
                        document.canvas.tool = PKInkingTool(.pen, color: UIColor(shade), width: 5)
                    }
                Spacer()
                Button {
                    erasing.toggle()
                    if erasing { document.canvas.tool = PKEraserTool(.bitmap) }
                    else { document.canvas.tool = PKInkingTool(.pen, color: UIColor(color), width: 5) }
                } label: { Image(systemName: erasing ? "eraser.fill" : "eraser") }
                .accessibilityLabel(erasing ? "Voltar à caneta" : "Apagar traços")
                Button { document.canvas.undoManager?.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .accessibilityLabel("Desfazer")
                Button { document.canvas.undoManager?.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .accessibilityLabel("Refazer")
                Button { confirmClear = true } label: { Image(systemName: "trash") }.accessibilityLabel("Limpar desenho")
            }
            .buttonStyle(.bordered).controlSize(.large).padding(.horizontal, 12)
            DrawingSurface(canvas: document.canvas)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 10)
                .accessibilityLabel("Tela de desenho com o dedo")
            Text(document.error ?? "Seu desenho é salvo neste iPhone.")
                .font(.footnote).foregroundStyle(.secondary).padding(.bottom, 8)
        }
        .onDisappear { document.save() }
        .onChange(of: phase) { _, phase in if phase != .active { document.save() } }
        .confirmationDialog("Limpar o desenho?", isPresented: $confirmClear) {
            Button("Limpar", role: .destructive) { document.canvas.drawing = PKDrawing(); document.canvasViewDrawingDidChange(document.canvas) }
        }
    }
}

enum StudioInstrument: String, CaseIterable, Identifiable {
    case harp = "Harpa", piano = "Piano", guitar = "Violão", bass = "Baixo", strings = "Cordas", flute = "Flauta", drums = "Bateria"
    var id: Self { self }
    var program: UInt8 {
        switch self {
        case .piano, .drums: return 0
        case .harp: return 46
        case .guitar: return 24
        case .bass: return 33
        case .strings: return 48
        case .flute: return 73
        }
    }
}

@MainActor final class InstrumentPlayer: ObservableObject {
    @Published var error: String?
    private let engine = AVAudioEngine()
    private let sampler = AVAudioUnitSampler()
    private let session = AVAudioSession.sharedInstance()
    private var loaded: StudioInstrument?
    private var activeNotes: Set<UInt8> = []
    private var releases: [UInt8: Task<Void, Never>] = [:]
    private var ownsSession = false

    init() {
        engine.attach(sampler)
        engine.connect(sampler, to: engine.mainMixerNode, format: nil)
    }

    @discardableResult func configure(_ instrument: StudioInstrument) -> Bool {
        silence()
        do {
            if !ownsSession {
                try session.setCategory(.playback, mode: .default, options: .mixWithOthers)
                try session.setActive(true)
                ownsSession = true
            }
            if instrument != loaded {
                guard let bank = Bundle.main.url(forResource: "JarvisInstruments", withExtension: "sf2") else {
                    throw NSError(domain: "JarvisMusic", code: 1, userInfo: [NSLocalizedDescriptionKey: "Banco de instrumentos indisponível."])
                }
                try sampler.loadSoundBankInstrument(at: bank, program: instrument.program,
                                                    bankMSB: instrument == .drums ? 0x78 : 0x79, bankLSB: 0)
                loaded = instrument
            }
            if !engine.isRunning { engine.prepare(); try engine.start() }
            error = nil
            return true
        } catch { stop(); self.error = error.localizedDescription; return false }
    }

    func press(_ note: UInt8, velocity: UInt8 = 96) {
        if !engine.isRunning, let loaded, !configure(loaded) { return }
        guard engine.isRunning else { return }
        release(note)
        activeNotes.insert(note)
        sampler.startNote(note, withVelocity: velocity, onChannel: 0)
    }

    func release(_ note: UInt8) {
        releases.removeValue(forKey: note)?.cancel()
        if activeNotes.remove(note) != nil { sampler.stopNote(note, onChannel: 0) }
    }

    func play(_ note: UInt8, instrument: StudioInstrument, velocity: UInt8, duration: Int, volume: Float) -> Bool {
        if (instrument != loaded || !engine.isRunning), !configure(instrument) { return false }
        engine.mainMixerNode.outputVolume = min(1, max(0, volume))
        press(note, velocity: velocity)
        releases[note] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration) * 1_000_000)
            guard !Task.isCancelled else { return }
            self?.release(note)
        }
        return true
    }

    func silence() {
        for note in Array(activeNotes) { release(note) }
    }

    func stop() {
        silence()
        engine.stop()
        if ownsSession && session.category == .playback { try? session.setActive(false, options: .notifyOthersOnDeactivation) }
        ownsSession = false
    }
}

@MainActor private final class InstrumentKey: UIButton {
    var down: (() -> Void)?
    var up: (() -> Void)?
    override var isHighlighted: Bool { didSet { alpha = isHighlighted ? 0.58 : 1 } }
    @objc func pressed() { down?() }
    @objc func released() { up?() }
    override func accessibilityActivate() -> Bool {
        pressed()
        let release = up
        Task { try? await Task.sleep(nanoseconds: 300_000_000); release?() }
        return true
    }
}

private struct NoteButton: UIViewRepresentable {
    let title: String
    let dark: Bool
    let note: UInt8
    let player: InstrumentPlayer

    func makeUIView(context: Context) -> InstrumentKey {
        let key = InstrumentKey(type: .custom)
        key.addTarget(key, action: #selector(InstrumentKey.pressed), for: [.touchDown, .touchDragEnter])
        key.addTarget(key, action: #selector(InstrumentKey.released), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
        key.layer.cornerRadius = 7
        key.layer.borderWidth = 1
        key.layer.borderColor = UIColor.systemGray.cgColor
        key.titleLabel?.font = UIFont.preferredFont(forTextStyle: .caption1)
        key.titleLabel?.adjustsFontSizeToFitWidth = true
        return key
    }

    func updateUIView(_ key: InstrumentKey, context: Context) {
        key.setTitle(title, for: .normal)
        key.setTitleColor(dark ? .white : .black, for: .normal)
        key.backgroundColor = dark ? UIColor(white: 0.13, alpha: 1) : UIColor(white: 0.94, alpha: 1)
        key.accessibilityLabel = title.replacingOccurrences(of: "♯", with: " sustenido")
        key.down = { player.press(note) }
        key.up = { player.release(note) }
    }
}

@MainActor struct OfflineInstruments: View {
    @StateObject private var player = InstrumentPlayer()
    @State private var instrument = StudioInstrument.piano
    @State private var octave = 4
    @Environment(\.scenePhase) private var phase
    private let natural = ["Dó", "Ré", "Mi", "Fá", "Sol", "Lá", "Si", "Dó"]
    private let naturalNotes = [0, 2, 4, 5, 7, 9, 11, 12]
    private let sharpKeys = [0, 1, 3, 4, 5]
    private let percussion = [("Bumbo", 36), ("Caixa", 38), ("Chimbal", 42), ("Chimbal aberto", 46), ("Tom", 45), ("Prato", 49)]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Instrumento", selection: $instrument) {
                ForEach(StudioInstrument.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.menu).font(.title3).accessibilityLabel("Escolher instrumento")
            if instrument == .drums {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(percussion.indices, id: \.self) { i in
                        NoteButton(title: percussion[i].0, dark: true, note: UInt8(percussion[i].1), player: player)
                            .frame(height: 78)
                    }
                }
            } else {
                Stepper("Oitava \(octave)", value: $octave, in: 2...5)
                    .onChange(of: octave) { _, _ in player.silence() }
                GeometryReader { geometry in
                    let width = geometry.size.width / 8
                    ZStack(alignment: .topLeading) {
                        HStack(spacing: 0) {
                            ForEach(natural.indices, id: \.self) { i in
                                NoteButton(title: natural[i], dark: false, note: note(naturalNotes[i]), player: player)
                                    .frame(width: width, height: geometry.size.height)
                            }
                        }
                        ForEach(sharpKeys, id: \.self) { i in
                            NoteButton(title: natural[i] + "♯", dark: true, note: note(naturalNotes[i] + 1), player: player)
                                .frame(width: width * 0.72, height: geometry.size.height * 0.56)
                                .offset(x: width * (CGFloat(i + 1) - 0.36))
                        }
                    }
                }
                .frame(minHeight: 130, idealHeight: 220, maxHeight: 340)
            }
            if let error = player.error {
                Text(error).font(.footnote)
                Button("Tentar ativar o som") { player.configure(instrument) }.buttonStyle(.bordered)
            }
            Text("GeneralUser GS · S. Christian Collins").font(.footnote).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding()
        .onAppear { player.configure(instrument) }
        .onChange(of: instrument) { _, choice in player.configure(choice) }
        .onChange(of: phase) { _, phase in
            if phase == .active { player.configure(instrument) } else { player.stop() }
        }
        .onDisappear { player.stop() }
    }

    private func note(_ step: Int) -> UInt8 { UInt8((octave + 1) * 12 + step) }
}
