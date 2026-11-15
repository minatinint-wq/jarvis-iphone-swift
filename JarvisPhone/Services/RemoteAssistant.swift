import Foundation
import SwiftUI
import UIKit

@MainActor final class RemoteAssistant: ObservableObject {
    struct Line: Identifiable { let id=UUID(); let user:Bool; let text:String }
    @Published var paired = PairingStore.read() != nil
    @Published var ready = false
    @Published var busy = false
    @Published var recording = false
    @Published var cameraAvailable = false
    @Published var wantsVoice = false
    @Published var cameraRequested = false
    @Published var message = "Conecte ao seu Jarvis."
    @Published var lines: [Line] = []
    @Published var artwork: UIImage?
    @Published var display: UIImage?
    private var imageID: String?
    private var receivedImage = Data()
    private let origin="https://jarvis-remoto.minatinint.workers.dev"
    private let session: URLSession = { let c=URLSessionConfiguration.ephemeral; c.httpShouldSetCookies=false; c.timeoutIntervalForRequest=20; return URLSession(configuration:c) }()
    private var ws:URLSessionWebSocketTask?, reader:Task<Void,Never>?, watchdog:Task<Void,Never>?, micJob:Task<Void,Never>?
    private let sound=HandsetAudio()
    private var pcm=Data(), active=true
    func pair(_ code:String) async {
        let trimmed=code.trimmingCharacters(in:.whitespacesAndNewlines)
        guard trimmed.range(of:"^[A-Za-z0-9_-]{32,128}$",options:.regularExpression) != nil else { message="Cole o código do painel Jarvis Remoto do PC."; return }
        do {
            var r=URLRequest(url:URL(string:origin+"/api/login")!); r.httpMethod="POST"
            r.setValue(origin,forHTTPHeaderField:"Origin"); r.setValue("application/json",forHTTPHeaderField:"Content-Type")
            r.httpBody=try JSONEncoder().encode(["code":trimmed])
            let (_,response)=try await session.data(for:r)
            guard let h=response as? HTTPURLResponse,h.statusCode==200,let raw=h.value(forHTTPHeaderField:"Set-Cookie"),
                  let c=HTTPCookie.cookies(withResponseHeaderFields:["Set-Cookie":raw],for:r.url!).first(where:{$0.name=="__Host-jarvis" && $0.isSecure}) else { message="Pareamento recusado. Confira o código atual no PC."; return }
            try PairingStore.save(c.value); paired=true; connect()
        } catch { message=error.localizedDescription }
    }
    func connect() {
        guard paired,active,ws==nil,let cookie=PairingStore.read() else { return }
        var r=URLRequest(url:URL(string:origin.replacingOccurrences(of:"https:",with:"wss:")+"/socket")!)
        r.setValue("__Host-jarvis="+cookie,forHTTPHeaderField:"Cookie");r.setValue(origin,forHTTPHeaderField:"Origin")
        let sock=session.webSocketTask(with:r); sock.maximumMessageSize=600_000;ws=sock; sock.resume(); message="Conectando ao PC…"
        reader=Task { [weak self] in
            do { while !Task.isCancelled {
                let event=try await sock.receive(); guard let self,self.ws===sock else {return}
                switch event {
                case .data(let chunk): if self.pcm.count+chunk.count <= 24*1024*1024 { self.pcm.append(chunk) }
                case .string(let txt):
                    guard let o=(try? JSONSerialization.jsonObject(with:Data(txt.utf8))) as? [String:Any] else { continue }
                    if o["type"] as? String=="pc-status",o["online"] as? Bool==true { try await self.send(["type":"connect","nativeAssistant":true],sock);continue }
                    self.event(o)
                @unknown default: break
                }
            }} catch {guard let self,self.ws===sock else{return}
                let expired = sock.closeCode.rawValue == 4003 || sock.response.flatMap { ($0 as? HTTPURLResponse)?.statusCode } == 401
                self.drop()
                if expired { PairingStore.remove(); self.paired=false; self.message="Sessão expirada. Conecte novamente pelo código do PC." }
                else {self.message="Conexão encerrada. Toque em Reconectar. Nenhum comando foi repetido."}
            }
        }
    }
    private func event(_ o:[String:Any]) {
        switch o["type"] as? String {
        case "pc-status": if o["online"] as? Bool==false {ready=false; finishWait();abortMic();message="O PC está offline."}
        case "status": ready=o["connected"] as? Bool==true; cameraAvailable=o["phoneCamera"] as? Bool==true;message=o["message"] as? String ?? ""; if ready && wantsVoice && active {wantsVoice=false;startListening()}
        case "transcript": if let t=o["text"] as? String { add(o["role"] as? String=="user",t) }
        case "tool-status","input-status": if let t=o["message"] as? String { message=t }; if o["phase"] as? String=="retry" {finishWait()}; if o["phase"] as? String=="open-phone-camera" && active { finishWait();cameraRequested=true }
        case "display":
            if o["kind"] as? String == "image-part" {
                guard let id=o["id"] as? String, let offset=o["offset"] as? Int, let total=o["total"] as? Int,
                      (1...1_048_576).contains(total),let part=o["part"] as? String,let bytes=Data(base64Encoded:part),
                      !bytes.isEmpty, bytes.count<=240000 else { return }
                if offset == 0 { imageID=id; receivedImage.removeAll() }
                guard imageID==id, offset==receivedImage.count, offset+bytes.count<=total else {return}
                receivedImage.append(bytes)
                if receivedImage.count==total { if let image=UIImage(data:receivedImage){artwork=image};receivedImage.removeAll();imageID=nil }
                return
            }
            if let s=o["image"] as? String,let cut=s.firstIndex(of:","),s.hasPrefix("data:image/"),let d=Data(base64Encoded:String(s[s.index(after:cut)...])),let image=UIImage(data:d) {
                if o["kind"] as? String=="generated" {artwork=image} else {display=image}
            }
        case "voice-error": message=o["text"] as? String ?? "O pedido falhou.";finishWait()
        case "interrupted": pcm.removeAll()
        case "turn-complete": finishWait(); if !pcm.isEmpty { do {try sound.speak(pcm);message="Resposta no iPhone."} catch {message=error.localizedDescription} }; pcm.removeAll()
        default: break
        }
    }
    func add(_ user:Bool,_ text:String) { lines.append(Line(user:user,text:text));if lines.count>60 {lines.removeFirst()} }
    private func send(_ o:[String:Any],_ sock:URLSessionWebSocketTask) async throws {try await sock.send(.string(String(decoding:try JSONSerialization.data(withJSONObject:o),as:UTF8.self)))}
    func say(_ text:String) async {
        let value=text.trimmingCharacters(in:.whitespacesAndNewlines);guard !value.isEmpty,value.count<=2000,ready,!busy,!recording,let sock=ws else{return}
        beginWait();add(true,value);do {try await send(["type":"text","text":value],sock)} catch {lost(sock)}
    }
    func activate() {wantsVoice=true;guard active else{return}; if ready {wantsVoice=false;startListening()} else {connect()} }
    func startListening() {
        guard ready,!busy,!recording,active else{return}
        recording=true;message="Ouvindo…";micJob=Task { do {try await sound.start { [weak self] in Task { await self?.sendRecording() } }} catch {if !Task.isCancelled {recording=false;message=error.localizedDescription}} }
    }
    func sendRecording() async {
        guard recording else{return};recording=false
        guard let data=sound.take(),let sock=ws,ready else {message="Não recebi áudio. Tente outra vez.";return}
        beginWait();do {
            for i in stride(from:0,to:data.count,by:3200) {guard ws===sock,busy else{return};try await sock.send(.data(data.subdata(in:i..<min(i+3200,data.count))))}
            try await send(["type":"audio-end"],sock)
        } catch {lost(sock)}
    }
    func analyze(_ photo:UIImage) async {
        guard let sock=ws,ready,!busy,cameraAvailable,!recording else {message="A análise por câmera ainda não está disponível nesta conexão.";return}
        let length=max(photo.size.width,photo.size.height)
        guard length>0 else {return}
        let ratio=min(1,640/length),size=CGSize(width:max(1,photo.size.width*ratio),height:max(1,photo.size.height*ratio))
        let format=UIGraphicsImageRendererFormat();format.scale=1;format.opaque=true
        let resized=UIGraphicsImageRenderer(size:size,format:format).image{_ in photo.draw(in:CGRect(origin:.zero,size:size))}
        for q in [0.75,0.55,0.38,0.22] {
            guard let bytes=resized.jpegData(compressionQuality:q),let packet=PhoneMedia.cameraPacket(bytes) else {continue}
            beginWait();add(true,"Analise esta foto da câmera.");do{try await sock.send(.data(packet))}catch{lost(sock)};return
        };message="A imagem excedeu o tamanho para análise."
    }
    private func beginWait() { sound.stop();pcm.removeAll();busy=true;message="Aguardando o Jarvis…";watchdog?.cancel()
        watchdog=Task {try? await Task.sleep(nanoseconds:245_000_000_000);if !Task.isCancelled && busy {drop();message="O pedido demorou. Confira no PC; não foi reenviado."}}
    }
    private func finishWait(){watchdog?.cancel();watchdog=nil;busy=false}
    private func abortMic(){micJob?.cancel();micJob=nil;recording=false;sound.stop()}
    private func lost(_ sock:URLSessionWebSocketTask){guard ws===sock else{return};drop();message="A conexão caiu. Não repeti o pedido."}
    func drop(){let old=ws;ws=nil;imageID=nil;receivedImage.removeAll();reader?.cancel();reader=nil;old?.cancel(with:.goingAway,reason:nil);finishWait();abortMic();pcm.removeAll();ready=false;cameraAvailable=false}
    func foreground(_ yes:Bool){ active=yes;if yes {connect();if ready && wantsVoice {activate()}}else{drop()} }
    func logout(){drop();PairingStore.remove();paired=false;wantsVoice=false;lines=[];artwork=nil;display=nil;message="Desconectado."}
}
