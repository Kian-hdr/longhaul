import Foundation
import Testing
@testable import LonghaulCore

@Test func controlSurfaceDefaultsToAvailableHostAndPreservesExplicitChoice() {
    #expect(ControlSurface.preferred(saved: nil, nodebayInstalled: true) == .nodebay)
    #expect(ControlSurface.preferred(saved: nil, nodebayInstalled: false) == .menuBar)
    for installed in [false, true] {
        for selected in ControlSurface.allCases {
            #expect(ControlSurface.preferred(saved: selected, nodebayInstalled: installed) == selected)
        }
    }
}

@Test func menuBarRemainsAvailableUntilEveryNodebayRequirementIsMet() {
    for installed in [false, true] {
        for paired in [false, true] {
            for linked in [false, true] {
                for supported in [false, true] {
                    #expect(ControlSurface.menuBar.usesMenuBar(nodebayInstalled: installed, paired: paired, linked: linked, routingSupported: supported))
                    #expect(ControlSurface.nodebay.usesMenuBar(nodebayInstalled: installed, paired: paired, linked: linked, routingSupported: supported)
                        == !(installed && paired && linked && supported))
                }
            }
        }
    }
}
