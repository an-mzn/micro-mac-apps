import Darwin
import Foundation
import XCTest
@testable import UsageCore

final class UsageCoreTests: XCTestCase {
    private var storage: Storage!
    private var client: Client!

    func testBankedResetWarningUsesFutureExpirationsWithin72Hours() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let deadline = now.addingTimeInterval(72 * 60 * 60)
        let payload = """
        {"rateLimitResetCredits":{"availableCount":3,"credits":[
            {"expiresAt":1699999999},{"expiresAt":null},{"expiresAt":1700259200}
        ]}}
        """
        let limits = try JSONDecoder().decode(Limits.self, from: Data(payload.utf8))
        let snapshot = Snapshot(windows: [], bankedResetCount: limits.bankedResetCount,
                                bankedResetExpirations: limits.bankedResetExpirations)

        XCTAssertTrue(snapshot.hasBankedResetExpiringSoon(now: now))
        XCTAssertFalse(snapshot.hasBankedResetExpiringSoon(now: now.addingTimeInterval(-1)))
        XCTAssertFalse(snapshot.hasBankedResetExpiringSoon(now: deadline))
        XCTAssertFalse(Snapshot(windows: [], bankedResetCount: 3).hasBankedResetExpiringSoon(now: now))
    }

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        storage = Storage(root: root)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/codex")
        client = Client(binary: fixture, storage: storage)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: storage.root)
    }

    func testMostAvailableUsesWeeklyOnlyWhenFiveHourWindowIsAbsent() {
        let identity = Identity(account: Account(type: "chatgpt", email: nil, planType: nil, workspaceName: nil),
                                workspaceID: nil)
        let fiveHours = Window(id: "codex:Primary", bucket: "Codex", slot: "Primary", minutes: 300, used: 60, reset: nil)
        let weekly = Window(id: "codex:Secondary", bucket: "Codex", slot: "Secondary", minutes: 10_080, used: 0, reset: nil)
        let weeklyOnly = Window(id: "codex:Primary", bucket: "Codex", slot: "Primary", minutes: 10_080, used: 30, reset: nil)
        let pairedProfile = Profile(id: UUID(), label: "Both", identity: identity,
                                    snapshot: Snapshot(windows: [fiveHours, weekly]))
        let weeklyProfile = Profile(id: UUID(), label: "Weekly only", identity: identity,
                                     snapshot: Snapshot(windows: [weeklyOnly]))
        var config = Configuration()
        config.profiles = [pairedProfile, weeklyProfile]
        XCTAssertEqual(config.mostAvailable?.profile.id, weeklyProfile.id)
        XCTAssertEqual(config.mostAvailable?.window.remaining, 70)
        config.profiles = [pairedProfile]
        XCTAssertEqual(config.mostAvailable?.window.remaining, 40)
    }

    private func profile(_ scenario: String) throws -> (UUID, URL) {
        let id = UUID()
        let home = try storage.home(id)
        try scenario.write(to: home.appendingPathComponent("scenario"), atomically: true, encoding: .utf8)
        return (id, home)
    }

    private func assertReaped(_ home: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let pidText = try String(contentsOf: home.appendingPathComponent("pid"), encoding: .utf8)
        let pid = try XCTUnwrap(Int32(pidText))
        XCTAssertEqual(kill(pid, 0), -1, file: file, line: line)
        XCTAssertEqual(errno, ESRCH, file: file, line: line)
    }

    func testSimultaneousProfilesAndNullableWindows() throws {
        let (first, firstHome) = try profile("normal")
        let (second, secondHome) = try profile("studio")
        let firstDone = expectation(description: "first account")
        DispatchQueue.global().async {
            defer { firstDone.fulfill() }
            do {
                let (account, snapshot) = try self.client.refresh(first, cancellation: Cancellation())
                XCTAssertEqual(account.account.email, "same@example.invalid")
                XCTAssertNil(account.workspaceID)
                XCTAssertEqual(snapshot.windows.map(\.remaining), [77])
                XCTAssertNotNil(snapshot.windows.first?.reset)
                try self.assertReaped(firstHome)
            } catch { XCTFail(error.localizedDescription) }
        }
        let (account, snapshot) = try client.refresh(second, cancellation: Cancellation())
        XCTAssertEqual(account.account.email, "same@example.invalid")
        XCTAssertEqual(account.workspaceID, "studio")
        XCTAssertEqual(snapshot.windows.map(\.title), ["Codex · 5 hours", "Codex · Weekly", "Studio Meter · Monthly (30 days)"])
        XCTAssertEqual(snapshot.windows.map(\.remaining), [77, 11, 60])
        XCTAssertNil(snapshot.windows.last?.reset)
        try assertReaped(secondHome)
        wait(for: [firstDone], timeout: 4)
    }

    func testSignInReauthenticationAndRemovalStayInProfileHomes() throws {
        let (first, firstHome) = try profile("normal")
        let (second, secondHome) = try profile("studio")
        for _ in 0..<2 {
            let identity = try client.signIn(first, cancellation: Cancellation()) { challenge in
                XCTAssertEqual(challenge.code, "TEST-CODE")
            }
            XCTAssertEqual(identity.account.email, "same@example.invalid")
            try assertReaped(firstHome)
        }
        _ = try client.signIn(second, cancellation: Cancellation()) { _ in }
        let calls = try String(contentsOf: firstHome.appendingPathComponent("calls"), encoding: .utf8)
        XCTAssertEqual(calls.components(separatedBy: "account/login/start").count - 1, 2)
        try storage.remove(first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstHome.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondHome.path))
        XCTAssertEqual(try client.refresh(second, cancellation: Cancellation()).0.workspaceID, "studio")
    }

    func testPartialFailurePreservesPersistedReading() throws {
        let (first, firstHome) = try profile("normal")
        let (second, _) = try profile("studio")
        let (identity, snapshot) = try client.refresh(first, cancellation: Cancellation())
        var config = Configuration()
        config.profiles = [Profile(id: first, label: "First", identity: identity, snapshot: snapshot)]
        try storage.save(config)
        let file = storage.root.appendingPathComponent("settings.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        try storage.save(config)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber,
                       attributes[.systemFileNumber] as? NSNumber)
        try "offline".write(to: firstHome.appendingPathComponent("scenario"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try client.refresh(first, cancellation: Cancellation())) { error in
            XCTAssertEqual(error as? UsageError, .offline)
        }
        XCTAssertEqual(try storage.load(), config)
        XCTAssertEqual(try client.refresh(second, cancellation: Cancellation()).1.windows.count, 3)
        XCTAssertTrue(snapshot.due(interval: 7200, now: snapshot.at.addingTimeInterval(3601)))
        XCTAssertFalse(snapshot.due(interval: 900, now: snapshot.at.addingTimeInterval(30)))
    }

    func testExpiredAuthRetriesOnceUsingManagedRefresh() throws {
        let (id, home) = try profile("expired")
        XCTAssertEqual(try client.refresh(id, cancellation: Cancellation()).1.windows.first?.remaining, 77)
        let calls = try String(contentsOf: home.appendingPathComponent("calls"), encoding: .utf8)
        XCTAssertEqual(calls.split(separator: "\n"),
                       ["initialize", "account/read", "account/rateLimits/read", "account/read", "account/rateLimits/read"])
        try assertReaped(home)
    }

    func testFailuresAreBoundedAndReaped() throws {
        for (scenario, expected) in [("timeout", UsageError.timeout), ("exit", .exited),
                                     ("malformed", .malformed), ("wrong-home", .isolation), ("signed-out", .signIn)] {
            let (id, home) = try profile(scenario)
            XCTAssertThrowsError(try client.refresh(id, cancellation: Cancellation(), timeout: 1)) { error in
                XCTAssertEqual(error as? UsageError, expected, scenario)
            }
            try assertReaped(home)
        }
    }

    func testCancellationBeforeRemovalAndDuringSignIn() throws {
        let (id, home) = try profile("timeout")
        let token = Cancellation()
        let done = expectation(description: "refresh reaped before removal")
        DispatchQueue.global().async {
            defer { done.fulfill() }
            do {
                XCTAssertThrowsError(try self.client.refresh(id, cancellation: token)) { error in
                    XCTAssertEqual(error as? UsageError, .cancelled)
                }
                try self.assertReaped(home)
                try self.storage.remove(id)
            } catch { XCTFail(error.localizedDescription) }
        }
        let calls = home.appendingPathComponent("calls")
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, (try? String(contentsOf: calls, encoding: .utf8).contains("rateLimits")) != true {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertTrue((try? String(contentsOf: calls, encoding: .utf8).contains("rateLimits")) == true)
        token.cancel()
        wait(for: [done], timeout: 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path))

        let (login, loginHome) = try profile("login-wait")
        let loginToken = Cancellation()
        XCTAssertThrowsError(try client.signIn(login, cancellation: loginToken) { _ in loginToken.cancel() }) { error in
            XCTAssertEqual(error as? UsageError, .cancelled)
        }
        try assertReaped(loginHome)
        XCTAssertTrue(try String(contentsOf: loginHome.appendingPathComponent("calls"), encoding: .utf8)
            .contains("account/login/cancel"))
    }

    func testRejectsSymlinkAndInheritedCredentials() throws {
        let (id, home) = try profile("normal")
        try storage.remove(id)
        let untouched = storage.root.appendingPathComponent("untouched")
        try FileManager.default.createDirectory(at: untouched, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: home, withDestinationURL: untouched)
        XCTAssertThrowsError(try storage.remove(id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: untouched.path))
        let env = Client.environment(home: home, inherited: [
            "CODEX_HOME": "/wrong", "OPENAI_API_KEY": "dummy", "CODEX_ACCESS_TOKEN": "dummy",
            "CHATGPT_TOKEN": "dummy", "AUTH_TOKEN": "dummy", "HTTPS_PROXY": "proxy", "HOME": "/test"
        ])
        XCTAssertEqual(env, ["CODEX_HOME": home.path, "HOME": "/test", "HTTPS_PROXY": "proxy",
                             "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"])
    }
}
