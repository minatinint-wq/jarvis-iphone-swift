import XCTest
@testable import JarvisPhone

final class PhoneCommandTests: XCTestCase {
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
