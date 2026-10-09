import SwiftUI

/// A small, explicit account journey. Draft fields remain local until the final submit.
struct AccountView: View {
    @Bindable var session: AccountSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedField: Field?
    @State private var step: Step = .welcome
    @State private var draft = Draft()
    @State private var showsPassword = false
    @State private var validationMessage: String?
    @State private var isSubmittingSignup = false
    @State private var confirmationKind: ConfirmationKind = .signup
    @State private var resendAvailableAt: [String: Date] = [:]

    private enum Step: Hashable {
        case welcome, signupEmail, signupPassword, signupFirstName, signupUsername
        case signinEmail, signinPassword, resetEmail, checkEmail
        case recoveryPassword, profileFirstName, profileUsername
        case restoring, loadingProfile, profileError, creating, account, unavailable
    }
    private enum Field: Hashable { case email, password, firstName, username, confirmation, emailCode }
    private enum ConfirmationKind { case signup, passwordReset }
    private struct Draft {
        var email = ""
        var password = ""
        var firstName = ""
        var username = ""
        var confirmation = ""
        var emailCode = ""
    }

    private var screen: Step {
        if isSubmittingSignup { return .creating }
        if session.isRestoring { return .restoring }
        if !session.isConfigured { return .unavailable }
        if session.needsPasswordReset { return .recoveryPassword }
        if step == .checkEmail && confirmationKind == .passwordReset { return .checkEmail }
        if session.isSignedIn {
            if session.isLoadingProfile { return .loadingProfile }
            if session.needsProfile {
                return step == .profileUsername ? .profileUsername : .profileFirstName
            }
            return session.profile == nil ? .profileError : .account
        }
        return step
    }

    private var isBusy: Bool { session.isWorking || session.isLoadingProfile || isSubmittingSignup }

