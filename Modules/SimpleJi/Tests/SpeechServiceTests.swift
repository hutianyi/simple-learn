import AVFoundation
import XCTest
@testable import WordMemoryCards

@MainActor
final class SpeechServiceTests: XCTestCase {
    func testChineseUtteranceSkipsPartOfSpeech() async {
        let played = expectation(description: "Chinese meaning played without labels")
        let meaning = "n.计划；v.打算"
        let service = SpeechService(activation: { true }) { utterance in
            XCTAssertEqual(utterance.speechString, "计划；打算")
            played.fulfill()
        }
        service.speak(meaning, language: .chinese, preferredIdentifier: nil, rate: 0.46)
        await fulfillment(of: [played], timeout: 1)
        XCTAssertEqual(service.speakingText, "计划；打算")
        service.stop()
    }

    func testEnglishUtteranceKeepsPartOfSpeechWords() async {
        let played = expectation(description: "English text played unchanged")
        let service = SpeechService(activation: { true }) { utterance in
            XCTAssertEqual(utterance.speechString, "adjective")
            played.fulfill()
        }
        service.speak("adjective", language: .english, preferredIdentifier: nil, rate: 0.46)
        await fulfillment(of: [played], timeout: 1)
        service.stop()
    }

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

    func testRepeatsTwiceAndCompletesOnlyAfterSecondUtterance() async {
        let firstPlayed = expectation(description: "First pronunciation played")
        let played = expectation(description: "Both pronunciations played")
        played.expectedFulfillmentCount = 2
        let finished = expectation(description: "Sequence finished")
        var utterances: [AVSpeechUtterance] = []
        var completionCount = 0
        let service = SpeechService(activation: { true }) { utterance in
            utterances.append(utterance)
            if utterances.count == 1 { firstPlayed.fulfill() }
            played.fulfill()
        }
        service.speak("gas", language: .english, preferredIdentifier: nil, rate: 0.46,
                      repetitions: 2, onCompletion: { completionCount += 1; finished.fulfill() })
        await fulfillment(of: [firstPlayed], timeout: 1)
        guard utterances.count == 1 else { return }
        XCTAssertEqual(completionCount, 0)
        XCTAssertEqual(utterances[0].postUtteranceDelay, 0.5)
        service.speechSynthesizer(AVSpeechSynthesizer(), didFinish: utterances[0])
        await fulfillment(of: [played], timeout: 1)
        XCTAssertEqual(utterances.map(\.speechString), ["gas", "gas"])
        XCTAssertEqual(completionCount, 0)
        XCTAssertEqual(utterances[1].postUtteranceDelay, 0)
        service.speechSynthesizer(AVSpeechSynthesizer(), didFinish: utterances[1])
        await fulfillment(of: [finished], timeout: 1)
        XCTAssertEqual(completionCount, 1)
        XCTAssertNil(service.speakingText)
        service.stop()
        XCTAssertEqual(completionCount, 1)
    }

    func testStoppingRepeatedSpeechPreventsLateSecondPronunciation() async {
        let played = expectation(description: "First pronunciation")
        var utterances: [AVSpeechUtterance] = []
        var completionCount = 0
        let service = SpeechService(activation: { true }) { utterance in
            utterances.append(utterance)
            played.fulfill()
        }
        service.speak("gas", language: .english, preferredIdentifier: nil, rate: 0.46,
                      repetitions: 2, onCompletion: { completionCount += 1 })
        await fulfillment(of: [played], timeout: 1)
        service.stop()
        service.speechSynthesizer(AVSpeechSynthesizer(), didFinish: utterances[0])
        await Task.yield()
        XCTAssertEqual(utterances.count, 1)
        XCTAssertEqual(completionCount, 1)
        XCTAssertNil(service.speakingText)
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
