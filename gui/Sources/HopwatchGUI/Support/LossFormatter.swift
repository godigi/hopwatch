import Foundation

/// Unified formatter for network packet loss figures.
///
/// Rules:
/// - If loss is 0 or negative (or nil): "0%" (or "0% packet loss" / "0% loss").
/// - If loss is below 1% (and > 0): displays with one decimal place, e.g. "0.3%",
///   so sub-1% packet loss is descriptive and not misleadingly rounded to "0%".
///   If `loss` rounds to 0.0%, displays "<0.1%" so non-zero loss is never shown as 0%.
/// - If loss is 1% or greater: displays integer percentage, e.g. "1%", "5%".
enum LossFormatter {

    /// Formats a packet loss percentage without label (e.g. "0%", "0.3%", "2%").
    static func formatPct(_ loss: Double?) -> String {
        guard let loss, loss > 0 else { return "0%" }
        if loss < 1.0 {
            let formatted = String(format: "%.1f%%", loss)
            if formatted == "0.0%" {
                return "<0.1%"
            }
            if formatted == "1.0%" {
                return "1%"
            }
            return formatted
        }
        return String(format: "%.0f%%", loss)
    }

    /// Formats a packet loss with "packet loss" suffix (e.g. "0% packet loss", "0.3% packet loss", "2% packet loss").
    static func formatPacketLoss(_ loss: Double?) -> String {
        "\(formatPct(loss)) packet loss"
    }

    /// Formats a packet loss with "loss" suffix (e.g. "0% loss", "0.3% loss", "2% loss").
    static func formatLoss(_ loss: Double?) -> String {
        "\(formatPct(loss)) loss"
    }
}
