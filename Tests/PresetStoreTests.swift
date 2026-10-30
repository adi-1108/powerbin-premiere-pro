import XCTest
@testable import PowerBin

final class PresetStoreTests: XCTestCase {
    func tempDir() -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func testRoundTrip() throws {
        let store = PresetStore(directory: tempDir())
        let snap: [String: Data] = ["com.adobe.premierepro.dummy": Data([0, 1, 2, 3])]
        let preset = try store.save(name: "My Preset", types: snap, tag: "blue")
        XCTAssertEqual(preset.tag, "blue")

        let reload = PresetStore(directory: store.directory)
        XCTAssertEqual(reload.presets.count, 1)
        XCTAssertEqual(reload.presets[0].name, "My Preset")
        XCTAssertEqual(reload.presets[0].types, snap)
    }

    func testNoClobber() throws {
        let store = PresetStore(directory: tempDir())
        _ = try store.save(name: "Same", types: [:])
        _ = try store.save(name: "Same", types: [:])
        XCTAssertEqual(store.presets.count, 2)
    }
}
