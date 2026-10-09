import Foundation
import Observation
import Supabase

struct AccountProfile: Codable, Equatable, Sendable {
    let userID: UUID
    let firstName: String
    let username: String

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case firstName = "first_name"
        case username
    }
}

enum EmailCodePurpose: Equatable, Sendable {
    case signup
    case recovery
}

/// Owns account state. Supabase stores and refreshes credentials in its Keychain storage.
@MainActor
@Observable
final class AccountSession {
    static let callbackURL = URL(string: "textual://auth/callback")!
    static let recoveryURL = URL(string: "textual://auth/recovery")!

    @ObservationIgnored let client: SupabaseClient?
    private(set) var userID: UUID?
    private(set) var email: String?
    private(set) var isRestoring = true
    private(set) var isWorking = false
    private(set) var needsPasswordReset = false
    private(set) var errorMessage: String?
    private(set) var message: String?
    private(set) var profile: AccountProfile?
    private(set) var isLoadingProfile = false
    private(set) var suggestedFirstName = ""
    private(set) var suggestedUsername = ""

    // This stores only a UI recovery marker, never credentials or tokens.
    @ObservationIgnored private let recoveryDefaults: UserDefaults
    private static let recoveryMarkerKey = "textual.pendingPasswordRecoveryUser"
    @ObservationIgnored private var isObserving = false
    @ObservationIgnored private var isHandlingRecovery = false
    @ObservationIgnored private var profileTask: Task<Void, Never>?
    @ObservationIgnored private var profileRequestID = UUID()
    private var hasLoadedProfile = false

    var isConfigured: Bool { client != nil }
    var isSignedIn: Bool { userID != nil }
    /// A failed lookup is not evidence that a profile is missing.
    var needsProfile: Bool { isSignedIn && hasLoadedProfile && profile == nil && !isLoadingProfile }

    convenience init() {
        let client = Secrets.supabaseConfiguration.map { configuration in
            SupabaseClient(
                supabaseURL: configuration.url,
                supabaseKey: configuration.anonKey,
                options: .init(auth: .init(
                    redirectToURL: Self.callbackURL,
                    emitLocalSessionAsInitialSession: true
                ))
            )
        }
        self.init(client: client)
    }

    init(client: SupabaseClient?, recoveryDefaults: UserDefaults = .standard) {
        self.client = client
        self.recoveryDefaults = recoveryDefaults
        if client == nil { isRestoring = false }
    }

    /// Keep this running from the app's root .task, outside the signed-in/out branches.
    func start() async {
        guard !isObserving else { return }
        guard let client else {
            isRestoring = false
            return
        }
        isObserving = true
        defer { isObserving = false }
        for await (event, session) in client.auth.authStateChanges {
            guard !Task.isCancelled else { break }
            receive(event: event, session: session)
            isRestoring = false
        }
    }

    func clearMessages() {
        errorMessage = nil
        message = nil
    }

    @discardableResult
    func signIn(email: String, password: String) async -> Bool {
        guard let client = beginOperation() else { return false }
        defer { isWorking = false }
        guard let email = validatedEmail(email), !password.isEmpty else {
            if errorMessage == nil { errorMessage = "Enter your password." }
            return false
        }
        do {
            let session = try await client.auth.signIn(email: email, password: password)
            setRecoveryRequired(for: nil)
            apply(session)
            return true
        } catch {
            show(error)
            return false
        }
    }

    @discardableResult
    func signUp(email: String, password: String) async -> Bool {
        await signUp(email: email, password: password, metadata: [:])
    }

    @discardableResult
    func signUp(email: String, password: String, firstName: String, username: String) async -> Bool {
        guard !isWorking else { return false }
        clearMessages()
        guard let fields = validatedProfile(firstName: firstName, username: username) else { return false }
        // Suggestions travel with the account; they do not reserve a username or grant ownership.
        return await signUp(email: email, password: password, metadata: [
            "first_name": .string(fields.firstName), "username": .string(fields.username)
        ])
    }

    private func signUp(email: String, password: String, metadata: [String: AnyJSON]) async -> Bool {
        guard let client = beginOperation() else { return false }
        defer { isWorking = false }
        guard let email = validatedEmail(email), validatedPassword(password) else { return false }
        do {
            let response = try await client.auth.signUp(email: email, password: password, data: metadata, redirectTo: Self.callbackURL)
            if let session = response.session {
                apply(session)
            } else {
                message = "Enter the code from your email to confirm your account."
            }
            return true
        } catch {
            show(error)
            return false
        }
    }

