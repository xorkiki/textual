import Foundation
import Supabase
import Testing
@testable import textual

@Suite(.serialized)
@MainActor
struct AccountSessionTests {
    @Test
    func missingConfigurationDoesNotCrashOrSignIn() async {
        let account = AccountSession(client: nil)
        await account.start()
        #expect(!account.isConfigured)
        #expect(!account.isRestoring)
        #expect(!account.isSignedIn)
        #expect(await account.signIn(email: "reader@example.com", password: "password123") == false)
        #expect(account.errorMessage != nil)
    }

    @Test
    func authURLsRejectUnrelatedOrMalformedDestinations() {
        #expect(AccountSession.acceptsAuthURL(URL(string: "textual://auth/callback?code=test")!))
        #expect(AccountSession.acceptsAuthURL(URL(string: "textual://auth/recovery?code=test")!))
        for value in ["https://auth/callback", "textual://elsewhere/callback", "textual://auth/other", "textual://user@auth/callback", "textual://auth:8080/recovery"] {
            #expect(!AccountSession.acceptsAuthURL(URL(string: value)!))
        }
    }

    @Test
    func signInAndRestoreUseStoredSDKSession() async throws {
        let (account, network, identifier) = makeAccount { request in
            #expect(request.url?.path == "/auth/v1/token")
            return (200, authSessionFixture)
        }
        defer { finish(network, identifier) }
        #expect(await account.signIn(email: "  reader@example.com \n", password: "password123"))
        #expect(account.userID == fixtureUserID)
        #expect(account.email == "reader@example.com")
        let restored = AccountSession(client: account.client, recoveryDefaults: UserDefaults(suiteName: identifier)!)
        let observer = Task { await restored.start() }
        defer { observer.cancel() }
        for _ in 0..<100 where restored.isRestoring { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!restored.isRestoring)
        #expect(restored.userID == fixtureUserID)
    }

    @Test
    func signupAwaitingConfirmationDoesNotOpenLibrary() async {
        let (account, network, identifier) = makeAccount { request in
            #expect(request.url?.path == "/auth/v1/signup")
            return (200, authUserFixture)
        }
        defer { finish(network, identifier) }
        #expect(await account.signUp(email: "reader@example.com", password: "password123"))
        #expect(!account.isSignedIn)
        #expect(account.message?.contains("confirm") == true)
    }

    @Test(arguments: ["obfuscated", "email_exists", "user_already_exists"])
    func existingSignupEmailOffersSignInWithoutConfirmation(kind: String) async throws {
        let (account, network, identifier) = makeAccount { request in
            #expect(request.url?.path == "/auth/v1/signup")
            if kind == "obfuscated" {
                var user = try #require(JSONSerialization.jsonObject(with: authUserFixture) as? [String: Any])
                user["identities"] = [] as [String]
                return (200, try JSONSerialization.data(withJSONObject: user))
            }
            return (422, Data("{\"error_code\":\"\(kind)\",\"message\":\"private details\"}".utf8))
        }
        defer { finish(network, identifier) }
        #expect(await account.signUp(email: "reader@example.com", password: "password123") == false)
        #expect(account.signupEmailAlreadyRegistered)
        #expect(account.errorMessage == "An account already uses this email. Sign in instead.")
        #expect(account.message == nil)
        #expect(!account.isSignedIn)
        #expect(!account.isWorking)
        account.clearMessages()
        #expect(!account.signupEmailAlreadyRegistered)
    }

