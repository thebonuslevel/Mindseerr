import SwiftUI

/// The Rotten Tomatoes scores on a detail page: the critics' score and, for movies, the audience score.
struct RottenTomatoesScores: View {
    let rating: RottenTomatoesRating

    var body: some View {
        HStack(spacing: 28) {
            if let score = rating.criticsScore {
                // 60% and up is "fresh" (a tomato); below that is "rotten" (the green splat).
                scoreView(icon: score >= 60 ? "🍅" : "🤢", score: score, label: rating.criticsRating ?? (score >= 60 ? "Fresh" : "Rotten"),
                          caption: "Tomatometer")
            }
            if let score = rating.audienceScore {
                scoreView(icon: "🍿", score: score, label: rating.audienceRating ?? (score >= 60 ? "Upright" : "Spilled"),
                          caption: "Audience")
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func scoreView(icon: String, score: Int, label: String, caption: String) -> some View {
        HStack(spacing: 10) {
            Text(icon).font(.title3)
            Text("\(score)%").font(.headline).monospacedDigit()
            VStack(alignment: .leading, spacing: 0) {
                Text(label).font(.caption).fontWeight(.semibold)
                Text(caption).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
