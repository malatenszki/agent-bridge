import Foundation

/// Detects confirmation prompts in terminal output
final class PromptDetector: Sendable {
    /// Patterns that indicate a confirmation prompt
    private let patterns: [NSRegularExpression] = {
        let patternStrings = [
            // Yes/No patterns
            #"\[y/n\]"#,
            #"\[Y/n\]"#,
            #"\[y/N\]"#,
            #"\[yes/no\]"#,
            #"\(y/n\)"#,
            #"\(Y/n\)"#,
            #"\(y/N\)"#,
            #"yes or no"#,

            // Question patterns
            #"Proceed\?"#,
            #"Continue\?"#,
            #"Are you sure"#,
            #"Do you want to"#,
            #"Would you like to"#,
            #"Confirm\?"#,
            #"Overwrite\?"#,
            #"Delete\?"#,
            #"Remove\?"#,
            #"Replace\?"#,

            // Claude Code specific patterns
            #"Do you want to proceed"#,
            #"Allow this action"#,
            #"Grant permission"#,
            #"Approve this"#,

            // Generic input request patterns
            #"Press enter to continue"#,
            #"Press any key"#,
            #"Hit enter"#,
            #"Type .+ to confirm"#,
        ]

        return patternStrings.compactMap { pattern in
            try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        }
    }()

    /// Additional simple string matches (faster than regex)
    private let simpleMatches: Set<String> = [
        "[y/n]",
        "[Y/n]",
        "[y/N]",
        "(y/n)",
        "(Y/n)",
        "(y/N)",
        "?",
    ]

    /// Characters that typically end a prompt line
    private let promptEndChars: Set<Character> = ["?", ":", ">"]

    /// Detect if the given text contains a confirmation prompt
    /// Focuses on the last few lines of output where prompts typically appear
    func detectPrompt(in text: String) -> Bool {
        // Get the last portion of text (prompts are at the end)
        let lines = text.components(separatedBy: .newlines)
        let recentLines = lines.suffix(5).joined(separator: "\n")

        // Quick check: does it end with a prompt character?
        let trimmed = recentLines.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let lastChar = trimmed.last,
              promptEndChars.contains(lastChar) || !trimmed.hasSuffix("\n") else {
            return false
        }

        // Check simple string matches first (faster)
        let lowercased = recentLines.lowercased()
        for match in simpleMatches {
            if lowercased.contains(match) {
                return true
            }
        }

        // Check regex patterns
        let range = NSRange(recentLines.startIndex..., in: recentLines)
        for pattern in patterns {
            if pattern.firstMatch(in: recentLines, options: [], range: range) != nil {
                return true
            }
        }

        return false
    }

    /// Analyze the prompt to determine what kind of response is expected
    func analyzePrompt(in text: String) -> PromptType {
        let lowercased = text.lowercased()

        // Check for yes/no patterns
        if lowercased.contains("[y/n]") ||
           lowercased.contains("(y/n)") ||
           lowercased.contains("yes or no") ||
           lowercased.contains("yes/no") {
            return .yesNo
        }

        // Check for confirmation patterns
        if lowercased.contains("proceed") ||
           lowercased.contains("continue") ||
           lowercased.contains("are you sure") ||
           lowercased.contains("confirm") {
            return .confirmation
        }

        // Check for enter-to-continue
        if lowercased.contains("press enter") ||
           lowercased.contains("press any key") ||
           lowercased.contains("hit enter") {
            return .enterToContinue
        }

        return .freeform
    }
}

/// Type of prompt detected
enum PromptType: String, Codable, Sendable {
    case yesNo
    case confirmation
    case enterToContinue
    case freeform
}
