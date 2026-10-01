import XCTest
import DropyCore

final class ReleasePolicyTests: XCTestCase {
    private func version(_ marketing: String, _ build: String) -> ReleaseVersion {
        guard case .success(let resolved) = ReleaseVersion.resolve(file: marketing, tag: nil, build: build) else {
            XCTFail("\(marketing)@\(build) should resolve")
            return ReleaseVersion(marketing: marketing, build: build, release: marketing, prerelease: nil)
        }
        return resolved
    }

    private func resolved(file: String?, tag: String?, build: String? = nil) -> ReleaseVersion? {
        guard case .success(let value) = ReleaseVersion.resolve(file: file, tag: tag, build: build) else { return nil }
        return value
    }

    private func problem(file: String?, tag: String?, build: String? = nil) -> ReleaseVersionProblem? {
        guard case .failure(let value) = ReleaseVersion.resolve(file: file, tag: tag, build: build) else { return nil }
        return value
    }

    // MARK: Version resolution

    func testVersionComesFromTheFileOrTheTag() {
        XCTAssertEqual(resolved(file: "1.2.3", tag: nil)?.marketing, "1.2.3")
        XCTAssertEqual(resolved(file: nil, tag: "v1.2.3")?.marketing, "1.2.3")
        // A trailing newline is what reading a VERSION file gives.
        XCTAssertEqual(resolved(file: "0.4.0\n", tag: nil)?.marketing, "0.4.0")
        // Both sources, agreeing.
        XCTAssertEqual(resolved(file: "1.2.3", tag: "v1.2.3")?.marketing, "1.2.3")
    }

    func testTagAndFileMustAgree() {
        XCTAssertEqual(problem(file: "1.2.3", tag: "v1.2.4"),
                       .tagDisagreesWithFile(tag: "v1.2.4", file: "1.2.3"))
        XCTAssertEqual(problem(file: "1.2.3", tag: "v1.2.3-rc.1", build: "9"),
                       .tagDisagreesWithFile(tag: "v1.2.3-rc.1", file: "1.2.3"))
    }

    func testNoVersionSourceIsRefused() {
        XCTAssertEqual(problem(file: nil, tag: nil), .noSource)
        XCTAssertEqual(problem(file: "  \n", tag: "-"), .noSource)
    }

    func testMalformedVersionsAreRefused() {
        for bad in ["1.2", "1.2.3.4", "1.02.3", "v1.2.3", "1.2.z", "1.2.3-", "1.2.3-rc..1",
                    "1.2.3 4", "1.2.3+build", "1.2.3-rc.01", "123456.0.0"] {
            XCTAssertEqual(problem(file: bad, tag: nil), .malformedVersion(bad), "\(bad) should be refused")
        }
    }

    func testTagMustCarryTheVPrefix() {
        XCTAssertEqual(problem(file: nil, tag: "1.2.3"), .malformedTag("1.2.3"))
        XCTAssertEqual(problem(file: nil, tag: "version-1.2.3"), .malformedTag("version-1.2.3"))
        XCTAssertEqual(problem(file: nil, tag: "v1.2"), .malformedTag("v1.2"))
    }

    func testPrereleaseIsParsedAndOrdered() {
        let candidate = resolved(file: "1.2.0-rc.1", tag: nil, build: "184")
        XCTAssertEqual(candidate?.marketing, "1.2.0-rc.1")
        XCTAssertEqual(candidate?.release, "1.2.0")
        XCTAssertEqual(candidate?.prerelease, "rc.1")
        XCTAssertTrue(candidate?.isPrerelease == true)
        XCTAssertFalse(version("1.2.0", "184").isPrerelease)
        XCTAssertEqual(ReleaseVersion.compare(version("1.2.0-rc.1", "1"), version("1.2.0", "2")), .orderedAscending)
        XCTAssertEqual(ReleaseVersion.compare(version("1.2.0-rc.1", "1"), version("1.2.0-rc.2", "2")), .orderedAscending)
        XCTAssertEqual(ReleaseVersion.compare(version("1.2.0-beta", "1"), version("1.2.0-rc", "2")), .orderedAscending)
        XCTAssertEqual(ReleaseVersion.compare(version("1.2.0-rc.1", "1"), version("1.2.0-rc.1.1", "2")), .orderedAscending)
        XCTAssertEqual(ReleaseVersion.compare(version("1.10.0", "1"), version("1.9.0", "2")), .orderedDescending)
        XCTAssertEqual(ReleaseVersion.compare(version("1.2.3", "1"), version("1.2.3", "9")), .orderedSame)
    }