    var body: some View {
        ZStack {
            Color.inkwell.ignoresSafeArea()
            VStack(spacing: 0) {
                navigationBar
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 28) {
                        content
                        if screen != .creating && screen != .checkEmail {
                            feedback
                        }
                    }
                    .frame(maxWidth: 480, alignment: .leading)
                    .padding(.horizontal, 28)
                    .padding(.top, screen == .welcome ? 34 : 42)
                    .padding(.bottom, 28)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
                .accessibilityIdentifier("auth.content")
                actions
            }
        }
        .environment(\.colorScheme, .dark)
        .task(id: screen) {
            seedProfileDraft()
            guard let target = initialFocus else { focusedField = nil; return }
            do {
                try await Task.sleep(for: .milliseconds(180))
                focusedField = target
            } catch { }
        }
        .onChange(of: session.isSignedIn) { wasSignedIn, isSignedIn in
            if wasSignedIn && !isSignedIn {
                draft.password = ""
                draft.confirmation = ""
                step = .welcome
                validationMessage = nil
            }
        }
        .onChange(of: session.userID) { _, _ in draft.emailCode = "" }
        .onChange(of: draft.email) { _, _ in draft.emailCode = "" }
        .onChange(of: session.needsPasswordReset) { _, _ in
            draft.password = ""
            draft.confirmation = ""
            showsPassword = false
            validationMessage = nil
            draft.emailCode = ""
        }
        .onDisappear {
            draft.password = ""
            draft.confirmation = ""
            draft.emailCode = ""
        }
    }

    private var navigationBar: some View {
        HStack {
            if screen == .account {
                Button("Done") { dismiss() }
                    .font(AccountTypography.body(14))
                    .foregroundStyle(Color.paper)
                    .frame(minWidth: 44, minHeight: 44)
            } else if screen == .profileFirstName || screen == .profileError {
                Button("Sign out") { Task { _ = await session.signOut() } }
                    .font(AccountTypography.body(14))
                    .foregroundStyle(Color.ghost)
                    .frame(minHeight: 44)
                    .disabled(isBusy)
            } else if canGoBack {
                Button(action: goBack) {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(Color.paper)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(screen == .recoveryPassword ? "Cancel password recovery and sign out" : "Back")
                .accessibilityIdentifier("auth.back")
                .disabled(isBusy)
            } else {
                Color.clear.frame(width: 44, height: 44)
                    .accessibilityHidden(true)
            }
            Spacer()
            if let progress = signupProgress {
                Text("\(progress) / 4")
                    .font(AccountTypography.body(12))
                    .tracking(2)
                    .foregroundStyle(Color.ghost)
                    .accessibilityLabel("Create account, step \(progress) of 4")
            } else if screen != .welcome {
                Text("TEXTUAL")
                    .font(.custom("CormorantGaramond-Regular", size: 18, relativeTo: .headline))
                    .tracking(3)
                    .foregroundStyle(Color.ghost)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
    }

    @ViewBuilder
    private var content: some View {
        switch screen {
        case .welcome:
            AccountWelcomePresentation()
        case .signupEmail:
            heading("What’s your email?", detail: "Your library starts here.")
            emailField
        case .signupPassword:
            heading("Choose a password.", detail: "A little privacy for your next chapter.")
            passwordField(isNew: true)
            passwordRequirement
        case .signupFirstName, .profileFirstName:
            heading("What should we\ncall you?", detail: "Just your first name.")
            nameField
        case .signupUsername, .profileUsername:
            heading("Pick a username.", detail: "A name to make this place yours.")
            usernameField
            Text(screen == .signupUsername
                 ? "You’ll claim your username after confirming your email."
                 : "Your username is yours once you finish setting up your account.")
                .font(AccountTypography.body(13))
                .foregroundStyle(Color.ghost)
                .fixedSize(horizontal: false, vertical: true)
        case .signinEmail:
            heading("Welcome back.", detail: "Let’s find your library.")
            emailField
            codeEntryLink("I have a confirmation code", identifier: "auth.haveConfirmationCode", kind: .signup)
        case .signinPassword:
            heading("Enter your password.", detail: draft.email.trimmingCharacters(in: .whitespacesAndNewlines))
            passwordField(isNew: false)
            Button("Forgot password?") {
                transition(to: .resetEmail)
            }
            .font(AccountTypography.body(14))
            .foregroundStyle(Color.paper)
            .frame(minHeight: 44, alignment: .leading)
            .accessibilityIdentifier("auth.forgotPassword")
            .disabled(isBusy)
        case .resetEmail:
            heading("Forgot your\npassword?", detail: "We’ll send a code to help you get back in.")
            emailField
            codeEntryLink("I have a recovery code", identifier: "auth.haveRecoveryCode", kind: .passwordReset)
        case .recoveryPassword:
            heading("A fresh start.", detail: "Choose a new password for your account.")
            passwordField(isNew: true)
            passwordRequirement
            confirmationField
        case .checkEmail:
            confirmationContent
        case .restoring:
            status("Welcome back.", detail: "Opening your account…")
        case .loadingProfile:
            status("Your next chapter.", detail: "Opening your profile…")
        case .creating:
            status("A new chapter.", detail: "Creating your account…")
        case .profileError:
            heading("Let’s try that again.", detail: "Your profile couldn’t be loaded. Check your connection and try again.")
        case .unavailable:
            heading("Back in a moment.", detail: "Sign-in is temporarily unavailable. Please try again later.")
        case .account:
            accountContent
        }
    }

    private func heading(_ title: String, detail: String) -> some View {
        AccountQuestionHeading(title: title, detail: detail)
    }

    private func status(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 32) {
            heading(title, detail: detail)
            ProgressView()
                .controlSize(.large)
                .tint(.paper)
                .accessibilityLabel(detail)
        }
        .padding(.top, 56)
    }

    private var emailField: some View {
        AccountFieldFrame(label: "EMAIL ADDRESS") {
            TextField("you@example.com", text: $draft.email)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focusedField, equals: .email)
                .submitLabel(.continue)
                .onSubmit { Task { await advance() } }
                .accessibilityIdentifier("auth.email")
        }
        .disabled(isBusy)
    }

    private var nameField: some View {
        AccountFieldFrame(label: "FIRST NAME") {
            TextField("Your first name", text: $draft.firstName)
                .textContentType(.givenName)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .focused($focusedField, equals: .firstName)
                .submitLabel(.continue)
                .onSubmit { Task { await advance() } }
                .accessibilityIdentifier("auth.firstName")
        }
        .disabled(isBusy)
    }

    private var usernameField: some View {
        AccountFieldFrame(label: "USERNAME") {
            HStack(spacing: 4) {
                Text("@").foregroundStyle(Color.ghost)
                TextField("your_username", text: $draft.username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .username)
                    .submitLabel(.go)
                    .onSubmit { Task { await advance() } }
                    .accessibilityIdentifier("auth.username")
            }
        }
        .disabled(isBusy)
    }

    private func passwordField(isNew: Bool) -> some View {
        AccountFieldFrame(label: isNew ? "NEW PASSWORD" : "PASSWORD") {
            HStack(spacing: 12) {
                Group {
                    if showsPassword {
                        TextField(isNew ? "At least 8 characters" : "Your password", text: $draft.password)
                    } else {
                        SecureField(isNew ? "At least 8 characters" : "Your password", text: $draft.password)
                    }
                }
                .textContentType(isNew ? .newPassword : .password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focusedField, equals: .password)
                .submitLabel(screen == .signinPassword ? .go : .continue)
                .onSubmit {
                    if screen == .recoveryPassword { focusedField = .confirmation }
                    else { Task { await advance() } }
                }
                .accessibilityIdentifier("auth.password")
                Button {
                    showsPassword.toggle()
                    focusedField = .password
                } label: {
                    Image(systemName: showsPassword ? "eye.slash" : "eye")
                        .font(.system(size: 18))
                        .foregroundStyle(Color.ghost)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showsPassword ? "Hide password" : "Show password")
                .accessibilityIdentifier("account.passwordVisibility")
            }
        }
        .disabled(isBusy)
    }

    private var passwordRequirement: some View {
        Label("At least 8 characters", systemImage: draft.password.count >= 8 ? "checkmark.circle.fill" : "circle")
            .font(AccountTypography.body(13))
            .foregroundStyle(draft.password.count >= 8 ? Color.paper : Color.ghost)
            .accessibilityLabel(draft.password.count >= 8 ? "Password length requirement met" : "Password must have at least 8 characters")
    }

    private var confirmationField: some View {
        AccountFieldFrame(label: "CONFIRM NEW PASSWORD") {
            SecureField("Repeat your password", text: $draft.confirmation)
                .textContentType(.newPassword)
                .focused($focusedField, equals: .confirmation)
                .submitLabel(.go)
                .onSubmit { Task { await advance() } }
                .accessibilityIdentifier("auth.confirmPassword")
        }
        .disabled(isBusy)
    }

    private var confirmationContent: some View {
        VStack(alignment: .leading, spacing: 28) {
            AccountCodeHeading(email: draft.email, isRecovery: confirmationKind == .passwordReset)
            AccountFieldFrame(label: "EMAIL CODE") {
                TextField("Your code", text: $draft.emailCode)
                    .textContentType(.oneTimeCode)
                    .keyboardType(.numberPad)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .emailCode)
                    .submitLabel(.go)
                    .onSubmit { Task { await advance() } }
                    .accessibilityLabel("Email code")
                    .accessibilityIdentifier("auth.emailCode")
            }
            .disabled(isBusy)
            feedback
            Text("You can read the email on any device. Enter its code here.")
                .font(AccountTypography.body(14))
                .foregroundStyle(Color.ghost)
                .fixedSize(horizontal: false, vertical: true)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = resendCooldown(at: context.date)
                AccountSecondaryButton(title: remaining > 0 ? "Resend Code in \(remaining)s" : "Resend Code",
                                       identifier: "auth.resendCode") {
                    Task { await resendCode() }
                }
                .disabled(isBusy || remaining > 0)
                .opacity(isBusy || remaining > 0 ? 0.55 : 1)
            }
        }
    }

    private func codeEntryLink(_ title: String, identifier: String, kind: ConfirmationKind,
                               sourceEmail: String? = nil) -> some View {
        Button(title) {
            if let sourceEmail { draft.email = sourceEmail }
            guard validateEmail() else { return }
            openCodeEntry(kind)
        }
        .font(AccountTypography.body(14))
        .foregroundStyle(Color.paper)
        .frame(minHeight: 44, alignment: .leading)
        .accessibilityIdentifier(identifier)
        .disabled(isBusy)
    }

    private var accountContent: some View {
        VStack(alignment: .leading, spacing: 28) {
            heading("Hello, \(session.profile?.firstName ?? "reader").", detail: "A little space for your reading life.")
            VStack(alignment: .leading, spacing: 18) {
                if let profile = session.profile {
                    accountValue("USERNAME", value: "@\(profile.username)")
                }
                if let email = session.email { accountValue("EMAIL ADDRESS", value: email) }
            }
            Rectangle().fill(Color.velvet).frame(height: 1).accessibilityHidden(true)
            Button("Send password reset email") {
                guard let email = session.email else { return }
                draft.email = email
                Task { await sendRecoveryCode() }
            }
            .font(AccountTypography.body(14))
            .foregroundStyle(Color.paper)
            .frame(minHeight: 44)
            .disabled(isBusy || session.email == nil)
            codeEntryLink("I have a recovery code", identifier: "auth.haveRecoveryCode",
                          kind: .passwordReset, sourceEmail: session.email)
                .disabled(session.email == nil)
        }
    }

    private func accountValue(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(AccountTypography.body(11)).tracking(1.5).foregroundStyle(Color.ghost)
            Text(value).font(AccountTypography.body(17)).foregroundStyle(Color.paper).textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var feedback: some View {
        if let error = validationMessage ?? session.errorMessage {
            Label(error, systemImage: "exclamationmark.circle")
                .font(AccountTypography.body(13))
                .foregroundStyle(Color.paper)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(error)
                .accessibilityIdentifier("auth.error")
        } else if let message = session.message {
            Text(message)
                .font(AccountTypography.body(13))
                .foregroundStyle(Color.ghost)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("auth.message")
        }
    }

    @ViewBuilder
    private var actions: some View {
        if screen == .welcome {
            VStack(spacing: 12) {
                AccountPrimaryButton(title: "Sign In", isWorking: false, identifier: "welcome.signIn") { begin(.signinEmail) }
                AccountSecondaryButton(title: "Create Account") { begin(.signupEmail) }
            }
            .accountActionArea()
        } else if let title = primaryTitle {
            VStack(spacing: 12) {
                AccountPrimaryButton(title: title, isWorking: isBusy, identifier: isSubmitStep ? "auth.submit" : "auth.next") {
                    Task { await advance() }
                }
                .disabled(isBusy)
                if screen == .checkEmail {
                    Button(session.isSignedIn ? "Back to Account" : "Back to Sign In") {
                        transition(to: session.isSignedIn ? .account : .signinEmail)
                    }
                        .font(AccountTypography.body(13))
                        .foregroundStyle(Color.ghost)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("auth.backToSignIn")
                        .disabled(isBusy)
                }
            }
            .accountActionArea()
        }
    }

    private var isSubmitStep: Bool {
        [.signupUsername, .signinPassword, .resetEmail, .checkEmail, .recoveryPassword, .profileUsername, .account].contains(screen)
    }

    private var primaryTitle: String? {
        switch screen {
        case .signupEmail, .signupPassword, .signupFirstName, .signinEmail, .profileFirstName: return "Continue"
        case .signupUsername: return "Create Account"
        case .signinPassword: return "Sign In"
        case .profileUsername: return "Finish Setup"
        case .resetEmail: return "Send Reset Code"
        case .recoveryPassword: return "Save New Password"
        case .checkEmail: return confirmationKind == .signup ? "Confirm Email" : "Verify Code"
        case .profileError: return "Try Again"
        case .account: return "Sign Out"
        default: return nil
        }
    }

    private var signupProgress: Int? {
        switch screen {
        case .signupEmail: return 1
        case .signupPassword: return 2
        case .signupFirstName: return 3
        case .signupUsername: return 4
        default: return nil
        }
    }

    private var canGoBack: Bool {
        switch screen {
        case .welcome, .restoring, .loadingProfile, .creating, .unavailable, .account, .profileError, .profileFirstName: return false
        default: return true
        }
    }

    private var initialFocus: Field? {
        switch screen {
        case .signupEmail, .signinEmail, .resetEmail: return .email
        case .signupPassword, .signinPassword, .recoveryPassword: return .password
        case .signupFirstName, .profileFirstName: return .firstName
        case .signupUsername, .profileUsername: return .username
        case .checkEmail: return .emailCode
        default: return nil
        }
    }

    private func begin(_ destination: Step) {
        draft.password = ""
        draft.confirmation = ""
        transition(to: destination)
    }

    private func transition(to destination: Step) {
        focusedField = nil
        validationMessage = nil
        showsPassword = false
        draft.emailCode = ""
        session.clearMessages()
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { step = destination }
    }

    private func goBack() {
        guard !isBusy else { return }
        switch screen {
        case .signupPassword: transition(to: .signupEmail)
        case .signupFirstName: transition(to: .signupPassword)
        case .signupUsername: transition(to: .signupFirstName)
        case .signinPassword: transition(to: .signinEmail)
        case .resetEmail: transition(to: .signinPassword)
        case .checkEmail:
            transition(to: session.isSignedIn ? .account : (confirmationKind == .signup ? .signinEmail : .resetEmail))
        case .profileUsername: transition(to: .profileFirstName)
        case .recoveryPassword: Task { _ = await session.signOut() }
        default: transition(to: .welcome)
        }
    }

    private func seedProfileDraft() {
        guard session.needsProfile else { return }
        if draft.firstName.isEmpty { draft.firstName = session.suggestedFirstName }
        if draft.username.isEmpty { draft.username = session.suggestedUsername }
    }

    private func advance() async {
        guard !isBusy else { return }
        validationMessage = nil
        switch screen {
        case .signupEmail:
            guard validateEmail() else { return }
            transition(to: .signupPassword)
        case .signupPassword:
            guard validatePassword() else { return }
            transition(to: .signupFirstName)
        case .signupFirstName:
            guard validateFirstName() else { return }
            transition(to: .signupUsername)
        case .signupUsername:
            guard validateUsername() else { return }
            guard validateEmail() else { step = .signupEmail; return }
            guard validatePassword() else { step = .signupPassword; return }
            guard validateFirstName() else { step = .signupFirstName; return }
            focusedField = nil
            isSubmittingSignup = true
            let succeeded = await session.signUp(email: draft.email, password: draft.password,
                                                  firstName: draft.firstName, username: draft.username)
            isSubmittingSignup = false
            if succeeded {
                draft.password = ""
                if !session.isSignedIn {
                    openCodeEntry(.signup, startCooldown: true, preserveMessage: true)
                }
            }
        case .signinEmail:
            guard validateEmail() else { return }
            transition(to: .signinPassword)
        case .signinPassword:
            guard !draft.password.isEmpty else { validationMessage = "Enter your password."; return }
            focusedField = nil
            if await session.signIn(email: draft.email, password: draft.password) { draft.password = "" }
        case .resetEmail:
            guard validateEmail() else { return }
            await sendRecoveryCode()
        case .recoveryPassword:
            guard validatePassword() else { return }
            guard draft.password == draft.confirmation else { validationMessage = "The passwords don’t match."; return }
            focusedField = nil
            if await session.updatePassword(draft.password) {
                draft.password = ""
                draft.confirmation = ""
            }
        case .profileFirstName:
            guard validateFirstName() else { return }
            transition(to: .profileUsername)
        case .profileUsername:
            guard validateFirstName(), validateUsername() else { return }
            focusedField = nil
            if !(await session.completeProfile(firstName: draft.firstName, username: draft.username)) {
                focusedField = .username
            }
        case .profileError:
            await session.reloadProfile()
        case .checkEmail:
            guard validateEmail(), validateEmailCode() else { return }
            focusedField = nil
            let purpose: EmailCodePurpose = confirmationKind == .signup ? .signup : .recovery
            if await session.verifyEmailCode(email: draft.email, code: draft.emailCode, purpose: purpose) {
                draft.emailCode = ""
                if confirmationKind == .passwordReset { step = .recoveryPassword }
            } else {
                focusedField = .emailCode
            }
        case .account:
            _ = await session.signOut()
        default: break
        }
    }

    private func openCodeEntry(_ kind: ConfirmationKind, startCooldown: Bool = false, preserveMessage: Bool = false) {
        focusedField = nil
        validationMessage = nil
        draft.emailCode = ""
        confirmationKind = kind
        if startCooldown { resendAvailableAt[resendKey] = Date().addingTimeInterval(60) }
        if !preserveMessage { session.clearMessages() }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { step = .checkEmail }
    }

    private var resendKey: String {
        "\(confirmationKind == .signup ? "signup" : "recovery"):\(draft.email.lowercased())"
    }

    private func resendCooldown(at date: Date) -> Int {
        max(0, Int(ceil((resendAvailableAt[resendKey] ?? .distantPast).timeIntervalSince(date))))
    }

    private func sendRecoveryCode() async {
        guard !isBusy, validateEmail() else { return }
        focusedField = nil
        if await session.resetPassword(email: draft.email) {
            openCodeEntry(.passwordReset, startCooldown: true, preserveMessage: true)
        }
    }

    private func resendCode() async {
        guard !isBusy, resendCooldown(at: .now) == 0, validateEmail() else { return }
        validationMessage = nil
        draft.emailCode = ""
        resendAvailableAt[resendKey] = Date().addingTimeInterval(60)
        if confirmationKind == .signup {
            _ = await session.resendSignupConfirmation(email: draft.email)
        } else {
            _ = await session.resetPassword(email: draft.email)
        }
    }

    private func validateEmailCode() -> Bool {
        let code = draft.emailCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (6...10).contains(code.utf8.count), code.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else {
            validationMessage = "Enter the full numeric code from your email."
            return false
        }
        draft.emailCode = code
        return true
    }

    private func validateEmail() -> Bool {
        let email = draft.email.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty,
              !email.contains(where: \.isWhitespace) else {
            validationMessage = "Enter a valid email address."
            return false
        }
        draft.email = email
        return true
    }

    private func validatePassword() -> Bool {
        guard draft.password.count >= 8 else {
            validationMessage = "Use at least 8 characters for your password."
            return false
        }
        return true
    }

    private func validateFirstName() -> Bool {
        let name = draft.firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...80).contains(name.unicodeScalars.count), name.rangeOfCharacter(from: .controlCharacters) == nil else {
            validationMessage = "Enter a first name with 1–80 characters."
            return false
        }
        draft.firstName = name
        return true
    }

    private func validateUsername() -> Bool {
        let username = draft.username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard username.range(of: "^[a-z0-9_]{3,30}$", options: .regularExpression) != nil else {
            validationMessage = "Use 3–30 letters, numbers, or underscores."
            return false
        }
        draft.username = username
        return true
    }
}

