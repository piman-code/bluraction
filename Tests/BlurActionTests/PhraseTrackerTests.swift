import AppKit
import CoreImage
import CoreText
import Foundation
import Testing
@testable import BlurAction

@Suite(.serialized)
struct PhraseTrackerTests {
    private let box = CGRect(x: 0.1, y: 0.3, width: 0.3, height: 0.1)
    private func line(_ box: CGRect) -> AutoDetector.RecognizedLine { .init(text: "BLUR 1234", box: box) }
    private func sample(_ time: Double, _ box: CGRect) -> ObjectTracker.Sample { .init(time: time, box: box) }

    @Test func motionUsesFrameSamplesAndOCRReanchorsWithLocalConservativeEnvelopes() async throws {
        let dependencies = PhraseTracker.Dependencies(recognize: { time in
            .init(time: time, lines: [line(box.offsetBy(dx: time * 0.05, dy: 0))])
        }, follow: { start, end, boxes in
            .init(outcomes: boxes.map { anchor in .init(samples: [sample(start + 0.5, anchor.offsetBy(dx: 0.025, dy: 0)), sample(end, anchor.offsetBy(dx: 0.05, dy: 0))], lostTarget: false, cancelled: false) })
        })
        let result = try await PhraseTracker.track(duration: 3, phrases: ["BLUR1234"], cancellation: .init(), dependencies: dependencies)
        #expect(result.tracks.count == 1)
        let track = try #require(result.tracks.first)
        #expect(track.samples.count == 7)
        #expect(track.start == 0 && track.end == 3)
        let at2 = try #require(track.samples.first { $0.time == 2 })
        #expect(abs(at2.box.midX - track.samples.first!.box.midX - 0.1) < 1e-8)
        #expect(abs(at2.box.width - track.samples.first!.box.width) < 1e-8)
        // The final interval has no new OCR read: it conservatively includes both
        // the last verified position and moving tracker, rather than trusting drift.
        #expect(track.samples.last!.box.contains(at2.box))
        #expect(track.samples.last!.box.contains(at2.box.offsetBy(dx: 0.05, dy: 0)))
        #expect(track.samples.last!.box.width <= track.samples.first!.box.width + 0.051)
        #expect(result.reviews.allSatisfy { $0.reason == .trackingLost && $0.start == 2 && $0.end == 3 })
        #expect(!result.reviews.isEmpty)
    }

    @Test func terminalOCRReanchorsMovingFinalFrameWithoutExtendingPastDuration() async throws {
        let finalTime = 1.9666666667
        let finalBox = box.offsetBy(dx: 0.035, dy: 0)
        var reads: [Double] = []
        let dependencies = PhraseTracker.Dependencies(recognize: { time in
            reads.append(time)
            return .init(time: time, lines: [line(time == finalTime ? finalBox : box)])
        }, follow: { start, end, boxes in
            // A plausible healthy image tracker can lag a word's last movement.
            .init(outcomes: boxes.map { .init(samples: [sample((start + end) / 2, $0), sample(end, $0)], lostTarget: false, cancelled: false) })
        })
        let result = try await PhraseTracker.track(duration: 2, phrases: ["BLUR1234"], cancellation: .init(),
            dependencies: dependencies, recognitionStep: 0.25, terminalRecognitionTime: finalTime)
        let track = try #require(result.tracks.first)
        #expect(reads.last == finalTime)
        #expect(reads.filter { $0 == finalTime }.count == 1)
        #expect(track.end == 2)
        #expect(track.samples.last!.box.contains(PhraseCover.coverBox(finalBox)))
        #expect(track.samples.allSatisfy { $0.time <= 2 })
        // The preceding short interval must contain the positively observed endpoint
        // as well, instead of jumping to the new cover only after the final frame.
        let prior = try #require(track.samples.last { $0.time < finalTime })
        #expect(prior.box.contains(PhraseCover.coverBox(finalBox)))
    }

