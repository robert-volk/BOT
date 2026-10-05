import SwiftUI
import MapKit
import Charts
import WebKit

/// Shows whatever BOT was asked to display.
struct VisualSheet: View {
    let visual: Visual
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(visual.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch visual {
        case .images(_, let images):
            ImagePager(images: images)
        case .map(let title, let coordinate):
            Map(initialPosition: .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 3000, longitudinalMeters: 3000))) {
                Marker(title, coordinate: coordinate)
            }
            .ignoresSafeArea(edges: .bottom)
        case .forecast(_, let days, let metric):
            ForecastChart(days: days, metric: metric)
        case .diagram(_, let svg):
            SVGView(svg: svg)
        }
    }
}

struct ImagePager: View {
    let images: [WebImage]

    var body: some View {
        TabView {
            ForEach(images) { image in
                VStack(spacing: 10) {
                    AsyncImage(url: image.thumbURL) { phase in
                        switch phase {
                        case .success(let picture):
                            picture.resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 12))
                        case .failure:
                            VStack { Image(systemName: "photo").font(.largeTitle); Text("Couldn't load this one").font(.caption) }
                                .foregroundStyle(.secondary)
                        default:
                            ProgressView()
                        }
                    }
                    .frame(maxHeight: .infinity)
                    Text(image.title).font(.headline).multilineTextAlignment(.center).lineLimit(2)
                    Text(image.credit).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if let page = image.pageURL { Link("View source", destination: page).font(.footnote) }
                }
                .padding(.horizontal)
                .padding(.bottom, 40)
            }
        }
        .tabViewStyle(.page)
    }
}

struct ForecastChart: View {
    let days: [WeatherService.DayForecast]
    let metric: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Daily high and low (\u{00B0}\(metric ? "C" : "F"))").font(.headline)
                Chart(days) { d in
                    BarMark(x: .value("Day", d.date, unit: .day), yStart: .value("Low", d.low), yEnd: .value("High", d.high))
                        .foregroundStyle(LinearGradient(colors: [.blue, .orange], startPoint: .bottom, endPoint: .top))
                        .annotation(position: .top) { Text("\(Int(d.high.rounded()))\u{00B0}").font(.caption2) }
                        .annotation(position: .bottom) { Text("\(Int(d.low.rounded()))\u{00B0}").font(.caption2) }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.abbreviated)) }
                }
                .frame(height: 280)

                Text("Chance of rain or snow (%)").font(.headline)
                Chart(days) { d in
                    BarMark(x: .value("Day", d.date, unit: .day), y: .value("Chance", d.rain))
                        .foregroundStyle(Color.cyan)
                        .annotation(position: .top) { Text("\(Int(d.rain))").font(.caption2) }
                }
                .chartYScale(domain: 0...100)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.abbreviated)) }
                }
                .frame(height: 200)
            }
            .padding()
        }
    }
}

/// Displays an SVG drawing. JavaScript is off and nothing outside the drawing is loaded.
struct SVGView: UIViewRepresentable {
    let svg: String

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .white
        web.scrollView.backgroundColor = .white
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        let html = "<html><head><meta name='viewport' content='width=device-width, initial-scale=1'>"
            + "<style>body{margin:0;background:#fff} svg{width:100vw;height:auto;display:block}</style></head><body>"
            + svg + "</body></html>"
        web.loadHTMLString(html, baseURL: nil)
    }
}
