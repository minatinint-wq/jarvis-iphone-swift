import Foundation
@main enum MediaChecks {
 static func main() throws {
    var conversation = WakeConversationWindow()
    for command in ["Jarvis, muta!", "oi, Jarvis, se muta", "Járvis, fique em silêncio por favor"] {
        precondition(PhoneVoiceControl.isMute(command))
    }
    for other in ["Jarvis, muta o Spotify", "não muta", "ele falou Jarvis muta", "Jarvis, mutação", "Jarvis, não se mute"] {
        precondition(!PhoneVoiceControl.isMute(other))
    }
    precondition(conversation.phase == .standby)
    conversation.listen(at:0); conversation.pause(at:1); conversation.expire(at:80)
    precondition(conversation.phase == .answering) // A long reply must not use listening time.
    conversation.resume(at:87); conversation.expire(at:146.99)
    precondition(conversation.phase == .listening(until:147))
    conversation.listen(at:146.99); conversation.pause(at:148); conversation.resume(at:160)
    conversation.expire(at:212); precondition(conversation.phase == .listening(until:220))
    conversation.expire(at:220); conversation.resume(at:225); precondition(conversation.phase == .standby)
    precondition(WakeConversationWindow.endpointDelay(at:10.91,partial:10,voice:9.8)==0)
    precondition(WakeConversationWindow.endpointDelay(at:10.91,partial:10,voice:10.82)>0.40)
    precondition(WakeConversationWindow.endpointDelay(at:12.81,partial:10,voice:12.80)==0)
    let pcm=Data([0,0,4,0]); precondition(PhoneMedia.samples(PhoneMedia.wave(pcm,rate:16000))==pcm)
    precondition(PhoneMedia.samples(PhoneMedia.wave(pcm,rate:24000))==nil)
    precondition(PhoneMedia.samples(Data([0]))==nil)
    precondition(PhoneMedia.cameraPacket(Data([0xff,0xd8,0xff,0xd9]))?.prefix(8)==PhoneMedia.cameraPrefix)
    precondition(PhoneMedia.cameraPacket(Data(repeating:0,count:120001))==nil)
    let code="jpc1."+String(repeating:"a",count:64),site="https://jarvis-remoto.minatinint.workers.dev/login"
    precondition(PhoneMedia.pairingCode(site+"#pair="+code)==code)
    precondition(PhoneMedia.pairingCode("jarvisiphone://parear#pair="+code)==code)
    precondition(PhoneMedia.pairingCode(code)==code)
    precondition(PhoneMedia.pairingCode(site+"?pair="+code)==nil)
    precondition(PhoneMedia.pairingCode("https://outro.example/login#pair="+code)==nil)
    precondition(PhoneMedia.pairingCode("jpc1.a")==nil)
    print("PCM16 / WAV / foto / pareamento do PC: OK")
 }
}