    func testBundleVersionDefaultsToTheReleaseTripleAndAPrereleaseNeedsItsOwn() {
        XCTAssertEqual(resolved(file: "1.2.3", tag: nil)?.build, "1.2.3")
        XCTAssertEqual(resolved(file: "1.2.3", tag: nil, build: "184")?.build, "184")
        // Without its own build number an rc and its final release are indistinguishable
        // to macOS and to any update feed.
        XCTAssertEqual(problem(file: "1.2.3-rc.1", tag: nil), .buildRequiredForPrerelease("1.2.3-rc.1"))
        XCTAssertEqual(resolved(file: "1.2.3-rc.1", tag: nil, build: "184")?.build, "184")
    }

    func testMalformedBuildNumbersAreRefused() {
        for bad in ["0", "0.0.0", "1.2.3.4", "01", "1.x", "-1", "1 2", ""] {
            XCTAssertFalse(ReleaseVersion.isValidBuild(bad), "\(bad) should be refused")
        }
        for good in ["1", "184", "1.2.3", "0.0.1", "99999"] {
            XCTAssertTrue(ReleaseVersion.isValidBuild(good), "\(good) should be accepted")
        }
        XCTAssertEqual(problem(file: "1.2.3", tag: nil, build: "01"), .malformedBuild("01"))
    }

    func testBuildNumbersOrderNumerically() {
        XCTAssertEqual(ReleaseVersion.compareBuilds("9", "10"), .orderedAscending)
        XCTAssertEqual(ReleaseVersion.compareBuilds("1.10", "1.9"), .orderedDescending)
        XCTAssertEqual(ReleaseVersion.compareBuilds("1.2", "1.2.0"), .orderedSame)
    }

    // MARK: Signing

    func testIdentityClassification() {
        XCTAssertEqual(ReleasePolicy.classify(identity: nil), .absent)
        XCTAssertEqual(ReleasePolicy.classify(identity: "   "), .absent)
        XCTAssertEqual(ReleasePolicy.classify(identity: "-"), .adHoc)
        XCTAssertEqual(ReleasePolicy.classify(identity: "Developer ID Application: Example (AB12CD34EF)"),
                       .developerIDApplication)
        XCTAssertEqual(ReleasePolicy.classify(identity: "Apple Development: someone@example.com (AB12CD34EF)"),
                       .appleDevelopment)
        XCTAssertEqual(ReleasePolicy.classify(identity: "Mac Developer: someone@example.com (AB12CD34EF)"),
                       .appleDevelopment)
        XCTAssertEqual(ReleasePolicy.classify(identity: "Developer ID Installer: Example (AB12CD34EF)"),
                       .wrongCertificateType)
        XCTAssertEqual(ReleasePolicy.classify(identity: "Apple Distribution: Example (AB12CD34EF)"), .wrongCertificateType)
        XCTAssertEqual(ReleasePolicy.classify(identity: "3rd Party Mac Developer Application: Example"),
                       .wrongCertificateType)
        // A certificate named by hash cannot be judged against this policy, so it is not
        // a way to slip a development certificate past the rules above.
        XCTAssertEqual(ReleasePolicy.classify(identity: "0123456789ABCDEF0123456789ABCDEF01234567"), .unrecognized)
        XCTAssertEqual(ReleasePolicy.classify(identity: "Developer ID Application: Example\nApple Development: x"),
                       .unrecognized)
    }

    func testDryRunSignsAdHocAndRefusesADevelopmentIdentity() {
        XCTAssertEqual(ReleasePolicy.signing(mode: .dryRun, identity: nil), .adHoc(ignoring: nil))
        XCTAssertEqual(ReleasePolicy.signing(mode: .dryRun, identity: "-"), .adHoc(ignoring: nil))
        // A real Developer ID is deliberately not used by a rehearsal.
        XCTAssertEqual(ReleasePolicy.signing(mode: .dryRun, identity: "Developer ID Application: Example (AB12CD34EF)"),
                       .adHoc(ignoring: "Developer ID Application: Example (AB12CD34EF)"))
        // A development identity is refused even though a rehearsal would not use it:
        // the rehearsal exists to catch this before the real run.
        XCTAssertEqual(ReleasePolicy.signing(mode: .dryRun, identity: "Apple Development: someone (AB12CD34EF)"),
                       .refuse(.appleDevelopmentIdentity("Apple Development: someone (AB12CD34EF)")))
        XCTAssertEqual(ReleasePolicy.signing(mode: .dryRun, identity: "Mac Developer: someone (AB12CD34EF)"),
                       .refuse(.appleDevelopmentIdentity("Mac Developer: someone (AB12CD34EF)")))
    }