    @discardableResult
    func verifyEmailCode(email: String, code: String, purpose: EmailCodePurpose) async -> Bool {
        guard let client = beginOperation() else { return false }
        defer { isWorking = false }
        guard let email = validatedEmail(email), let code = validatedEmailCode(code) else { return false }

        // The SDK emits signedIn before verifyOTP returns. Mark this operation
        // first so the observer persists the recovery gate before applying it.
        isHandlingRecovery = purpose == .recovery
        defer { isHandlingRecovery = false }
        do {
            let response = try await client.auth.verifyOTP(
                email: email, token: code,
                type: purpose == .signup ? .signup : .recovery,
                redirectTo: purpose == .signup ? Self.callbackURL : Self.recoveryURL
            )
            guard let session = response.session else {
                errorMessage = "The code couldn’t be verified. Request a new code and try again."
                return false
            }
            if purpose == .recovery { setRecoveryRequired(for: session.user.id) }
            apply(session)
            return true
        } catch {
            if let authError = error as? AuthError,
               ["otp_expired", "invalid_credentials", "validation_failed"].contains(authError.errorCode.rawValue) {
                errorMessage = "That code is incorrect or has expired. Request a new code and try again."
            } else {
                show(error)
            }
            return false
        }
    }

    @discardableResult
    func resendSignupConfirmation(email: String) async -> Bool {
        guard let client = beginOperation() else { return false }
        defer { isWorking = false }
        guard let email = validatedEmail(email) else { return false }
        do {
            try await client.auth.resend(email: email, type: .signup, emailRedirectTo: Self.callbackURL)
            message = "If this email is waiting for confirmation, a new code is on its way."
            return true
        } catch {
            show(error)
            return false
        }
    }

    @discardableResult
    func resetPassword(email: String) async -> Bool {
        guard let client = beginOperation() else { return false }
        defer { isWorking = false }
        guard let email = validatedEmail(email) else { return false }
        do {
            try await client.auth.resetPasswordForEmail(email, redirectTo: Self.recoveryURL)
            // Deliberately do not reveal whether an address has an account.
            message = "If an account uses this email, a recovery code is on its way. Enter it here to choose a new password."
            return true
        } catch {
            show(error)
            return false
        }
    }

    @discardableResult
    func updatePassword(_ password: String) async -> Bool {
        guard let client = beginOperation() else { return false }
        defer { isWorking = false }
        guard isSignedIn else {
            errorMessage = "Enter the recovery code from your email before choosing a new password."
            return false
        }
        guard validatedPassword(password) else { return false }
        do {
            let user = try await client.auth.update(user: .init(password: password))
            userID = user.id
            email = user.email
            setRecoveryRequired(for: nil)
            message = "Your password has been updated."
            return true
        } catch {
            show(error)
            return false
        }
    }

    @discardableResult
    func signOut() async -> Bool {
        guard let client = beginOperation() else { return false }
        defer { isWorking = false }
        do {
            // This device's session only; leave other signed-in devices alone.
            try await client.auth.signOut(scope: .local)
            apply(nil)
            return true
        } catch {
            // The SDK removes Keychain credentials before making its logout request.
            if client.auth.currentSession == nil {
                apply(nil)
                message = "You’re signed out on this device. The account service couldn’t confirm the sign-out."
                return true
            }
            show(error)
            return false
        }
    }

    @discardableResult
    func handleOpenURL(_ url: URL) async -> Bool {
        guard Self.acceptsAuthURL(url) else { return false }
        // Email callbacks can arrive while a sign-up/reset request is finishing.
        // Serialize the exchange instead of silently dropping a valid link.
        while isWorking {
            do { try await Task.sleep(for: .milliseconds(50)) }
            catch { return false }
        }
        guard !Task.isCancelled, let client = beginOperation() else { return false }
        let isRecovery = url.path == Self.recoveryURL.path
        isHandlingRecovery = isRecovery
        defer {
            isWorking = false
            isHandlingRecovery = false
        }
        do {
            let session = try await client.auth.session(from: url)
            if isRecovery { setRecoveryRequired(for: session.user.id) }
            apply(session)
            return true
        } catch {
            // SDK callback errors may contain the full token-bearing URL; never display them.
            errorMessage = "This sign-in link has expired or couldn’t be opened. Request a new email code and try again."
            return false
        }
    }

