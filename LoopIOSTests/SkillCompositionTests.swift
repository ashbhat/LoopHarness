//
//  SkillCompositionTests.swift
//  LoopIOSTests
//
//  Unit tests for skill-to-skill invocation via host.callSkill:
//  happy path, missing skill errors, recursion depth guard,
//  and error propagation from invoked skills.
//

import XCTest
@testable import Loop

// MARK: - Skill composition tests

final class SkillCompositionTests: XCTestCase {

    private var registry: DynamicSkillRegistry!

    override func setUp() {
        super.setUp()
        registry = DynamicSkillRegistry.shared
        // Seed test skills into the registry's in-memory map directly.
        seedTestSkills()
    }

    override func tearDown() {
        // Remove test skills
        removeTestSkills()
        super.tearDown()
    }

    // MARK: - Test skills

    /// Skill B: a simple skill that uppercases a given string.
    private let skillBSource = """
    async function run(args, host) {
        var text = args.text || "";
        return { status: "ok", result: text.toUpperCase() };
    }
    """

    /// Skill A: calls skill B via host.callSkill and returns the result.
    private let skillASource = """
    async function run(args, host) {
        var result = await host.callSkill("test_skill_b", { text: args.text });
        return { status: "ok", from_b: result };
    }
    """

    /// Recursive skill: calls itself to test depth guard.
    private let recursiveSkillSource = """
    async function run(args, host) {
        var depth = (args.depth || 0) + 1;
        var result = await host.callSkill("test_recursive", { depth: depth });
        return { status: "ok", depth: depth, inner: result };
    }
    """

    /// Skill that returns an error.
    private let errorSkillSource = """
    async function run(args, host) {
        throw new Error("intentional failure from test_error_skill");
    }
    """

    /// Skill that calls a non-existent skill.
    private let callsMissingSource = """
    async function run(args, host) {
        var result = await host.callSkill("nonexistent_skill_xyz", {});
        return { status: "ok", result: result };
    }
    """

    /// Skill that calls the error skill.
    private let callsErrorSkillSource = """
    async function run(args, host) {
        var result = await host.callSkill("test_error_skill", {});
        return { status: "ok", result: result };
    }
    """

    private func seedTestSkills() {
        let skills: [(String, String, String)] = [
            ("test_skill_a", "Test skill A — calls B", skillASource),
            ("test_skill_b", "Test skill B — uppercases text", skillBSource),
            ("test_recursive", "Recursive test skill", recursiveSkillSource),
            ("test_error_skill", "Always throws", errorSkillSource),
            ("test_calls_missing", "Calls a missing skill", callsMissingSource),
            ("test_calls_error", "Calls the error skill", callsErrorSkillSource),
        ]

        for (name, desc, source) in skills {
            let loaded = DynamicSkillRegistry.LoadedSkill(
                name: name,
                description: desc,
                parameters: ["type": "object", "properties": [String: Any](), "required": [String]()],
                source: source,
                folder: URL(fileURLWithPath: "/tmp/test_skills/\(name)"),
                manifestMTime: nil,
                scriptMTime: nil
            )
            registry.skills[name] = loaded
        }
    }

    private func removeTestSkills() {
        let names = ["test_skill_a", "test_skill_b", "test_recursive",
                     "test_error_skill", "test_calls_missing", "test_calls_error"]
        for name in names {
            registry.skills.removeValue(forKey: name)
        }
    }

    // MARK: - Happy path

    func testCallSkillHappyPath() {
        let expectation = XCTestExpectation(description: "Skill A calls Skill B and gets result")

        let skillA = registry.skills["test_skill_a"]!
        registry.executeSkill(skillA, args: ["text": "hello"], callDepth: 0) { result in
            switch result {
            case .success(let value):
                guard let dict = value as? [String: Any],
                      let fromB = dict["from_b"] as? [String: Any],
                      let inner = fromB["result"] as? String else {
                    XCTFail("Unexpected result structure: \(value)")
                    expectation.fulfill()
                    return
                }
                XCTAssertEqual(inner, "HELLO")
            case .failure(let error):
                XCTFail("Expected success, got error: \(error)")
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 10)
    }

    // MARK: - Missing skill

    func testCallSkillMissing() {
        let expectation = XCTestExpectation(description: "Calling missing skill returns error")

        let skill = registry.skills["test_calls_missing"]!
        registry.executeSkill(skill, args: [:], callDepth: 0) { result in
            switch result {
            case .success:
                XCTFail("Expected failure for missing skill call")
            case .failure(let error):
                XCTAssertTrue(error.localizedDescription.contains("not found"),
                              "Error should mention skill not found: \(error.localizedDescription)")
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 10)
    }

    // MARK: - Recursion depth guard

    func testCallSkillRecursionDepthGuard() {
        let expectation = XCTestExpectation(description: "Recursive calls hit depth limit")

        let skill = registry.skills["test_recursive"]!
        registry.executeSkill(skill, args: ["depth": 0], callDepth: 0) { result in
            switch result {
            case .success:
                XCTFail("Expected failure from depth limit")
            case .failure(let error):
                XCTAssertTrue(
                    error.localizedDescription.contains("depth") ||
                    error.localizedDescription.contains("Max skill call depth"),
                    "Error should mention depth: \(error.localizedDescription)")
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 15)
    }

    // MARK: - Error propagation

    func testCallSkillErrorPropagation() {
        let expectation = XCTestExpectation(description: "Error from called skill propagates")

        let skill = registry.skills["test_calls_error"]!
        registry.executeSkill(skill, args: [:], callDepth: 0) { result in
            switch result {
            case .success:
                XCTFail("Expected failure from error skill")
            case .failure(let error):
                XCTAssertTrue(
                    error.localizedDescription.contains("intentional failure"),
                    "Error should propagate from inner skill: \(error.localizedDescription)")
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 10)
    }
}
