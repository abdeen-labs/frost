//
//  InactivityLockOptionTests.swift
//  frostTests
//
//  The inactivity threshold enum: raw-value ↔ seconds mapping, labels, and the
//  ordered, complete case list the Settings picker depends on.
//

import Foundation
import Testing

@testable import Frost

@MainActor
struct InactivityLockOptionTests {

    @Test func offHasNoThreshold() {
        #expect(InactivityLockOption.off.seconds == nil)
    }

    @Test(arguments: InactivityLockOption.allCases)
    func secondsMatchRawValue(_ option: InactivityLockOption) {
        if option == .off {
            #expect(option.seconds == nil)
        } else {
            #expect(option.seconds == TimeInterval(option.rawValue))
        }
    }

    @Test(arguments: InactivityLockOption.allCases)
    func idEqualsRawValue(_ option: InactivityLockOption) {
        #expect(option.id == option.rawValue)
    }

    @Test func allCasesAreOrderedAndComplete() {
        #expect(InactivityLockOption.allCases == [
            .off, .thirtySeconds, .oneMinute, .twoMinutes, .fiveMinutes,
            .tenMinutes, .fifteenMinutes, .thirtyMinutes, .oneHour, .twoHours,
        ])
    }

    @Test func initFromRawValue() {
        #expect(InactivityLockOption(rawValue: 0) == .off)
        #expect(InactivityLockOption(rawValue: 30) == .thirtySeconds)
        #expect(InactivityLockOption(rawValue: 300) == .fiveMinutes)
        #expect(InactivityLockOption(rawValue: 7200) == .twoHours)
    }

    @Test func initFromInvalidRawValueIsNil() {
        #expect(InactivityLockOption(rawValue: 45) == nil)
        #expect(InactivityLockOption(rawValue: -1) == nil)
        #expect(InactivityLockOption(rawValue: 1) == nil)
    }

    @Test func labels() {
        #expect(InactivityLockOption.off.label == "Off")
        #expect(InactivityLockOption.thirtySeconds.label == "30 seconds")
        #expect(InactivityLockOption.oneMinute.label == "1 minute")
        #expect(InactivityLockOption.twoMinutes.label == "2 minutes")
        #expect(InactivityLockOption.fiveMinutes.label == "5 minutes")
        #expect(InactivityLockOption.tenMinutes.label == "10 minutes")
        #expect(InactivityLockOption.fifteenMinutes.label == "15 minutes")
        #expect(InactivityLockOption.thirtyMinutes.label == "30 minutes")
        #expect(InactivityLockOption.oneHour.label == "1 hour")
        #expect(InactivityLockOption.twoHours.label == "2 hours")
    }

    @Test(arguments: InactivityLockOption.allCases)
    func everyCaseHasANonEmptyLabel(_ option: InactivityLockOption) {
        #expect(!option.label.isEmpty)
    }
}
