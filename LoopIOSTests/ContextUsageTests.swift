//
//  ContextUsageTests.swift
//  LoopIOSTests
//
//  Unit tests for TokenUsage percentage computation and
//  ModelSelection.contextWindowSize lookup.
//

import XCTest
@testable import Loop

// MARK: - TokenUsage.contextPercent

final class TokenUsageTests: XCTestCase {

    func testPercentageBasicComputation() {
        let usage = TokenUsage(promptTokens: 800, completionTokens: 200, totalTokens: 1000)
        XCTAssertEqual(usage.contextPercent(windowSize: 10_000), 10)
    }

    func testPercentageClampsAt100() {
        let usage = TokenUsage(promptTokens: 9000, completionTokens: 2000, totalTokens: 11_000)
        XCTAssertEqual(usage.contextPercent(windowSize: 10_000), 100)
    }

    func testPercentageReturnsNilForNilWindow() {
        let usage = TokenUsage(promptTokens: 100, completionTokens: 50, totalTokens: 150)
        XCTAssertNil(usage.contextPercent(windowSize: nil))
    }

    func testPercentageReturnsNilForZeroWindow() {
        let usage = TokenUsage(promptTokens: 100, completionTokens: 50, totalTokens: 150)
        XCTAssertNil(usage.contextPercent(windowSize: 0))
    }

    func testPercentageRoundsDown() {
        let usage = TokenUsage(promptTokens: 0, completionTokens: 0, totalTokens: 1)
        // 1/200_000 = 0.0005% → rounds to 0
        XCTAssertEqual(usage.contextPercent(windowSize: 200_000), 0)
    }
}

// MARK: - ModelSelection.contextWindowSize

final class ModelSelectionContextWindowTests: XCTestCase {

    func testKnownModelsHaveWindowSizes() {
        for model in ModelSelection.allCases {
            switch model {
            case .appleFoundation:
                XCTAssertNil(model.contextWindowSize,
                             "Apple Foundation should have nil context window")
            default:
                XCTAssertNotNil(model.contextWindowSize,
                                "\(model.displayName) should have a context window size")
                XCTAssertGreaterThan(model.contextWindowSize ?? 0, 0)
            }
        }
    }

    func testLookupByStampReturnsCorrectSize() {
        let size = ModelSelection.contextWindowSize(forStamp: "GPT-5.5")
        XCTAssertEqual(size, 1_048_576)
    }

    func testLookupByStampReturnsNilForUnknown() {
        let size = ModelSelection.contextWindowSize(forStamp: "UnknownModel-99")
        XCTAssertNil(size)
    }
}

// MARK: - MessageStruct.tokenUsage integration

final class MessageTokenUsageTests: XCTestCase {

    func testMessageDefaultsToNilUsage() {
        let msg = MessageStruct(role: "assistant", content: "hi")
        XCTAssertNil(msg.tokenUsage)
    }

    func testMessageCarriesUsage() {
        let usage = TokenUsage(promptTokens: 500, completionTokens: 100, totalTokens: 600)
        let msg = MessageStruct(role: "assistant", content: "hi", tokenUsage: usage)
        XCTAssertEqual(msg.tokenUsage?.totalTokens, 600)
    }
}
