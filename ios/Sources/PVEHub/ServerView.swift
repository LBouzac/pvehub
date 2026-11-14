import SwiftUI
import Charts

// MARK: - Graphiques
struct Series {
    let name: String
    let color: Color
    let value: (J) -> Double?
}
let cpuSeries = Series(name: "CPU", color: .orange) { r in r.cpu.opt.map { $0 * 100 } }
let memSeries = Series(name: "Mémoire", color: .blue) { r in
    guard let m = r.mem.opt ?? r.memused.opt, let t = r.maxmem.opt ?? r.memtotal.opt, t > 0 else { return nil }
    return min(100, m / t * 100)
}
let netSeries = [Series(name: "Entrant", color: .green) { $0.netin.opt }, Series(name: "Sortant", color: .orange) { $0.netout.opt }]

struct UsageChart: View {
    let rows: [J]
    let series: [Series]
    var maxY: Double? = nil
    var unit: (Double) -> String = { p0($0) + " %" }

    private struct Point: Identifiable {
        let id: String
        let t: Date
        let v: Double
        let s: String
    }

    var body: some View {
        let pts = rows.filter { r in series.contains { $0.value(r)?.isFinite == true } }
        let points = series.flatMap { s in
            pts.enumerated().map { i, r in Point(id: "\(s.name)\(i)", t: date(r.time.num), v: s.value(r) ?? 0, s: s.name) }
        }
        let top = maxY ?? max(1, (points.map(\.v).max() ?? 1) * 1.15)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                ForEach(series, id: \.name) { s in
                    HStack(spacing: 4) { RoundedRectangle(cornerRadius: 2).fill(s.color).frame(width: 10, height: 10); Text(s.name) }
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            if pts.count < 2 {
                Text("Pas encore de données").font(.footnote).foregroundStyle(.secondary).frame(height: 110)
            } else {
                Chart(points) { p in
                    LineMark(x: .value("Heure", p.t), y: .value(p.s, min(p.v, top)), series: .value("Série", p.s))
                        .foregroundStyle(series.first { $0.name == p.s }?.color ?? .accentColor)
                        .interpolationMethod(.monotone)
                }
                .chartYScale(domain: 0...top)
                .chartYAxis {
                    AxisMarks(values: [0, top / 2, top]) { v in
                        AxisGridLine()
                        AxisValueLabel { if let d = v.as(Double.self) { Text(unit(d)) } }
                    }
                }
                .frame(height: 110)
            }
        }
        .padding(.vertical, 4)
    }
}

let TFS: [(String, String)] = [("hour", "1 h"), ("day", "24 h"), ("week", "7 j"), ("month", "30 j")]
struct TimeframePicker: View {
    @AppStorage("tf") private var tf = "hour"
    var body: some View {
        Picker("Période", selection: $tf) { ForEach(TFS, id: \.0) { Text($0.1).tag($0.0) } }
            .pickerStyle(.segmented)
    }
}

// MARK: - Serveur
struct ServerView: View {
    @EnvironmentObject var hub: Hub
    @AppStorage("tf") private var tf = "hour"
    @State private var nodeRrd: [String: [J]] = [:]

    private var nodes: [J] { hub.ov?.nodes.arr ?? [] }
    private var real: [J] { hub.guests.filter { !$0.template.bool } }
    private var storages: [J] { (hub.ov?.storage.arr ?? []).filter { $0.status.str == "available" && $0.maxdisk.num > 0 } }

