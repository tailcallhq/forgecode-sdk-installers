import Foundation

/// Debug-only escape hatch that points the supervisor at a locally built
/// `forge3` instead of the managed runtime store.
///
/// This exists so a developer can iterate on the runtime without publishing a
/// release and without hand-editing the private store (which is checksum- and
/// permission-validated, and silently re-downloaded when validation fails).
///
/// The entire mechanism is compiled out of release builds: `resolve` returns
/// `nil` unconditionally when `DEBUG` is not defined, so a shipped app cannot be
/// redirected to an arbitrary binary by setting an environment variable.
///
/// Usage (debug builds only):
///
///     FORGE_RUNTIME_BINARY=/path/to/forge3 .build/debug/ForgeMenuBar
///
/// Note that the launch-time safety checks in `RuntimePinnedExecutable` still
/// apply to the override: the binary must be a regular file owned by the current
/// user, with no hard links, no group/other write permission, the owner execute
/// bit set, and no symlink or group/other-writable directory anywhere along the
/// path below the user boundary.
public enum DeveloperRuntimeOverride {
    public static let environmentKey = "FORGE_RUNTIME_BINARY"

    /// Version reported for an overridden runtime. `0.0.0` sorts below every
    /// real release so the override is never mistaken for an upgrade.
    public static let overrideVersion = RuntimeReleaseVersion(rawValue: "0.0.0")!

    /// Resolves the developer override, if one is configured and this is a
    /// debug build.
    ///
    /// - Returns: `nil` when no override is set, or in any release build.
    /// - Throws: `ForgeCoreError.missingExecutable` when the variable is set but
    ///   does not point at an executable regular file, so a typo fails loudly
    ///   instead of silently falling back to the downloaded runtime.
    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> InstalledRuntime? {
#if DEBUG
        let raw = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw, !raw.isEmpty else { return nil }

        let url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath).standardizedFileURL
        guard url.path.hasPrefix("/") else {
            throw ForgeCoreError.missingExecutable("\(environmentKey) must be an absolute path, got \(raw)")
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              fileManager.isExecutableFile(atPath: url.path)
        else {
            throw ForgeCoreError.missingExecutable(url.path)
        }

        return InstalledRuntime(
            version: overrideVersion,
            architecture: .native,
            executableURL: url
        )
#else
        _ = environment
        _ = fileManager
        return nil
#endif
    }
}

/// Wraps a real `RuntimeInstalling` and short-circuits it when a developer
/// override is active, so no download, staging, or store validation runs.
public struct DeveloperOverrideRuntimeInstaller: RuntimeInstalling {
    private let base: any RuntimeInstalling
    private let runtime: InstalledRuntime

    public init(base: any RuntimeInstalling, runtime: InstalledRuntime) {
        self.base = base
        self.runtime = runtime
    }

    /// Builds an installer that honours `FORGE_RUNTIME_BINARY` in debug builds.
    /// Returns `base` unchanged in release builds or when no override is set.
    public static func wrapIfOverridden(
        base: any RuntimeInstalling,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        logger: AppLogger = .shared
    ) -> any RuntimeInstalling {
        do {
            guard let runtime = try DeveloperRuntimeOverride.resolve(environment: environment) else {
                return base
            }
            logger.warning(
                "Using developer runtime override from \(DeveloperRuntimeOverride.environmentKey): "
                + runtime.executableURL.path
            )
            return DeveloperOverrideRuntimeInstaller(base: base, runtime: runtime)
        } catch {
            logger.error("Ignoring \(DeveloperRuntimeOverride.environmentKey): \(error.localizedDescription)")
            return base
        }
    }

    public func installedCurrentRuntime() async throws -> InstalledRuntime? {
        runtime
    }

    public func installLatest(
        progress: @escaping @Sendable (RuntimeInstallationPhase) async -> Void
    ) async throws -> InstalledRuntime {
        await progress(.ready)
        return runtime
    }
}
