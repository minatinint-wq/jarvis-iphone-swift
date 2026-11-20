import Foundation
import AVFoundation
var failures = 0

let bank = URL(fileURLWithPath:CommandLine.arguments[1])
for (name, program, bankMSB, note) in [("electric-guitar",27,121,40),("harp",46,121,60),("piano",0,121,60),("guitar",24,121,60),("bass",33,121,60),("strings",48,121,60),("flute",73,121,60),("drums",0,120,38)] {
    do {
        let format = AVAudioFormat(standardFormatWithSampleRate:44100,channels:2)!
        let engine = AVAudioEngine(), sampler = AVAudioUnitSampler()
        engine.attach(sampler); engine.connect(sampler,to:engine.mainMixerNode,format:format)
        try engine.enableManualRenderingMode(.offline,format:format,maximumFrameCount:1024)
        try sampler.loadSoundBankInstrument(at:bank,program:UInt8(program),bankMSB:UInt8(bankMSB),bankLSB:0)
        try engine.start()
        let buffer = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:1024)!
        sampler.startNote(UInt8(note),withVelocity:100,onChannel:0)
        var peak:Float = 0
        for _ in 0..<20 {
            if try engine.renderOffline(1024,to:buffer) == .success, let data=buffer.floatChannelData {
                for i in 0..<Int(buffer.frameLength) {peak=max(peak,abs(data[0][i]))}
            }
        }
        print("Sampler",name,"peak",peak)
        if peak <= 0.0001 { failures += 1 }
        engine.stop()
    } catch { failures += 1; print("Sampler",name,"ERROR",error) }
}

if failures > 0 { exit(1) }