    @Test func objectDisappearanceAndReappearanceCreateSeparateIdentities() async throws {
        let dependencies = PhraseTracker.Dependencies(recognize: { time in
            .init(time: time, lines: time == 1 ? [] : [line(box)])
        }, follow: { start, end, boxes in
            .init(outcomes: boxes.map { .init(samples: [sample(start == 0 ? start + 0.25 : end, $0)], lostTarget: start == 0, cancelled: false) })
        })
        let result = try await PhraseTracker.track(duration: 3, phrases: ["blur1234"], cancellation: .init(), dependencies: dependencies)
        #expect(result.tracks.count == 2)
        #expect(result.tracks[0].end == 1 && result.tracks[1].start == 2)
        #expect(result.tracks[0].id != result.tracks[1].id)
        #expect(result.reviews.contains { $0.trackID == result.tracks[0].id && $0.reason == .trackingLost })
    }

    @Test func singleOCRMissKeepsMotionAndReanchorsSameIdentity() async throws {
        let dependencies = PhraseTracker.Dependencies(recognize: { time in
            .init(time: time, lines: time == 1 ? [] : [line(box.offsetBy(dx: time * 0.02, dy: 0))])
        }, follow: { start, end, boxes in
            .init(outcomes: boxes.map { .init(samples: [sample(start + 0.5, $0.offsetBy(dx: 0.01, dy: 0)),
                sample(end, $0.offsetBy(dx: 0.02, dy: 0))], lostTarget: false, cancelled: false) })
        })
        let result = try await PhraseTracker.track(duration: 4, phrases: ["blur1234"], cancellation: .init(), dependencies: dependencies)
        #expect(result.tracks.count == 1)
        let track = try #require(result.tracks.first)
        #expect(track.start == 0 && track.end == 4)
        #expect(track.samples.contains { $0.time == 1.5 })
        #expect(result.reviews.contains { $0.trackID == track.id && $0.start == 0 && $0.end == 1 && $0.reason == .textUnconfirmed })
    }

    @Test func sustainedOCRAbsenceStopsAtBoundAndLaterHitGetsNewIdentity() async throws {
        let dependencies = PhraseTracker.Dependencies(recognize: { time in
            .init(time: time, lines: time == 0 || time >= 4 ? [line(box)] : [])
        }, follow: { _, end, boxes in
            .init(outcomes: boxes.map { .init(samples: [sample(end, $0)], lostTarget: false, cancelled: false) })
        })
        let result = try await PhraseTracker.track(duration: 6, phrases: ["blur1234"], cancellation: .init(), dependencies: dependencies)
        #expect(result.tracks.count == 2)
        #expect(result.tracks[0].end == PhraseTracker.maximumUnconfirmedDuration)
        #expect(result.tracks[1].start == 4)
        #expect(result.tracks[0].id != result.tracks[1].id)
    }

    @Test func reliableReplacementStopsButPartialLowConfidenceReadAllowsRecovery() async throws {
        for replacement in [false, true] {
            let dependencies = PhraseTracker.Dependencies(recognize: { time in
                let observation = AutoDetector.RecognizedLine(text: replacement ? "OTHER WORD" : "BLUR",
                    box: box, confidence: replacement ? 0.99 : 0.3)
                return .init(time: time, lines: time == 1 ? [observation] : [line(box)])
            }, follow: { _, end, boxes in
                .init(outcomes: boxes.map { .init(samples: [sample(end, $0)], lostTarget: false, cancelled: false) })
            })
            let result = try await PhraseTracker.track(duration: 3, phrases: ["blur1234"], cancellation: .init(), dependencies: dependencies)
            #expect(result.tracks.count == (replacement ? 2 : 1))
            #expect(result.tracks[0].end == (replacement ? 1 : 3))
            #expect(result.reviews.contains { $0.reason == .textUnconfirmed })
        }
    }

    @Test func lossKeepsAnExplicitUncertainTailAndDoesNotBridgeNewDetection() async throws {
        let dependencies = PhraseTracker.Dependencies(recognize: { time in .init(time: time, lines: [line(box)]) },
            follow: { start, end, boxes in .init(outcomes: boxes.map { .init(samples: [sample(start + 0.25, $0)], lostTarget: true, cancelled: false) }) })
        let result = try await PhraseTracker.track(duration: 2, phrases: ["blur1234"], cancellation: .init(), dependencies: dependencies)
        #expect(result.tracks.count == 2)
        #expect(result.tracks[0].samples.last!.time == 0.25)
        #expect(result.tracks[0].end == 1)
        #expect(result.reviews.contains { $0.start == 0.25 && $0.end == 1 && $0.reason == .trackingLost })
    }

