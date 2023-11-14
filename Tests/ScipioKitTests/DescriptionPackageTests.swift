import Foundation
@testable import ScipioKit
import XCTest

private let fixturePath = URL(fileURLWithPath: #file)
    .deletingLastPathComponent()
    .appendingPathComponent("Resources")
    .appendingPathComponent("Fixtures")

final class DescriptionPackageTests: XCTestCase {
    func testDescriptionPackage() throws {
        let rootPath = fixturePath.appendingPathComponent("TestingPackage")
        let package = try XCTUnwrap(try DescriptionPackage(packageDirectory: rootPath.absolutePath, mode: .prepareDependencies))
        XCTAssertEqual(package.name, "TestingPackage")

        let packageNames = package.graph.packages.map(\.manifest.displayName)
        XCTAssertEqual(packageNames, ["TestingPackage", "swift-log"])

        XCTAssertEqual(
            package.workspaceDirectory.pathString,
            rootPath.appendingPathComponent(".build/scipio").path
        )

        XCTAssertEqual(
            package.derivedDataPath.pathString,
            rootPath.appendingPathComponent(".build/scipio/DerivedData").path
        )
    }

    func testBuildProductsInPrepareMode() throws {
        let rootPath = fixturePath.appendingPathComponent("IntegrationTestPackage")
        let package = try XCTUnwrap(try DescriptionPackage(packageDirectory: rootPath.absolutePath, mode: .prepareDependencies))
        XCTAssertEqual(package.name, "IntegrationTestPackage")

        XCTAssertEqual(
            Set(try package.resolveBuildProducts().map(\.target.name)),
            [
                "CNIOWindows", "NIOConcurrencyHelpers",
                "NIO", "CNIOAtomics", "Logging", "NIOEmbedded", "Atomics",
                "DequeModule", "_AtomicsShims", "NIOPosix", "_NIODataStructures",
                "SDWebImageMapKit", "NIOCore", "CNIOLinux",
                "OrderedCollections", "SDWebImage", "CNIODarwin",
            ]
        )
    }

    func testBuildProductsInCreateMode() throws {
        let rootPath = fixturePath.appendingPathComponent("BinaryPackage")
        let package = try XCTUnwrap(try DescriptionPackage(packageDirectory: rootPath.absolutePath, mode: .createPackage(.all)))
        XCTAssertEqual(package.name, "BinaryPackage")

        XCTAssertEqual(
            Set(try package.resolveBuildProducts().map(\.target.name)),
            ["SomeBinary"]
        )
    }
}
