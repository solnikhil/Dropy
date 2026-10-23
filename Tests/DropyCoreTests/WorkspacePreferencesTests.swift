import XCTest
import DropyCore

final class WorkspacePreferencesTests: XCTestCase {
    private func window(_ id: UInt32, app: String = "notes", launch: TimeInterval = 1) -> WindowIdentity {
        WindowIdentity(processID: 42, processLaunchDate: Date(timeIntervalSince1970: launch), windowID: id, bundleIdentifier: app)
    }

    func testLegacyPinMigratesWithoutLosingOpeningChoice() throws {
        let old = Data(#"{"pinnedBundleIdentifier":"notes","sizePreset":"wide","openBehavior":"lastUsed"}"#.utf8)
        let preferences = try JSONDecoder().decode(DropyPreferences.self, from: old)
        XCTAssertEqual(preferences.favoriteApps.map(\.id), ["notes"])
        XCTAssertEqual(preferences.openTargetBundleIdentifier, "notes")
        XCTAssertEqual(preferences.sizePreset, .wide)
        XCTAssertFalse(preferences.favoriteShortcutsEnabled)
        XCTAssertTrue(preferences.rememberedWindows.isEmpty)
        XCTAssertEqual(try JSONDecoder().decode(DropyPreferences.self, from: JSONEncoder().encode(preferences)), preferences)
    }

    func testFavoriteCollectionKeepsOrderAndRemovesDefaultExplicitly() {
        var preferences = DropyPreferences()
        preferences.addFavorite("notes")
        preferences.addFavorite("browser")
        preferences.addFavorite("notes")
        XCTAssertEqual(preferences.favoriteApps.map(\.id), ["notes", "browser"])
        XCTAssertEqual(preferences.openTargetBundleIdentifier, "notes")
        preferences.removeFavorite("notes")
        XCTAssertEqual(preferences.favoriteApps.map(\.id), ["browser"])
        XCTAssertNil(preferences.openTargetBundleIdentifier, "Removing a default must not silently open another app")
        preferences.addFavorite("browser")
        XCTAssertEqual(preferences.favoriteApps.map(\.id), ["browser"])
    }

    func testPerAppPresentationDoesNotChangeGlobalDefaults() throws {
        let preferences = DropyPreferences(sizePreset: .compact, favorites: [
            FavoriteApp(bundleIdentifier: "notes", sizePreset: .wide, position: .left),
            FavoriteApp(bundleIdentifier: "browser")
        ])
        XCTAssertEqual(preferences.presentation(for: "notes").sizePreset, .wide)
        XCTAssertEqual(preferences.presentation(for: "notes").position, .left)
        XCTAssertEqual(preferences.presentation(for: "browser").sizePreset, .compact)
        XCTAssertEqual(preferences.presentation(for: "missing").position, .notch)
        XCTAssertEqual(preferences.sizePreset, .compact)
        XCTAssertEqual(try JSONDecoder().decode(DropyPreferences.self, from: JSONEncoder().encode(preferences)), preferences)
    }

    func testWindowMemoryNeverFallsBackToAnotherDocumentOrProcessIncarnation() {
        let original = window(1), other = window(2), reused = window(1, launch: 2)
        XCTAssertEqual(WindowSelection.resolve(bundleIdentifier: "notes", remembered: original,
                                               candidates: [other, original]), .selected(original))
        XCTAssertEqual(WindowSelection.resolve(bundleIdentifier: "notes", remembered: original,
                                               candidates: [other]), .chooseWindow)
        XCTAssertEqual(WindowSelection.resolve(bundleIdentifier: "notes", remembered: original,
                                               candidates: [reused]), .chooseWindow)
        XCTAssertEqual(WindowSelection.resolve(bundleIdentifier: "notes", remembered: nil,
                                               candidates: [original, other]), .chooseWindow)
        XCTAssertEqual(WindowSelection.resolve(bundleIdentifier: "notes", remembered: nil,
                                               candidates: [window(3, app: "browser")]), .noWindows)
        XCTAssertEqual(WindowSelection.resolve(bundleIdentifier: "notes", remembered: nil,
                                               candidates: [original]), .selected(original))
    }

    func testMissingAppWindowsReportUnavailableDespiteRememberedSelection() {
        let remembered = window(1)
        XCTAssertEqual(WindowSelection.resolve(bundleIdentifier: "notes", remembered: remembered,
                                               candidates: []), .noWindows)
        XCTAssertEqual(WindowSelection.resolve(bundleIdentifier: "notes", remembered: remembered,
                                               candidates: [window(2, app: "browser")]), .noWindows)
        XCTAssertEqual(WindowSelection.resolve(bundleIdentifier: "notes", remembered: nil,
                                               candidates: []), .noWindows)
    }

    func testMemoryIsBoundedAndContainsOneRecentWindowPerApp() throws {
        var preferences = DropyPreferences()
        preferences.rememberWindow(window(1))
        preferences.rememberWindow(window(2))
        XCTAssertEqual(preferences.rememberedWindows.count, 1)
        XCTAssertEqual(preferences.rememberedWindow(for: "notes"), window(2))
        for index in 0..<40 { preferences.rememberWindow(window(UInt32(index), app: "app.\(index)")) }
        XCTAssertEqual(preferences.rememberedWindows.count, 30)
        XCTAssertNil(preferences.rememberedWindow(for: "notes"))
        XCTAssertEqual(preferences.lastUsedBundleIdentifier, "app.39")
        XCTAssertEqual(try JSONDecoder().decode(DropyPreferences.self, from: JSONEncoder().encode(preferences)), preferences)
    }

    func testSearchUsesAllWordsAndSharesStableFavoriteRecentOrder() {
        let a = window(1), b = window(2, app: "browser"), c = window(3, app: "editor")
        let items = [WindowSearchItem(identity: a, applicationName: "Notes", title: "Café Plan"),
                     WindowSearchItem(identity: b, applicationName: "Browser", title: "Plan"),
                     WindowSearchItem(identity: c, applicationName: "Editor", title: "Draft")]
        XCTAssertEqual(WorkspaceSearch.results(items, query: "", favorites: ["browser"], recents: [c]), [b, c, a])
        XCTAssertEqual(WorkspaceSearch.results(items, query: "  NOTES cafe ", favorites: [], recents: []), [a])
        XCTAssertEqual(WorkspaceSearch.results(items, query: "plan", favorites: ["browser"], recents: [a]), [b, a])
        XCTAssertTrue(WorkspaceSearch.results(items, query: "missing", favorites: [], recents: []).isEmpty)
        XCTAssertEqual(WorkspaceSearch.results(items, query: " ", favorites: [], recents: []), [a, b, c])
    }

    func testDisplayContractIncludesScaleAndRefreshRate() {
        let frame = CGRect(x: 0, y: 0, width: 1500, height: 1000)
        let retina = DisplayConfiguration(id: 1, frame: frame, visibleFrame: frame, scale: 2, refreshRate: 120)
        let lowDPI = DisplayConfiguration(id: 1, frame: frame, visibleFrame: frame, scale: 1, refreshRate: 120)
        let slow = DisplayConfiguration(id: 1, frame: frame, visibleFrame: frame, scale: 2, refreshRate: 60)
        XCTAssertFalse(retina == lowDPI)
        XCTAssertFalse(retina == slow)
    }
    func testSourceReturnRetainsOriginalHiddenAndMinimizedState() {
        let original = WindowPlacementState(frame: CGRect(x: 40, y: 60, width: 600, height: 400),
                                            isMinimized: true, isAppHidden: true)
        let shown = WindowPlacementState(frame: CGRect(x: 400, y: 40, width: 400, height: 300),
                                         isMinimized: false, isAppHidden: false)
        let entry = PlacementEntry(identity: window(1), mode: .docked, original: original,
                                   applied: shown, createdAt: Date(), applicationConfirmed: true)
        let plan = RestorePlan.make(for: entry, read: .state(shown),
                                    displays: [CGRect(x: 0, y: 0, width: 1500, height: 1000)])
        XCTAssertEqual(plan, .restore(.restore(original), unhide: false, unminimize: false,
                                      frame: original.frame, resize: true))
        // A person moving the window still wins over our original frame/flags.
        var moved = shown
        moved.frame.origin.x += 100
        XCTAssertEqual(RestorePlan.make(for: entry, read: .state(moved),
                                        displays: [CGRect(x: 0, y: 0, width: 1500, height: 1000)]),
                       .settle(.keepUserChange))
    }

}