    @Test func sceneCutsDiscardPostCutCoordinatesEvenWhenOCRFindsSameText() async throws {
        let dependencies = PhraseTracker.Dependencies(recognize: { time in .init(time: time, lines: [line(box)]) },
            follow: { start, end, boxes in .init(outcomes: boxes.map { .init(samples: [sample(start + 0.25, $0), sample(end, $0.offsetBy(dx: 0.6, dy: 0))], lostTarget: false, cancelled: false) }, sceneCuts: [start + 0.5]) })
        let result = try await PhraseTracker.track(duration: 2, phrases: ["blur1234"], cancellation: .init(), dependencies: dependencies)
        #expect(result.tracks.count == 2)
        #expect(result.tracks.allSatisfy { $0.samples.allSatisfy { $0.box.midX < 0.5 } })
        #expect(result.reviews.filter { $0.reason == .sceneChange }.count == 2)
    }

    @Test func duplicateOCRLinesAreDeduplicatedButTwoPlacesStaySeparate() async throws {
        let second = box.offsetBy(dx: 0.5, dy: 0.4)
        let dependencies = PhraseTracker.Dependencies(recognize: { time in .init(time: time, lines: [line(box), line(box), line(second)]) },
            follow: { _, end, boxes in .init(outcomes: boxes.map { .init(samples: [sample(end, $0)], lostTarget: false, cancelled: false) }) })
        let result = try await PhraseTracker.track(duration: 2, phrases: ["blur1234"], cancellation: .init(), dependencies: dependencies)
        #expect(result.tracks.count == 2)
        #expect(result.reviews.isEmpty)
    }

    @Test func containedTiledOCRHitDoesNotCreateCompetingIdentity() async throws {
        let contained = CGRect(x: box.minX + 0.08, y: box.minY + 0.02, width: 0.12, height: 0.06)
        let dependencies = PhraseTracker.Dependencies(recognize: { time in
            .init(time: time, lines: [line(contained), line(box)])
        }, follow: { _, end, boxes in
            .init(outcomes: boxes.map { .init(samples: [sample(end, $0)], lostTarget: false, cancelled: false) })
        })
        let result = try await PhraseTracker.track(duration: 3, phrases: ["blur1234"], cancellation: .init(), dependencies: dependencies)
        #expect(result.tracks.count == 1)
        #expect(result.tracks[0].end == 3)
        #expect(result.tracks[0].samples.allSatisfy { $0.box == PhraseCover.coverBox(box) })
        #expect(result.reviews.isEmpty)
    }

    @Test func trackerPortraitDriftKeepsOCRCoverAndMarksUncertainMotion() async throws {
        let dependencies = PhraseTracker.Dependencies(recognize: { time in .init(time: time, lines: [line(box)]) },
            follow: { start, end, boxes in
                .init(outcomes: boxes.map { seed in
                    .init(samples: [sample(start + 0.5, CGRect(x: seed.minX, y: 0, width: seed.width * 0.5, height: seed.height * 4)),
                        sample(end, CGRect(x: seed.minX, y: 0, width: seed.width * 0.5, height: seed.height * 4))],
                        lostTarget: false, cancelled: false)
                })
            })
        let result = try await PhraseTracker.track(duration: 3, phrases: ["blur1234"], cancellation: .init(), dependencies: dependencies)
        #expect(result.tracks.count == 1)
        #expect(result.tracks[0].samples.allSatisfy { $0.box == PhraseCover.coverBox(box) })
        #expect(result.reviews.filter { $0.reason == .trackingLost }.count == 3)
    }

    @Test func implausibleTrackerWithMovingOCRUsesContainingSpanCover() async throws {
        let dependencies = PhraseTracker.Dependencies(recognize: { time in
            .init(time: time, lines: [line(box.offsetBy(dx: 0, dy: time * 0.04))])
        }, follow: { start, end, boxes in
            .init(outcomes: boxes.map { seed in .init(samples: [sample(start + 0.5,
                CGRect(x: seed.minX, y: 0, width: seed.width * 0.5, height: seed.height * 4)), sample(end, seed)],
                lostTarget: false, cancelled: false) })
        })
        let result = try await PhraseTracker.track(duration: 2, phrases: ["blur1234"], cancellation: .init(), dependencies: dependencies)
        #expect(result.tracks.count == 1)
        let middle = try #require(result.tracks[0].samples.first { $0.time == 0.5 })
        let start = PhraseCover.coverBox(box)
        let next = PhraseCover.coverBox(box.offsetBy(dx: 0, dy: 0.04))
        #expect(middle.box.contains(start) && middle.box.contains(next))
        #expect(result.reviews.contains { $0.reason == .trackingLost && $0.start == 0 && $0.end == 1 })
    }

