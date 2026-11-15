import XCTest
import AVFoundation
@testable import JarvisPhone

final class PhoneCommandTests: XCTestCase {
    @MainActor func testMuteEndsCurrentTurnAndIgnoresSpeechUntilFreshWake() async {
        let phone = RemoteAssistant()
        phone.heardCall()
        await phone.say("Oi Jarvis")
        XCTAssertEqual(phone.lines.last?.text, PhoneLocalKit.greeting)
        let count = phone.lines.count
        await phone.say("Jarvis, muta")
        XCTAssertFalse(phone.isSpeaking)
        XCTAssertFalse(phone.followUp)
        XCTAssertFalse(phone.showingFace)
        await phone.say("Oi")
        XCTAssertEqual(phone.lines.count, count)
        phone.heardCall()
        await phone.say("Oi Jarvis")
        XCTAssertEqual(phone.lines.count, count + 2)
        XCTAssertEqual(phone.lines.last?.text, PhoneLocalKit.greeting)
        await phone.say("Jarvis, muta")
    }
    func testBundledInstrumentsRenderAudibleSamples() throws {
        let bank = try XCTUnwrap(Bundle.main.url(forResource: "JarvisInstruments", withExtension: "sf2"))
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2))
        for instrument in StudioInstrument.allCases {
            let engine = AVAudioEngine(), sampler = AVAudioUnitSampler()
            engine.attach(sampler)
            engine.connect(sampler, to: engine.mainMixerNode, format: format)
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
            try sampler.loadSoundBankInstrument(at: bank, program: instrument.program,
                                                bankMSB: instrument == .drums ? 0x78 : 0x79, bankLSB: 0)
            try engine.start()
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
            sampler.startNote(instrument == .drums ? 38 : 60, withVelocity: 100, onChannel: 0)
            var peak: Float = 0
            for _ in 0..<20 {
                if try engine.renderOffline(1024, to: buffer) == .success, let samples = buffer.floatChannelData {
                    for index in 0..<Int(buffer.frameLength) { peak = max(peak, abs(samples[0][index])) }
                }
            }
            engine.stop()
            XCTAssertGreaterThan(peak, 0.0001, instrument.rawValue)
        }
    }
    @MainActor func testConversationRoutesTorchToPhoneButNotBedroomLight() {
        for s in ["Oi Jarvis, você pode acender a lanterna do meu celular?", "Liga o flash pra mim", "Acende minha lanterna"] {
            XCTAssertEqual(PhoneLocalKit.torchAction(s), .torchOn, s)
        }
        XCTAssertEqual(PhoneLocalKit.torchAction("Pode desligar a lanterna agora?"), .torchOff)
        for s in ["acenda a luz do quarto","não ligue a lanterna","ligue a lanterna e a cafeteira"] { XCTAssertNil(PhoneLocalKit.torchAction(s),s) }
    }
    func testNotificationQueueIsLiteralFreshAndOrdered() {
        var q = VoiceInbox(); let t=Date()
        XCTAssertTrue(q.insert("  Oi   Ana  ",now:t))
        XCTAssertFalse(q.insert("Oi Ana",now:t))
        XCTAssertFalse(q.insert("JARVIS_COMANDO",now:t))
        XCTAssertTrue(q.insert("ligue a luz",now:t))
        XCTAssertEqual(q.next(now:t), "Oi Ana")
        XCTAssertEqual(q.next(now:t), "ligue a luz")
        XCTAssertTrue(q.insert("antiga",now:t))
        XCTAssertNil(q.next(now:t.addingTimeInterval(91)))
    }
    @MainActor
    func testUnpairedPhoneCanAnswerTimeOffline() async {
        let assistant = RemoteAssistant()
        assistant.paired = false
        assistant.ready = false
        await assistant.say("Que horas são?")
        XCTAssertEqual(assistant.lines.first?.text, "Que horas são?")
        XCTAssertEqual(assistant.lines.last?.user, false)
        XCTAssertTrue(assistant.lines.last?.text.hasPrefix("Agora são ") == true)
        XCTAssertFalse(assistant.busy)
    }

    @MainActor
    func testLocalTimeDoesNotConsumeCalendarRequest() async {
        let result = await PhoneLocalKit.resolve("Que horas são as reuniões da minha agenda?")
        XCTAssertNil(result)
    }

    func testAllNineteenActionsHaveUniqueIDs() {
        XCTAssertEqual(PhoneAction.allCases.count, 19)
        XCTAssertEqual(Set(PhoneAction.allCases.map(\.rawValue)).count, 19)
    }

    func testDeepLinkRoutesKnownAction() throws {
        let command = try PhoneCommand.decode(URL(string: "jarvisiphone://command?action=lanterna_ligar")!)
        XCTAssertEqual(command.action, .torchOn)
        XCTAssertNil(command.percentage)
    }

    func testBrightnessAcceptsZeroAndOneHundred() throws {
        for value in [0.0, 100.0] {
            XCTAssertEqual(try PhoneCommand(action: .brightness, percentage: value).percentage, value)
        }
    }

    func testPercentageRejectsInvalidAndNonFiniteValues() {
        for value in [-1.0, 100.1, Double.infinity, Double.nan] {
            XCTAssertThrowsError(try PhoneCommand(action: .volume, percentage: value))
        }
    }

    func testPercentageOnlyAppliesToSupportedActions() {
        XCTAssertThrowsError(try PhoneCommand(action: .torchOn, percentage: 50))
    }

    func testDeepLinkRejectsUnknownAction() {
        XCTAssertThrowsError(try PhoneCommand.decode(URL(string: "jarvisiphone://command?action=enviar_mensagem")!))
    }

    func testDeepLinkRejectsOtherHostsAndSchemes() {
        for raw in ["https://command?action=volume", "jarvisiphone://other?action=volume", "jarvisiphone://command/other?action=volume"] {
            XCTAssertThrowsError(try PhoneCommand.decode(URL(string: raw)!))
        }
    }

    func testDeepLinkRejectsDuplicateOrUnknownParameters() {
        for query in ["action=volume&action=brilho", "action=volume&value=20&value=30", "action=volume&token=x"] {
            XCTAssertThrowsError(try PhoneCommand.decode(URL(string: "jarvisiphone://command?\(query)")!))
        }
    }

    func testDeepLinkRejectsBadNumber() {
        XCTAssertThrowsError(try PhoneCommand.decode(URL(string: "jarvisiphone://command?action=brilho&value=abc")!))
    }

    func testShortcutURLContainsOnlyExpectedPayload() throws {
        let command = try PhoneCommand(action: .volume, percentage: 50)
        let parts = try XCTUnwrap(URLComponents(url: command.systemShortcutURL, resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.scheme, "shortcuts")
        XCTAssertEqual(parts.host, "run-shortcut")
        XCTAssertEqual(parts.queryItems?.first(where: { $0.name == "name" })?.value, "JARVIS Sistema")
        XCTAssertEqual(parts.queryItems?.first(where: { $0.name == "text" })?.value, "volume|50.0")
    }

    func testShortcutURLWithoutPercentageDoesNotCrash() throws {
        let command = try PhoneCommand(action: .meeting)
        let parts = try XCTUnwrap(URLComponents(url: command.systemShortcutURL, resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.queryItems?.first(where: { $0.name == "text" })?.value, "reuniao")
    }

    func testAppIntentsExposeSameActionSet() {
        XCTAssertEqual(Set(PhoneActionParameter.allCases.map(\.rawValue)), Set(PhoneAction.allCases.map(\.rawValue)))
    }
}
