import Testing
@testable import ObjCDiffing

@Suite("Reporters")
struct ObjCAPIReporterTests {
    @Test func diffReportRendersSectionsSigilsAndWarnings() {
        let diff = ObjCAPIDiff(
            classes: [
                ObjCContainerChange(
                    key: ObjCAPIKey(rawValue: "class:Widget"),
                    name: "Widget",
                    containerKind: .class,
                    status: .modified,
                    memberChanges: [
                        ObjCMemberChange(key: ObjCAPIKey(rawValue: "method:-gain"), kind: .instanceMethod, status: .added, oldSignature: nil, newSignature: "- (void)gain;"),
                        ObjCMemberChange(key: ObjCAPIKey(rawValue: "method:-retype"), kind: .instanceMethod, status: .modified, oldSignature: "- (void)retype;", newSignature: "- (long long)retype;"),
                    ]
                ),
            ],
            protocols: [
                ObjCContainerChange(
                    key: ObjCAPIKey(rawValue: "protocol:Gone"),
                    name: "Gone",
                    containerKind: .protocol,
                    status: .removed,
                    memberChanges: []
                ),
            ],
            diagnostics: ObjCAPIDiffDiagnostics(
                oldSideKeyCollisions: [
                    ObjCAPIKeyCollision(key: ObjCAPIKey(rawValue: "class:Twin"), containerName: nil, droppedSignatures: ["Twin"]),
                ],
                newSideKeyCollisions: []
            )
        )
        let report = ObjCAPIDiffReporter().report(diff)
        let expected = """
        Classes:
          ~ Widget
              + - (void)gain;
              ~ - (void)retype; → - (long long)retype;

        Protocols:
          - Gone

        Warnings — identity-key collisions (first record kept, later ones not compared):
          old · dropped: Twin
        """
        #expect(report == expected)
    }

    @Test func emptyDiffReportsNoChanges() {
        #expect(ObjCAPIDiffReporter().report(ObjCAPIDiff()) == "No ObjC API changes.")
    }

    @Test func evolutionReportRendersTimelineWithBitmaps() throws {
        let baseline = ObjCAPISnapshot(classes: [
            Fixtures.containerSnapshot(key: "class:Widget", name: "Widget", members: [
                Fixtures.record(identity: "method:-run", payload: "enc:v16@0:8", signature: "- (void)run;"),
            ]),
        ])
        let withoutMethod = ObjCAPISnapshot(classes: [
            Fixtures.containerSnapshot(key: "class:Widget", name: "Widget", members: []),
        ])
        let evolution = try ObjCAPIEvolutionBuilder().evolution(
            of: [baseline, withoutMethod],
            versions: [ObjCAPIVersionDescriptor(label: "17.0"), ObjCAPIVersionDescriptor(label: "26.0")]
        )
        let report = ObjCAPIEvolutionReporter().report(evolution)
        let expected = """
        ObjC API evolution across 2 versions: 17.0 → 26.0

        Transitions:
          17.0 → 26.0: 1 removed · API-breaking
        First API-breaking transition: 17.0 → 26.0

        Classes:
          [●●] Widget
              [●○] - (void)run;
                  - removed in 26.0
        """
        #expect(report == expected)
    }

    @Test func evolutionSummaryIsHeaderAndTransitionsOnly() throws {
        let evolution = try ObjCAPIEvolutionBuilder().evolution(
            of: [ObjCAPISnapshot(), ObjCAPISnapshot()],
            versions: [ObjCAPIVersionDescriptor(label: "1"), ObjCAPIVersionDescriptor(label: "2")]
        )
        let summary = ObjCAPIEvolutionReporter().summary(evolution)
        let expected = """
        ObjC API evolution across 2 versions: 1 → 2

        Transitions:
          1 → 2: no changes
        """
        #expect(summary == expected)
    }
}