    @Test func plausibleOneRowDriftRetainsObservedTextAtIntermediateFrames() async throws {
        let dependencies = PhraseTracker.Dependencies(recognize: { time in .init(time: time, lines: [line(box)]) },
            follow: { start, end, boxes in
                .init(outcomes: boxes.map { seed in .init(samples: [sample(start + 0.5, seed.offsetBy(dx: 0, dy: -0.08)),
                    sample(end, seed.offsetBy(dx: 0, dy: -0.08))], lostTarget: false, cancelled: false) })
            })
        let result = try await PhraseTracker.track(duration: 2, phrases: ["blur1234"], cancellation: .init(), dependencies: dependencies)
        #expect(result.tracks.count == 1)
        #expect(result.tracks[0].samples.allSatisfy { $0.box.contains(PhraseCover.coverBox(box)) })
        #expect(result.reviews.contains { $0.reason == .trackingLost })
    }

    @Test func quarterSecondRecognitionReanchorsAtActualTimesAndStaysBounded() async throws {
        let dependencies = PhraseTracker.Dependencies(recognize: { time in .init(time: time, lines: [line(box)]) },
            follow: { _, end, boxes in
                .init(outcomes: boxes.map { .init(samples: [sample(end, $0)], lostTarget: false, cancelled: false) })
            })
        let result = try await PhraseTracker.track(duration: 2, phrases: ["blur1234"], cancellation: .init(),
            dependencies: dependencies, recognitionStep: 0.25)
        #expect(result.recognitionStep == 0.25)
        #expect(result.tracks.count == 1)
        #expect(result.tracks[0].samples.map(\.time) == (0...8).map { Double($0) * 0.25 })
        let longer = try await PhraseTracker.track(duration: 1200, phrases: ["blur1234"], cancellation: .init(),
            dependencies: dependencies, recognitionStep: 0.25)
        #expect(longer.recognitionStep == 2)
        #expect(longer.tracks[0].samples.count == PhraseCover.maximumSamples + 1)
    }

    @Test func newTextOnsetUsesOnlyEarlierDecodedPositiveObservations() async throws {
        let dependencies = PhraseTracker.Dependencies(recognize: { time in
            .init(time: time, lines: time >= 0.1 ? [line(box)] : [])
        }, follow: { _, end, boxes in
            .init(outcomes: boxes.map { .init(samples: [sample(end, $0)], lostTarget: false, cancelled: false) })
        })
        let result = try await PhraseTracker.track(duration: 0.5, phrases: ["blur1234"], cancellation: .init(),
            dependencies: dependencies, recognitionStep: 0.25, birthProbeStep: 1 / 30)
        let track = try #require(result.tracks.first)
        #expect(track.start == 0.125)
        #expect(track.samples.first!.time >= 0.1)
        #expect(result.reviews.contains { $0.start == 0.125 && $0.end == 0.25 && $0.reason == .textUnconfirmed })
    }

    @Test func onsetIdentityScopesSelectedTermsAcrossWholeLineAndTiledOCR() async throws {
        for latestHasBoth in [false, true] {
            let dependencies = PhraseTracker.Dependencies(recognize: { time in
                let lines: [AutoDetector.RecognizedLine]
                if time < 0.1 { lines = [] }
                else if time < 0.25 {
                    lines = latestHasBoth ? [.init(text: "BLUR1234", box: box)] : [
                        .init(text: "BLUR1234 OTHER5678", box: box),
                        .init(text: "BLUR1234", box: CGRect(x: box.minX + 0.03, y: box.minY + 0.02, width: 0.12, height: 0.06))]
                } else { lines = [.init(text: latestHasBoth ? "BLUR1234 OTHER5678" : "BLUR1234", box: box)] }
                return .init(time: time, lines: lines)
            }, follow: { _, end, boxes in
                .init(outcomes: boxes.map { .init(samples: [sample(end, $0)], lostTarget: false, cancelled: false) })
            })
            let result = try await PhraseTracker.track(duration: 0.5, phrases: ["blur1234", "other5678"], cancellation: .init(),
                dependencies: dependencies, recognitionStep: 0.25, birthProbeStep: 1 / 30)
            let track = try #require(result.tracks.first)
            #expect(result.tracks.count == 1)
            #expect(track.start == 0.125)
            #expect(track.phrase == (latestHasBoth ? "blur1234, other5678" : "blur1234"))
            #expect(result.reviews.contains { $0.start == 0.125 && $0.end == 0.25 })
        }
    }

