import SwiftUI

struct StocksView: View {
    @EnvironmentObject var stocks: StockWatcher
    @Environment(\.dismiss) private var dismiss
    @State private var adding = false

    var body: some View {
        NavigationStack {
            List {
                if stocks.watches.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "chart.line.uptrend.xyaxis").font(.system(size: 40)).foregroundStyle(.secondary)
                        Text("No stocks watched").font(.headline)
                        Text("Tap + to pick any stock and set how far it has to move from yesterday's close before BOT tells you.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 30)
                    .listRowBackground(Color.clear)
                } else {
                    Section {
                        ForEach(stocks.watches) { w in row(w) }
                    } footer: {
                        Text("BOT checks about every 2 minutes while it is running and tells you once a day per stock. Turn on \"Speak alerts even in silent mode\" in Customize to keep checking with the app in the background (uses more battery). Prices come from Yahoo Finance and can be delayed up to 15 minutes.")
                    }
                }
            }
            .navigationTitle("Stock alerts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { adding = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add stock")
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(isPresented: $adding) { AddStockView() }
            .task { await stocks.refresh() }
            .refreshable { await stocks.refresh() }
        }
    }

    private func row(_ w: StockWatch) -> some View {
        let q = stocks.quotes[w.symbol]
        return HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(w.symbol).font(.body.weight(.semibold))
                Text(w.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text("Alert when \(w.rising ? "up" : "down") \(Self.trim(w.percent))% from yesterday")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let q {
                VStack(alignment: .trailing, spacing: 3) {
                    Text(String(format: "%.2f", q.price)).font(.body)
                    Text(String(format: "%+.2f%%", q.changePercent))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(q.changePercent >= 0 ? Color.green : Color.red)
                }
            }
        }
        .swipeActions { Button(role: .destructive) { stocks.remove(w) } label: { Label("Delete", systemImage: "trash") } }
    }

    static func trim(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }
}

/// Search for a company or ticker, then choose the trigger.
struct AddStockView: View {
    @EnvironmentObject var stocks: StockWatcher
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var results: [StockMatch] = []
    @State private var searching = false
    @State private var picked: StockMatch?
    @State private var percent = 3.0
    @State private var rising = true

    var body: some View {
        NavigationStack {
            Form {
                Section("Find a stock") {
                    TextField("Company or ticker (Apple, TSLA, SHOP.TO)", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if searching { ProgressView() }
                    ForEach(results) { m in
                        Button { picked = m } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(m.symbol).font(.body.weight(.semibold))
                                    Text(m.name + (m.exchange.isEmpty ? "" : " · \(m.exchange)"))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                if picked?.symbol == m.symbol { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                    if !searching, results.isEmpty, query.trimmingCharacters(in: .whitespaces).count >= 2 {
                        Text("No matches. Try the ticker symbol.").font(.subheadline).foregroundStyle(.secondary)
                    }
                }

                if let picked {
                    Section {
                        Picker("Tell me when it goes", selection: $rising) {
                            Text("Up").tag(true)
                            Text("Down").tag(false)
                        }
                        .pickerStyle(.segmented)
                        Stepper(value: $percent, in: 0.5...50, step: 0.5) {
                            Text("By \(StocksView.trim(percent))% from the previous close")
                        }
                    } header: {
                        Text(picked.symbol)
                    } footer: {
                        Text("Example: with 3%, BOT announces it once the stock is 3% above (or below) yesterday's closing price.")
                    }
                }
            }
            .navigationTitle("Add stock")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        if let picked {
                            stocks.add(symbol: picked.symbol, name: picked.name, percent: percent, rising: rising)
                            dismiss()
                        }
                    }
                    .disabled(picked == nil)
                }
            }
            .task(id: query) {
                let q = query.trimmingCharacters(in: .whitespaces)
                guard q.count >= 2 else { results = []; return }
                try? await Task.sleep(nanoseconds: 400_000_000)
                if Task.isCancelled { return }
                searching = true
                let found = await StockService.search(q)
                if Task.isCancelled { return }
                results = found
                searching = false
            }
        }
    }
}