    var body: some View {
        NavigationStack(path: $hub.serverPath) {
            List {
                if hub.ver?.available.bool == true { updateBanner }
                Section { tiles }.listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                Section {
                    NavigationLink(value: Route.maint) {
                        HStack(spacing: 12) {
                            IconBox(symbol: "wrench.and.screwdriver.fill", color: .orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Maintenance")
                                Text(hub.maintSummary).font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if hub.maintAlert { Circle().fill(.orange).frame(width: 9, height: 9) }
                        }
                    }
                    NavigationLink(value: Route.journal("")) {
                        LinkRow(symbol: "bell.fill", color: .red, title: "Journal", subtitle: "Alertes, connexions et actions")
                    }
                    NavigationLink(value: Route.sched) {
                        LinkRow(symbol: "power", color: .indigo, title: "Horaires", subtitle: schedSubtitle)
                    }
                }
                ForEach(nodes) { n in nodeSection(n) }
                if !storages.isEmpty {
                    Section("Stockage") {
                        ForEach(storages) { s in
                            MeterRow(title: s.storage.str + (nodes.count > 1 ? " · \(s.node.str)" : ""),
                                     detail: "\(fb(s.disk.num)) / \(fb(s.maxdisk.num))", value: pct(s.disk.num, s.maxdisk.num))
                        }
                    }
                }
                activeSection
            }
            .navigationTitle("Serveur")
            .hubToolbar()
            .navigationDestination(for: Route.self) { destination($0) }
            .refreshable { await hub.refresh(); await loadCharts() }
            .task(id: tf) {  // graphiques : toutes les minutes, et à chaque changement de période
                while !Task.isCancelled {
                    await loadCharts()
                    try? await Task.sleep(for: .seconds(60))
                }
            }
        }
    }

    private var schedSubtitle: String {
        guard let s = hub.sched, !s.isEmpty else { return "Allumer ou éteindre des machines à heure fixe" }
        let on = s.filter { $0.enabled.bool }.count
        return "\(on) actif\(on > 1 ? "s" : "") sur \(s.count)"
    }

    private func loadCharts() async {
        for n in nodes {
            if let r = try? await API.shared.get("/api/rrd", ["node": n.node.str, "tf": tf]) { nodeRrd[n.node.str] = r.data.arr }
        }
    }

    private var updateBanner: some View {
        Section {
            Button {
                if hub.ver?.can_update.bool == true { Task { await hub.doUpdate() } } else { hub.showSettings = true }
            } label: {
                LinkRow(symbol: "arrow.down.circle.fill", color: .accentColor, title: "Mise à jour disponible",
                        subtitle: hub.ver?.can_update.bool == true ? "Touche pour installer la nouvelle version" : hub.ver?.why_not.str ?? "")
            }
            .foregroundStyle(.primary)
        }
    }

    private var tiles: some View {
        let run = real.filter { $0.status.str == "running" }.count
        let cpuW = nodes.reduce(0.0) { $0 + $1.cpu.num * max(1, $1.maxcpu.num) }
        let cpuT = max(1, nodes.reduce(0.0) { $0 + max(1, $1.maxcpu.num) })
        let cpu = cpuW / cpuT * 100
        let mem = pct(nodes.reduce(0.0) { $0 + $1.mem.num }, nodes.reduce(0.0) { $0 + $1.maxmem.num })
        let st: Double? = storages.isEmpty ? nil : pct(storages.reduce(0.0) { $0 + $1.disk.num }, storages.reduce(0.0) { $0 + $1.maxdisk.num })
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            Button { hub.tab = .guests } label: {
                Tile(symbol: "play.fill", color: .green, title: "Actives", value: "\(run)", unit: " / \(real.count)", bar: nil)
            }
            .buttonStyle(.plain)
            Tile(symbol: "cpu", color: .orange, title: "CPU", value: p0(cpu), unit: " %", bar: cpu)
            Tile(symbol: "memorychip", color: .blue, title: "Mémoire", value: p0(mem), unit: " %", bar: mem)
            Tile(symbol: "internaldrive", color: .purple, title: "Stockage", value: st.map(p0) ?? "–", unit: " %", bar: st)
        }
    }

    private func nodeSection(_ n: J) -> some View {
        let c = n.cpu.num * 100
        return Section("Nœud \(n.node.str)") {
            HStack {
                StatusDot(status: n.status.str)
                Text(STATUS[n.status.str] ?? n.status.str)
                Spacer()
                if n.status.str == "online" { Text("depuis \(up(n.uptime.num))").foregroundStyle(.secondary) }
            }
            MeterRow(title: "Processeur", detail: "\(p0(c)) % · \(n.maxcpu.int) cœurs", value: c)
            MeterRow(title: "Mémoire", detail: "\(fb(n.mem.num)) / \(fb(n.maxmem.num))", value: pct(n.mem.num, n.maxmem.num))
            MeterRow(title: "Disque système", detail: "\(fb(n.disk.num)) / \(fb(n.maxdisk.num))", value: pct(n.disk.num, n.maxdisk.num))
            VStack(spacing: 10) {
                TimeframePicker()
                UsageChart(rows: nodeRrd[n.node.str] ?? [], series: [cpuSeries, memSeries], maxY: 100)
            }
        }
    }

    private var activeSection: some View {
        let act = real.filter { $0.status.str == "running" }.sorted { $0.cpu.num > $1.cpu.num }.prefix(6)
        return Section("Machines actives") {
            if act.isEmpty { Text("Aucune machine allumée").foregroundStyle(.secondary) }
            ForEach(Array(act)) { g in
                NavigationLink(value: Route.guest(g.id)) {
                    HStack {
                        StatusDot(status: "running")
                        Text(g.name.str.isEmpty ? g.vmid.str : g.name.str).lineLimit(1)
                        Spacer()
                        Text("\(kind(g.type.str)) \(g.vmid.str) · CPU \(p0(g.cpu.num * 100)) %").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct Tile: View {
    let symbol: String
    let color: Color
    let title: String
    let value: String
    let unit: String
    let bar: Double?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).font(.subheadline.weight(.semibold)).foregroundStyle(color)
            (Text(value).font(.title.bold()) + Text(unit).font(.headline).foregroundColor(.secondary))
            if let bar { UsageBar(value: bar) } else { Spacer(minLength: 4) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct LinkRow: View {
    let symbol: String
    let color: Color
    let title: String
    var subtitle: String = ""
    var body: some View {
        HStack(spacing: 12) {
            IconBox(symbol: symbol, color: color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if !subtitle.isEmpty { Text(subtitle).font(.subheadline).foregroundStyle(.secondary) }
            }
        }
    }
}
