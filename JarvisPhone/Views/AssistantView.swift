import SwiftUI
import AVFoundation

struct AssistantView: View {
    @ObservedObject var model: RemoteAssistant
    @State private var code="", draft="", camera=false, preview:UIImage?, expanded:UIImage?
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
                        if let image=model.artwork {
                            Button { expanded=image } label:{Image(uiImage:image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius:16))}.accessibilityLabel("Ampliar imagem gerada pelo Jarvis")
                        }
                        ForEach(model.lines){line in VStack(alignment:.leading,spacing:4){Text(line.user ? "VOCÊ":"JARVIS").font(.caption2.monospaced()).foregroundStyle(line.user ? Color.orange:.cyan);Text(line.text).textSelection(.enabled)}.frame(maxWidth:.infinity,alignment:.leading)}
                        if let image=model.display {DisclosureGroup("Visor do PC"){Image(uiImage:image).resizable().scaledToFit().frame(maxHeight:240)}}
                    }
                }.padding(22)
            }.background(Color(red:0.025,green:0.045,blue:0.066)).navigationTitle("JARVIS XLV")
            .fullScreenCover(isPresented:$camera){CameraCapture(onCapture:{photo in camera=false;preview=photo},onCancel:{camera=false}).ignoresSafeArea()}
            .confirmationDialog("Enviar esta foto ao Jarvis do PC para análise pela NVIDIA?",isPresented:Binding(get:{preview != nil && !camera},set:{if !$0 { } })){
                Button("Enviar foto para análise"){if let photo=preview {preview=nil;Task{await model.analyze(photo)}}}
                Button("Cancelar",role:.cancel){preview=nil}
            }
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
