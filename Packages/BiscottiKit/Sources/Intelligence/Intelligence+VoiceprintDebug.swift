#if DEBUG

    import DataStore
    import Foundation
    import VoiceprintMatching

    // MARK: - Debug Report Model

    public struct VoiceprintDebugReport: Sendable, Equatable {
        public struct Candidate: Sendable, Equatable, Identifiable {
            public let id: UUID
            public let name: String
            public let email: String?
            public let score: Float
            public let distance: Float
            public let countedMeetings: Int
            public let confirmedMeetings: Int
            public let invited: Bool
        }

        public struct Neighbor: Sendable, Equatable, Identifiable {
            public let id: Int
            public let meetingTitle: String
            public let meetingDate: Date
            public let speakerID: Int
            public let personName: String?
            public let confirmed: Bool?
            public let distance: Float
            public let insideRadius: Bool
            public let speakingDuration: Double
        }

        public let speakerID: Int
        public let kind: VoiceprintKind
        public let space: String?
        public let corpusVoiceprints: Int
        public let corpusMeetings: Int
        public let hasVoiceprint: Bool
        public let level: MatchLevel?
        public let candidates: [Candidate]
        public let neighbors: [Neighbor]
        public let llmBlock: String
        public let errorMessage: String?

        public init(
            speakerID: Int, kind: VoiceprintKind, space: String?,
            corpusVoiceprints: Int, corpusMeetings: Int,
            hasVoiceprint: Bool, level: MatchLevel?,
            candidates: [Candidate], neighbors: [Neighbor],
            llmBlock: String, errorMessage: String?
        ) {
            self.speakerID = speakerID
            self.kind = kind
            self.space = space
            self.corpusVoiceprints = corpusVoiceprints
            self.corpusMeetings = corpusMeetings
            self.hasVoiceprint = hasVoiceprint
            self.level = level
            self.candidates = candidates
            self.neighbors = neighbors
            self.llmBlock = llmBlock
            self.errorMessage = errorMessage
        }
    }

    // MARK: - Intelligence Extension

    public extension Intelligence {
        func voiceprintDebug(
            meetingID: UUID, transcriptID: UUID,
            speakerID: Int, kind: VoiceprintKind
        ) async -> VoiceprintDebugReport {
            do {
                guard let detail = try await store.meetingDetail(id: meetingID),
                      let transcript = try await store.transcript(id: transcriptID)
                else {
                    return emptyDebugReport(
                        speakerID: speakerID, kind: kind,
                        error: "Meeting or transcript not found"
                    )
                }

                let human = await (try? store.humanSetSpeakerMappings(for: transcriptID)) ?? [:]

                let evidence = try await VoiceprintEvidence.compute(
                    store: store, meetingID: meetingID,
                    transcript: transcript, detail: detail,
                    human: human, kind: kind
                )

                let hasVoiceprint = evidence.queryVectors[speakerID] != nil
                var level: MatchLevel?
                var debugCandidates: [VoiceprintDebugReport.Candidate] = []
                var debugNeighbors: [VoiceprintDebugReport.Neighbor] = []

                if let vector = evidence.queryVectors[speakerID] {
                    let matcher = VoiceprintMatcher()
                    let explanation = matcher.explain(
                        vector: vector, speakerID: speakerID,
                        corpus: evidence.corpus, invitees: evidence.invitees
                    )
                    level = explanation.match.level
                    debugCandidates = buildDebugCandidates(
                        from: explanation, people: evidence.corpus.people
                    )
                    debugNeighbors = buildDebugNeighbors(
                        from: explanation, people: evidence.corpus.people
                    )
                }

                let space = evidence.corpus.space.isEmpty ? nil : evidence.corpus.space
                return VoiceprintDebugReport(
                    speakerID: speakerID, kind: kind, space: space,
                    corpusVoiceprints: evidence.corpus.entryCount,
                    corpusMeetings: evidence.corpus.history.meetingCount,
                    hasVoiceprint: hasVoiceprint, level: level,
                    candidates: debugCandidates, neighbors: debugNeighbors,
                    llmBlock: evidence.block, errorMessage: nil
                )
            } catch {
                return emptyDebugReport(
                    speakerID: speakerID, kind: kind,
                    error: error.localizedDescription
                )
            }
        }

        private func buildDebugCandidates(
            from explanation: SpeakerExplanation,
            people: [UUID: PersonData]
        ) -> [VoiceprintDebugReport.Candidate] {
            explanation.allCandidates.map { candidate in
                let person = people[candidate.personID]
                return VoiceprintDebugReport.Candidate(
                    id: candidate.personID,
                    name: person?.name ?? "Unknown",
                    email: person?.email,
                    score: candidate.score,
                    distance: candidate.reportedDistance,
                    countedMeetings: candidate.countedMeetings,
                    confirmedMeetings: candidate.confirmedCountedMeetings,
                    invited: candidate.isInvitee
                )
            }
        }

        private func buildDebugNeighbors(
            from explanation: SpeakerExplanation,
            people: [UUID: PersonData]
        ) -> [VoiceprintDebugReport.Neighbor] {
            explanation.nearest.enumerated().map { rank, neighbor in
                let personName: String?
                let confirmed: Bool?
                if let tag = neighbor.tag,
                   let person = people[tag.personID]
                {
                    personName = person.name
                    confirmed = tag.userSet
                } else {
                    personName = nil
                    confirmed = nil
                }
                return VoiceprintDebugReport.Neighbor(
                    id: rank,
                    meetingTitle: neighbor.meetingTitle,
                    meetingDate: neighbor.meetingDate,
                    speakerID: neighbor.speakerID,
                    personName: personName,
                    confirmed: confirmed,
                    distance: neighbor.distance,
                    insideRadius: neighbor.insideRadius,
                    speakingDuration: neighbor.speakingDuration
                )
            }
        }

        private func emptyDebugReport(
            speakerID: Int, kind: VoiceprintKind, error: String
        ) -> VoiceprintDebugReport {
            VoiceprintDebugReport(
                speakerID: speakerID, kind: kind, space: nil,
                corpusVoiceprints: 0, corpusMeetings: 0,
                hasVoiceprint: false, level: nil,
                candidates: [], neighbors: [],
                llmBlock: "", errorMessage: error
            )
        }
    }

#endif
