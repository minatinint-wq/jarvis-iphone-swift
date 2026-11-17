import XCTest
import AVFoundation
@testable import JarvisPhone

final class PhoneCommandTests: XCTestCase {
    @MainActor func testPhoneContextCommands() {
        XCTAssertEqual(HandsetContext.parse("Oi, Jarvis, quantos passos hj?"), .steps)
        XCTAssertEqual(HandsetContext.parse("qual foi a última notificação?"), .notification)
        XCTAssertEqual(HandsetContext.parse("ligue pra Ana"), .call("Ana"))
        XCTAssertEqual(HandsetContext.parse("mande um SMS para Ana dizendo Olá!"), .sms("Ana", "Olá!"))
        XCTAssertNil(HandsetContext.parse("ligue para Ana no WhatsApp"))
        XCTAssertEqual(PhoneLocalKit.torchAction("Ei Jarvis, liga a lanterna de novo"), .torchOn)
    }
    @MainActor func testRelativeBrightnessWhenLocked() async {
        let result = await PhoneLocalKit.resolve("diminui o brilho", readOnly: true)
        XCTAssertEqual(result, "Abra o Jarvis no iPhone desbloqueado para executar essa ação.")
    }
    @MainActor func testVoiceVisionModes() {
        XCTAssertEqual(RemoteAssistant.visionCommand("Jarvis, o que estou vendo?"), .once)
        XCTAssertEqual(RemoteAssistant.visionCommand("visão ao vivo"), .start)
        XCTAssertEqual(RemoteAssistant.visionCommand("parar visão"), .stop)
        XCTAssertNil(RemoteAssistant.visionCommand("não abra a câmera"))
    }
    @MainActor func testBrightnessPhrasesResolveOnPhone() async {
        for phrase in ["Jarvis, ajusta o brilho pra 40 %", "Coloca o brilho em quarenta por cento"] {
            let reply = await PhoneLocalKit.resolve(phrase, readOnly: true)
            XCTAssertEqual(reply, "Abra o Jarvis no iPhone desbloqueado para executar essa ação.", phrase)
        }
    }
    @MainActor func testSpotifyPersistsOnlyAcknowledgedDevice() {
        let defaults = UserDefaults.standard
        let keys = ["jarvis.spotify.phone","jarvis.spotify.name"]
        let original = keys.map { defaults.string(forKey:$0) }
        defer { for (key, old) in zip(keys, original) { defaults.set(old, forKey:key) } }
        let phone = RemoteAssistant()
        phone.acceptSpotifyStatus(["state":"bound","confirmed":true,"deviceId":"test-confirmed","deviceName":"iPhone de teste"])
        phone.acceptSpotifyStatus(["state":"choose","phones":[["id":"test-other","name":"Telefone","active":true]]])
        phone.selectSpotifyPhone("test-other") // No bridge acknowledgement.
        phone.acceptSpotifyStatus(["state":"bound","confirmed":false,"deviceId":"test-other","deviceName":"Outro"])
        XCTAssertEqual(phone.spotifyID, "test-confirmed")
        XCTAssertEqual(phone.spotifyPhones.first?["id"], "test-other")
        XCTAssertEqual(RemoteAssistant().spotifyName, "iPhone de teste")
        XCTAssertTrue(RemoteAssistant.isSpotifyBindingCommand("Oi Jarvis, vincula o Spotify neste iPhone!"))
        XCTAssertFalse(RemoteAssistant.isSpotifyBindingCommand("Toque rock no Spotify"))
    }
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
        var checks = StudioInstrument.allCases.map { (instrument: $0, note: UInt8($0 == .drums ? 38 : 60), velocity: UInt8(100)) }
        for note: UInt8 in [36, 60, 84] {
            for velocity: UInt8 in [65, 96, 110] {
                checks.append((.flute, note, velocity))
            }
        }
        for (instrument, note, velocity) in checks {
            let engine = AVAudioEngine(), sampler = AVAudioUnitSampler()
            engine.attach(sampler)
            engine.connect(sampler, to: engine.mainMixerNode, format: format)
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
            try sampler.loadSoundBankInstrument(at: bank, program: instrument.program,
                                                bankMSB: instrument == .drums ? 0x78 : 0x79, bankLSB: 0)
            try engine.start()
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
            sampler.startNote(note, withVelocity: velocity, onChannel: 0)
            var peak: Float = 0
            for _ in 0..<20 {
                if try engine.renderOffline(1024, to: buffer) == .success, let samples = buffer.floatChannelData {
                    for index in 0..<Int(buffer.frameLength) { peak = max(peak, abs(samples[0][index])) }
                }
            }
            engine.stop()
            XCTAssertGreaterThan(peak, 0.0001, "\(instrument.rawValue), MIDI \(note), velocidade \(velocity)")
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

    func testAlmanacUnderstandsWeatherWithoutTakingAgendaOrTimers() {
        XCTAssertEqual(PhoneAlmanac.request("vai chover amanha em recife"), .weather(.tomorrow, "recife"))
        XCTAssertEqual(PhoneAlmanac.request("previsao do tempo em recife para amanha"), .weather(.tomorrow, "recife"))
        XCTAssertEqual(PhoneAlmanac.request("qual a previsao do tempo para a semana"), .weather(.week, nil))
        XCTAssertEqual(PhoneAlmanac.request("como ta o tempo aqui"), .weather(.now, nil))
        XCTAssertEqual(PhoneAlmanac.request("qual a data de hoje"), .date(0))
        XCTAssertNil(PhoneAlmanac.request("que horas sao as reunioes da minha agenda"))
        XCTAssertNil(PhoneAlmanac.request("qual o tempo de viagem em curitiba"))
        XCTAssertNil(PhoneAlmanac.request("qual a temperatura do meu iphone"))
        XCTAssertNil(PhoneAlmanac.request("coloque musica para chover"))
    }

    func testPhoneCalendarUsesDeviceZoneAcrossMidnight() throws {
        let instant = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-01-02T01:05:00Z"))
        let zone = try XCTUnwrap(TimeZone(identifier: "America/Sao_Paulo"))
        XCTAssertEqual(PhoneAlmanac.calendarReply(.time, date: instant, zone: zone), "Agora são 22:05.")
        XCTAssertEqual(PhoneAlmanac.calendarReply(.weekday(1), date: instant, zone: zone), "Amanhã é sexta-feira.")
        XCTAssertEqual(PhoneAlmanac.calendarReply(.date(0), date: instant, zone: zone), "Hoje é quinta-feira, 1 de janeiro de 2026.")
    }

    @MainActor func testAlmanacDashboardButtonsUseTheLocalRoutes() async {
        let reply = await PhoneLocalKit.resolve("Qual a data e a hora de hoje?")
        XCTAssertNotNil(reply?.range(of: #"Hoje é .+ [0-9]{4}, [0-9]{2}:[0-9]{2}\."#, options: .regularExpression))
        XCTAssertEqual(PhoneAlmanac.request("como esta o tempo hoje"), .weather(.today, nil))
    }

    func testWeatherSelectsTomorrowByLocalDayAndDoesNotInventMissingData() throws {
        let fixture = #"{"current":{"temperature_2m":19.7,"weather_code":2},"daily":{"time":["2026-01-01","2026-01-02"],"weather_code":[0,61],"temperature_2m_min":[18,17],"temperature_2m_max":[30,25],"precipitation_probability_max":[0,80]}}"#
        let forecast = try JSONDecoder().decode(PhoneAlmanac.Forecast.self, from: Data(fixture.utf8))
        XCTAssertTrue(PhoneAlmanac.forecastReply(forecast, period: .now, place: "Em Recife").contains("20 °C"))
        let nextDay = PhoneAlmanac.forecastReply(forecast, period: .tomorrow, place: "Em Recife")
        XCTAssertTrue(nextDay.contains("17 e máxima de 25"))
        XCTAssertTrue(nextDay.contains("80%"))
        XCTAssertTrue(PhoneAlmanac.forecastReply(forecast, period: .afterTomorrow, place: "Em Recife").contains("indisponível"))
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