    func testReleaseSigningNeedsADeveloperIDApplicationCertificate() {
        XCTAssertEqual(ReleasePolicy.signing(mode: .release, identity: "Developer ID Application: Example (AB12CD34EF)"),
                       .developerID("Developer ID Application: Example (AB12CD34EF)"))
        XCTAssertEqual(ReleasePolicy.signing(mode: .release, identity: nil), .refuse(.missingIdentity))
        XCTAssertEqual(ReleasePolicy.signing(mode: .release, identity: "-"), .refuse(.adHocRelease))
        XCTAssertEqual(ReleasePolicy.signing(mode: .release, identity: "Apple Development: someone (AB12CD34EF)"),
                       .refuse(.appleDevelopmentIdentity("Apple Development: someone (AB12CD34EF)")))
        XCTAssertEqual(ReleasePolicy.signing(mode: .release, identity: "Apple Distribution: Example (AB12CD34EF)"),
                       .refuse(.wrongCertificateType("Apple Distribution: Example (AB12CD34EF)")))
        XCTAssertEqual(ReleasePolicy.signing(mode: .release, identity: "0123456789ABCDEF0123456789ABCDEF01234567"),
                       .refuse(.unnamedIdentity("0123456789ABCDEF0123456789ABCDEF01234567")))
    }

    func testADevelopmentIdentityIsRefusedInEveryMode() {
        for mode in ReleasePolicy.Mode.allCases {
            XCTAssertEqual(ReleasePolicy.signing(mode: mode, identity: "Apple Development: someone (AB12CD34EF)"),
                           .refuse(.appleDevelopmentIdentity("Apple Development: someone (AB12CD34EF)")),
                           "\(mode.rawValue) accepted a development identity")
        }
    }

    // MARK: Notarization

    func testNotarization() {
        XCTAssertEqual(ReleasePolicy.notarization(mode: .dryRun, keychainProfile: nil), .skip(reason: "dry run"))
        // A rehearsal submits nothing even when it could.
        guard case .skip(let reason) = ReleasePolicy.notarization(mode: .dryRun, keychainProfile: "dropy-notary") else {
            return XCTFail("a dry run must not submit")
        }
        XCTAssertTrue(reason.contains("nothing is submitted"))
        XCTAssertEqual(ReleasePolicy.notarization(mode: .release, keychainProfile: "dropy-notary"),
                       .submit(profile: "dropy-notary"))
        XCTAssertEqual(ReleasePolicy.notarization(mode: .release, keychainProfile: nil), .refuse(.missingProfile))
        XCTAssertEqual(ReleasePolicy.notarization(mode: .release, keychainProfile: "  "), .refuse(.missingProfile))
        XCTAssertEqual(ReleasePolicy.notarization(mode: .release, keychainProfile: "a\nb"), .refuse(.malformedProfile("a\nb")))
    }

    // MARK: Source state

    func testReleaseNeedsACleanTaggedTreeAndADryRunDoesNot() {
        XCTAssertEqual(ReleasePolicy.source(mode: .release, dirty: false, tagged: true), .proceed(notes: []))
        XCTAssertEqual(ReleasePolicy.source(mode: .release, dirty: true, tagged: true), .refuse(.uncommittedChanges))
        XCTAssertEqual(ReleasePolicy.source(mode: .release, dirty: false, tagged: false), .refuse(.untaggedRelease))
        guard case .proceed(let notes) = ReleasePolicy.source(mode: .dryRun, dirty: true, tagged: false) else {
            return XCTFail("a dry run must run from a dirty untagged tree")
        }
        XCTAssertEqual(notes.count, 2)
        XCTAssertEqual(ReleasePolicy.source(mode: .dryRun, dirty: false, tagged: true), .proceed(notes: []))
    }

    // MARK: Artifacts