    @Test func onsetPrefersDirectPositionOverRemoteSameSentenceButRejectsAmbiguousMotion() async throws {
        for hasDirect in [false, true] {
            let dependencies = PhraseTracker.Dependencies(recognize: { time in
                let lines: [AutoDetector.RecognizedLine]
                if time < 0.1 { lines = [] }
                else if time < 0.25 { lines = hasDirect ? [line(box), line(box.offsetBy(dx: 0, dy: -0.2))]
                    : [line(box.offsetBy(dx: 0, dy: -0.18)), line(box.offsetBy(dx: 0, dy: 0.18))] }
                else { lines = [line(box)] }
                return .init(time: time, lines: lines)
            }, follow: { _, end, boxes in
                .init(outcomes: boxes.map { .init(samples: [sample(end, $0)], lostTarget: false, cancelled: false) })
            })
            let result = try await PhraseTracker.track(duration: 0.5, phrases: ["blur1234"], cancellation: .init(),
                dependencies: dependencies, recognitionStep: 0.25, birthProbeStep: 1 / 30)
            let track = try #require(result.tracks.first)
            #expect(track.start == (hasDirect ? 0.125 : 0.25))
            if hasDirect {
                #expect(track.samples.first!.box == PhraseCover.coverBox(box))
                #expect(!track.samples.first!.box.intersects(PhraseCover.coverBox(box.offsetBy(dx: 0, dy: -0.2))))
            }
        }
    }

    @Test func onsetNeverStealsEarlierObservationFromEstablishedDuplicate() async throws {
        let bottom = CGRect(x: 0.1, y: 0.3, width: 0.3, height: 0.02)
        let top = bottom.offsetBy(dx: 0, dy: 0.2)
        let dependencies = PhraseTracker.Dependencies(recognize: { time in
            .init(time: time, lines: time >= 0.1 ? [line(bottom), line(top)] : [line(bottom)])
        }, follow: { _, end, boxes in
            .init(outcomes: boxes.map { .init(samples: [sample(end, $0)], lostTarget: false, cancelled: false) })
        })
        let result = try await PhraseTracker.track(duration: 0.5, phrases: ["blur1234"], cancellation: .init(),
            dependencies: dependencies, recognitionStep: 0.25, birthProbeStep: 1 / 30)
        #expect(result.tracks.count == 2)
        let old = try #require(result.tracks.first { $0.start == 0 })
        let born = try #require(result.tracks.first { $0.start > 0 })
        #expect(born.start == 0.125)
        #expect(old.id != born.id)
        #expect(born.samples.first!.box == PhraseCover.coverBox(top))
        #expect(!born.samples.first!.box.intersects(PhraseCover.coverBox(bottom)))
    }

    @Test func variableFrameTimestampsProbeNominalMidpointButStoreDecodedTime() async throws {
        let dependencies = PhraseTracker.Dependencies(recognize: { requested in
            let positive = requested == 0.125 || requested == 0.25
            return .init(time: requested == 0.25 ? 0.23 : requested, lines: positive ? [line(box)] : [])
        }, follow: { _, end, boxes in
            .init(outcomes: boxes.map { .init(samples: [sample(end, $0)], lostTarget: false, cancelled: false) })
        })
        let result = try await PhraseTracker.track(duration: 0.5, phrases: ["blur1234"], cancellation: .init(),
            dependencies: dependencies, recognitionStep: 0.25, birthProbeStep: 1 / 30)
        let track = try #require(result.tracks.first)
        #expect(track.start == 0.125)
        #expect(track.samples.contains { $0.time == 0.23 })
        #expect(!track.samples.contains { $0.time == 0.25 })
    }