private enum AccountTypography {
    static func body(_ size: CGFloat = 16) -> Font {
        .custom("PlusJakartaSans-Regular", size: size, relativeTo: .body)
    }
}

private struct AccountWelcomePresentation: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 36) {
            Text("A READING LIFE")
                .font(AccountTypography.body(11))
                .tracking(3)
                .foregroundStyle(Color.ghost)
                .padding(.top, 42)
            Text("TEXTUAL")
                .font(.custom("CormorantGaramond-Regular", size: 76, relativeTo: .largeTitle))
                .tracking(1)
                .foregroundStyle(Color.paper)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .accessibilityAddTraits(.isHeader)
            Rectangle()
                .fill(Color.bloodletter)
                .frame(width: 46, height: 3)
                .accessibilityHidden(true)
            Text("where reading\nbecomes ritual")
                .font(.custom("CormorantGaramond-Regular", size: 38, relativeTo: .title))
                .foregroundStyle(Color.paper.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 48)
    }
}

private struct AccountQuestionHeading: View {
    let title: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title)
                .font(.custom("CormorantGaramond-Regular", size: 46, relativeTo: .largeTitle))
                .foregroundStyle(Color.paper)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(detail)
                .font(AccountTypography.body(15))
                .foregroundStyle(Color.ghost)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 18)
    }
}