    func testArtifactNames() {
        let names = ReleasePolicy.artifacts(for: version("1.2.3", "184"))
        XCTAssertEqual(names.app, "Dropy.app")
        XCTAssertEqual(names.zip, "Dropy-1.2.3.zip")
        XCTAssertEqual(names.dmg, "Dropy-1.2.3.dmg")
        XCTAssertEqual(names.checksums, "SHA256SUMS")
        XCTAssertEqual(names.volumeName, "Dropy 1.2.3")
        for name in names.all {
            XCTAssertFalse(name.contains(" "), "\(name) has a space")
            XCTAssertFalse(name.contains("v1"), "\(name) carries a tag prefix")
        }
        // A long pre-release name falls back to the release triple, still a legal
        // HFS+ volume name and still unambiguous.
        let long = ReleasePolicy.artifacts(for: version("11.22.33-rc.1.abcdefghij", "9"))
        XCTAssertTrue(long.volumeName.count <= 27, "volume name \(long.volumeName) is too long")
        XCTAssertEqual(long.volumeName, "Dropy 11.22.33")
        XCTAssertEqual(long.zip, "Dropy-11.22.33-rc.1.abcdefghij.zip")
    }

    // MARK: Continuous integration

    func testCIRehearsesWithoutSecretsAndRefusesHalfOfThem() {
        guard case .dryRun = ReleasePolicy.ciPlan(certificatePresent: false, identityPresent: false,
                                                 notaryCredentialsPresent: false) else {
            return XCTFail("a checkout without secrets must rehearse")
        }
        XCTAssertEqual(ReleasePolicy.ciPlan(certificatePresent: true, identityPresent: true,
                                            notaryCredentialsPresent: true), .signAndNotarize)
        guard case .refuse(let why) = ReleasePolicy.ciPlan(certificatePresent: true, identityPresent: true,
                                                          notaryCredentialsPresent: false) else {
            return XCTFail("a half-configured release must not sign quietly")
        }
        XCTAssertTrue(why.contains("DROPY_NOTARY"))
        guard case .refuse = ReleasePolicy.ciPlan(certificatePresent: false, identityPresent: true,
                                                 notaryCredentialsPresent: true) else {
            return XCTFail("a missing certificate must not be rehearsed away")
        }
    }

    // MARK: Rollback

    func testRollbackRepublishesTheOlderVersionWithAHigherBuildNumber() {
        let bad = version("1.3.0", "210")
        let good = version("1.2.3", "184")
        guard case .success(let plan) = ReleasePolicy.rollback(withdraw: bad, to: good, targetWasNotarized: true,
                                                              targetChecksumsRecorded: true) else {
            return XCTFail("a notarized, checksummed older release is a valid rollback target")
        }
        XCTAssertEqual(plan.withdrawn, bad)
        XCTAssertEqual(plan.republish.marketing, "1.2.3")
        // Higher than the withdrawn build, or installs stay on the withdrawn version.
        XCTAssertEqual(plan.republish.build, "211")
        XCTAssertEqual(ReleaseVersion.compareBuilds(plan.republish.build, bad.build), .orderedDescending)
        // Dotted build numbers bump their last component.
        guard case .success(let dotted) = ReleasePolicy.rollback(withdraw: version("1.3.0", "1.3.0"),
                                                                to: version("1.2.3", "1.2.3"),
                                                                targetWasNotarized: true,
                                                                targetChecksumsRecorded: true) else {
            return XCTFail("a dotted build number is a valid rollback target")
        }
        XCTAssertEqual(dotted.republish.build, "1.3.1")
    }

    func testRollbackBuildCarryAndExhaustion() {
        let carry = ReleasePolicy.rollback(withdraw: version("1.3.0", "1.99999"),
                                           to: version("1.2.3", "1.0"),
                                           targetWasNotarized: true, targetChecksumsRecorded: true)
        guard case .success(let plan) = carry else { return XCTFail("carry must succeed") }
        XCTAssertEqual(plan.republish.build, "2.0")
        XCTAssertEqual(ReleasePolicy.rollback(withdraw: version("1.3.0", "99999.99999.99999"),
                                              to: version("1.2.3", "184"),
                                              targetWasNotarized: true, targetChecksumsRecorded: true),
                       .failure(.buildNumberExhausted))
    }