    @Test func fastMovingObservedBirthIncludesBothPositionsWithoutUnobservedBackfill() async throws {
        let dependencies = PhraseTracker.Dependencies(recognize: { time in
            .init(time: time, lines: time >= 0.1 ? [line(box.offsetBy(dx: 0, dy: time))] : [])
        }, follow: { _, end, boxes in
            .init(outcomes: boxes.map { .init(samples: [sample(end, $0)], lostTarget: false, cancelled: false) })
        })
        let result = try await PhraseTracker.track(duration: 0.5, phrases: ["blur1234"], cancellation: .init(),
            dependencies: dependencies, recognitionStep: 0.25, birthProbeStep: 1 / 30)
        let track = try #require(result.tracks.first)
        #expect(track.start == 0.125)
        let first = track.samples.first!.box.insetBy(dx: -1e-9, dy: -1e-9)
        #expect(first.contains(PhraseCover.coverBox(box.offsetBy(dx: 0, dy: 0.125))))
        #expect(first.contains(PhraseCover.coverBox(box.offsetBy(dx: 0, dy: 0.25))))
    }

    @Test func onsetRefinementNeverCrossesSceneCutOrAmbiguousSameWords() async throws {
        for cut in [false, true] {
            let dependencies = PhraseTracker.Dependencies(recognize: { time in
                let lines: [AutoDetector.RecognizedLine]
                if time == 0 { lines = [] }
                else if !cut && time < 0.25 { lines = [line(box.offsetBy(dx: -0.13, dy: 0)), line(box.offsetBy(dx: 0.13, dy: 0))] }
                else { lines = [line(box)] }
                return .init(time: time, lines: lines)
            }, follow: { _, end, boxes in
                .init(outcomes: boxes.map { .init(samples: [sample(end, $0)], lostTarget: false, cancelled: false) })
            }, detectCuts: { _, _ in cut ? [0.2] : [] })
            let result = try await PhraseTracker.track(duration: 0.5, phrases: ["blur1234"], cancellation: .init(),
                dependencies: dependencies, recognitionStep: 0.25, birthProbeStep: 1 / 30)
            let track = try #require(result.tracks.first)
            #expect(cut ? track.start >= 0.2 : track.start == 0.25)
            #expect(track.samples.allSatisfy { $0.time >= track.start })
        }
    }

    @Test func onsetProbeCancellationAndSharedRecognitionBudgetAreBounded() async throws {
        var reads = 0
        let many = PhraseTracker.Dependencies(recognize: { time in
            reads += 1
            return .init(time: time, lines: time == 0 ? [] : (0..<20).map { i in
                .init(text: "BLUR1234 LINE\(i)", box: CGRect(x: 0.1 + Double(i % 5) * 0.18,
                    y: 0.1 + Double(i / 5) * 0.18, width: 0.08, height: 0.04))
            })
        }, follow: { _, end, boxes in
            .init(outcomes: boxes.map { .init(samples: [sample(end, $0)], lostTarget: false, cancelled: false) })
        })
        let bounded = try await PhraseTracker.track(duration: 0.5, phrases: ["blur1234"], cancellation: .init(),
            dependencies: many, recognitionStep: 0.25, birthProbeStep: 1 / 120)
        #expect(bounded.tracks.count == 20)
        #expect(reads <= 14, "Two scheduled reads plus at most twelve shared onset probes")
        let cancellation = ObjectTracker.Cancellation()
        let cancelling = PhraseTracker.Dependencies(recognize: { time in
            if time > 0 && time < 0.25 { cancellation.cancel() }
            return .init(time: time, lines: time == 0 ? [] : [line(box)])
        }, follow: { _, end, boxes in
            .init(outcomes: boxes.map { .init(samples: [sample(end, $0)], lostTarget: false, cancelled: false) })
        })
        let stopped = try await PhraseTracker.track(duration: 0.5, phrases: ["blur1234"], cancellation: cancellation,
            dependencies: cancelling, recognitionStep: 0.25, birthProbeStep: 1 / 30)
        #expect(stopped.cancelled && stopped.tracks.isEmpty)
    }

