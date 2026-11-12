import ColorSync
import CoreGraphics
import Foundation
import simd

/// Puts a monitor's colour calibration into an ICC profile and makes that the display's
/// profile, so the correction holds without NitSync running, in every app, in SDR and HDR.
///
/// - The profile is a copy of the display's factory profile (never of whatever is active, so
///   corrections don't stack) with a new name and a `vcgt` table, which the system loads into
///   the display's gamma table whenever the profile is in use.
/// - It is set as the display's custom profile at the current-user level, where System
///   Settings keeps its choice too. (The any-user level needs admin rights; writes to it
///   report success and do nothing.) The entry that was there first is recorded and written
///   back on removal; clearing the entry instead would also drop that original choice.
/// - Every install writes a new file name, so nothing can serve a cached older version.
enum DisplayProfiles {
    static let folder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/ColorSync/Profiles/NitSync")

    private static let displayClass = kColorSyncDisplayDeviceClass.takeUnretainedValue()
    private static let originalsKey = "originalDisplayProfiles"

    private static func uuid(_ id: CGDirectDisplayID) -> CFUUID? {
        CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue()
    }

    private static func info(_ id: CGDirectDisplayID) -> [String: Any]? {
        guard let uuid = uuid(id) else { return nil }
        return ColorSyncDeviceCopyDeviceInfo(displayClass, uuid)?.takeRetainedValue() as? [String: Any]
    }

    /// The factory profile's ID (the custom-profile slot to use) and file.
    private static func factory(_ id: CGDirectDisplayID) -> (profileID: String, url: URL)? {
        guard let factory = info(id)?["FactoryProfiles"] as? [String: Any] else { return nil }
        let profileID = factory["DeviceDefaultProfileID"].map { "\($0)" } ?? "1"
        guard let entry = factory[profileID] as? [String: Any], let url = entry["DeviceProfileURL"] as? URL else { return nil }
        return (profileID, url)
    }

    static func factoryProfileData(_ id: CGDirectDisplayID) -> Data? {
        factory(id).flatMap { try? Data(contentsOf: $0.url) }
    }

    /// The display's current custom profile, if any.
    static func customProfile(_ id: CGDirectDisplayID) -> URL? {
        guard let profileID = factory(id)?.profileID,
              let custom = info(id)?["CustomProfiles"] as? [String: Any] else { return nil }
        return custom[profileID] as? URL
    }

    /// Whether the display currently uses a profile NitSync wrote.
    static func isInstalled(_ id: CGDirectDisplayID) -> Bool {
        customProfile(id).map { $0.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL } ?? false
    }

    private static func setCustom(_ value: Any, profileID: String, on id: CGDirectDisplayID) -> Bool {
        guard let uuid = uuid(id) else { return false }
        let scope = kColorSyncProfileUserScope.takeUnretainedValue() as String
        return ColorSyncDeviceSetCustomProfiles(displayClass, uuid, [profileID: value, scope: kCFPreferencesCurrentUser as String] as CFDictionary)
    }

    /// Builds the profile from the factory one: renamed, with `table` (if any) as its `vcgt`
    /// and `colourants` (if any) as its primaries.
    static func makeProfile(for id: CGDirectDisplayID, name: String,
                            table: (r: [Float], g: [Float], b: [Float])?, colourants: double3x3?) -> Data? {
        guard let base = factoryProfileData(id),
              let withPrimaries = colourants.map({ PrimaryMath.profile(base, colourants: $0) }) ?? base,
              var profile = ICCProfile(withPrimaries) else { return nil }
        profile.setTag("desc", ICCProfile.descTag(name))
        // Apple's localised name, which System Settings shows.
        if profile.tag("dscm") != nil { profile.setTag("dscm", ICCProfile.mlucTag(name)) }
        if let table { profile.setTag("vcgt", ICCProfile.vcgtTag(r: table.r, g: table.g, b: table.b)) }
        return profile.data
    }

    /// Writes `profile` and makes it the display's profile. `key` names the files and the
    /// record of what to restore.
    @discardableResult
    static func install(_ profile: Data, key: String, on id: CGDirectDisplayID) -> Bool {
        guard let slot = factory(id)?.profileID else { return false }
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)

        // What the user has chosen, unless it's NitSync's own (a path, or "" for nothing). Taken
        // on every install, not just the first: the user may have picked another profile in
        // System Settings since, and that is the choice to give back on removal.
        let previous = isInstalled(id) ? nil : customProfile(id)?.path ?? ""

        // Milliseconds, so two installs in quick succession still get different names.
        let url = folder.appendingPathComponent("\(fileStem(key))-\(Int(Date().timeIntervalSince1970 * 1000)).icc")
        guard (try? profile.write(to: url)) != nil else { return false }
        guard setCustom(url as CFURL, profileID: slot, on: id) else {
            try? fm.removeItem(at: url)
            return false
        }
        // Recorded only once installed: a record means "NitSync's profile went in", which
        // `installMissingProfiles` reads as "installed before; if it's gone, the user chose so".
        if let previous {
            var originals = UserDefaults.standard.dictionary(forKey: originalsKey) as? [String: String] ?? [:]
            originals[key] = previous
            UserDefaults.standard.set(originals, forKey: originalsKey)
        }
        deleteFiles(of: key, except: url)
        return true
    }

    /// Makes the system load the display's profile again (switching to the factory profile
    /// and back), which also rebuilds the gamma table it falls back to. Restoring ColorSync
    /// settings alone did not help when that fallback had become all zeros.
    static func reload(_ id: CGDirectDisplayID) {
        guard let (slot, factoryURL) = factory(id) else { return }
        let current = customProfile(id)
        _ = setCustom(factoryURL as CFURL, profileID: slot, on: id)
        _ = setCustom((current ?? factoryURL) as CFURL, profileID: slot, on: id)
        if current == nil { _ = setCustom(kCFNull!, profileID: slot, on: id) }
    }

    /// Puts back the profile entry that was there before NitSync's, and deletes its files.
    /// Needs the display: without it the entry can't be reached, so the record and files stay
    /// (deleting them would leave the display pointing at a missing file with nothing to
    /// restore). Returns whether it was done.
    @discardableResult
    static func remove(key: String, on id: CGDirectDisplayID?) -> Bool {
        guard let id, let slot = factory(id)?.profileID else { return false }
        var originals = UserDefaults.standard.dictionary(forKey: originalsKey) as? [String: String] ?? [:]
        if isInstalled(id) {
            let original = originals[key] ?? ""
            let restored = original.isEmpty || !FileManager.default.fileExists(atPath: original)
                ? setCustom(kCFNull!, profileID: slot, on: id)
                : setCustom(URL(fileURLWithPath: original) as CFURL, profileID: slot, on: id)
            guard restored else { return false }
        }
        originals[key] = nil
        UserDefaults.standard.set(originals, forKey: originalsKey)
        deleteFiles(of: key, except: nil)
        return true
    }

    private static func fileStem(_ key: String) -> String {
        key.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }.reduce("") { $0 + String($1) }
    }

    /// This key's files: "<stem>-<digits>.icc". Matching the digits too keeps a monitor whose
    /// key is a prefix of another's (same model, one without a serial) off the other's files.
    private static func deleteFiles(of key: String, except keep: URL?) {
        let stem = fileStem(key) + "-"
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.standardizedFileURL != keep?.standardizedFileURL {
            let name = file.lastPathComponent
            guard name.hasPrefix(stem), name.hasSuffix(".icc") else { continue }
            let stamp = name.dropFirst(stem.count).dropLast(4)
            guard !stamp.isEmpty, stamp.allSatisfy(\.isNumber) else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }
}
