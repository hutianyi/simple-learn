import AVFoundation
import XCTest
@testable import WordMemoryCards

@MainActor
final class SpeechServiceTests: XCTestCase {
    func testWaitsForActivationBeforeSpeaking() async {
        let started = expectation(description: "Activation started")
        let played = expectation(description: "Word played after activation")
        let gate = ActivationGate(started: started)
        let service = SpeechService(activation: { try await gate.activate() }) { utterance in
            XCTAssertEqual(utterance.speechString, "gas")
            played.fulfill()
        }
        speak("gas", using: service)
        await fulfillment(of: [started], timeout: 1)
        XCTAssertNil(service.speakingText)
        gate.complete(with: .success(true))
        await fulfillment(of: [played], timeout: 1)
        XCTAssertEqual(service.speakingText, "gas")
        service.stop()
    }

    func testStopDuringActivationPreventsLatePlayback() async {
        let started = expectation(description: "Activation started")
        let played = expectation(description: "Cancelled word must not play")
        played.isInverted = true
        let gate = ActivationGate(started: started)
        let service = SpeechService(activation: { try await gate.activate() }) { _ in played.fulfill() }
        speak("gas", using: service)
        await fulfillment(of: [started], timeout: 1)
        service.stop()
        gate.complete(with: .success(true))
        await fulfillment(of: [played], timeout: 0.2)
        XCTAssertNil(service.speakingText)
        XCTAssertFalse(service.isSpeaking)
    }

    func testReplacementIgnoresOlderActivationFinishingLast() async {
        let firstStarted = expectation(description: "First activation started")
        let secondStarted = expectation(description: "Second activation started")
        let newPlayed = expectation(description: "Only replacement word plays")
        let oldPlayed = expectation(description: "Old word must not play")
        oldPlayed.isInverted = true
        let first = ActivationGate(started: firstStarted)
        let second = ActivationGate(started: secondStarted)
        var activationCount = 0
        let service = SpeechService(activation: {
            activationCount += 1
            return try await (activationCount == 1 ? first : second).activate()
        }) { utterance in
            if utterance.speechString == "lamp" { newPlayed.fulfill() }
            else { oldPlayed.fulfill() }
        }
        speak("gas", using: service)
        await fulfillment(of: [firstStarted], timeout: 1)
        speak("lamp", using: service)
        await fulfillment(of: [secondStarted], timeout: 1)
        second.complete(with: .success(true))
        await fulfillment(of: [newPlayed], timeout: 1)
        first.complete(with: .success(true))
        await fulfillment(of: [oldPlayed], timeout: 0.2)
        XCTAssertEqual(service.speakingText, "lamp")
        service.stop()
    }

    func testActivationRefusalDoesNotPlay() async {
        await verifyActivationFailure(.success(false))
    }

    func testActivationErrorDoesNotPlay() async {
        await verifyActivationFailure(.failure(NSError(domain: "SpeechServiceTests", code: 1)))
    }

    private func verifyActivationFailure(_ result: Result<Bool, Error>) async {
        let started = expectation(description: "Activation started")
        let played = expectation(description: "Failed activation must not play")
        played.isInverted = true
        let gate = ActivationGate(started: started)
        let service = SpeechService(activation: { try await gate.activate() }) { _ in played.fulfill() }
        speak("gas", using: service)
        await fulfillment(of: [started], timeout: 1)
        gate.complete(with: result)
        await fulfillment(of: [played], timeout: 0.2)
        XCTAssertNil(service.speakingText)
        XCTAssertFalse(service.isSpeaking)
        service.stop()
    }

    private func speak(_ text: String, using service: SpeechService) {
        service.speak(text, language: .english, preferredIdentifier: nil, rate: 0.46)
    }

    private final class ActivationGate {
        let started: XCTestExpectation
        private var continuation: CheckedContinuation<Bool, Error>?

        init(started: XCTestExpectation) { self.started = started }

        func activate() async throws -> Bool {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                started.fulfill()
            }
        }

        func complete(with result: Result<Bool, Error>) {
            continuation?.resume(with: result)
            continuation = nil
        }
    }
}