    @Test func decodedTimestampsDefineAnchorsAndDuplicateFramesDoNotCreateTracks() async throws {
        let dependencies = PhraseTracker.Dependencies(recognize: { requested in
            .init(time: requested < 2 ? 0 : 1.75, lines: [line(box)])
        }, follow: { start, end, boxes in .init(outcomes: boxes.map { .init(samples: [sample(end, $0)], lostTarget: false, cancelled: false) }) })
        let result = try await PhraseTracker.track(duration: 3, phrases: ["blur1234"], cancellation: .init(), dependencies: dependencies)
        #expect(result.tracks.count == 1)
        #expect(result.tracks[0].samples.map(\.time) == [0, 1.75, 3])
    }

    @Test func twoTracksCompetingForOneOCRHitAreBothFlaggedInsteadOfSwappingIdentity() async throws {
        let second = box.offsetBy(dx: 0.5, dy: 0)
        let dependencies = PhraseTracker.Dependencies(recognize: { time in
            .init(time: time, lines: time == 0 ? [line(box), line(second)] : [line(box)])
        }, follow: { _, end, boxes in
            .init(outcomes: boxes.map { _ in .init(samples: [sample(end, PhraseCover.coverBox(box))], lostTarget: false, cancelled: false) })
        })
        let result = try await PhraseTracker.track(duration: 2, phrases: ["blur1234"], cancellation: .init(), dependencies: dependencies)
        #expect(result.tracks.count == 3)
        #expect(result.reviews.filter { $0.reason == .textUnconfirmed && $0.end == 1 }.count == 2)
    }