private struct AccountCodeHeading: View {
    let email: String
    let isRecovery: Bool
    var body: some View {
        AccountQuestionHeading(title: "Check your email.", detail: isRecovery
                               ? "Enter the recovery code for \(email)."
                               : "Enter the confirmation code for \(email).")
    }
}

private struct AccountFieldFrame<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(label)
                .font(AccountTypography.body(10))
                .tracking(1.5)
                .foregroundStyle(Color.ghost)
            content
                .font(AccountTypography.body(21))
                .foregroundStyle(Color.paper)
                .tint(.paper)
                .frame(minHeight: 44)
            Rectangle()
                .fill(Color.paper.opacity(0.4))
                .frame(height: 1)
                .accessibilityHidden(true)
        }
    }
}

private struct AccountPrimaryButton: View {
    let title: String
    let isWorking: Bool
    var identifier = "auth.next"
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(isWorking ? "\(title)…" : title)
                .font(.custom("PlusJakartaSans-Medium", size: 16, relativeTo: .body))
                .multilineTextAlignment(.center)
            .foregroundStyle(Color.inkwell)
            .padding(.horizontal, 22)
            .padding(.vertical, 19)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(Color.paper, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}

private struct AccountSecondaryButton: View {
    let title: String
    var identifier = "welcome.createAccount"
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.custom("PlusJakartaSans-Medium", size: 16, relativeTo: .body))
                .foregroundStyle(Color.paper)
                .padding(.vertical, 19)
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(Color.velvet.opacity(0.35), in: Capsule())
                .overlay(Capsule().stroke(Color.paper.opacity(0.2), lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}

private extension View {
    func accountActionArea() -> some View {
        self
            .frame(maxWidth: 480)
            .padding(.horizontal, 28)
            .padding(.top, 16)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity)
            .background(Color.inkwell)
    }
}

#Preview("Welcome") {
    ZStack {
        Color.inkwell.ignoresSafeArea()
        VStack(alignment: .leading) {
            AccountWelcomePresentation().padding(28)
            Spacer()
            VStack(spacing: 12) {
                AccountPrimaryButton(title: "Sign In", isWorking: false, action: {})
                AccountSecondaryButton(title: "Create Account", action: {})
            }.accountActionArea()
        }
    }
    .environment(\.colorScheme, .dark)
}