    func testRollbackRefusals() {
        let bad = version("1.3.0", "210")
        let good = version("1.2.3", "184")
        func refusal(_ result: Result<RollbackPlan, RollbackRefusal>) -> RollbackRefusal? {
            guard case .failure(let value) = result else { return nil }
            return value
        }
        XCTAssertEqual(refusal(ReleasePolicy.rollback(withdraw: good, to: bad, targetWasNotarized: true,
                                                     targetChecksumsRecorded: true)), .targetNotOlder)
        XCTAssertEqual(refusal(ReleasePolicy.rollback(withdraw: bad, to: bad, targetWasNotarized: true,
                                                     targetChecksumsRecorded: true)), .targetNotOlder)
        XCTAssertEqual(refusal(ReleasePolicy.rollback(withdraw: bad, to: good, targetWasNotarized: false,
                                                     targetChecksumsRecorded: true)), .targetNotNotarized)
        XCTAssertEqual(refusal(ReleasePolicy.rollback(withdraw: bad, to: good, targetWasNotarized: true,
                                                     targetChecksumsRecorded: false)), .targetChecksumsMissing)
    }

    // MARK: Bundle contents

    func testRefusedEntitlementsAreReported() {
        XCTAssertEqual(ReleasePolicy.entitlementProblems([]), [])
        let problems = ReleasePolicy.entitlementProblems(["com.apple.security.get-task-allow",
                                                          "com.apple.security.network.client"])
        XCTAssertEqual(problems.count, 2)
        XCTAssertTrue(problems[0].contains("get-task-allow"))
        XCTAssertTrue(problems[1].contains("network.client"))
        // Development signing adds get-task-allow, which is why it is listed first here.
        XCTAssertNotNil(ReleasePolicy.refusedEntitlements["com.apple.security.get-task-allow"])
        XCTAssertNotNil(ReleasePolicy.refusedEntitlements["com.apple.security.cs.disable-library-validation"])
        XCTAssertNotNil(ReleasePolicy.refusedEntitlements["com.apple.security.network.client"])
        // Nothing Dropy actually needs is on the list: capture and Accessibility are
        // permissions a person grants, not entitlements.
        XCTAssertNil(ReleasePolicy.refusedEntitlements["com.apple.security.app-sandbox"])
    }

    func testInfoPlistPolicy() {
        let target = version("1.2.3", "184")
        var values = ["CFBundleIdentifier": "org.dropy.app", "CFBundleName": "Dropy", "CFBundleExecutable": "Dropy",
                      "CFBundlePackageType": "APPL", "LSUIElement": "true", "LSMinimumSystemVersion": "15.0",
                      "NSScreenCaptureDescription": "Dropy shows windows you choose inside its temporary overlay.",
                      "CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "184"]
        XCTAssertEqual(ReleasePolicy.infoPlistProblems(values, expecting: target), [])
        XCTAssertEqual(ReleasePolicy.infoPlistProblems(values, expecting: version("1.2.3-rc.1", "184")), [])

        var wrongVersion = values
        wrongVersion["CFBundleShortVersionString"] = "1.2.2"
        XCTAssertEqual(ReleasePolicy.infoPlistProblems(wrongVersion, expecting: target).count, 1)
        wrongVersion["CFBundleVersion"] = "183"
        XCTAssertEqual(ReleasePolicy.infoPlistProblems(wrongVersion, expecting: target).count, 2)

        // A background app that became a Dock app would cover the notch differently and
        // is not what was tested.
        var foreground = values
        foreground["LSUIElement"] = "false"
        XCTAssertTrue(ReleasePolicy.infoPlistProblems(foreground, expecting: target)[0].contains("LSUIElement"))

        var oldFloor = values
        oldFloor["LSMinimumSystemVersion"] = "14.0"
        XCTAssertTrue(ReleasePolicy.infoPlistProblems(oldFloor, expecting: target)[0].contains("below the supported floor"))
        oldFloor["LSMinimumSystemVersion"] = "15.1"
        XCTAssertEqual(ReleasePolicy.infoPlistProblems(oldFloor, expecting: target), [])

        var noCapture = values
        noCapture["NSScreenCaptureDescription"] = ""
        XCTAssertTrue(ReleasePolicy.infoPlistProblems(noCapture, expecting: target)[0].contains("NSScreenCaptureDescription"))

        // A new purpose string means a new kind of personal data.
        values["NSMicrophoneUsageDescription"] = "why"
        let extra = ReleasePolicy.infoPlistProblems(values, expecting: target)
        XCTAssertEqual(extra.count, 1)
        XCTAssertTrue(extra[0].contains("NSMicrophoneUsageDescription"))
        XCTAssertTrue(extra[0].contains("privacy review"))

        var missing = values
        missing["NSMicrophoneUsageDescription"] = nil
        missing["CFBundleIdentifier"] = nil
        XCTAssertTrue(ReleasePolicy.infoPlistProblems(missing, expecting: target)[0].contains("missing"))
    }
}
