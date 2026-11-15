import Foundation
@main enum MediaChecks {
 static func main() throws {
    let pcm=Data([0,0,4,0]); precondition(PhoneMedia.samples(PhoneMedia.wave(pcm,rate:16000))==pcm)
    precondition(PhoneMedia.samples(PhoneMedia.wave(pcm,rate:24000))==nil)
    precondition(PhoneMedia.samples(Data([0]))==nil)
    precondition(PhoneMedia.cameraPacket(Data([0xff,0xd8,0xff,0xd9]))?.prefix(8)==PhoneMedia.cameraPrefix)
    precondition(PhoneMedia.cameraPacket(Data(repeating:0,count:120001))==nil)
    print("PCM16 / WAV / validação de foto: OK")
 }
}
