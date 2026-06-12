// `facet --resign` — re-sign the installed Facet.app with the
// persistent self-signed identity and restart the daemon (the TCC
// Accessibility grant is keyed to the code-signing identity; see
// setup-signing-cert.sh). Extracted unchanged from Main.swift (#182
// phase 1) — same-module extension, no logic change.

import AppKit
import FacetCore

extension FacetApp {

    // MARK: - --resign

    /// `facet --resign` re-signs the installed Facet.app with the
    /// persistent ``facet Local Signing`` self-signed identity and
    /// restarts the daemon. Necessary after every `brew install` /
    /// `brew upgrade facet` — Homebrew's build sandbox blocks the
    /// in-formula ``setup-signing-cert.sh`` from touching the user's
    /// login keychain, so installs fall back to ad-hoc signing and
    /// TCC re-prompts for Accessibility on every upgrade.
    ///
    /// Same pattern as chord 0.3.3 / stroke 2.3.0; mirror updates
    /// across the three repos when this changes.
    ///
    /// Exit codes:
    ///   0 — re-signed (restart attempted, best-effort)
    ///   1 — codesign failed
    ///   2 — no Facet.app found in any expected location
    ///   3 — signing identity missing (run setup-signing-cert.sh first)
    static func runResign() -> Never {
        guard let appPath = findFacetApp() else {
            let msg = "facet: no Facet.app found at "
                + "/opt/homebrew/Cellar/facet/*/, /Applications, or "
                + "~/Applications.\n"
                + "       install via "
                + "`brew install akira-toriyama/tap/facet` first.\n"
            FileHandle.standardError.write(Data(msg.utf8))
            exit(2)
        }
        print("facet: detected Facet.app at \(appPath)")

        let identity = "facet Local Signing"
        guard hasSigningIdentity(identity) else {
            let setupHint = setupCertHint()
            let msg = "facet: no '\(identity)' identity in your "
                + "login keychain.\n"
                + "       run once:\n"
                + "         \(setupHint)\n"
                + "         facet --resign\n"
            FileHandle.standardError.write(Data(msg.utf8))
            exit(3)
        }

        print("facet: signing with identity '\(identity)'")
        let codesignExit = runProcess(
            "/usr/bin/codesign",
            args: ["--force", "--sign", identity, appPath])
        guard codesignExit == 0 else {
            FileHandle.standardError.write(Data(
                "facet: codesign failed (exit \(codesignExit))\n".utf8))
            exit(1)
        }

        print("facet: restarting daemon")
        let brewExit = runProcess(
            "/opt/homebrew/bin/brew",
            args: ["services", "restart", "facet"],
            captureOutput: true)
        if brewExit == 0 {
            print("facet: restarted via `brew services restart facet`")
            exit(0)
        }
        // Only `homebrew.mxcl.facet` — facet doesn't ship an
        // in-repo LaunchAgent template, so `com.facet.app` (the
        // bundle id) wouldn't match any registered Label key.
        // Adding it as a kickstart fallback was dead code.
        let label = "homebrew.mxcl.facet"
        let kick = runProcess(
            "/bin/launchctl",
            args: ["kickstart", "-k", "gui/\(getuid())/\(label)"],
            captureOutput: true)
        if kick == 0 {
            print("facet: restarted via `launchctl kickstart \(label)`")
            exit(0)
        }
        FileHandle.standardError.write(Data((
            "facet: re-signed, but couldn't restart the daemon — "
            + "start it manually.\n"
        ).utf8))
        exit(0)
    }

    /// Pick the first existing Facet.app from the canonical install
    /// locations. The brew Cellar is preferred over manual copies.
    static func findFacetApp() -> String? {
        let cellar = "/opt/homebrew/Cellar/facet"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: cellar) {
            // `.numeric` makes "1.10.0" > "1.2.0" — a plain string
            // sort would silently pick the older 1.2.0 as "latest"
            // once a 1.10 series ships.
            let sorted = versions.sorted { a, b in
                a.compare(b, options: .numeric) == .orderedDescending
            }
            for v in sorted {
                let p = "\(cellar)/\(v)/Facet.app"
                if FileManager.default.fileExists(atPath: p) { return p }
            }
        }
        for candidate in [
            "/Applications/Facet.app",
            "\(NSHomeDirectory())/Applications/Facet.app",
        ] {
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Untrusted self-signed certs don't appear in `find-identity`
    /// (that filter lists trusted identities only). Use
    /// `find-certificate` which surfaces untrusted entries too.
    static func hasSigningIdentity(_ name: String) -> Bool {
        runProcess(
            "/usr/bin/security",
            args: ["find-certificate", "-c", name,
                   "\(NSHomeDirectory())/Library/Keychains/login.keychain-db"],
            captureOutput: true
        ) == 0
    }

    /// Best-effort guess at where `setup-signing-cert.sh` lives on
    /// the user's machine. brew installs ship it under
    /// `share/facet/`, dev installs have it at the repo root.
    static func setupCertHint() -> String {
        let brewShared = "/opt/homebrew/share/facet/setup-signing-cert.sh"
        if FileManager.default.fileExists(atPath: brewShared) {
            return brewShared
        }
        return "./setup-signing-cert.sh"
    }

    /// Spawn + wait. Returns the child's exit code on completion,
    /// or `-1` when `Process.run()` itself failed (executable not
    /// found, permission denied, etc.) — the catch path also emits
    /// a stderr line so the caller's generic "exit -1" message
    /// isn't the only signal.
    @discardableResult
    static func runProcess(_ executable: String,
                           args: [String],
                           captureOutput: Bool = false) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        if captureOutput {
            p.standardOutput = FileHandle.nullDevice
            p.standardError  = FileHandle.nullDevice
        }
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus
        } catch {
            FileHandle.standardError.write(Data(
                "facet: couldn't launch \(executable): \(error)\n".utf8))
            return -1
        }
    }
}
