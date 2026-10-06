import SwiftUI

struct StocksView: View {
    @EnvironmentObject var stocks: StockWatcher
    @Environment(\.dismiss) private var dismiss
    @State private var adding = false
    @State private var editing: StockWatch?

    var body: some View {
        NavigationStack {
            List {
                if stocks.watches.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "chart.line.uptrend.xyaxis").font(.system(size: 40)).foregroundStyle(.secondary)
                        Text("No stocks watched").font(.headline)
                        Text("Tap + to pick any stock and set its own trigger: how far it has to move from yesterday's close before BOT tells you. Tap a stock later to change its trigger.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 30)
                    .listRowBackground(Color.clear)
                } else {
                    Section {
                        ForEach(stocks.watches) { w in row(w) }
                    } footer: {
                        Text("Tap a stock to change its trigger. BOT checks about every 2 minutes while it is running and tells you once a day per stock. Turn on \"Speak alerts even in silent mode\" in Customize to keep checking with the app in the background (uses more battery). Prices come from Yahoo Finance and can be delayed up to 15 minutes.")
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
            .sheet(item: $editing) { AddStockView(editing: $0) }
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
        .contentShape(Rectangle())
        .onTapGesture { editing = w }
        .swipeActions { Button(role: .destructive) { stocks.remove(w) } label: { Label("Delete", systemImage: "trash") } }
    }

    /// 3 -> "3", 2.5 -> "2.5", 2.25 -> "2.25"
    static func trim(_ v: Double) -> String { String(format: "%g", v) }
}

/// Search for a company or ticker, then choose that stock's own trigger. Also edits an existing stock's trigger.
struct AddStockView: View {
    @EnvironmentObject var stocks: StockWatcher
    @Environment(\.dismiss) private var dismiss

    private let editing: StockWatch?
    @State private var query = ""
    @State private var results: [StockMatch] = []
    @State private var searching = false
    @State private var picked: StockMatch?
    @State private var percentText: String
    @State private var rising: Bool

    init(editing: StockWatch? = nil) {
        self.editing = editing
        _picked = State(initialValue: editing.map { StockMatch(symbol: $0.symbol, name: $0.name, exchange: "") })
        _percentText = State(initialValue: StocksView.trim(editing?.percent ?? 3))
        _rising = State(initialValue: editing?.rising ?? true)
    }

    private var percent: Double? {
        Double(percentText.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces))
            .flatMap { $0 > 0 && $0 <= 100 ? $0 : nil }
    }

    var body: some View {
        NavigationStack {
            Form {
                if editing == nil {
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
                                        Text(m.name + (m.exchange.isEmpty ? "" : " \u{00B7} \(m.exchange)"))
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
                }

                if let picked {
                    Section {
                        Picker("Tell me when it goes", selection: $rising) {
                            Text("Up").tag(true)
                            Text("Down").tag(false)
                        }
                        .pickerStyle(.segmented)
                        HStack {
                            Text("By")
                            TextField("3", text: $percentText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                            Text("%")
                        }
                        HStack(spacing: 8) {
                            ForEach([1.0, 2.0, 3.0, 5.0, 10.0], id: \.self) { v in
                                Button("\(StocksView.trim(v))%") { percentText = StocksView.trim(v) }
                                    .buttonStyle(.bordered)
                            }
                        }
                    } header: {
                        Text("\(picked.symbol) trigger")
                    } footer: {
                        Text("Each stock has its own trigger. With 3%, BOT announces this stock once it is 3% above (or below) yesterday's closing price. Type any number, such as 2.5.")
                    }
                }
            }
            .navigationTitle(editing == nil ? "Add stock" : "Edit trigger")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editing == nil ? "Add" : "Save") {
                        guard let picked, let percent else { return }
                        if let editing {
                            stocks.update(editing, percent: percent, rising: rising)
                        } else {
                            stocks.add(symbol: picked.symbol, name: picked.name, percent: percent, rising: rising)
                        }
                        dismiss()
                    }
                    .disabled(picked == nil || percent == nil)
                }
            }
            .task(id: query) {
                guard editing == nil else { return }
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
