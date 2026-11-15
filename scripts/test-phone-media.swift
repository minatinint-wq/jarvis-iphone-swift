import Foundation
@main enum MediaChecks {
 static func main() throws {
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
