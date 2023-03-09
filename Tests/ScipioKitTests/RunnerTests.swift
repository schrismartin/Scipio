import Foundation
import XCTest
@testable import ScipioKit
import Logging

private let fixturePath = URL(fileURLWithPath: #file)
    .deletingLastPathComponent()
    .appendingPathComponent("Resources")
    .appendingPathComponent("Fixtures")
private let testPackagePath = fixturePath.appendingPathComponent("E2ETestPackage")
private let binaryPackagePath = fixturePath.appendingPathComponent("BinaryPackage")
private let resourcePackagePath = fixturePath.appendingPathComponent("ResourcePackage")
private let usingBinaryPackagePath = fixturePath.appendingPathComponent("UsingBinaryPackage")
private let clangPackagePath = fixturePath.appendingPathComponent("ClangPackage")
private let clangPackageWithCustomModuleMapPath = fixturePath.appendingPathComponent("ClangPackageWithCustomModuleMap")

final class RunnerTests: XCTestCase {
    private let fileManager: FileManager = .default
    lazy var tempDir = fileManager.temporaryDirectory
    lazy var frameworkOutputDir = tempDir.appendingPathComponent("XCFrameworks")

    override class func setUp() {
        LoggingSystem.bootstrap { _ in SwiftLogNoOpLogHandler() }

        super.setUp()
    }

    override func setUpWithError() throws {
        try fileManager.createDirectory(at: frameworkOutputDir, withIntermediateDirectories: true)

        try super.setUpWithError()
    }

    func testBuildXCFramework() async throws {
        let runner = Runner(
            mode: .prepareDependencies,
            options: .init(
                baseBuildOptions: .init(isSimulatorSupported: false)
            )
        )
        do {
            try await runner.run(packageDirectory: testPackagePath,
                                 frameworkOutputDir: .custom(frameworkOutputDir))
        } catch {
            XCTFail("Build should be succeeded. \(error.localizedDescription)")
        }

        for library in ["ScipioTesting"] {
            let xcFramework = frameworkOutputDir.appendingPathComponent("\(library).xcframework")
            let simulatorFramework = xcFramework.appendingPathComponent("ios-arm64_x86_64-simulator/\(library).framework")
            let deviceFramework = xcFramework.appendingPathComponent("ios-arm64/\(library).framework")

            XCTAssertTrue(
                fileManager.fileExists(atPath: deviceFramework.appendingPathComponent("Headers/\(library)-Swift.h").path),
                "Should exist a bridging header"
            )

            XCTAssertTrue(
                fileManager.fileExists(atPath: deviceFramework.appendingPathComponent("Modules/module.modulemap").path),
                "Should exist a modulemap"
            )

            let expectedSwiftInterface = deviceFramework.appendingPathComponent("Modules/\(library).swiftmodule/arm64-apple-ios.swiftinterface")
            XCTAssertTrue(
                fileManager.fileExists(atPath: expectedSwiftInterface.path),
                "Should exist a swiftinterface"
            )

            let frameworkType = try await detectFrameworkType(of: deviceFramework.appendingPathComponent(library))
            XCTAssertEqual(
                frameworkType,
                .dynamic,
                "Binary should be a dynamic library"
            )

            XCTAssertFalse(fileManager.fileExists(atPath: simulatorFramework.path),
                           "Should not create Simulator framework")
        }
    }

    func testBuildClangPackage() async throws {
        let runner = Runner(
            mode: .createPackage,
            options: .init(
                baseBuildOptions: .init(isSimulatorSupported: false)
            )
        )
        do {
            try await runner.run(packageDirectory: clangPackagePath,
                                 frameworkOutputDir: .custom(frameworkOutputDir))
        } catch {
            XCTFail("Build should be succeeded. \(error.localizedDescription)")
        }

        for library in ["some_lib"] {
            let xcFramework = frameworkOutputDir.appendingPathComponent("\(library).xcframework")
            let versionFile = frameworkOutputDir.appendingPathComponent(".\(library).version")
            let framework = xcFramework.appendingPathComponent("ios-arm64")
                .appendingPathComponent("\(library).framework")

            XCTAssertTrue(
                fileManager.fileExists(atPath: framework.appendingPathComponent("Headers/some_lib.h").path),
                "Should exist an umbrella header"
            )

            let moduleMapPath = framework.appendingPathComponent("Modules/module.modulemap").path
            XCTAssertTrue(
                fileManager.fileExists(atPath: moduleMapPath),
                "Should exist a modulemap"
            )
            let moduleMapContents = try XCTUnwrap(fileManager.contents(atPath: moduleMapPath).flatMap { String(data: $0, encoding: .utf8) })
            XCTAssertEqual(
                moduleMapContents,
                """
                framework module some_lib {
                    umbrella header "some_lib.h"
                    export *
                }
                """,
                "modulemap should be generated"
            )

            XCTAssertTrue(fileManager.fileExists(atPath: xcFramework.path),
                          "Should create \(library).xcframework")
            XCTAssertFalse(fileManager.fileExists(atPath: versionFile.path),
                           "Should not create .\(library).version in create mode")
        }
    }

    func testBuildClangPackageWithCustomModuleMap() async throws {
        let runner = Runner(
            mode: .createPackage,
            options: .init(
                baseBuildOptions: .init(isSimulatorSupported: false)
            )
        )
        do {
            try await runner.run(packageDirectory: clangPackageWithCustomModuleMapPath,
                                 frameworkOutputDir: .custom(frameworkOutputDir))
        } catch {
            XCTFail("Build should be succeeded. \(error.localizedDescription)")
        }

        for library in ["ClangPackageWithCustomModuleMap"] {
            let xcFramework = frameworkOutputDir.appendingPathComponent("\(library).xcframework")
            let versionFile = frameworkOutputDir.appendingPathComponent(".\(library).version")
            let framework = xcFramework.appendingPathComponent("ios-arm64")
                .appendingPathComponent("\(library).framework")

            XCTAssertTrue(
                fileManager.fileExists(atPath: framework.appendingPathComponent("Headers/mycalc.h").path),
                "Should exist an umbrella header"
            )

            let moduleMapPath = framework.appendingPathComponent("Modules/module.modulemap").path
            XCTAssertTrue(
                fileManager.fileExists(atPath: moduleMapPath),
                "Should exist a modulemap"
            )
            let moduleMapContents = try XCTUnwrap(fileManager.contents(atPath: moduleMapPath).flatMap { String(data: $0, encoding: .utf8) })
            XCTAssertEqual(
                moduleMapContents,
                """
                framework module ClangPackageWithCustomModuleMap {
                  header "mycalc.h"
                }
                """,
                "modulemap should be converted for frameworks"
            )

            XCTAssertTrue(fileManager.fileExists(atPath: xcFramework.path),
                          "Should create \(library).xcframework")
            XCTAssertFalse(fileManager.fileExists(atPath: versionFile.path),
                           "Should not create .\(library).version in create mode")
        }
    }

    func testCacheIsValid() async throws {
        let descriptionPackage = try DescriptionPackage(packageDirectory: testPackagePath.absolutePath, mode: .prepareDependencies)
        let cacheSystem = CacheSystem(descriptionPackage: descriptionPackage,
                                      buildOptions: .init(buildConfiguration: .release,
                                                          isDebugSymbolsEmbedded: false,
                                                          frameworkType: .dynamic,
                                                          sdks: [.iOS],
                                                          extraFlags: nil,
                                                          extraBuildParameters: nil,
                                                          enableLibraryEvolution: true),
                                      outputDirectory: frameworkOutputDir,
                                      storage: nil)
        let packages = descriptionPackage.graph.packages
            .filter { $0.manifest.displayName != descriptionPackage.manifest.displayName }

        let allProducts = packages.flatMap { package in
            package.targets.map { BuildProduct(package: package, target: $0) }
        }

        for product in allProducts {
            try await cacheSystem.generateVersionFile(for: product)
            // generate dummy directory
            try fileManager.createDirectory(
                at: frameworkOutputDir.appendingPathComponent("\(product.target.name).xcframework"),
                withIntermediateDirectories: true
            )
        }
        let versionFile2 = frameworkOutputDir.appendingPathComponent(".ScipioTesting.version")
        XCTAssertTrue(fileManager.fileExists(atPath: versionFile2.path))

        let runner = Runner(
            mode: .prepareDependencies,
            options: .init(
                cacheMode: .project
            )
        )
        do {
            try await runner.run(packageDirectory: testPackagePath,
                                 frameworkOutputDir: .custom(frameworkOutputDir))
        } catch {
            XCTFail("Build should be succeeded. \(error.localizedDescription)")
        }

        for library in ["ScipioTesting"] {
            let xcFramework = frameworkOutputDir
                .appendingPathComponent("\(library).xcframework")
                .appendingPathComponent("Info.plist")
            let versionFile = frameworkOutputDir.appendingPathComponent(".\(library).version")
            XCTAssertFalse(fileManager.fileExists(atPath: xcFramework.path),
                           "Should skip to build \(library).xcramework")
            XCTAssertTrue(fileManager.fileExists(atPath: versionFile.path),
                          "Should create .\(library).version")
        }
    }

    func testLocalStorage() async throws {
        let storage = LocalCacheStorage(cacheDirectory: .custom(tempDir))
        let storageDir = tempDir.appendingPathComponent("Scipio")

        let runner = Runner(
            mode: .prepareDependencies,
            options: .init(
                cacheMode: .storage(storage, [.consumer, .producer])
            )
        )
        do {
            try await runner.run(packageDirectory: testPackagePath,
                                 frameworkOutputDir: .custom(frameworkOutputDir))
        } catch {
            XCTFail("Build should be succeeded. \(error.localizedDescription)")
        }

        XCTAssertTrue(fileManager.fileExists(atPath: storageDir.appendingPathComponent("ScipioTesting").path))

        let outputFrameworkPath = frameworkOutputDir.appendingPathComponent("ScipioTesting.xcframework")

        try self.fileManager.removeItem(atPath: outputFrameworkPath.path)

        // Fetch from local storage
        do {
            try await runner.run(packageDirectory: testPackagePath,
                                 frameworkOutputDir: .custom(frameworkOutputDir))
        } catch {
            XCTFail("Build should be succeeded.")
        }

        XCTAssertTrue(fileManager.fileExists(atPath: storageDir.appendingPathComponent("ScipioTesting").path))

        addTeardownBlock {
            try self.fileManager.removeItem(at: storageDir)
        }
    }

    func testExtractBinary() async throws {
        let runner = Runner(
            mode: .createPackage,
            options: .init(
                baseBuildOptions: .init(
                    buildConfiguration: .release,
                    isSimulatorSupported: false,
                    isDebugSymbolsEmbedded: false,
                    frameworkType: .dynamic
                ),
                cacheMode: .project,
                overwrite: false,
                verbose: false)
        )

        try await runner.run(packageDirectory: binaryPackagePath, frameworkOutputDir: .custom(frameworkOutputDir))

        let binaryPath = frameworkOutputDir.appendingPathComponent("SomeBinary.xcframework")
        XCTAssertTrue(
            fileManager.fileExists(atPath: binaryPath.path),
            "Binary frameworks should be copied."
        )

        addTeardownBlock {
            try self.fileManager.removeItem(atPath: binaryPath.path)
        }
    }

    func testPrepareBinary() async throws {
        let runner = Runner(
            mode: .prepareDependencies,
            options: .init(
                baseBuildOptions: .init(
                    buildConfiguration: .release,
                    isSimulatorSupported: false,
                    isDebugSymbolsEmbedded: false,
                    frameworkType: .dynamic
                ),
                cacheMode: .project,
                overwrite: false,
                verbose: false)
        )

        try await runner.run(packageDirectory: usingBinaryPackagePath, frameworkOutputDir: .custom(frameworkOutputDir))

        let binaryPath = frameworkOutputDir.appendingPathComponent("SomeBinary.xcframework")
        XCTAssertTrue(
            fileManager.fileExists(atPath: binaryPath.path),
            "Binary frameworks should be copied."
        )

        let versionFilePath = frameworkOutputDir.appendingPathComponent(".SomeBinary.version")
        XCTAssertTrue(
            fileManager.fileExists(atPath: versionFilePath.path),
            "Version files should be created"
        )

        addTeardownBlock {
            try self.fileManager.removeItem(atPath: binaryPath.path)
        }
    }

    func testBinaryHasValidCache() async throws {
        // Generate VersionFile
        let descriptionPackage = try DescriptionPackage(
            packageDirectory: usingBinaryPackagePath.absolutePath,
            mode: .prepareDependencies
        )
        let cacheSystem = CacheSystem(descriptionPackage: descriptionPackage,
                                      buildOptions: .init(buildConfiguration: .release,
                                                          isDebugSymbolsEmbedded: false,
                                                          frameworkType: .dynamic,
                                                          sdks: [.iOS],
                                                          extraFlags: nil,
                                                          extraBuildParameters: nil,
                                                          enableLibraryEvolution: true),
                                      outputDirectory: frameworkOutputDir,
                                      storage: nil)
        let packages = descriptionPackage.graph.packages
            .filter { $0.manifest.displayName != descriptionPackage.manifest.displayName }

        let allProducts = packages.flatMap { package in
            package.targets.map { BuildProduct(package: package, target: $0) }
        }

        for product in allProducts {
            try await cacheSystem.generateVersionFile(for: product)
            // generate dummy directory
            try fileManager.createDirectory(
                at: frameworkOutputDir.appendingPathComponent("\(product.target.name).xcframework"),
                withIntermediateDirectories: true
            )
        }
        let versionFile2 = frameworkOutputDir.appendingPathComponent(".SomeBinary.version")
        XCTAssertTrue(
            fileManager.fileExists(atPath: versionFile2.path),
            "VersionFile should be generated"
        )

        // Attempt to generate XCFrameworks
        let runner = Runner(
            mode: .prepareDependencies,
            options: .init(
                baseBuildOptions: .init(
                    buildConfiguration: .release,
                    isSimulatorSupported: false,
                    isDebugSymbolsEmbedded: false,
                    frameworkType: .dynamic
                ),
                cacheMode: .project,
                overwrite: false,
                verbose: false)
        )

        try await runner.run(packageDirectory: usingBinaryPackagePath, frameworkOutputDir: .custom(frameworkOutputDir))

        let binaryPath = frameworkOutputDir.appendingPathComponent("SomeBinary.xcframework")
        XCTAssertTrue(
            fileManager.fileExists(atPath: binaryPath.path),
            "Binary frameworks should be copied."
        )

        // We generated an empty XCFramework directory to simulate cache is valid before.
        // So if runner doesn't create valid XCFrameworks, framework's contents are not exists
        let infoPlistPath = binaryPath.appendingPathComponent("Info.plist")
        XCTAssertFalse(
            fileManager.fileExists(atPath: infoPlistPath.path),
            "XCFramework should not be updated"
        )

        addTeardownBlock {
            try self.fileManager.removeItem(atPath: binaryPath.path)
        }
    }

    func testWithPlatformMatrix() async throws {
        let runner = Runner(
            mode: .prepareDependencies,
            options: .init(
                baseBuildOptions: .init(isSimulatorSupported: true),
                buildOptionsMatrix: [
                    "ScipioTesting": .init(
                        platforms: .specific([.iOS, .watchOS]),
                        isSimulatorSupported: true
                    ),
                ],
                cacheMode: .project,
                overwrite: false,
                verbose: false)
        )

        try await runner.run(packageDirectory: testPackagePath,
                             frameworkOutputDir: .custom(frameworkOutputDir))

        for library in ["ScipioTesting"] {
            let xcFramework = frameworkOutputDir.appendingPathComponent("\(library).xcframework")
            let versionFile = frameworkOutputDir.appendingPathComponent(".\(library).version")
            let contentsOfXCFramework = try XCTUnwrap(fileManager.contentsOfDirectory(atPath: xcFramework.path))
            XCTAssertTrue(fileManager.fileExists(atPath: xcFramework.path),
                          "Should create \(library).xcramework")
            XCTAssertTrue(fileManager.fileExists(atPath: versionFile.path),
                          "Should create .\(library).version")
            XCTAssertEqual(
                Set(contentsOfXCFramework),
                [
                    "Info.plist",
                    "watchos-arm64_arm64_32_armv7k",
                    "ios-arm64_x86_64-simulator",
                    "watchos-arm64_i386_x86_64-simulator",
                    "ios-arm64",
                ]
            )
        }
    }

    func testWithResourcePackage() async throws {
        let runner = Runner(
            mode: .createPackage,
            options: .init(
                baseBuildOptions: .init(
                    platforms: .specific([.iOS]),
                    isSimulatorSupported: true
                ),
                cacheMode: .disabled
            )
        )

        try await runner.run(packageDirectory: resourcePackagePath,
                             frameworkOutputDir: .custom(frameworkOutputDir))

        let xcFramework = frameworkOutputDir.appendingPathComponent("ResourcePackage.xcframework")
        for arch in ["ios-arm64", "ios-arm64_x86_64-simulator"] {
            let bundlePath = xcFramework
                .appendingPathComponent(arch)
                .appendingPathComponent("ResourcePackage.framework")
                .appendingPathComponent("ResourcePackage_ResourcePackage.bundle")
            XCTAssertTrue(
                fileManager.fileExists(atPath: bundlePath.path),
                "A framework for \(arch) should contain resource bundles"
            )
            XCTAssertTrue(
                fileManager.fileExists(atPath: bundlePath.appendingPathComponent("giginet.png").path),
                "Image files should be contained"
            )
            XCTAssertTrue(
                fileManager.fileExists(atPath: bundlePath.appendingPathComponent("AvatarView.nib").path),
                "XIB files should be contained"
            )

            let contents = try XCTUnwrap(try fileManager.contentsOfDirectory(atPath: bundlePath.path))
            XCTAssertTrue(
                Set(contents).isSuperset(of: ["giginet.png", "AvatarView.nib", "Info.plist"]),
                "The resource bundle should contain expected resources"
            )
        }
    }

    func testWithExtraBuildParameters() async throws {
        let runner = Runner(
            mode: .prepareDependencies,
            options: .init(
                baseBuildOptions: .init(
                    isSimulatorSupported: false,
                    extraBuildParameters: [
                        "SWIFT_OPTIMIZATION_LEVEL": "-Osize",
                    ]
                )
            )
        )

        do {
            try await runner.run(packageDirectory: testPackagePath,
                                 frameworkOutputDir: .custom(frameworkOutputDir))
        } catch {
            XCTFail("Build should be succeeded. \(error.localizedDescription)")
        }

        for library in ["ScipioTesting"] {
            let xcFramework = frameworkOutputDir.appendingPathComponent("\(library).xcframework")
            let versionFile = frameworkOutputDir.appendingPathComponent(".\(library).version")
            let simulatorFramework = xcFramework.appendingPathComponent("ios-arm64_x86_64-simulator")
            XCTAssertTrue(fileManager.fileExists(atPath: xcFramework.path),
                          "Should create \(library).xcramework")
            XCTAssertTrue(fileManager.fileExists(atPath: versionFile.path),
                          "Should create .\(library).version")
            XCTAssertFalse(fileManager.fileExists(atPath: simulatorFramework.path),
                           "Should not create Simulator framework")
        }
    }

    func testBuildXCFrameworkWithNoLibraryEvolution() async throws {
        let runner = Runner(
            mode: .prepareDependencies,
            options: .init(
                baseBuildOptions: .init(
                    isSimulatorSupported: false,
                    enableLibraryEvolution: false
                )
            )
        )
        do {
            try await runner.run(packageDirectory: testPackagePath,
                                 frameworkOutputDir: .custom(frameworkOutputDir))
        } catch {
            XCTFail("Build should be succeeded. \(error.localizedDescription)")
        }

        for library in ["ScipioTesting"] {
            let xcFramework = frameworkOutputDir.appendingPathComponent("\(library).xcframework")
            let versionFile = frameworkOutputDir.appendingPathComponent(".\(library).version")
            let simulatorFramework = xcFramework.appendingPathComponent("ios-arm64_x86_64-simulator/\(library).framework")
            let deviceFramework = xcFramework.appendingPathComponent("ios-arm64/\(library).framework")

            XCTAssertTrue(
                fileManager.fileExists(atPath: deviceFramework.appendingPathComponent("Headers/\(library)-Swift.h").path),
                "Should exist a bridging header"
            )

            XCTAssertTrue(
                fileManager.fileExists(atPath: deviceFramework.appendingPathComponent("Modules/module.modulemap").path),
                "Should exist a modulemap"
            )

            let expectedSwiftInterface = deviceFramework.appendingPathComponent("Modules/\(library).swiftmodule/arm64-apple-ios.swiftinterface")
            XCTAssertFalse(
                fileManager.fileExists(atPath: expectedSwiftInterface.path),
                "Should not exist a swiftinterface because emission is disabled"
            )

            XCTAssertTrue(fileManager.fileExists(atPath: xcFramework.path),
                          "Should create \(library).xcramework")
            XCTAssertTrue(fileManager.fileExists(atPath: versionFile.path),
                          "Should create .\(library).version")
            XCTAssertFalse(fileManager.fileExists(atPath: simulatorFramework.path),
                           "Should not create Simulator framework")
        }
    }

    override func tearDownWithError() throws {
        try removeIfExist(at: testPackagePath.appendingPathComponent(".build"))
        try removeIfExist(at: frameworkOutputDir)
        try super.tearDownWithError()
    }

    private func removeIfExist(at path: URL) throws {
        if fileManager.fileExists(atPath: path.path) {
            try self.fileManager.removeItem(at: path)
        }
    }
}
