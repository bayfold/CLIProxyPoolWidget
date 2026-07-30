import Foundation

@main
enum UsageParserRegression {
    static func main() {
        testDualWindows()
        testWeeklyWindowInPrimarySlot()
        testReversedWindowSlots()
        testLegacyWindowPositions()
        testGenericRemainingDoesNotBecomeWeeklyQuota()
        testAnthropicWindowsAndModernFable()
        testAnthropicWeeklyOnly()
        testAnthropicFractionalPercentStaysPercent()
        testAnthropicLegacyFableFallback()
        testClaudeProviderClassification()
        print("UsageParser regression tests passed")
    }

    private static func testDualWindows() {
        let snapshot = UsageParser.parse(#"""
        {
          "plan_type": "pro",
          "rate_limit": {
            "primary_window": {
              "used_percent": 42,
              "reset_after_seconds": 3600,
              "limit_window_seconds": 18000
            },
            "secondary_window": {
              "used_percent": 10,
              "reset_after_seconds": 86400,
              "limit_window_seconds": 604800
            }
          }
        }
        """#)

        expect(snapshot.primaryRemainingPercent == 58, "dual-window 5h remaining")
        expect(snapshot.weeklyRemainingPercent == 90, "dual-window Week remaining")
    }

    private static func testWeeklyWindowInPrimarySlot() {
        let snapshot = UsageParser.parse(#"""
        {
          "plan_type": "plus",
          "rate_limit": {
            "primary_window": {
              "used_percent": 39,
              "reset_after_seconds": 474388,
              "limit_window_seconds": 604800
            },
            "secondary_window": null
          }
        }
        """#)

        expect(snapshot.primaryRemainingPercent == nil, "removed 5h window stays absent")
        expect(snapshot.weeklyRemainingPercent == 61, "primary-slot Week remaining")
        expect(snapshot.primaryResetSeconds == nil, "removed 5h reset stays absent")
        expect(snapshot.weeklyResetSeconds == 474388, "primary-slot Week reset")
    }

    private static func testReversedWindowSlots() {
        let snapshot = UsageParser.parse(#"""
        {
          "rate_limit": {
            "primary_window": {
              "used_percent": 25,
              "reset_after_seconds": 500000,
              "limit_window_seconds": 604800
            },
            "secondary_window": {
              "used_percent": 40,
              "reset_after_seconds": 9000,
              "limit_window_seconds": 18000
            }
          }
        }
        """#)

        expect(snapshot.primaryRemainingPercent == 60, "duration identifies reversed 5h window")
        expect(snapshot.weeklyRemainingPercent == 75, "duration identifies reversed Week window")
    }

    private static func testLegacyWindowPositions() {
        let snapshot = UsageParser.parse(#"""
        {
          "rate_limit": {
            "primary_window": {"used_percent": 20, "reset_after_seconds": 1000},
            "secondary_window": {"used_percent": 30, "reset_after_seconds": 2000}
          }
        }
        """#)

        expect(snapshot.primaryRemainingPercent == 80, "legacy primary slot remains 5h")
        expect(snapshot.weeklyRemainingPercent == 70, "legacy secondary slot remains Week")
    }

    private static func testGenericRemainingDoesNotBecomeWeeklyQuota() {
        let snapshot = UsageParser.parse(#"{"remaining": 12, "limit": 20}"#)
        expect(snapshot.primaryRemainingPercent == 60, "generic remaining is normalized for primary")
        expect(snapshot.weeklyRemainingPercent == nil, "generic remaining is not duplicated as Week")
    }

    private static func testAnthropicWindowsAndModernFable() {
        let snapshot = UsageParser.parse(#"""
        {
          "five_hour": {
            "utilization": 37,
            "resets_at": "2099-07-31T10:00:00.000000+00:00"
          },
          "seven_day": {
            "utilization": 26,
            "resets_at": "2099-08-04T10:00:00.000000+00:00"
          },
          "limits": [
            {
              "kind": "weekly_scoped",
              "percent": 12,
              "resets_at": "2099-08-03T10:00:00.000000+00:00",
              "is_active": false,
              "scope": {"model": {"display_name": "Claude Fable 5"}}
            },
            {
              "kind": "weekly_scoped",
              "percent": 64,
              "resets_at": "2099-08-04T10:00:00.000000+00:00",
              "is_active": true,
              "scope": {"model": {"display_name": "Fable"}}
            }
          ]
        }
        """#)

        expect(snapshot.planType == "claude", "Anthropic usage identifies the Claude plan family")
        expect(snapshot.primaryRemainingPercent == 63, "Anthropic 5h remaining")
        expect(snapshot.weeklyRemainingPercent == 74, "Anthropic Week remaining")
        expect(snapshot.fableRemainingPercent == 36, "active modern Fable window wins")
        expect(snapshot.primaryResetSeconds != nil, "Anthropic 5h ISO reset")
        expect(snapshot.weeklyResetSeconds != nil, "Anthropic Week ISO reset")
        expect(snapshot.fableResetSeconds != nil, "Anthropic Fable ISO reset")
    }

    private static func testAnthropicWeeklyOnly() {
        let snapshot = UsageParser.parse(#"""
        {
          "five_hour": null,
          "seven_day": {
            "utilization": 45,
            "resets_at": "2099-08-04T10:00:00Z"
          }
        }
        """#)

        expect(snapshot.primaryRemainingPercent == nil, "missing Anthropic 5h stays absent")
        expect(snapshot.weeklyRemainingPercent == 55, "Anthropic Week-only response is not moved to 5h")
    }

    private static func testAnthropicFractionalPercentStaysPercent() {
        let snapshot = UsageParser.parse(#"{"five_hour":{"utilization":0.5,"resets_at":null}}"#)
        expect(snapshot.primaryRemainingPercent == 99.5, "Anthropic utilization is already a 0...100 percentage")
    }

    private static func testAnthropicLegacyFableFallback() {
        let snapshot = UsageParser.parse(#"""
        {
          "seven_day": {"utilization": 20, "resets_at": null},
          "iguana_necktie": {
            "utilization": 41,
            "resets_at": "2099-08-04T10:00:00Z"
          },
          "limits": [
            {
              "kind": "weekly_scoped",
              "percent": null,
              "is_active": true,
              "scope": {"model": {"display_name": "Fable"}}
            },
            {
              "kind": "weekly_scoped",
              "percent": 35,
              "scope": {"model": {"display_name": "Sonnet"}}
            }
          ]
        }
        """#)

        expect(snapshot.weeklyRemainingPercent == 80, "unrelated scoped limits preserve ordinary Week")
        expect(snapshot.fableRemainingPercent == 59, "invalid modern Fable falls back to legacy field")
    }

    private static func testClaudeProviderClassification() {
        let data = Data(#"""
        {
          "files": [
            {"id":"oauth","auth_index":"oauth","provider":"claude","account_type":"oauth"},
            {"id":"key","auth_index":"key","provider":"claude","account_type":"api_key"},
            {"id":"unknown","auth_index":"unknown","provider":"claude"}
          ]
        }
        """#.utf8)
        let files = try? JSONDecoder().decode(AuthFilesResponse.self, from: data).files
        expect(files?.first?.supportsQuotaUsage == true, "Claude OAuth supports subscription quota")
        expect(files?[safe: 1]?.supportsQuotaUsage == false, "Claude API key is not treated as subscription quota")
        expect(files?.last?.supportsQuotaUsage == false, "Claude without an explicit OAuth account type is excluded")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAILED: \(message)\n", stderr)
            exit(1)
        }
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
