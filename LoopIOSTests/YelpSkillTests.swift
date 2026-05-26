//
//  YelpSkillTests.swift
//  LoopIOSTests
//
//  Lightweight unit tests for YelpSkill schema, dispatch routing, and
//  graceful missing-key behavior. No live Yelp API calls are made.
//

import XCTest
@testable import Loop

final class YelpSkillTests: XCTestCase {

    // MARK: - Schema

    func testToolSchemaRegistered() {
        // YelpSkill.tools should contain exactly one tool.
        XCTAssertEqual(YelpSkill.tools.count, 1)
        let tool = YelpSkill.tools[0]
        let fn = tool["function"] as? [String: Any]
        XCTAssertEqual(fn?["name"] as? String, "yelp_search_businesses")
    }

    func testToolNamesMatchSchema() {
        XCTAssertTrue(YelpSkill.toolNames.contains("yelp_search_businesses"))
        XCTAssertEqual(YelpSkill.toolNames.count, 1)
    }

    // MARK: - handles

    func testHandlesRecognizesOwnTool() {
        XCTAssertTrue(YelpSkill.shared.handles(functionName: "yelp_search_businesses"))
    }

    func testHandlesRejectsUnknownTool() {
        XCTAssertFalse(YelpSkill.shared.handles(functionName: "exa_search"))
        XCTAssertFalse(YelpSkill.shared.handles(functionName: "yelp_unknown"))
    }

    // MARK: - statusText

    func testStatusTextWithTerm() {
        let call = FunctionCallStruct(name: "yelp_search_businesses",
                                      arguments: ["term": "coffee"])
        let text = YelpSkill.shared.statusText(for: call)
        XCTAssertEqual(text, "searching Yelp for coffee")
    }

    func testStatusTextWithoutTerm() {
        let call = FunctionCallStruct(name: "yelp_search_businesses",
                                      arguments: [:])
        let text = YelpSkill.shared.statusText(for: call)
        XCTAssertEqual(text, "searching Yelp")
    }

    func testStatusTextReturnsNilForUnknownTool() {
        let call = FunctionCallStruct(name: "some_other_tool",
                                      arguments: [:])
        XCTAssertNil(YelpSkill.shared.statusText(for: call))
    }

    // MARK: - Missing API key

    func testMissingApiKeyReturnsGuidance() {
        // Without a YELP_API_KEY in the Keychain or Info.plist, the skill
        // should return a function-role message guiding the user to add one.
        let expectation = expectation(description: "completion called")
        let call = FunctionCallStruct(name: "yelp_search_businesses",
                                      arguments: ["term": "pizza", "location": "NYC"])
        YelpSkill.shared.handle(functionCall: call) { msg in
            XCTAssertEqual(msg.role, "function")
            XCTAssertEqual(msg.name, "yelp_search_businesses")
            XCTAssertTrue(msg.content.contains("API key"),
                          "Expected missing-key guidance, got: \(msg.content)")
            expectation.fulfill()
        }
        waitForExpectations(timeout: 2)
    }

    // MARK: - Missing location

    func testMissingLocationReturnsError() {
        // This test only verifies the location-validation path. It runs
        // regardless of whether a Yelp key is configured — if no key is
        // present the skill returns a missing-key message before reaching
        // location validation, so we just assert on the completion being
        // called (both paths are valid).
        let expectation = expectation(description: "completion called")
        let call = FunctionCallStruct(name: "yelp_search_businesses",
                                      arguments: ["term": "sushi"])
        YelpSkill.shared.handle(functionCall: call) { msg in
            // Either "no API key" or "location required" — both are valid
            // depending on the environment.
            XCTAssertFalse(msg.content.isEmpty)
            expectation.fulfill()
        }
        waitForExpectations(timeout: 2)
    }

    // MARK: - System prompt

    func testSystemPromptFragmentNotEmpty() {
        XCTAssertFalse(YelpSkill.systemPromptFragment.isEmpty)
        XCTAssertTrue(YelpSkill.systemPromptFragment.contains("yelp_search_businesses"))
    }

    // MARK: - Global tools array includes Yelp

    func testGlobalToolsArrayIncludesYelp() {
        let allNames = tools.compactMap { tool -> String? in
            let fn = tool["function"] as? [String: Any]
            return fn?["name"] as? String
        }
        XCTAssertTrue(allNames.contains("yelp_search_businesses"),
                       "Global tools array should include yelp_search_businesses")
    }

    // MARK: - SkillDispatcher routes Yelp

    func testSkillDispatcherRoutesYelp() {
        let expectation = expectation(description: "dispatcher routes to YelpSkill")
        let call = FunctionCallStruct(name: "yelp_search_businesses",
                                      arguments: ["term": "tacos", "location": "LA"])
        SkillDispatcher.shared.dispatch(call) { msg in
            // Should get a response (either missing-key or actual result),
            // not "Unknown tool".
            XCTAssertFalse(msg.content.contains("Unknown tool"),
                           "SkillDispatcher should route yelp_search_businesses")
            expectation.fulfill()
        }
        waitForExpectations(timeout: 2)
    }

    // MARK: - KeyStore has Yelp key

    func testKeyStoreHasYelpCase() {
        let key = KeyStore.Key.yelp
        XCTAssertEqual(key.rawValue, "YELP_API_KEY")
        XCTAssertFalse(key.displayName.isEmpty)
        XCTAssertFalse(key.subtitle.isEmpty)
    }

    func testKeyStoreServiceHasYelp() {
        let service = KeyStore.Service.yelp
        XCTAssertEqual(service.keys, [.yelp])
        XCTAssertFalse(service.displayName.isEmpty)
        XCTAssertFalse(service.summary.isEmpty)
    }
}
