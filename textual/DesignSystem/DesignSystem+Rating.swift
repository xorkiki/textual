import SwiftUI

/// Ratings use the supplied star silhouette, with a clipped fill for fractional values.
struct RatingView: View {
    let rating: Double
    let count: Int?

    init(rating: Double, count: Int? = nil) {
        self.rating = rating.isFinite ? min(5, max(0, rating)) : 0
        self.count = count
    }

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 2) {
                ForEach(0..<5, id: \.self) { index in
                    let fill = CGFloat(min(1, max(0, rating - Double(index))))
                    DesignSystemIconView(.star, size: TextualIconStyle.rating.size, color: .bloodletter)
                        .overlay(alignment: .leading) {
                            DesignSystemIconView(.starFilled, size: TextualIconStyle.rating.size, color: .bloodletter)
                                .mask(alignment: .leading) {
                                    Rectangle().frame(width: TextualIconStyle.rating.size * fill)
                                }
                        }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(rating.formatted()) out of 5 stars")
            if let count, count > 0 {
                Text("(\(count))").textStyle(.uiLabel).foregroundStyle(Color.ghost)
            }
        }
    }
}

/// Shared input: tap whole stars, then use the stepper for quarter stars.
struct RatingPicker: View {
    @Binding var rating: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: TextualLayout.itemGap) {
            HStack(spacing: 0) {
                ForEach(1...5, id: \.self) { star in
                    Button { rating = star * 4 } label: {
                        let fill = CGFloat(min(1, max(0, Double(rating ?? 0) / 4 - Double(star - 1))))
                        DesignSystemIconView(.star, size: TextualIconStyle.navigation.size, color: .bloodletter)
                            .overlay(alignment: .leading) {
                                DesignSystemIconView(.starFilled, size: TextualIconStyle.navigation.size, color: .bloodletter)
                                    .mask(alignment: .leading) {
                                        Rectangle().frame(width: TextualIconStyle.navigation.size * fill)
                                    }
                            }
                    }
                    .buttonStyle(IconButtonStyle())
                    .accessibilityLabel("Rate \(star) \(star == 1 ? "star" : "stars")")
                    .accessibilityIdentifier("review.star.\(star)")
                }
            }
            if let value = rating {
                HStack(spacing: 12) {
                    Text("\((Double(value) / 4).formatted()) out of 5")
                        .textStyle(.bodyMedium)
                    Spacer(minLength: 8)
                    adjustment("−", label: "Decrease rating by a quarter star", enabled: value > 0) {
                        rating = max(0, (rating ?? 0) - 1)
                    }
                    adjustment("+", label: "Increase rating by a quarter star", enabled: value < 20) {
                        rating = min(20, (rating ?? 0) + 1)
                    }
                }
                Button("Clear rating") { rating = nil }
                    .buttonStyle(TextualHeaderActionStyle())
            } else {
                Text("No rating yet").textStyle(.bodySmall).foregroundStyle(Color.ghost)
            }
        }
    }

    private func adjustment(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(symbol).font(.designSystem(.bodyMedium))
                .foregroundStyle(Color.paper)
                .frame(width: 44, height: 44)
                .background(Color.velvet, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(label)
    }

}
