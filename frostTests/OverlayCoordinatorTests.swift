//
//  OverlayCoordinatorTests.swift
//  frostTests
//
//  Pins the two pure decisions extracted from OverlayCoordinator: whether a
//  screen-parameters change should defer past a live Touch ID prompt, and
//  which display becomes the active (keyed) one. Both are easy to get subtly
//  wrong and hard to exercise through real NSWindows/NSScreens.
//

import CoreGraphics
import Testing

@testable import Frost

@MainActor
struct OverlayCoordinatorTests {

    // MARK: - screenChangeAction

    @Test func nothingPresentedIsIgnoredRegardlessOfAuthState() {
        #expect(
            OverlayCoordinator.screenChangeAction(isPresented: false, isAuthenticating: false)
                == .ignore)
        #expect(
            OverlayCoordinator.screenChangeAction(isPresented: false, isAuthenticating: true)
                == .ignore)
    }

    @Test func presentedAndAuthenticatingDefers() {
        #expect(
            OverlayCoordinator.screenChangeAction(isPresented: true, isAuthenticating: true)
                == .deferUntilAuthEnds)
    }

    @Test func presentedAndIdleRebuildsImmediately() {
        #expect(
            OverlayCoordinator.screenChangeAction(isPresented: true, isAuthenticating: false)
                == .rebuild)
    }

    // MARK: - shouldApplyDeferredRebuild

    @Test func deferredRebuildAppliesOnlyWhenNeededAndStillPresented() {
        #expect(
            OverlayCoordinator.shouldApplyDeferredRebuild(
                needsRebuildAfterAuth: true, isPresented: true) == true)
        #expect(
            OverlayCoordinator.shouldApplyDeferredRebuild(
                needsRebuildAfterAuth: true, isPresented: false) == false)
        #expect(
            OverlayCoordinator.shouldApplyDeferredRebuild(
                needsRebuildAfterAuth: false, isPresented: true) == false)
        #expect(
            OverlayCoordinator.shouldApplyDeferredRebuild(
                needsRebuildAfterAuth: false, isPresented: false) == false)
    }

    // MARK: - activeScreenIndex

    @Test func mouseInsideSecondFrameSelectsIt() {
        let frames = [
            CGRect(x: 0, y: 0, width: 100, height: 100),
            CGRect(x: 100, y: 0, width: 100, height: 100),
        ]
        let index = OverlayCoordinator.activeScreenIndex(
            frames: frames, mouse: CGPoint(x: 150, y: 50), mainIndex: nil)
        #expect(index == 1)
    }

    @Test func mouseOutsideAllFramesFallsBackToMainIndex() {
        let frames = [
            CGRect(x: 0, y: 0, width: 100, height: 100),
            CGRect(x: 100, y: 0, width: 100, height: 100),
        ]
        let index = OverlayCoordinator.activeScreenIndex(
            frames: frames, mouse: CGPoint(x: 500, y: 500), mainIndex: 1)
        #expect(index == 1)
    }

    @Test func mouseOutsideAllFramesWithNoMainIndexFallsBackToFirst() {
        let frames = [
            CGRect(x: 0, y: 0, width: 100, height: 100),
            CGRect(x: 100, y: 0, width: 100, height: 100),
        ]
        let index = OverlayCoordinator.activeScreenIndex(
            frames: frames, mouse: CGPoint(x: 500, y: 500), mainIndex: nil)
        #expect(index == 0)
    }

    @Test func emptyFramesReturnsZero() {
        let index = OverlayCoordinator.activeScreenIndex(
            frames: [], mouse: .zero, mainIndex: nil)
        #expect(index == 0)
    }

    @Test func outOfRangeMainIndexFallsBackToFirst() {
        let frames = [
            CGRect(x: 0, y: 0, width: 100, height: 100),
            CGRect(x: 100, y: 0, width: 100, height: 100),
        ]
        let index = OverlayCoordinator.activeScreenIndex(
            frames: frames, mouse: CGPoint(x: 500, y: 500), mainIndex: 5)
        #expect(index == 0)
    }
}
