import Foundation

/// One LLM call recorded in a conversation SQLite database (`gen_metadata` row).
public struct GenStepModel: Sendable, Equatable {
    public let inputTokens: Int
    public let cacheReadTokens: Int
    public let modelName: String?

    public init(inputTokens: Int, cacheReadTokens: Int, modelName: String?) {
        self.inputTokens = inputTokens
        self.cacheReadTokens = cacheReadTokens
        self.modelName = modelName
    }
}

/// Matches transcript `PLANNER_RESPONSE` steps with the per-call rows from the sibling SQLite database.
///
/// Older transcripts have no `model` field, but the SQLite database records the exact model of every
/// LLM call. Both sources list calls in the same order, so we walk them in lockstep, comparing input and
/// cache-read token counts. A short look-ahead absorbs rows that exist on only one side, and a small
/// tolerance absorbs minor counter drift between the two sources.
public enum StepModelAligner {
    /// How many rows past the cursor are inspected when the next row does not match.
    static let lookahead = 3

    public static func align(steps: [(Int, Int)], rows: [GenStepModel]) -> [String?] {
        var result = [String?](repeating: nil, count: steps.count)
        var cursor = 0

        for (index, step) in steps.enumerated() {
            guard cursor < rows.count else { break }
            let upper = min(rows.count, cursor + lookahead + 1)
            if let match = (cursor..<upper).first(where: { matches(step, rows[$0]) }) {
                result[index] = rows[match].modelName
                cursor = match + 1
            }
        }
        return result
    }

    static func matches(_ step: (Int, Int), _ row: GenStepModel) -> Bool {
        let difference = abs(step.0 - row.inputTokens) + abs(step.1 - row.cacheReadTokens)
        let tolerance = max(2, (step.0 + step.1) / 50)
        return difference <= tolerance
    }
}
