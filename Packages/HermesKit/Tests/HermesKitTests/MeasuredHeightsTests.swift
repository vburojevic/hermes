import Foundation
import Testing
@testable import HermesKit

struct MeasuredHeightsTests {
    @Test func aHeightIsKeptByWidth() {
        let heights = MeasuredHeights()
        #expect(heights.height(at: 600) == nil)
        heights.record(412.5, at: 600)
        heights.record(530, at: 400)
        #expect(heights.height(at: 600) == 412.5)
        #expect(heights.height(at: 400) == 530)
        #expect(heights.height(at: 601) == nil)
    }

    @Test func onlyTheLatestWidthsAreKept() {
        let heights = MeasuredHeights(widths: 2)
        heights.record(100, at: 300)
        heights.record(90, at: 400)
        heights.record(80, at: 500)
        #expect(heights.height(at: 300) == nil)
        #expect(heights.height(at: 400) == 90)
        #expect(heights.height(at: 500) == 80)
    }

    @Test func measuringAWidthAgainKeepsItsPlace() {
        let heights = MeasuredHeights(widths: 2)
        heights.record(100, at: 300)
        heights.record(90, at: 400)
        heights.record(101, at: 300)
        heights.record(80, at: 500)
        // 300 was kept first; measuring it again didn't make it newer.
        #expect(heights.height(at: 300) == nil)
        #expect(heights.height(at: 400) == 90)
    }

    @Test func blocksAreKeptByParagraphAndWidth() {
        let heights = MeasuredHeights()
        let code = MeasuredHeights.BlockKey(paragraph: 2, width: 580)
        heights.recordBlock(240, at: code)
        #expect(heights.blockHeight(code) == 240)
        #expect(heights.blockHeight(.init(paragraph: 2, width: 560)) == nil)
        #expect(heights.blockHeight(.init(paragraph: 3, width: 580)) == nil)
    }

    @Test func blocksPastTheLimitDropTheOldest() {
        let heights = MeasuredHeights(blocks: 2)
        heights.recordBlock(10, at: .init(paragraph: 0, width: 500))
        heights.recordBlock(20, at: .init(paragraph: 1, width: 500))
        heights.recordBlock(30, at: .init(paragraph: 2, width: 500))
        #expect(heights.blockHeight(.init(paragraph: 0, width: 500)) == nil)
        #expect(heights.blockHeight(.init(paragraph: 2, width: 500)) == 30)
    }

    @Test func aResizedBlockStopsKeepingHeights() {
        let heights = MeasuredHeights()
        heights.record(400, at: 600)
        heights.recordBlock(120, at: .init(paragraph: 1, width: 600))
        heights.blockResized()
        #expect(!heights.isKept)
        #expect(heights.height(at: 600) == nil)
        #expect(heights.blockHeight(.init(paragraph: 1, width: 600)) == nil)
        // An image that arrived can change again: nothing measured later is kept either.
        heights.record(460, at: 600)
        heights.recordBlock(180, at: .init(paragraph: 1, width: 600))
        #expect(heights.height(at: 600) == nil)
        #expect(heights.blockHeight(.init(paragraph: 1, width: 600)) == nil)
    }

    @Test func viewsOnOtherThreadsShareIt() async {
        let heights = MeasuredHeights(widths: 64)
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<32 {
                group.addTask { heights.record(CGFloat(index), at: CGFloat(index * 10)) }
            }
        }
        for index in 0..<32 {
            #expect(heights.height(at: CGFloat(index * 10)) == CGFloat(index))
        }
    }
}