#Preview("Email question") {
    ZStack {
        Color.inkwell.ignoresSafeArea()
        VStack(alignment: .leading, spacing: 32) {
            AccountQuestionHeading(title: "What’s your email?", detail: "Your library starts here.")
            AccountFieldFrame(label: "EMAIL ADDRESS") {
                TextField("you@example.com", text: .constant(""))
            }
            Spacer()
            AccountPrimaryButton(title: "Continue", isWorking: false, action: {})
        }
        .padding(28)
        .padding(.top, 76)
    }
    .environment(\.colorScheme, .dark)
}

#Preview("Email code") {
    ZStack {
        Color.inkwell.ignoresSafeArea()
        VStack(alignment: .leading, spacing: 28) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    AccountCodeHeading(email: "reader@example.com", isRecovery: false)
                    AccountFieldFrame(label: "EMAIL CODE") {
                        TextField("Your code", text: .constant(""))
                            .textContentType(.oneTimeCode)
                            .keyboardType(.numberPad)
                    }
                    Text("You can read the email on any device. Enter its code here.")
                        .font(AccountTypography.body(14))
                        .foregroundStyle(Color.ghost)
                    AccountSecondaryButton(title: "Resend Code", action: {})
                }
                .padding(28)
                .padding(.top, 42)
            }
            AccountPrimaryButton(title: "Confirm Email", isWorking: false, action: {})
                .accountActionArea()
        }
    }
    .environment(\.colorScheme, .dark)
}
