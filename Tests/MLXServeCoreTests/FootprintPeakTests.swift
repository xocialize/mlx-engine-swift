//
//  FootprintPeakTests.swift
//  MLXServeCoreTests
//
//  AB-A-0134 — a polled peak under-reads, and the kernel's ledger peak is exact but process-lifetime.
//  These pin the rule that attributes the ledger to a window, then show on the live kernel that a
//  spike no poll saw still lands in the number.
//

import Foundation
import Testing
@testable import MLXServeCore

// MARK: - The attribution rule

// The ledger rose during the window, so its new high-water is the window's exact peak. The numbers
// are AB-A-0134's tile-128 case: the sampler read 4.17 GB, the kernel 4.70 GB.
@Test func aLedgerThatRoseIsTheWindowsExactPeak() {
    let peak = FootprintPeak.window(sampled: 4_170_000_000, lifetimePeakBefore: 3_000_000_000,
                                    lifetimePeakAfter: 4_700_000_000)
    #expect(peak == FootprintPeak(bytes: 4_700_000_000, source: .kernelLedger))
}

// The process peaked higher before the window: the ledger cannot attribute it, so the sample stands,
// marked as a lower bound.
@Test func aLedgerThatDidNotMoveLeavesTheSampledLowerBound() {
    let peak = FootprintPeak.window(sampled: 7_980_000_000, lifetimePeakBefore: 12_000_000_000,
                                    lifetimePeakAfter: 12_000_000_000)
    #expect(peak == FootprintPeak(bytes: 7_980_000_000, source: .sampled))
}

@Test func anUnreadableLedgerLeavesTheSampledLowerBound() {
    #expect(FootprintPeak.window(sampled: 5, lifetimePeakBefore: nil, lifetimePeakAfter: 9)
                == FootprintPeak(bytes: 5, source: .sampled))
    #expect(FootprintPeak.window(sampled: 5, lifetimePeakBefore: 3, lifetimePeakAfter: nil)
                == FootprintPeak(bytes: 5, source: .sampled))
}

// MARK: - The live kernel

@Test func theLifetimePeakIsReadableAndNeverBelowTheCurrentFootprint() throws {
    let current = try #require(HostMemory.physFootprint())
    let peak = try #require(HostMemory.physFootprintLifetimePeak())
    #expect(peak >= current)
}

// The case AB-A-0134 measured: a transient that no poll saw. Allocate past this process's lifetime
// peak, touch every page, free it, and never sample in between. The kernel's peak still has it.
@Test func aSpikeNoPollSawIsInTheKernelPeak() throws {
    let before = try #require(HostMemory.physFootprintLifetimePeak())
    let current = try #require(HostMemory.physFootprint())
    let spike = 256 << 20                                    // 256 MiB above the earlier high-water
    let size = (before > current ? Int(before - current) : 0) + spike
    // Too costly to prove when this test process already peaked far above where it sits now.
    guard size <= 2 << 30 else { return }

    let page = 16_384
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: page)
    buffer.initializeMemory(as: UInt8.self, repeating: 1, count: size)
    // Read one byte per page back, so no optimizer can drop the stores that make the pages resident.
    var touched = 0
    for offset in stride(from: 0, to: size, by: page) { touched += Int(buffer.load(fromByteOffset: offset, as: UInt8.self)) }
    buffer.deallocate()
    #expect(touched == (size + page - 1) / page)

    let after = try #require(HostMemory.physFootprintLifetimePeak())
    let peak = FootprintPeak.window(sampled: current, lifetimePeakBefore: before, lifetimePeakAfter: after)
    #expect(peak.source == .kernelLedger)
    // Half the spike is margin for whatever else this process frees meanwhile.
    #expect(peak.bytes > before + UInt64(spike / 2))
}