    static func acceptsAuthURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "textual"
            && url.host?.lowercased() == "auth"
            && url.user == nil && url.password == nil && url.port == nil
            && [callbackURL.path, recoveryURL.path].contains(url.path)
    }

    func reloadProfile() async {
        guard !isWorking, let userID, let client, client.auth.currentSession?.user.id == userID else { return }
        clearMessages()
        beginProfileLoad(for: userID)
        await profileTask?.value
    }

    @discardableResult
    func completeProfile(firstName: String, username: String) async -> Bool {
        guard !isLoadingProfile, hasLoadedProfile else { return false }
        guard let client = beginOperation() else { return false }
        defer { isWorking = false }
        guard let ownerID = userID, client.auth.currentSession?.user.id == ownerID else {
            errorMessage = "Please sign in again to finish your profile."
            return false
        }
        guard let fields = validatedProfile(firstName: firstName, username: username) else { return false }
        suggestedFirstName = fields.firstName
        suggestedUsername = fields.username
        let requestID = profileRequestID
        isLoadingProfile = true
        defer {
            if profileRequestID == requestID { isLoadingProfile = false }
        }
        do {
            let saved: AccountProfile = try await client.rpc("textual_upsert_profile", params: ProfileParameters(
                p_expected_user_id: ownerID, p_first_name: fields.firstName, p_username: fields.username
            )).execute().value
            guard isCurrentProfileRequest(requestID, ownerID: ownerID) else { return false }
            guard saved.userID == ownerID else {
                errorMessage = "Your profile couldn’t be saved. Please try again."
                return false
            }
            profile = saved
            suggestedFirstName = saved.firstName
            suggestedUsername = saved.username
            return true
        } catch {
            guard isCurrentProfileRequest(requestID, ownerID: ownerID) else { return false }
            if let databaseError = error as? PostgrestError, databaseError.code == "23505" {
                errorMessage = "That username is already taken. Choose another one."
            } else if !Task.isCancelled {
                errorMessage = "Your profile couldn’t be saved. Please try again."
            }
            return false
        }
    }

    private struct ProfileParameters: Encodable {
        let p_expected_user_id: UUID
        let p_first_name: String
        let p_username: String
    }

    private func beginProfileLoad(for ownerID: UUID) {
        profileTask?.cancel()
        let requestID = UUID()
        profileRequestID = requestID
        isLoadingProfile = true
        hasLoadedProfile = false
        profileTask = Task { [weak self] in
            guard let self, let client = self.client else { return }
            defer {
                if self.profileRequestID == requestID {
                    self.isLoadingProfile = false
                    self.profileTask = nil
                }
            }
            do {
                let rows: [AccountProfile] = try await client.from("textual_profiles")
                    .select("user_id,first_name,username")
                    .eq("user_id", value: ownerID.uuidString)
                    .limit(1)
                    .execute().value
                guard !Task.isCancelled, self.isCurrentProfileRequest(requestID, ownerID: ownerID) else { return }
                guard rows.allSatisfy({ $0.userID == ownerID }) else {
                    self.errorMessage = "Your profile couldn’t be loaded. Please try again."
                    return
                }
                self.profile = rows.first
                self.hasLoadedProfile = true
                if let profile = rows.first {
                    self.suggestedFirstName = profile.firstName
                    self.suggestedUsername = profile.username
                }
            } catch {
                guard !Task.isCancelled, self.isCurrentProfileRequest(requestID, ownerID: ownerID) else { return }
                // Server and transport errors can contain identifiers or credentials.
                self.errorMessage = "Your profile couldn’t be loaded. Check your connection and try again."
            }
        }
    }

    private func isCurrentProfileRequest(_ requestID: UUID, ownerID: UUID) -> Bool {
        profileRequestID == requestID && userID == ownerID && client?.auth.currentSession?.user.id == ownerID
    }

    private func beginOperation() -> SupabaseClient? {
        guard !isWorking else { return nil }
        clearMessages()
        guard let client else {
            errorMessage = "Accounts aren’t available yet. Please try again later."
            return nil
        }
        isWorking = true
        return client
    }

    /// A queued SDK event must not restore an older account after a newer sign-in/out.
    func receive(event: AuthChangeEvent, session: Session?) {
        guard let client else { return }
        let current = client.auth.currentSession
        guard current?.user.id == session?.user.id,
              current?.accessToken == session?.accessToken else { return }
        if event == .passwordRecovery || (event == .signedIn && isHandlingRecovery), let current {
            setRecoveryRequired(for: current.user.id)
        }
        apply(current)
    }

    private func apply(_ session: Session?) {
        let identityChanged = userID != session?.user.id
        if identityChanged {
            clearMessages()
            profileTask?.cancel()
            profileTask = nil
            profileRequestID = UUID()
            profile = nil
            hasLoadedProfile = false
            isLoadingProfile = false
            suggestedFirstName = session?.user.userMetadata["first_name"]?.stringValue ?? ""
            suggestedUsername = session?.user.userMetadata["username"]?.stringValue ?? ""
        }
        userID = session?.user.id
        email = session?.user.email
        isRestoring = false
        if let userID {
            needsPasswordReset = recoveryDefaults.string(forKey: Self.recoveryMarkerKey) == userID.uuidString
        } else {
            setRecoveryRequired(for: nil)
        }
        if identityChanged, let userID { beginProfileLoad(for: userID) }
    }

    private func setRecoveryRequired(for userID: UUID?) {
        if let userID {
            recoveryDefaults.set(userID.uuidString, forKey: Self.recoveryMarkerKey)
        } else {
            recoveryDefaults.removeObject(forKey: Self.recoveryMarkerKey)
        }
        needsPasswordReset = userID != nil
    }

    private func validatedEmail(_ value: String) -> String? {
        let email = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty,
              !email.contains(where: \.isWhitespace) else {
            errorMessage = "Enter a valid email address."
            return nil
        }
        return email
    }

    private func validatedPassword(_ password: String) -> Bool {
        guard password.count >= 8 else {
            errorMessage = "Use a password with at least 8 characters."
            return false
        }
        return true
    }

    private func validatedEmailCode(_ value: String) -> String? {
        let code = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (6...10).contains(code.count), code.utf8.allSatisfy({ (48...57).contains($0) }) else {
            errorMessage = "Enter the 6–10 digit code from your email."
            return nil
        }
        return code
    }

    private func validatedProfile(firstName: String, username: String) -> (firstName: String, username: String)? {
        let name = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        let handle = username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !name.isEmpty, name.unicodeScalars.count <= 80,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            errorMessage = "Enter a first name between 1 and 80 characters."
            return nil
        }
        guard handle.range(of: "^[a-z0-9_]{3,30}$", options: .regularExpression) != nil else {
            errorMessage = "Use 3 to 30 letters, numbers, or underscores for your username."
            return nil
        }
        return (name, handle)
    }

    private func show(_ error: Error) {
        if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { return }
        if let networkError = error as? URLError {
            errorMessage = networkError.code == .timedOut
                ? "The account service took too long to respond. Please try again."
                : "Couldn’t connect to your account. Check your internet connection and try again."
            return
        }
        if let authError = error as? AuthError {
            switch authError.errorCode.rawValue {
            case "invalid_credentials": errorMessage = "The email or password is incorrect."
            case "email_not_confirmed": errorMessage = "Confirm your email address before signing in."
            case "otp_expired": errorMessage = "That code is incorrect or has expired. Request a new code and try again."
            case "weak_password": errorMessage = "Choose a stronger password that meets the account requirements."
            case "same_password": errorMessage = "Choose a different password from your current one."
            case "email_exists", "user_already_exists": errorMessage = "An account already uses this email. Try signing in."
            case "over_email_send_rate_limit", "over_request_rate_limit": errorMessage = "Please wait a moment before trying again."
            case "signup_disabled", "email_provider_disabled": errorMessage = "New accounts aren’t available right now. Please try again later."
            case "reauthentication_needed", "session_not_found", "session_expired":
                errorMessage = "Please sign in again or request a new recovery code."
            default: errorMessage = "The account request couldn’t be completed. Please try again."
            }
            return
        }
        errorMessage = "The account request couldn’t be completed. Please try again."
    }
}
