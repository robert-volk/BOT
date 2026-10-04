import SwiftUI

/// The text BOT is saying. If it's taller than the box, it scrolls along with the voice, word by word.
/// Outside of speech it's an ordinary scroll view you can drag.
struct CaptionView: View {
    let text: String
    let font: Font
    let color: Color
    let following: Bool            // true while BOT is speaking
    @ObservedObject var speaker: Speaker

    private let slices = 60        // invisible markers along the text that we scroll to

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                Text(text)
                    .font(font)
                    .foregroundStyle(color)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .overlay {
                        GeometryReader { g in
                            VStack(spacing: 0) {
                                ForEach(0..<slices, id: \.self) { i in
                                    Color.clear
                                        .frame(height: g.size.height / CGFloat(slices))
                                        .id(i)
                                }
                            }
                        }
                    }
            }
            .frame(minHeight: 70, maxHeight: 150)
            .onChange(of: speaker.spokenChars) { _, chars in
                guard following else { return }
                let fraction = Double(chars) / Double(max(text.count, chars, 1))
                let slice = min(slices - 1, max(0, Int(fraction * Double(slices))))
                withAnimation(.linear(duration: 0.35)) {
                    proxy.scrollTo(slice, anchor: UnitPoint(x: 0.5, y: 0.4))
                }
            }
            .onChange(of: text) { _, _ in
                // A new reply starts at the top.
                if !following || speaker.spokenChars < 5 { proxy.scrollTo(0, anchor: .top) }
            }
        }
    }
}
