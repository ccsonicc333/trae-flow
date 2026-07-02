import AppKit
import XCTest
@testable import TRAE_FLOW

@MainActor
final class IslandPresentationCoordinatorTests: XCTestCase {
    private var originalSurfaceMode: IslandSurfaceMode!

    override func setUp() {
        super.setUp()
        originalSurfaceMode = AppSettings.surfaceMode
    }

    override func tearDown() {
        AppSettings.surfaceMode = originalSurfaceMode
        super.tearDown()
    }

    func testRedockDetachedReusesExistingDockedWindow() throws {
        AppSettings.surfaceMode = .notch
        let screen = try XCTUnwrap(NSScreen.main)
        let coordinator = IslandPresentationCoordinator(screen: screen)

        // init 时已经创建了一次 docked window。
        XCTAssertEqual(coordinator.dockedWindowRecreationCount, 1)
        XCTAssertEqual(coordinator.viewModel.presentationMode, .docked)

        // 模拟宠物分离到桌面。
        coordinator.beginDetachment(from: IslandDetachmentRequest(
            source: .closed,
            dragStartScreenLocation: CGPoint(x: 100, y: 100),
            currentScreenLocation: CGPoint(x: 100, y: 150)
        ))
        XCTAssertEqual(coordinator.viewModel.presentationMode, .detached)

        // 宠物拖回 Flow 岛。
        coordinator.redockDetached()

        // 分离期间 docked 窗口一直保留，拖回时不应再重建。
        XCTAssertEqual(coordinator.dockedWindowRecreationCount, 1)
        XCTAssertEqual(coordinator.viewModel.presentationMode, .docked)
        XCTAssertNotNil(coordinator.dockedWindowControllerForTesting)
    }

    func testRepeatedDetachAndRedockDoesNotAccumulateExtraRecreations() throws {
        AppSettings.surfaceMode = .notch
        let screen = try XCTUnwrap(NSScreen.main)
        let coordinator = IslandPresentationCoordinator(screen: screen)

        XCTAssertEqual(coordinator.dockedWindowRecreationCount, 1)

        for _ in 0..<3 {
            coordinator.beginDetachment(from: IslandDetachmentRequest(
                source: .closed,
                dragStartScreenLocation: CGPoint(x: 100, y: 100),
                currentScreenLocation: CGPoint(x: 100, y: 150)
            ))
            XCTAssertEqual(coordinator.viewModel.presentationMode, .detached)

            coordinator.redockDetached()
            XCTAssertEqual(coordinator.viewModel.presentationMode, .docked)
        }

        // 多次 detach/redock 循环后，docked 窗口应始终复用，总重建次数保持为 1。
        XCTAssertEqual(coordinator.dockedWindowRecreationCount, 1)
        XCTAssertNotNil(coordinator.dockedWindowControllerForTesting)
    }
}