    @Test func invalidTimestampsAndExcessSimultaneousTargetsFailExplicitly() async throws {
        let invalid = PhraseTracker.Dependencies(recognize: { _ in .init(time: .nan, lines: []) }, follow: { _, _, _ in .init(outcomes: []) })
        await #expect(throws: PhraseTracker.TrackError.self) {
            try await PhraseTracker.track(duration: 2, phrases: ["blur1234"], cancellation: .init(), dependencies: invalid)
        }
        let many = PhraseTracker.Dependencies(recognize: { time in
            .init(time: time, lines: (0..<33).map { i in line(CGRect(x: Double(i % 8) / 8, y: Double(i / 8) / 8, width: 0.02, height: 0.02)) })
        }, follow: { _, _, _ in .init(outcomes: []) })
        await #expect(throws: PhraseTracker.TrackError.self) {
            try await PhraseTracker.track(duration: 2, phrases: ["blur1234"], cancellation: .init(), dependencies: many)
        }
    }

    @Test func cancellationReturnsFlagAndNeverReportsCompletedProgress() async throws {
        let cancellation = ObjectTracker.Cancellation()
        let dependencies = PhraseTracker.Dependencies(recognize: { time in .init(time: time, lines: [line(box)]) },
            follow: { _, _, _ in cancellation.cancel(); return .init(outcomes: []) })
        let result = try await PhraseTracker.track(duration: 2, phrases: ["blur1234"], cancellation: cancellation, dependencies: dependencies)
        #expect(result.cancelled)
        #expect(result.tracks[0].end == 0)
    }

    @Test func longVideoReportsCoarseSamplingAndResourceLimitsFailExplicitly() async throws {
        let dependencies = PhraseTracker.Dependencies(recognize: { time in .init(time: time, lines: time == 0 ? [line(box)] : []) },
            follow: { _, end, boxes in .init(outcomes: boxes.map { .init(samples: [sample(end, $0)], lostTarget: false, cancelled: false) }) })
        let result = try await PhraseTracker.track(duration: 1200, phrases: ["blur1234"], cancellation: .init(), dependencies: dependencies)
        #expect(result.recognitionStep == 2)
        #expect(result.reviews.contains { $0.reason == .samplingGap && $0.start == 0 && $0.end == 2 })
        await #expect(throws: PhraseTracker.TrackError.self) {
            try await PhraseTracker.track(duration: PhraseTracker.maximumDuration + 1, phrases: ["blur1234"], cancellation: .init(), dependencies: dependencies)
        }
    }

    @Test func nativeOCRAndTrackingFollowMovingSyntheticTextAndDetectHardCut() async throws {
        let fixtures = VideoExportTests()
        let directory = try fixtures.directory()
        // Synthetic fixtures are retained in temporary storage; no originals are modified or deleted.
        let patch = directory.appendingPathComponent("phrase.png")
        let context = try #require(CGContext(data: nil, width: 300, height: 70, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(gray: 1, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: 300, height: 70))
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "BLUR 1234", attributes: [
            .font: NSFont.systemFont(ofSize: 44, weight: .bold), .foregroundColor: NSColor.black]))
        context.textPosition = CGPoint(x: 12, y: 18); CTLineDraw(line, context)
        let image = try #require(context.makeImage())
        let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try png.write(to: patch)
        let video = directory.appendingPathComponent("phrase-motion.mp4")
        try fixtures.ffmpeg(["-f", "lavfi", "-i", "color=c=0x202020:s=640x240:d=3:r=30",
            "-loop", "1", "-i", patch.path, "-filter_complex", "[0][1]overlay=x='20+t*40':y=80:shortest=1", "-t", "3",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", video.path])
        let before = try VideoProjectSourceBinding.Source.capture(video)
        let result = try await PhraseTracker.track(url: video, duration: 3, phrases: ["blur1234"], cancellation: .init(), progress: { _ in })
        #expect(!result.cancelled)
        let track = try #require(result.tracks.first)
        #expect(track.samples.count > 30, "Real Vision tracker supplies frame motion")
        let at2 = try #require(track.samples.min { abs($0.time - 2) < abs($1.time - 2) })
        #expect(at2.box.midX - track.samples[0].box.midX > 0.08)
        #expect(abs(at2.time - 2) < 0.05)
        #expect(try VideoProjectSourceBinding.Source.capture(video) == before)

        let cut = directory.appendingPathComponent("cut.mp4")
        try fixtures.ffmpeg(["-f", "lavfi", "-i", "color=black:s=320x180:d=0.5:r=30",
            "-f", "lavfi", "-i", "color=white:s=320x180:d=0.5:r=30",
            "-filter_complex", "[0][1]concat=n=2:v=1:a=0", "-c:v", "libx264", "-pix_fmt", "yuv420p", cut.path])
        let cuts = try await PhraseTracker.sceneCuts(url: cut, from: 0, until: 1, cancellation: .init())
        #expect(cuts.contains { abs($0 - 0.5) < 0.05 })

        // Reusing a streaming decoder must preserve each independently read interval,
        // including boundaries not aligned to source frames.
        let asset = VideoAssetPolicy.asset(url: cut)
        let videoTrack = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let flag = ObjectTracker.Cancellation()
        let scanner = try PhraseTracker.SceneCutScanner(asset: asset, track: videoTrack, cancellation: flag)
        for (start, end) in [(0.0, 0.35), (0.35, 0.7), (0.7, 1.0)] {
            let independent = try await PhraseTracker.sceneCuts(url: cut, from: start, until: end, cancellation: .init())
            #expect(try scanner.cuts(from: start, until: end) == independent)
        }
        #expect(throws: PhraseTracker.TrackError.self) { try scanner.cuts(from: 0, until: 0.3) }
        flag.cancel()
        #expect(throws: CancellationError.self) { try scanner.cuts(from: 1, until: 1.1) }

        // A late first detection or inactive gap must seek to its own interval,
        // rather than decoding all frames from zero/previousEnd.
        let motionAsset = VideoAssetPolicy.asset(url: video)
        let motionTrack = try #require(try await motionAsset.loadTracks(withMediaType: .video).first)
        let gapFlag = ObjectTracker.Cancellation()
        let gapScanner = try PhraseTracker.SceneCutScanner(asset: motionAsset, track: motionTrack, cancellation: gapFlag)
        _ = try gapScanner.cuts(from: 0, until: 0.2)
        for (start, end) in [(2.0, 2.3), (2.3, 2.6)] {
            let independent = try await PhraseTracker.sceneCuts(url: video, from: start, until: end, cancellation: .init())
            #expect(try gapScanner.cuts(from: start, until: end) == independent)
        }
        #expect(gapScanner.visitedFrameCount < 35, "Skipped gap must not be decoded")
        gapFlag.cancel()
        #expect(throws: CancellationError.self) { try gapScanner.cuts(from: 2.6, until: 2.9) }
        let lateScanner = try PhraseTracker.SceneCutScanner(asset: motionAsset, track: motionTrack, cancellation: .init())
        let lateCuts = try await PhraseTracker.sceneCuts(url: video, from: 2, until: 2.3, cancellation: .init())
        #expect(try lateScanner.cuts(from: 2, until: 2.3) == lateCuts)
        #expect(lateScanner.visitedFrameCount < 15, "Late first observation must seek")
    }
}
