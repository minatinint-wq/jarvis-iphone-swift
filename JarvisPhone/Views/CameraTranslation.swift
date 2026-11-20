import SwiftUI
import Vision
import NaturalLanguage
import Translation
import AVFoundation

struct CameraTextLine: Identifiable {
    let id: Int
    let text: String
    let box: CGRect
}

enum CameraTextReader {
    static func read(_ image: CGImage) throws -> [CameraTextLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage:image).perform([request])
        return (request.results ?? []).prefix(60).enumerated().compactMap { index, observation in
            guard let text = observation.topCandidates(1).first, text.confidence >= 0.35 else { return nil }
            return CameraTextLine(id:index,text:text.string,box:observation.boundingBox)
        }
    }
}

@available(iOS 18.0, *)
@MainActor struct CameraTranslation: View {
    @State private var photo: UIImage?
    @State private var lines: [CameraTextLine] = []
    @State private var translated: [Int:String] = [:]
    @State private var configuration: TranslationSession.Configuration?
    @State private var camera = false
    @State private var working = false
    @State private var message = "Aponte para um texto e capture a imagem."
    @State private var generation = 0
    @State private var target = "pt"
    @State private var overlay = true
    @State private var job: Task<Void,Never>?

    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:16) {
                HStack {
                    Picker("Traduzir para",selection:$target) {
                        Text("Português").tag("pt"); Text("Inglês").tag("en"); Text("Espanhol").tag("es")
                    }.disabled(working)
                    Spacer()
                    Button("Nova foto") { Task { await openCamera() } }.disabled(working)
                }
                if let photo {
                    GeometryReader { geometry in
                        ZStack(alignment:.topLeading) {
                            Image(uiImage:photo).resizable().scaledToFit()
                            if overlay {
                                ForEach(lines) { line in
                                    if let text = translated[line.id] {
                                        Text(text).font(.system(size:12,weight:.medium)).foregroundStyle(.white)
                                            .padding(3).frame(width:max(55,line.box.width*geometry.size.width),alignment:.leading)
                                            .background(.black.opacity(0.82)).clipShape(RoundedRectangle(cornerRadius:3))
                                            .offset(x:line.box.minX*geometry.size.width,y:(1-line.box.maxY)*geometry.size.height)
                                    }
                                }
                            }
                        }.clipped()
                    }.aspectRatio(photo.size.width/photo.size.height,contentMode:.fit)
                    Toggle("Tradução sobre a foto",isOn:$overlay)
                } else {
                    ContentUnavailableView("Traduzir pela câmera",systemImage:"character.viewfinder",description:Text("Placas, cardápios e textos impressos. Capture pela câmera traseira."))
                }
                HStack { if working { ProgressView() }; Text(message).font(.footnote).foregroundStyle(.secondary) }
                if !lines.isEmpty && !working { Button("Traduzir novamente") { translate() } }
                ForEach(lines) { line in
                    VStack(alignment:.leading,spacing:5) {
                        Text(line.text).font(.caption).foregroundStyle(.secondary)
                        Text(translated[line.id] ?? "…").textSelection(.enabled)
                    }.padding(10).frame(maxWidth:.infinity,alignment:.leading).background(.white.opacity(0.05)).clipShape(RoundedRectangle(cornerRadius:10))
                }
                Text("Reconhecimento do texto no iPhone. A tradução usa os idiomas da Apple e pode pedir um download na primeira vez.").font(.caption).foregroundStyle(.secondary)
            }.padding()
        }
        .sheet(isPresented:$camera) {
            CameraCapture(onCapture:{ image in camera=false; recognize(image) },onCancel:{ camera=false })
        }
        .translationTask(configuration) { session in
            let own = generation, snapshot = lines
            guard !snapshot.isEmpty else { return }
            do {
                let requests = snapshot.map { TranslationSession.Request(sourceText:$0.text,clientIdentifier:String($0.id)) }
                let result = try await session.translations(from:requests)
                guard !Task.isCancelled, own == generation else { return }
                translated = Dictionary(uniqueKeysWithValues:result.compactMap { response -> (Int,String)? in
                    guard let id=response.clientIdentifier.flatMap(Int.init) else { return nil }
                    return (id,response.targetText)
                })
                message = "Tradução pronta. O texto original está disponível abaixo."; working=false
            } catch {
                guard own == generation else { return }
                message="A tradução não terminou. Confira os idiomas baixados e tente novamente."; working=false
            }
        }
        .onChange(of:target) { _, _ in translate() }
        .onDisappear { generation += 1; job?.cancel(); configuration=nil }
        .task { await openCamera() }
    }
    private func openCamera() async {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else { message="Câmera disponível no iPhone físico."; return }
        guard await AVCaptureDevice.requestAccess(for:.video) else { message="Permita a câmera nos Ajustes do iPhone."; return }
        guard !Task.isCancelled else { return }; camera=true
    }
    private func recognize(_ image: UIImage) {
        generation += 1; let own=generation
        job?.cancel(); configuration=nil; translated=[:]; lines=[]; working=true; message="Lendo o texto no iPhone…"
        let scale=min(1,1600/max(image.size.width,image.size.height))
        let size=CGSize(width:image.size.width*scale,height:image.size.height*scale)
        let format=UIGraphicsImageRendererFormat();format.scale=1
        let upright=UIGraphicsImageRenderer(size:size,format:format).image { _ in image.draw(in:CGRect(origin:.zero,size:size)) }
        photo=upright
        guard let cg=upright.cgImage else { working=false; return }
        job=Task {
            let result = await Task.detached(priority:.userInitiated) { try? CameraTextReader.read(cg) }.value
            guard !Task.isCancelled, own == generation else { return }
            lines=result ?? []
            if lines.isEmpty { working=false;message="Não encontrei texto legível. Aproxime e melhore a iluminação." }
            else { translate() }
        }
    }
    private func translate() {
        guard !lines.isEmpty else { return }
        let language=NLLanguageRecognizer()
        language.processString(lines.map(\.text).joined(separator:" "))
        if language.dominantLanguage?.rawValue == target {
            translated=Dictionary(uniqueKeysWithValues:lines.map { ($0.id,$0.text) });working=false;message="O texto já está no idioma escolhido.";return
        }
        generation += 1; translated=[:];working=true;message="Traduzindo para o idioma escolhido…"
        if configuration?.target?.languageCode?.identifier == target { configuration?.invalidate() }
        else { configuration=TranslationSession.Configuration(source:nil,target:Locale.Language(identifier:target)) }
    }
}