    @Test
    func recoveryCallbackRequiresNewPasswordAndCompletesUpdate() async {
        let (account, network, identifier) = makeAccount { request in
            switch request.url?.path {
            case "/auth/v1/recover":
                let redirect = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "redirect_to" }?.value
                #expect(redirect == "textual://auth/recovery")
                return (200, Data("{}".utf8))
            case "/auth/v1/token": return (200, authSessionFixture)
            case "/auth/v1/user": return (200, authUserFixture)
            default:
                Issue.record("Unexpected auth endpoint")
                return (500, Data("{}".utf8))
            }
        }
        defer { finish(network, identifier) }
        #expect(await account.resetPassword(email: "reader@example.com"))
        #expect(await account.handleOpenURL(URL(string: "textual://auth/recovery?code=test-code")!))
        #expect(account.isSignedIn)
        #expect(account.needsPasswordReset)
        #expect(await account.updatePassword("new-password-123"))
        #expect(!account.needsPasswordReset)
        #expect(account.userID == fixtureUserID)
    }

    @Test
    func recoverySessionPersistsInKeychainBeforeSavingPassword() async throws {
        // In-memory auth tests cannot detect a simulator app installed without
        // the signing entitlements required by the production Keychain storage.
        let storage = KeychainLocalStorage(service: "textual.tests.recovery.\(UUID().uuidString)")
        let requests = AccountRequestLog()
        let (account, network, identifier) = makeAccount(storage: storage) { request in
            await requests.add(request)
            switch request.url?.path {
            case "/auth/v1/verify": return (200, authSessionFixture)
            case "/auth/v1/user": return (200, authUserFixture)
            default:
                Issue.record("Unexpected auth endpoint")
                return (500, Data("{}".utf8))
            }
        }
        defer {
            try? storage.remove(key: identifier)
            finish(network, identifier)
        }
        #expect(await account.verifyEmailCode(email: "reader@example.com", code: "12345678", purpose: .recovery))
        try await waitForProfile(account)
        let persisted = try #require(account.client?.auth.currentSession)
        #expect(persisted.user.id == fixtureUserID)
        #expect(account.needsPasswordReset)
        #expect(await account.updatePassword("new-password-123"))
        #expect(await requests.paths == ["/auth/v1/verify", "/auth/v1/user"])
        #expect(!account.needsPasswordReset)
    }

    @Test
    func failedLogoutStillRemovesLocalAccount() async {
        let (account, network, identifier) = makeAccount { request in
            if request.url?.path == "/auth/v1/logout" { throw URLError(.notConnectedToInternet) }
            return (200, authSessionFixture)
        }
        defer { finish(network, identifier) }
        #expect(await account.signIn(email: "reader@example.com", password: "password123"))
        #expect(await account.signOut())
        #expect(!account.isSignedIn)
        #expect(account.client?.auth.currentSession == nil)
    }

    @Test
    func staleSignInEventCannotRestoreSignedOutAccount() async {
        let (account, network, identifier) = makeAccount { request in
            if request.url?.path == "/auth/v1/logout" { return (204, Data()) }
            return (200, authSessionFixture)
        }
        defer { finish(network, identifier) }
        #expect(await account.signIn(email: "reader@example.com", password: "password123"))
        let staleSession = account.client?.auth.currentSession
        #expect(await account.signOut())
        account.receive(event: .signedIn, session: staleSession)
        #expect(!account.isSignedIn)
    }

    @Test
    func recoveryRequirementSurvivesRelaunch() async throws {
        let (account, network, identifier) = makeAccount { request in
            if request.url?.path == "/auth/v1/recover" { return (200, Data("{}".utf8)) }
            return (200, authSessionFixture)
        }
        defer { finish(network, identifier) }
        #expect(await account.resetPassword(email: "reader@example.com"))
        #expect(await account.handleOpenURL(URL(string: "textual://auth/recovery?code=test-code")!))
        let restored = AccountSession(client: account.client, recoveryDefaults: UserDefaults(suiteName: identifier)!)
        let observer = Task { await restored.start() }
        defer { observer.cancel() }
        for _ in 0..<100 where restored.isRestoring { try await Task.sleep(for: .milliseconds(10)) }
        #expect(restored.needsPasswordReset)
        #expect(restored.userID == fixtureUserID)
    }

    @Test
    func signupChecksNormalizedUsernameBeforeSendingEmail() async throws {
        let requests = AccountRequestLog()
        let (account, network, identifier) = makeAccount { request in
            await requests.add(request)
            let body = try #require(request.httpBody)
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            if request.url?.path == "/rest/v1/rpc/textual_username_available" {
                #expect(json["p_username"] as? String == "kiki_reader")
                return (200, Data("true".utf8))
            }
            let metadata = try #require(json["data"] as? [String: String])
            #expect(metadata == ["first_name": "Kiki", "username": "kiki_reader"])
            return (200, authUserFixture)
        }
        defer { finish(network, identifier) }
        #expect(await account.signUp(email: "reader@example.com", password: "password123", firstName: " Kiki ", username: " KIKI_READER "))
        #expect(!account.needsProfile)
        #expect(account.profile == nil)
        #expect(await requests.paths == ["/rest/v1/rpc/textual_username_available", "/auth/v1/signup"])
    }

    @Test
    func takenUsernameStopsSignupAndAllowsAnotherName() async throws {
        let requests = AccountRequestLog()
        let (account, network, identifier) = makeAccount { request in
            await requests.add(request)
            if request.url?.path == "/rest/v1/rpc/textual_username_available" {
                let body = try #require(request.httpBody)
                let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
                return (200, Data((json["p_username"] == "new_reader" ? "true" : "false").utf8))
            }
            #expect(request.url?.path == "/auth/v1/signup")
            return (200, authUserFixture)
        }
        defer { finish(network, identifier) }
        #expect(await account.signUp(email: "reader@example.com", password: "password123", firstName: "Kiki", username: " TAKEN_READER ") == false)
        #expect(account.errorMessage == "That username is already taken. Choose another one.")
        #expect(!account.isSignedIn)
        #expect(!account.isWorking)
        #expect(await requests.paths == ["/rest/v1/rpc/textual_username_available"])
        #expect(await account.signUp(email: "reader@example.com", password: "password123", firstName: "Kiki", username: "new_reader"))
        #expect(account.errorMessage == nil)
        #expect(await requests.paths == ["/rest/v1/rpc/textual_username_available", "/rest/v1/rpc/textual_username_available", "/auth/v1/signup"])
    }

    @Test(arguments: [false, true])
    func failedUsernameCheckNeverCreatesAnAccount(networkFailure: Bool) async {
        let requests = AccountRequestLog()
        let (account, network, identifier) = makeAccount { request in
            await requests.add(request)
            #expect(request.url?.path == "/rest/v1/rpc/textual_username_available")
            if networkFailure { throw URLError(.notConnectedToInternet) }
            return (403, Data("{\"code\":\"42501\",\"message\":\"private database details\"}".utf8))
        }
        defer { finish(network, identifier) }
        #expect(await account.signUp(email: "reader@example.com", password: "password123", firstName: "Kiki", username: "kiki_reader") == false)
        #expect(account.errorMessage == "Couldn’t check that username. Please try again.")
        #expect(!account.isWorking)
        #expect(!account.isSignedIn)
        #expect(await requests.paths.allSatisfy { $0 == "/rest/v1/rpc/textual_username_available" })
    }

    @Test
    func repeatedSubmitWhileCheckingUsernameDoesNotDuplicateSignup() async throws {
        let gate = AccountResponseGate()
        let requests = AccountRequestLog()
        let (account, network, identifier) = makeAccount { request in
            await requests.add(request)
            if request.url?.path == "/rest/v1/rpc/textual_username_available" {
                await gate.wait()
                return (200, Data("true".utf8))
            }
            return (200, authUserFixture)
        }
        defer { finish(network, identifier) }
        let first = Task { await account.signUp(email: "reader@example.com", password: "password123", firstName: "Kiki", username: "kiki_reader") }
        for _ in 0..<100 {
            if await gate.isWaiting { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(account.isWorking)
        #expect(await account.signUp(email: "reader@example.com", password: "password123", firstName: "Kiki", username: "kiki_reader") == false)
        await gate.release()
        #expect(await first.value)
        #expect(await requests.paths == ["/rest/v1/rpc/textual_username_available", "/auth/v1/signup"])
    }

    @Test
    func existingProfileWinsOverSignupMetadataAndTokenRefreshDoesNotRefetch() async throws {
        let requests = AccountRequestLog()
        let (account, network, identifier) = makeAccount(profileHandler: { request in
            await requests.add(request)
            #expect(request.url?.query?.contains("user_id=eq.") == true)
            return (200, profileListFixture)
        }) { _ in
            (200, makeAuthSession(metadata: ["first_name": "Stale", "username": "old_handle"]))
        }
        defer { finish(network, identifier) }
        #expect(await account.signIn(email: "reader@example.com", password: "password123"))
        try await waitForProfile(account)
        #expect(account.profile?.firstName == "Kiki")
        #expect(account.suggestedUsername == "kiki_reader")
        #expect(!account.needsProfile)
        account.receive(event: .tokenRefreshed, session: account.client?.auth.currentSession)
        account.receive(event: .signedIn, session: account.client?.auth.currentSession)
        #expect(!account.isLoadingProfile)
        #expect(await requests.paths.count == 1)
    }

    @Test(arguments: [false, true])
    func confirmedSignupFinishesProfileWithoutRepeatingQuestions(restore: Bool) async throws {
        let requests = AccountRequestLog()
        let (account, network, identifier) = makeAccount(profileHandler: { request in
            await requests.add(request)
            return (200, Data("[]".utf8))
        }) { request in
            await requests.add(request)
            if request.url?.path == "/rest/v1/rpc/textual_upsert_profile" {
                let body = try #require(request.httpBody)
                let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
                #expect(json["p_first_name"] == "Kiki")
                #expect(json["p_username"] == "kiki_reader")
                #expect(json["p_expected_user_id"]?.lowercased() == fixtureUserID.uuidString.lowercased())
                return (200, profileFixture)
            }
            return (200, makeAuthSession(metadata: ["first_name": "Kiki", "username": "kiki_reader"]))
        }
        defer { finish(network, identifier) }
        if restore {
            #expect(await account.signIn(email: "reader@example.com", password: "password123"))
        } else {
            #expect(await account.verifyEmailCode(email: "reader@example.com", code: "12345678", purpose: .signup))
        }
        try await waitForProfile(account)
        #expect(account.profile?.username == "kiki_reader")
        #expect(!account.needsProfile)
        #expect(!account.needsUsernameChoice)
        #expect(await requests.paths.filter { $0.contains("/rpc/") } == ["/rest/v1/rpc/textual_upsert_profile"])
    }

    @Test
    func nameClaimedDuringEmailConfirmationOnlyRequiresAnotherUsername() async throws {
        let (account, network, identifier) = makeAccount(profileHandler: { _ in (200, Data("[]".utf8)) }) { request in
            if request.url?.path == "/auth/v1/verify" {
                return (200, makeAuthSession(metadata: ["first_name": "Kiki", "username": "taken_reader"]))
            }
            let body = try #require(request.httpBody)
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
            if json["p_username"] == "taken_reader" {
                return (409, Data("{\"code\":\"23505\",\"message\":\"Username is unavailable.\"}".utf8))
            }
            #expect(json["p_first_name"] == "Kiki")
            return (200, profileFixture)
        }
        defer { finish(network, identifier) }
        #expect(await account.verifyEmailCode(email: "reader@example.com", code: "12345678", purpose: .signup))
        try await waitForProfile(account)
        #expect(account.needsProfile)
        #expect(account.needsUsernameChoice)
        #expect(account.suggestedFirstName == "Kiki")
        #expect(account.errorMessage == "That username is already taken. Choose another one.")
        #expect(await account.completeProfile(firstName: account.suggestedFirstName, username: "kiki_reader"))
        #expect(!account.needsProfile)
        #expect(!account.needsUsernameChoice)
    }

    @Test
    func automaticProfileSaveFailureOffersRetryInsteadOfRepeatingQuestions() async throws {
        let requests = AccountRequestLog()
        let (account, network, identifier) = makeAccount(profileHandler: { _ in (200, Data("[]".utf8)) }) { request in
            if request.url?.path == "/auth/v1/verify" {
                return (200, makeAuthSession(metadata: ["first_name": "Kiki", "username": "kiki_reader"]))
            }
            let count = await requests.add(request)
            if count == 1 { return (403, Data("{\"code\":\"42501\",\"message\":\"temporary failure\"}".utf8)) }
            return (200, profileFixture)
        }
        defer { finish(network, identifier) }
        #expect(await account.verifyEmailCode(email: "reader@example.com", code: "12345678", purpose: .signup))
        try await waitForProfile(account)
        #expect(account.profile == nil)
        #expect(!account.needsProfile)
        #expect(!account.needsUsernameChoice)
        #expect(account.errorMessage != nil)
        await account.reloadProfile()
        #expect(account.profile?.username == "kiki_reader")
        #expect(account.errorMessage == nil)
    }

    @Test
    func failedProfileLookupIsNotMissingAndCanBeRetried() async throws {
        let endpoint = AccountProfileEndpoint()
        let (account, network, identifier) = makeAccount(profileHandler: { _ in
            await endpoint.response()
        }) { _ in (200, authSessionFixture) }
        defer { finish(network, identifier) }
        #expect(await account.signIn(email: "reader@example.com", password: "password123"))
        try await waitForProfile(account)
        #expect(account.isSignedIn)
        #expect(!account.needsProfile)
        #expect(account.profile == nil)
        #expect(account.errorMessage != nil)
        #expect(await account.completeProfile(firstName: "Kiki", username: "overwrite") == false)
        let requestsBeforeRetry = await endpoint.requestCount
        #expect(requestsBeforeRetry >= 1)
        await endpoint.makeAvailable()
        await account.reloadProfile()
        #expect(account.profile?.username == "kiki_reader")
        #expect(account.errorMessage == nil)
        #expect(await endpoint.requestCount == requestsBeforeRetry + 1)
    }

    @Test
    func usernameCollisionIsRecoverableAndRPCAssertsTheCurrentOwner() async throws {
        let requests = AccountRequestLog()
        let (account, network, identifier) = makeAccount(profileHandler: { _ in (200, Data("[]".utf8)) }) { request in
            if request.url?.path == "/auth/v1/token" { return (200, authSessionFixture) }
            #expect(request.url?.path == "/rest/v1/rpc/textual_upsert_profile")
            let count = await requests.add(request)
            let body = try #require(request.httpBody)
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
            #expect(json["p_expected_user_id"]?.lowercased() == fixtureUserID.uuidString.lowercased())
            #expect(json["p_first_name"] == "Kiki")
            if count == 1 {
                return (409, Data("{\"code\":\"23505\",\"message\":\"private database detail must not leak\"}".utf8))
            }
            #expect(json["p_username"] == "kiki_reader")
            return (200, profileFixture)
        }
        defer { finish(network, identifier) }
        #expect(await account.signIn(email: "reader@example.com", password: "password123"))
        try await waitForProfile(account)
        #expect(await account.completeProfile(firstName: " Kiki ", username: "TAKEN_HANDLE") == false)
        #expect(account.errorMessage == "That username is already taken. Choose another one.")
        #expect(account.needsProfile)
        #expect(await account.completeProfile(firstName: " Kiki ", username: "KIKI_READER"))
        #expect(account.profile?.username == "kiki_reader")
        #expect(!account.needsProfile)
    }

    @Test
    func invalidSignupProfileNeverSendsAnEmail() async {
        let (account, network, identifier) = makeAccount { _ in
            Issue.record("Invalid signup unexpectedly reached the network")
            return (500, Data())
        }
        defer { finish(network, identifier) }
        for (name, username) in [("", "reader"), ("A\u{0007}B", "reader"), (String(repeating: "a", count: 81), "reader"), ("Kiki", "a"), ("Kiki", "not a handle"), ("Kiki", "rêader")] {
            #expect(await account.signUp(email: "reader@example.com", password: "password123", firstName: name, username: username) == false)
            #expect(account.errorMessage != nil)
        }
    }

    @Test
    func delayedProfileCannotCrossAccountSwitch() async throws {
        let gate = AccountResponseGate()
        let (account, network, identifier) = makeAccount(profileHandler: { request in
            if request.url?.query?.lowercased().contains(fixtureUserID.uuidString.lowercased()) == true {
                await gate.wait()
                return (200, profileListFixture)
            }
            return (200, Data("[]".utf8))
        }) { request in
            if request.url?.path == "/auth/v1/logout" { return (204, Data()) }
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            return (200, body.contains("second@example.com") ? makeAuthSession(userID: secondUserID, metadata: ["username": "other_reader"]) : authSessionFixture)
        }
        defer { finish(network, identifier) }
        #expect(await account.signIn(email: "reader@example.com", password: "password123"))
        for _ in 0..<100 {
            if await gate.isWaiting { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await gate.isWaiting)
        #expect(await account.signOut())
        #expect(account.profile == nil)
        #expect(account.suggestedFirstName.isEmpty)
        #expect(await account.signIn(email: "second@example.com", password: "password123"))
        try await waitForProfile(account)
        await gate.release()
        #expect(account.userID == secondUserID)
        #expect(account.profile == nil)
        #expect(account.needsProfile)
        #expect(account.suggestedUsername == "other_reader")
    }

    @Test
    func profileSaveFinishingAfterSDKSignoutCannotRestoreProfile() async throws {
        let gate = AccountResponseGate()
        let (account, network, identifier) = makeAccount(profileHandler: { _ in (200, Data("[]".utf8)) }) { request in
            if request.url?.path == "/auth/v1/logout" { return (204, Data()) }
            if request.url?.path == "/rest/v1/rpc/textual_upsert_profile" {
                await gate.wait()
                return (200, profileFixture)
            }
            return (200, authSessionFixture)
        }
        defer { finish(network, identifier) }
        #expect(await account.signIn(email: "reader@example.com", password: "password123"))
        try await waitForProfile(account)
        let completion = Task { await account.completeProfile(firstName: "Kiki", username: "kiki_reader") }
        for _ in 0..<100 {
            if await gate.isWaiting { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await gate.isWaiting)
        try await account.client?.auth.signOut(scope: .local)
        account.receive(event: .signedOut, session: nil)
        await gate.release()
        #expect(await completion.value == false)
        #expect(!account.isSignedIn)
        #expect(account.profile == nil)
        #expect(!account.needsProfile)
        #expect(!account.isLoadingProfile)
        #expect(account.suggestedUsername.isEmpty)
    }

    @Test
    func signupCodeVerifiesWithoutDeepLinkAndLoadsPrivateProfile() async throws {
        let requests = AccountRequestLog()
        let (account, network, identifier) = makeAccount(profileHandler: { request in
            await requests.add(request)
            return (200, profileListFixture)
        }) { request in
            await requests.add(request)
            #expect(request.url?.path == "/auth/v1/verify")
            #expect(request.httpMethod == "POST")
            let body = try #require(request.httpBody)
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
            #expect(json["email"] == "reader@example.com")
            #expect(json["token"] == "00123456")
            #expect(json["type"] == "signup")
            #expect(json["password"] == nil)
            return (200, authSessionFixture)
        }
        defer { finish(network, identifier) }
        #expect(await account.verifyEmailCode(email: " reader@example.com ", code: " 00123456\n", purpose: .signup))
        try await waitForProfile(account)
        #expect(account.userID == fixtureUserID)
        #expect(account.profile?.username == "kiki_reader")
        #expect(!account.needsPasswordReset)
        #expect(await requests.paths == ["/auth/v1/verify", "/rest/v1/textual_profiles"])
    }

    @Test
    func recoveryCodeGatesSignedInEventAndPersistsUntilPasswordUpdate() async throws {
        let (account, network, identifier) = makeAccount { request in
            if request.url?.path == "/auth/v1/user" { return (200, authUserFixture) }
            #expect(request.url?.path == "/auth/v1/verify")
            let body = try #require(request.httpBody)
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
            #expect(json["type"] == "recovery")
            return (200, authSessionFixture)
        }
        defer { finish(network, identifier) }
        let observer = Task { await account.start() }
        defer { observer.cancel() }
        #expect(await account.verifyEmailCode(email: "reader@example.com", code: "12345678", purpose: .recovery))
        try await waitForProfile(account)
        #expect(account.isSignedIn)
        #expect(account.needsPasswordReset)
        account.receive(event: .signedIn, session: account.client?.auth.currentSession)
        account.receive(event: .tokenRefreshed, session: account.client?.auth.currentSession)
        #expect(account.needsPasswordReset)

        let restored = AccountSession(client: account.client, recoveryDefaults: UserDefaults(suiteName: identifier)!)
        let restoredObserver = Task { await restored.start() }
        defer { restoredObserver.cancel() }
        for _ in 0..<100 where restored.isRestoring { try await Task.sleep(for: .milliseconds(10)) }
        #expect(restored.userID == fixtureUserID)
        #expect(restored.needsPasswordReset)
        #expect(await restored.updatePassword("new-password-123"))
        #expect(!restored.needsPasswordReset)
    }

    @Test
    func expiredOrReusedEmailCodeNeverCreatesALocalSession() async {
        let (account, network, identifier) = makeAccount { request in
            #expect(request.url?.path == "/auth/v1/verify")
            return (403, Data("{\"error_code\":\"otp_expired\",\"message\":\"secret server detail and token must never appear\"}".utf8))
        }
        defer { finish(network, identifier) }
        for purpose in [EmailCodePurpose.signup, .recovery] {
            #expect(await account.verifyEmailCode(email: "reader@example.com", code: "12345678", purpose: purpose) == false)
            #expect(!account.isSignedIn)
            #expect(account.client?.auth.currentSession == nil)
            #expect(account.profile == nil)
            #expect(!account.needsPasswordReset)
            #expect(account.errorMessage == "That code is incorrect or has expired. Request a new code and try again.")
        }
    }

    @Test
    func malformedEmailCodesNeverReachVerificationOrSendEmail() async {
        let (account, network, identifier) = makeAccount { _ in
            Issue.record("Malformed input unexpectedly reached the network")
            return (500, Data())
        }
        defer { finish(network, identifier) }
        for code in ["", "12345", "12345678901", "123a56", "123 456", "١٢٣٤٥٦", "１２３４５６"] {
            #expect(await account.verifyEmailCode(email: "reader@example.com", code: code, purpose: .signup) == false)
            #expect(account.errorMessage == "Enter the 6–10 digit code from your email.")
        }
        #expect(await account.verifyEmailCode(email: "invalid email", code: "12345678", purpose: .recovery) == false)
        #expect(await account.resendSignupConfirmation(email: "invalid email") == false)
        #expect(await account.resetPassword(email: "invalid email") == false)
        #expect(!account.isSignedIn)
        #expect(!account.needsPasswordReset)
    }

    @Test
    func resendsUseExistingSignupAndRecoveryFlowsWithoutCreatingAUser() async throws {
        let requests = AccountRequestLog()
        let (account, network, identifier) = makeAccount { request in
            await requests.add(request)
            let body = try #require(request.httpBody)
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(json["email"] as? String == "reader@example.com")
            #expect(json["password"] == nil)
            switch request.url?.path {
            case "/auth/v1/resend": #expect(json["type"] as? String == "signup")
            case "/auth/v1/recover": break
            default: Issue.record("Resend used an unexpected endpoint")
            }
            return (200, Data("{}".utf8))
        }
        defer { finish(network, identifier) }
        #expect(await account.resendSignupConfirmation(email: " reader@example.com "))
        #expect(account.message?.contains("code") == true)
        #expect(await account.resetPassword(email: "reader@example.com"))
        #expect(account.message?.contains("recovery code") == true)
        #expect(await requests.paths == ["/auth/v1/resend", "/auth/v1/recover"])
        #expect(!account.isSignedIn)
        #expect(account.profile == nil)
    }

    @Test
    func emailCodeRateLimitsNeverExposeServerMessages() async {
        let (account, network, identifier) = makeAccount { request in
            let code = request.url?.path == "/auth/v1/resend" ? "over_email_send_rate_limit" : "over_request_rate_limit"
            return (429, Data("{\"error_code\":\"\(code)\",\"message\":\"private-token-bearing-provider-details\"}".utf8))
        }
        defer { finish(network, identifier) }
        #expect(await account.resendSignupConfirmation(email: "reader@example.com") == false)
        #expect(account.errorMessage == "Please wait a moment before trying again.")
        #expect(await account.verifyEmailCode(email: "reader@example.com", code: "12345678", purpose: .signup) == false)
        #expect(account.errorMessage == "Please wait a moment before trying again.")
        #expect(!account.isSignedIn)
    }

    @Test
    func verificationResponseWithoutSessionCannotOpenTheLibrary() async {
        let (account, network, identifier) = makeAccount { request in
            #expect(request.url?.path == "/auth/v1/verify")
            return (200, authUserFixture)
        }
        defer { finish(network, identifier) }
        #expect(await account.verifyEmailCode(email: "reader@example.com", code: "12345678", purpose: .recovery) == false)
        #expect(!account.isSignedIn)
        #expect(!account.needsPasswordReset)
        #expect(account.profile == nil)
        #expect(account.errorMessage != nil)
    }

    private func waitForProfile(_ account: AccountSession) async throws {
        for _ in 0..<100 where account.isLoadingProfile { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!account.isLoadingProfile)
    }

    private func makeAccount(storage: (any AuthLocalStorage)? = nil, profileHandler: AccountURLProtocol.Handler? = nil, handler: @escaping AccountURLProtocol.Handler) -> (AccountSession, URLSession, String) {
        let identifier = UUID().uuidString
        AccountURLProtocol.registry.set({ request in
            if request.url?.path == "/rest/v1/textual_profiles" {
                if let profileHandler { return try await profileHandler(request) }
                return (200, profileListFixture)
            }
            return try await handler(request)
        }, for: identifier)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AccountURLProtocol.self]
        let network = URLSession(configuration: configuration)
        let client = SupabaseClient(
            supabaseURL: URL(string: "https://account-test.supabase.co")!,
            supabaseKey: "test-publishable-key",
            options: .init(
                auth: .init(storage: storage ?? MemoryAccountStorage(), storageKey: identifier, autoRefreshToken: false, emitLocalSessionAsInitialSession: true),
                global: .init(headers: ["X-Account-Test": identifier], session: network)
            )
        )
        return (AccountSession(client: client, recoveryDefaults: UserDefaults(suiteName: identifier)!), network, identifier)
    }

    private func finish(_ network: URLSession, _ identifier: String) {
        network.invalidateAndCancel()
        UserDefaults(suiteName: identifier)?.removePersistentDomain(forName: identifier)
        AccountURLProtocol.registry.remove(identifier)
    }
}

private let fixtureUserID = UUID(uuidString: "5DB7713D-47B7-42F3-90A3-93CC3CBBCBF3")!
private let secondUserID = UUID(uuidString: "7ACE7CAC-3C74-45CC-8673-D496A2B18A31")!
private let profileFixture = Data("{\"user_id\":\"5db7713d-47b7-42f3-90a3-93cc3cbbcbf3\",\"first_name\":\"Kiki\",\"username\":\"kiki_reader\"}".utf8)
private var profileListFixture: Data { Data("[\(String(decoding: profileFixture, as: UTF8.self))]".utf8) }
private let authUserFixture = Data("""
{"id":"5db7713d-47b7-42f3-90a3-93cc3cbbcbf3","aud":"authenticated","email":"reader@example.com","created_at":"2026-10-08T00:00:00Z","updated_at":"2026-10-08T00:00:00Z","app_metadata":{},"user_metadata":{}}
""".utf8)
private var authSessionFixture: Data {
    makeAuthSession()
}

private func makeAuthSession(userID: UUID = fixtureUserID, metadata: [String: String] = [:]) -> Data {
    var user = try! JSONSerialization.jsonObject(with: authUserFixture) as! [String: Any]
    user["id"] = userID.uuidString
    user["user_metadata"] = metadata
    return try! JSONSerialization.data(withJSONObject: [
        "access_token": "test-access-token-\(userID)", "refresh_token": "test-refresh-token",
        "token_type": "bearer", "expires_in": 3600,
        "expires_at": Date().addingTimeInterval(3600).timeIntervalSince1970, "user": user
    ])
}

private actor AccountRequestLog {
    private(set) var paths: [String] = []
    @discardableResult func add(_ request: URLRequest) -> Int {
        paths.append(request.url?.path ?? "")
        return paths.count
    }
}

private actor AccountProfileEndpoint {
    private var isAvailable = false
    private(set) var requestCount = 0
    func response() -> (Int, Data) {
        requestCount += 1
        if isAvailable { return (200, profileListFixture) }
        // A permission error is not retried by the SDK. Keep failing until the
        // test explicitly repairs the endpoint, rather than succeeding by count.
        return (403, Data("{\"code\":\"42501\",\"message\":\"Profile lookup is unavailable\"}".utf8))
    }
    func makeAvailable() { isAvailable = true }
}

private actor AccountResponseGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false
    private(set) var isWaiting = false
    func wait() async {
        isWaiting = true
        guard !isReleased else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

private final class MemoryAccountStorage: AuthLocalStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func store(key: String, value: Data) throws { lock.withLock { values[key] = value } }
    func retrieve(key: String) throws -> Data? { lock.withLock { values[key] } }
    func remove(key: String) throws { lock.withLock { _ = values.removeValue(forKey: key) } }
}

private final class AccountURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) async throws -> (Int, Data)
    static let registry = Registry()
    private let loaderLock = NSLock()
    private var loader: Task<Void, Never>?
    final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var handlers: [String: Handler] = [:]
        func set(_ handler: @escaping Handler, for key: String) { lock.withLock { handlers[key] = handler } }
        func remove(_ key: String) { lock.withLock { _ = handlers.removeValue(forKey: key) } }
        func handler(for key: String) -> Handler? { lock.withLock { handlers[key] } }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let key = request.value(forHTTPHeaderField: "X-Account-Test"),
              let handler = Self.registry.handler(for: key) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            captured.httpBody = data
        }
        let requestToHandle = captured
        loaderLock.withLock {
            loader = Task { [self] in
                do {
                    let (status, data) = try await handler(requestToHandle)
                    guard !Task.isCancelled else { return }
                    let response = HTTPURLResponse(url: requestToHandle.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: data)
                    client?.urlProtocolDidFinishLoading(self)
                } catch {
                    guard !Task.isCancelled else { return }
                    client?.urlProtocol(self, didFailWithError: error)
                }
            }
        }
    }
    override func stopLoading() { loaderLock.withLock { loader?.cancel() } }
}
