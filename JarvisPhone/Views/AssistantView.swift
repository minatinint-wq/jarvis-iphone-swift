import SwiftUI
import AVFoundation
import VisionKit
import WebKit

struct AssistantView: View {
    @ObservedObject var model: RemoteAssistant
    @State private var scanning=false
    @State private var code = ""
    @State private var draft = ""
    @State private var camera = false
    @State private var preview: UIImage?
    @State private var expanded: UIImage?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:18) {
                    HStack {
                        Circle().fill(model.ready ? Color.mint : .orange).frame(width:8,height:8)
                        Text(model.ready ? "NÚCLEO DO PC ONLINE" : "CONEXÃO COM O PC").font(.caption.monospaced())
                        Spacer()
                        if model.paired {Button("Sair"){model.logout()}.font(.caption)}
                    }
                    Text("Às suas ordens.").font(.system(size:38,weight:.semibold,design:.rounded))
                    Text(model.message).font(.callout).foregroundStyle(.secondary).accessibilityIdentifier("assistantStatus")
                    if !model.paired {
                        Button { if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {scanning=true} else {model.message="Use o código que aparece ao lado do QR no computador."} } label:{Label("Ler QR do meu PC", systemImage:"qrcode.viewfinder")}.buttonStyle(.borderedProminent)
                        SecureField("Código de conexão do PC",text:$code).textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder)
                        Button("Conectar ao meu Jarvis"){let c=code;code="";Task{await model.pair(c)}}.buttonStyle(.borderedProminent)
                        Text("Use o código do painel Jarvis Remoto no computador.").font(.footnote).foregroundStyle(.secondary)
                    } else {
                        if !model.ready {Button("Reconectar"){model.drop();model.connect()}.buttonStyle(.bordered)}
                        Button { if model.recording {Task{await model.sendRecording()}} else {model.startListening()} } label:{
                            Label(model.recording ? "Terminar e enviar" : "Falar com o Jarvis",systemImage:model.recording ? "stop.circle.fill":"waveform.circle.fill").frame(maxWidth:.infinity,minHeight:46)
                        }.buttonStyle(.borderedProminent).disabled(!model.ready || model.busy)
                        HStack {TextField("Escreva um pedido…",text:$draft,axis:.vertical).textFieldStyle(.roundedBorder); Button("Enviar"){let t=draft;draft="";Task{await model.say(t)}}.disabled(draft.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)}
                            .disabled(!model.ready || model.busy || model.recording)
                        ScrollView(.horizontal,showsIndicators:false){HStack {
                            preset("Gerar imagem","Gere uma imagem de ");preset("Último e-mail","Leia meu último e-mail");preset("Minha agenda","Quais são meus eventos de hoje?")
                            Button("Analisar câmera"){Task{await openCamera()}}.disabled(!model.cameraAvailable)
                        }.buttonStyle(.bordered)}.disabled(!model.ready || model.busy || model.recording)
                        HStack { ForEach([("sketch","Desenhar"),("music","Instrumentos"),("libras","Libras")],id:\.0){option in Button(option.1){model.studioMode=option.0}} }.buttonStyle(.bordered).disabled(!model.ready || model.busy || model.recording)
                        if let photo=preview {
                            VStack(alignment:.leading){
                                Image(uiImage:photo).resizable().scaledToFit().frame(maxHeight:180)
                                Text("Enviar esta foto para análise pela NVIDIA?").font(.headline)
                                HStack {Button("Enviar foto"){preview=nil;Task{await model.analyze(photo)}}.buttonStyle(.borderedProminent);Button("Descartar"){preview=nil}}
                            }.disabled(!model.ready || model.busy)
                        }
                        if let image=model.artwork {
                            Button { expanded=image } label:{Image(uiImage:image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius:16))}.accessibilityLabel("Ampliar imagem gerada pelo Jarvis")
                        }
                        ForEach(model.lines){line in VStack(alignment:.leading,spacing:4){Text(line.user ? "VOCÊ":"JARVIS").font(.caption2.monospaced()).foregroundStyle(line.user ? Color.orange:.cyan);Text(line.text).textSelection(.enabled)}.frame(maxWidth:.infinity,alignment:.leading)}
                        if let image=model.display {DisclosureGroup("Visor do PC"){Image(uiImage:image).resizable().scaledToFit().frame(maxHeight:240)}}
                    }
                }.padding(22)
            }.background(Color(red:0.025,green:0.045,blue:0.066)).navigationTitle("JARVIS XLV")
            .sheet(isPresented:$scanning){QRReader { value in if PhoneMedia.pairingCode(value) != nil {scanning=false;Task{await model.pair(value)}} } }
            .fullScreenCover(isPresented:Binding(get:{model.studioMode != nil},set:{if !$0{model.studioMode=nil}})){
                if let mode=model.studioMode { VStack(spacing:0){ HStack {Text(["sketch":"Desenho no ar","music":"Instrumentos","libras":"Libras"][mode] ?? "Estúdio").font(.headline);Spacer();Button("Fechar"){model.studioMode=nil} }.padding();StudioWeb(mode:mode,origin:model.origin){text in model.studioMode=nil;Task{await model.say(text)}} }.preferredColorScheme(.dark) }
            }
            .onChange(of:model.cameraRequested){_,requested in if requested {model.cameraRequested=false;Task{await openCamera()}}}
            .fullScreenCover(isPresented:$camera){CameraCapture(onCapture:{photo in camera=false;preview=photo},onCancel:{camera=false}).ignoresSafeArea()}
            .sheet(isPresented:Binding(get:{expanded != nil},set:{if !$0{expanded=nil}})){if let expanded {Image(uiImage:expanded).resizable().scaledToFit().padding()}}
        }
    }
    private func preset(_ title:String,_ command:String)->some View {
        Button(title){if title=="Gerar imagem" {draft=command}else{Task{await model.say(command)}}}
    }
    private func openCamera() async {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {model.message="A câmera não está disponível neste aparelho.";return}
        guard await AVCaptureDevice.requestAccess(for:.video) else {model.message="Autorize a câmera em Ajustes.";return}
        camera=true
    }
}
private struct QRReader: UIViewControllerRepresentable {
    var accept:(String)->Void
    final class Coordinator:NSObject, DataScannerViewControllerDelegate {
        let accept:(String)->Void
        init(_ a:@escaping(String)->Void){accept=a}
        func dataScanner(_ dataScanner:DataScannerViewController,didAdd addedItems:[RecognizedItem],allItems:[RecognizedItem]){
            for case let .barcode(code) in addedItems { if let s=code.payloadStringValue,PhoneMedia.pairingCode(s) != nil {dataScanner.stopScanning();accept(s);return} }
        }
        func dataScanner(_ dataScanner:DataScannerViewController,didTapOn item:RecognizedItem){if case .barcode(let b)=item,let s=b.payloadStringValue,PhoneMedia.pairingCode(s) != nil {accept(s)}}
    }
    func makeCoordinator()->Coordinator{Coordinator(accept)}
    func makeUIViewController(context:Context)->DataScannerViewController{
        let v=DataScannerViewController(recognizedDataTypes:[.barcode(symbologies:[.qr])],recognizesMultipleItems:false,isHighlightingEnabled:true)
        v.delegate=context.coordinator;return v
    }
    func updateUIViewController(_ v:DataScannerViewController,context:Context){Task{@MainActor in try? await Task.sleep(nanoseconds:300_000_000);if v.view.window != nil && !v.isScanning {try? v.startScanning()}}}
    static func dismantleUIViewController(_ v:DataScannerViewController,coordinator:Coordinator){v.stopScanning()}
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
