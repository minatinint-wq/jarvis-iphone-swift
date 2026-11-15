import AVFoundation
import UIKit

@MainActor final class HandsetAudio {
    private var recorder: AVAudioRecorder?
    private var url: URL?
    private var meter: Timer?
    private var player: AVAudioPlayer?
    func start(finish: @escaping @MainActor () -> Void) async throws {
        guard await AVAudioApplication.requestRecordPermission() else { throw fail("Permita o microfone nos Ajustes do iPhone.") }
        try Task.checkCancellation()
        stop()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-mic-"+UUID().uuidString+".wav")
            url = file
            let r = try AVAudioRecorder(url:file, settings:[AVFormatIDKey:kAudioFormatLinearPCM, AVSampleRateKey:16000, AVNumberOfChannelsKey:1, AVLinearPCMBitDepthKey:16, AVLinearPCMIsFloatKey:false, AVLinearPCMIsBigEndianKey:false])
            recorder=r; r.isMeteringEnabled=true
            guard r.record() else { throw fail("O microfone está ocupado.") }
            let start=Date(); var last: Date?; var active = 0
            meter=Timer.scheduledTimer(withTimeInterval:0.12,repeats:true){ [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let r=self.recorder else { return }
                    r.updateMeters(); if r.averagePower(forChannel:0) > -42 { last=Date(); active += 1 }
                    if (active >= 2 && -(last?.timeIntervalSinceNow ?? 0) > 1.05) || -start.timeIntervalSinceNow >= 14 {
                        self.meter?.invalidate(); self.meter=nil; finish()
                    }
                }
            }
        } catch { stop(); throw error }
    }
    func take() -> Data? {
        meter?.invalidate(); meter=nil; recorder?.stop(); recorder=nil
        defer { cleanFile(); releaseAudio() }
        guard let url, let data=try? Data(contentsOf:url) else { return nil }
        return PhoneMedia.samples(data)
    }
    func speak(_ pcm: Data) throws {
        guard !pcm.isEmpty else { return }; stop()
        let s=AVAudioSession.sharedInstance(); try s.setCategory(.playback,mode:.spokenAudio); try s.setActive(true)
        player=try AVAudioPlayer(data:PhoneMedia.wave(pcm,rate:24000)); guard player?.play()==true else { throw fail("Não consegui tocar a resposta.") }
    }
    private func cleanFile() { if let url { try? FileManager.default.removeItem(at:url) }; url=nil }
    private func releaseAudio() { try? AVAudioSession.sharedInstance().setActive(false, options:.notifyOthersOnDeactivation) }
    func stop() { meter?.invalidate(); meter=nil; recorder?.stop(); recorder=nil; player?.stop(); player=nil; cleanFile(); releaseAudio() }
    private func fail(_ s:String)->NSError { NSError(domain:"JarvisAudio",code:1,userInfo:[NSLocalizedDescriptionKey:s]) }
}
