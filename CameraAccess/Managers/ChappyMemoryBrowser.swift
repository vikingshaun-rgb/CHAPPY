/*
 * ChappyMemoryBrowser — your life, scrollable and mapped
 *
 * ADDITIVE FILE. A standalone SwiftUI view. Overwrites nothing in
 * TurboMetaHomeView; present it from wherever the Records tab lives:
 *
 *     .sheet(isPresented: $showMemory) { ChappyMemoryBrowser() }
 *
 * PHASE 5 STEP 4, second half.
 *
 * ── WHAT IT IS ─────────────────────────────────────────────────────────
 * Everything Chappy has filed — photos, places, notes, conversations, scans,
 * routes, spend — browsable, searchable, mapped, and every item a card you can
 * navigate back to. Built entirely on what ChappyMemory already stores; it adds
 * no new data, only a way in.
 *
 * ── TWO-TIER SEARCH, AND WHY THE FAST TIER MATTERS MOST ────────────────
 * Typing filters the 30 hot days instantly, on-device, offline. That is the
 * tier that gets used, because it answers before you finish the word. Only if
 * you ask does it go to disk for the full history, on a background queue, with
 * a spinner — the ChappyMemory API already separates search() from
 * searchEverything() for exactly this reason.
 *
 * On a plane with no signal, the fast tier still works. That was one of the
 * Phase 5 audit checks and it falls out of the architecture rather than
 * needing anything special.
 *
 * ── EVERY MEMORY IS A PLACE ────────────────────────────────────────────
 * Entries already carry lat/lon, street and city captured at the moment of
 * filing, so the address is text stored at ingest rather than a geocode
 * performed later. It works offline forever, and "take me back" hands straight
 * to NavEngine with coordinates rather than a name to re-resolve.
 *
 * ── ONE DELIBERATE OMISSION ────────────────────────────────────────────
 * Pulse frames are filtered out of the default view and live behind their own
 * filter chip. A day at Dense tier can produce a hundred ambient captions, and
 * letting those bury the eight photos he actually chose to take would make the
 * browser useless on the first day it mattered.
 */

import SwiftUI
import MapKit
import CoreLocation

// MARK: -

struct ChappyMemoryBrowser: View {
    @Environment(\.dismiss) private var dismiss
    /// BUILD 226 — true only when presented as a sheet. This browser is
    /// the Memory TAB, and a tab has nothing to dismiss to, so it must
    /// not draw a Done button that can never work.
    var isModal: Bool = false
    @ObservedObject private var memory = ChappyMemory.shared

    @State private var query = ""
    @State private var category: Category = .all
    @State private var showingMap = false
    @State private var deepResults: [ChappyMemory.Entry]?
    @State private var searchingDisk = false
    @State private var selected: ChappyMemory.Entry?
    /// BUILD 221 — held rather than deleted immediately. A memory is not
    /// a to-do item; losing one to a stray thumb is not recoverable.
    @State private var pendingDelete: ChappyMemory.Entry?
    @State private var editing: ChappyMemory.Entry?

    /// BUILD 227 — HOW THE LIST IS CARVED UP.
    ///
    /// By day is a diary and by type is a mind, and both are the right
    /// answer to different questions. "What did I do Tuesday" wants
    /// days; "what do you know about me" wants types, and wading
    /// through three weeks of photographs to find a passport expiry is
    /// exactly the wall he described.
    ///
    /// So it is a switch, not a replacement. Remembered between
    /// launches, because whichever he prefers he will prefer every time.
    enum Grouping: String { case day, type }
    @AppStorage("chappy_memory_grouping") private var groupingRaw = Grouping.day.rawValue
    private var grouping: Grouping { Grouping(rawValue: groupingRaw) ?? .day }
    @State private var includePulse = false

    // MARK: Categories

    enum Category: String, CaseIterable, Identifiable {
        case all, places, photos, food, notes, talks, docs, spend
        var id: String { rawValue }

        var label: String {
            switch self {
            case .all: return "All";      case .places: return "Places"
            case .photos: return "Photos"; case .food: return "Food"
            case .notes: return "Notes";   case .talks: return "Talks"
            case .docs: return "Docs";     case .spend: return "Spend"
            }
        }

        var icon: String {
            switch self {
            case .all: return "square.grid.2x2";  case .places: return "mappin.and.ellipse"
            case .photos: return "photo";          case .food: return "fork.knife"
            case .notes: return "note.text";       case .talks: return "bubble.left.and.bubble.right"
            case .docs: return "doc.text.viewfinder"; case .spend: return "dollarsign.circle"
            }
        }

        func matches(_ e: ChappyMemory.Entry) -> Bool {
            switch self {
            case .all:    return true
            case .places: return e.kind == .place || e.kind == .route
            case .photos: return e.kind == .photo || e.kind == .video
            case .notes:  return e.kind == .note || e.kind == .ask
            case .talks:  return e.kind == .talk
            case .docs:   return e.kind == .scan
            case .spend:  return e.kind == .spend
            case .food:
                // No separate kind — food is a tag or a word, which is honest:
                // the caption call already writes what it saw.
                let t = (e.title + " " + e.body).lowercased()
                return e.tags.contains("food")
                    || ["cafe", "coffee", "restaurant", "warung", "meal", "lunch",
                        "dinner", "breakfast", "bar", "laksa", "noodle", "bakery"]
                        .contains { t.contains($0) }
            }
        }
    }

    // MARK: Filtering

    private var source: [ChappyMemory.Entry] { deepResults ?? memory.recent }

    private var filtered: [ChappyMemory.Entry] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        return source
            .filter { e in
                if e.kind == .day { return false }
                if !includePulse, e.tags.contains("pulse") { return false }
                guard category.matches(e) else { return false }
                guard !q.isEmpty else { return true }
                return (e.title + " " + e.body + " " + e.tags.joined(separator: " ")
                        + " " + (e.city ?? "") + " " + (e.place ?? ""))
                    .lowercased().contains(q)
            }
            .sorted { $0.at > $1.at }
    }

    private var mappable: [ChappyMemory.Entry] {
        filtered.filter { $0.lat != nil && $0.lon != nil }
    }

    // MARK: Body

    var body: some View {
        NavigationStack {
            Group {
                if showingMap { mapView } else { listView }
            }
            .navigationTitle("Memory")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "laksa, Kuta, that temple…")
            .toolbar {
                // BUILD 226 — A BUTTON THAT COULD NEVER WORK.
                //
                // This browser is presented as a TAB (MainTabView, tag 1)
                // and this calls @Environment(\.dismiss). In a tab there
                // is nothing to dismiss, so the button did precisely
                // nothing, for ever. It was written for the sheet
                // presentation described in this file's own header; the
                // tab came later and nobody removed it.
                if isModal {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Done") { dismiss() }
                    }
                }
                // BUILD 227 — day or type. Both are right, for different
                // questions, so it is a switch rather than a decision I
                // make on his behalf.
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Group by", selection: $groupingRaw) {
                            Label("By day", systemImage: "calendar")
                                .tag(Grouping.day.rawValue)
                            Label("By type", systemImage: "square.stack.3d.up")
                                .tag(Grouping.type.rawValue)
                        }
                    } label: {
                        Image(systemName: grouping == .type
                              ? "square.stack.3d.up.fill" : "calendar")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        withAnimation { showingMap.toggle() }
                    } label: {
                        Image(systemName: showingMap ? "list.bullet" : "map")
                    }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) { chips }
            .sheet(item: $selected) { BrowserMemoryCard(entry: $0) }
            .sheet(item: $editing) { e in
                BrowserMemoryEditor(entry: e) { ChappyMemory.shared.reload() }
            }
            .alert("Delete this memory?",
                   isPresented: Binding(get: { pendingDelete != nil },
                                        set: { if !$0 { pendingDelete = nil } })) {
                Button("Delete", role: .destructive) {
                    if let e = pendingDelete { ChappyMemory.shared.forget(id: e.id) }
                    pendingDelete = nil
                }
                Button("Keep it", role: .cancel) { pendingDelete = nil }
            } message: {
                Text(pendingDelete.map { "\($0.title)\n\nThis removes the entry and its photo. It cannot be undone." }
                     ?? "")
            }
        }
    }

    // MARK: Chips

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Category.allCases) { c in
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { category = c }
                    } label: {
                        Label(c.label, systemImage: c.icon)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 11).padding(.vertical, 7)
                            .background(category == c ? Color.accentColor.opacity(0.22)
                                                      : Color.secondary.opacity(0.12))
                            .foregroundStyle(category == c ? Color.accentColor : .secondary)
                            .clipShape(Capsule())
                    }
                }
                Divider().frame(height: 20)
                Button {
                    withAnimation { includePulse.toggle() }
                } label: {
                    Label("Ambient", systemImage: includePulse ? "eye" : "eye.slash")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 11).padding(.vertical, 7)
                        .background(includePulse ? Color.accentColor.opacity(0.22)
                                                 : Color.secondary.opacity(0.12))
                        .foregroundStyle(includePulse ? Color.accentColor : .secondary)
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .background(.bar)
    }

    // MARK: List

    /// BUILD 227 — one row definition, used by both groupings.
    ///
    /// It was inlined inside the day loop, so adding a second grouping
    /// would have meant a second copy of the swipe actions, the context
    /// menu and the tap handler — and two copies of an interaction are
    /// two things that drift apart.
    @ViewBuilder
    private func row(_ e: ChappyMemory.Entry) -> some View {
        BrowserMemoryRow(entry: e).onTapGesture { selected = e }
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) { pendingDelete = e } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            .swipeActions(edge: .leading) {
                Button { editing = e } label: { Label("Edit", systemImage: "pencil") }
                    .tint(.orange)
            }
            .contextMenu {
                Button { editing = e } label: {
                    Label("Correct this", systemImage: "pencil")
                }
                Button {
                    ChappyMemory.shared.setPinned(id: e.id, !e.pinned)
                } label: {
                    Label(e.pinned ? "Unpin" : "Keep for good",
                          systemImage: e.pinned ? "star.slash" : "star")
                }
                Divider()
                Button(role: .destructive) { pendingDelete = e } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
    }

    private var listView: some View {
        List {
            if filtered.isEmpty { emptyState }

            if grouping == .type {
                // BUILD 227 — carved by meaning. Heaviest types first,
                // so a deadline is never below a fortnight of photos.
                ForEach(groupedByType, id: \.0) { meaning, items in
                    Section {
                        ForEach(items) { e in row(e) }
                    } header: {
                        HStack(spacing: 6) {
                            Image(systemName: meaning.icon)
                                .font(.system(size: 10, weight: .semibold))
                            Text(meaning.label)
                            Spacer()
                            Text("\(items.count)")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .foregroundStyle(BrowserMemoryRow.tint(meaning))
                    }
                }
            } else {
            ForEach(grouped, id: \.0) { day, items in
                Section {
                    ForEach(items) { e in
                        BrowserMemoryRow(entry: e).onTapGesture { selected = e }
                            // BUILD 221 — the answer to "Chappy has this
                            // wrong" used to be: you can star it. Delete
                            // and edit both existed, in a screen that is
                            // not the one wired into this tab.
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    pendingDelete = e
                                } label: { Label("Delete", systemImage: "trash") }
                            }
                            .swipeActions(edge: .leading) {
                                Button {
                                    editing = e
                                } label: { Label("Edit", systemImage: "pencil") }
                                .tint(.orange)
                            }
                            // BUILD 226 — a swipe is not discoverable. He
                            // asked for a delete button, which means he
                            // went looking for one and there wasn't one.
                            // Long press puts the same three actions
                            // somewhere he can find them.
                            .contextMenu {
                                Button { editing = e } label: {
                                    Label("Correct this", systemImage: "pencil")
                                }
                                Button {
                                    ChappyMemory.shared.setPinned(id: e.id, !e.pinned)
                                } label: {
                                    Label(e.pinned ? "Unpin" : "Keep for good",
                                          systemImage: e.pinned ? "star.slash" : "star")
                                }
                                Divider()
                                Button(role: .destructive) { pendingDelete = e } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                } header: {
                    HStack {
                        Text(day)
                        if let s = summaryFor(items.first?.at) {
                            Spacer()
                            Text(s).font(.caption2).foregroundStyle(.secondary)
                                .lineLimit(1).frame(maxWidth: 200, alignment: .trailing)
                        }
                    }
                }
            }
            }

            if deepResults == nil, !query.isEmpty {
                Section {
                    Button {
                        searchEverywhere()
                    } label: {
                        HStack {
                            if searchingDisk { ProgressView().padding(.trailing, 6) }
                            else { Image(systemName: "clock.arrow.circlepath") }
                            Text(searchingDisk ? "Searching everything…"
                                               : "Search all of it, not just the last month")
                        }
                        .font(.footnote)
                    }
                    .disabled(searchingDisk)
                }
            }
            if deepResults != nil {
                Section {
                    Button("Back to recent") { deepResults = nil }
                        .font(.footnote)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var grouped: [(String, [ChappyMemory.Entry])] {
        let f = DateFormatter(); f.dateFormat = "EEEE d MMMM"
        let cal = Calendar.current
        var buckets: [String: [ChappyMemory.Entry]] = [:]
        var order: [String] = []
        for e in filtered {
            let key = cal.isDateInToday(e.at) ? "Today"
                    : cal.isDateInYesterday(e.at) ? "Yesterday"
                    : f.string(from: e.at)
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(e)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    /// BUILD 227 — the same memories, carved by MEANING.
    ///
    /// Ordered by the type's own standing weight rather than
    /// alphabetically or by count, so the things that matter sit at the
    /// top: what has a date on it, then who he is, then what he prefers,
    /// and the diary last. That ordering is the same one retrieval uses,
    /// which means the screen and the reasoning agree about what is
    /// important — they were two different opinions before.
    private var groupedByType: [(ChappyMemory.Semantic, [ChappyMemory.Entry])] {
        var buckets: [ChappyMemory.Semantic: [ChappyMemory.Entry]] = [:]
        for e in filtered { buckets[e.meaning, default: []].append(e) }
        return buckets
            .map { ($0.key, $0.value.sorted { $0.at > $1.at }) }
            .sorted { a, b in
                if a.0.baseWeight != b.0.baseWeight { return a.0.baseWeight > b.0.baseWeight }
                return a.1.count > b.1.count
            }
    }

    private func summaryFor(_ date: Date?) -> String? {
        guard let d = date else { return nil }
        return ChappyMemory.shared.summary(for: d)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "brain")
                .font(.system(size: 34)).foregroundStyle(.tertiary)
            Text(query.isEmpty ? "Nothing here yet." : "Nothing matching “\(query)”.")
                .font(.callout).foregroundStyle(.secondary)
            if query.isEmpty {
                Text("Take a photo, save a spot, or turn on ambient memory in Settings.")
                    .font(.caption).foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 46)
        .listRowSeparator(.hidden)
    }

    private func searchEverywhere() {
        searchingDisk = true
        let q = ChappyMemory.Query(text: query)
        ChappyMemory.shared.searchEverything(q) { hits in
            deepResults = hits
            searchingDisk = false
        }
    }

    // MARK: Map

    private var mapView: some View {
        Map {
            ForEach(mappable) { e in
                if let la = e.lat, let lo = e.lon {
                    Annotation(e.title,
                               coordinate: CLLocationCoordinate2D(latitude: la, longitude: lo)) {
                        Button { selected = e } label: {
                            Image(systemName: e.pinned ? "star.fill" : "mappin.circle.fill")
                                .font(.title3)
                                .foregroundStyle(e.pinned ? .yellow : .accentColor)
                                .background(Circle().fill(.background).padding(2))
                        }
                    }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if mappable.isEmpty {
                Text("Nothing with a location in this filter.")
                    .font(.caption).padding(9)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 22)
            }
        }
    }
}

// MARK: - Row

private struct BrowserMemoryRow: View {
    let entry: ChappyMemory.Entry

    var body: some View {
        HStack(spacing: 11) {
            thumb
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title).font(.callout).lineLimit(2)
                HStack(spacing: 6) {
                    // BUILD 226 — WHAT KIND OF THING IS THIS.
                    //
                    // Every row looked identical: grey thumbnail, a line
                    // of text, a time. A photo, a job from the calendar,
                    // a translated conversation and a saved place are
                    // four completely different things rendered the same
                    // way, which is why the list reads as a wall.
                    //
                    // Build 222 gave every memory a semantic type. This
                    // is that type as a coloured tag — what Google
                    // Photos, Apple's Journal and Samsung's gallery all
                    // do, for the same reason: colour is read before
                    // text.
                    Label(entry.meaning.label, systemImage: entry.meaning.icon)
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(Self.tint(entry.meaning).opacity(0.18), in: Capsule())
                        .foregroundStyle(Self.tint(entry.meaning))
                    Text(time).font(.caption2).foregroundStyle(.secondary)
                    if let where_ = place {
                        Text("·").font(.caption2).foregroundStyle(.tertiary)
                        Text(where_).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if entry.tags.contains("pulse") {
                        Text("ambient").font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer(minLength: 4)
            if entry.pinned {
                Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    /// One colour per kind of knowing. Warm for things about HIM, cool
    /// for things about the world, amber for anything with a date on it
    /// — so a deadline never hides in a row of photographs.
    static func tint(_ m: ChappyMemory.Semantic) -> Color {
        switch m {
        case .identity:      return .pink
        case .preference:    return .purple
        case .procedural:    return .indigo
        case .relational:    return .teal
        case .temporal:      return .orange
        case .project:       return .blue
        case .transactional: return .green
        case .affective:     return .yellow
        case .spatial:       return .mint
        case .semantic:      return .cyan
        case .episodic:      return .gray
        }
    }

    private var thumb: some View {
        Group {
            if let img = ChappyMemory.shared.thumbnail(for: entry.id) {
                // thumbnail(for:) returns a UIImage, already cached by
                // ChappyMemory's NSCache — no decode per row.
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                ZStack {
                    Color.secondary.opacity(0.12)
                    Image(systemName: entry.kind.icon)
                        .font(.system(size: 15)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var time: String {
        let f = DateFormatter(); f.dateFormat = "h:mm a"
        return f.string(from: entry.at)
    }

    private var place: String? {
        entry.place ?? entry.street ?? entry.city
    }
}

// MARK: - Detail card

private struct BrowserMemoryCard: View {
    let entry: ChappyMemory.Entry
    @Environment(\.dismiss) private var dismiss
    @State private var pinned: Bool

    init(entry: ChappyMemory.Entry) {
        self.entry = entry
        _pinned = State(initialValue: entry.pinned)
    }

    private var coord: CLLocationCoordinate2D? {
        guard let la = entry.lat, let lo = entry.lon else { return nil }
        return CLLocationCoordinate2D(latitude: la, longitude: lo)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {

                    if let img = ChappyMemory.shared.thumbnail(for: entry.id) {
                        Image(uiImage: img).resizable().scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }

                    Text(entry.title).font(.title3.weight(.semibold))
                    if !entry.body.isEmpty {
                        Text(entry.body).font(.callout).foregroundStyle(.secondary)
                    }

                    Label(fullWhen, systemImage: "clock")
                        .font(.footnote).foregroundStyle(.secondary)

                    // The address was stored as text at ingest, so this line
                    // works with no signal, forever.
                    if let addr = address {
                        Label(addr, systemImage: "mappin.and.ellipse")
                            .font(.footnote).foregroundStyle(.secondary)
                    }

                    if let c = coord {
                        Map(initialPosition: .region(MKCoordinateRegion(
                            center: c,
                            latitudinalMeters: 400, longitudinalMeters: 400))) {
                            Marker(entry.title, coordinate: c)
                        }
                        .frame(height: 170)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .allowsHitTesting(false)

                        Button {
                            Task {
                                dismiss()
                                _ = await NavEngine.shared.navigate(to: entry.title, driving: false)
                            }
                        } label: {
                            Label("Take me back", systemImage: "location.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            openInGoogleMaps(c)
                        } label: {
                            Label("Open in Google Maps", systemImage: "map")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)

                        Button {
                            share(c)
                        } label: {
                            Label("Share this pin", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }

                    if !nearby.isEmpty {
                        Divider()
                        Text("You've been here before")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(nearby) { n in
                            HStack(spacing: 8) {
                                Image(systemName: n.kind.icon)
                                    .font(.caption).foregroundStyle(.tertiary)
                                Text(n.title).font(.footnote).lineLimit(1)
                                Spacer()
                                Text(shortDate(n.at)).font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                .padding(18)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        pinned.toggle()
                        ChappyMemory.shared.setPinned(id: entry.id, pinned)
                    } label: {
                        Image(systemName: pinned ? "star.fill" : "star")
                            .foregroundStyle(pinned ? .yellow : .secondary)
                    }
                }
            }
        }
    }

    private var fullWhen: String {
        let f = DateFormatter(); f.dateFormat = "EEEE d MMMM yyyy, h:mm a"
        return f.string(from: entry.at)
    }

    private var address: String? {
        let bits = [entry.place, entry.street, entry.city, entry.country]
            .compactMap { $0 }.filter { !$0.isEmpty }
        return bits.isEmpty ? nil : bits.joined(separator: ", ")
    }

    /// Anything else filed within 200 m — the cross-link that turns a list into
    /// a history of a place.
    private var nearby: [ChappyMemory.Entry] {
        guard let la = entry.lat, let lo = entry.lon else { return [] }
        let here = CLLocation(latitude: la, longitude: lo)
        return ChappyMemory.shared.recent
            .filter { other in
                guard other.id != entry.id, other.kind != .day else { return false }
                guard let ola = other.lat, let olo = other.lon else { return false }
                return here.distance(from: CLLocation(latitude: ola, longitude: olo)) < 200
            }
            .sorted { $0.at > $1.at }
            .prefix(5).map { $0 }
    }

    private func shortDate(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "d MMM"
        return f.string(from: d)
    }

    private func openInGoogleMaps(_ c: CLLocationCoordinate2D) {
        let g = URL(string: "comgooglemaps://?q=\(c.latitude),\(c.longitude)&zoom=17")!
        let web = URL(string: "https://maps.google.com/?q=\(c.latitude),\(c.longitude)")!
        UIApplication.shared.open(UIApplication.shared.canOpenURL(g) ? g : web)
    }

    private func share(_ c: CLLocationCoordinate2D) {
        let text = "\(entry.title)\nhttps://maps.google.com/?q=\(c.latitude),\(c.longitude)"
        let av = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first?.rootViewController?
            .presentedViewController?.present(av, animated: true)
    }
}


// =====================================================================
// BUILD 221 — CORRECTING A MEMORY.
//
// Editing was title-only, in a screen that is not the one wired into
// the Memory tab. So a wrong BODY — the transcript, the note, the part
// that actually holds the content — could not be fixed at all, and the
// only correction available anywhere was renaming the label on top of
// it.
//
// A memory you cannot correct is one you eventually stop trusting, and
// an assistant reasoning from memories its owner has stopped trusting
// is worse than one with no memory at all.
//
// Correcting the title or body SUPERSEDES rather than overwrites, so
// the earlier version keeps its dates and the change lands in the
// audit trail. Tags and pinning are plain edits — those are labels on
// a memory rather than claims about the world.
// =====================================================================

struct BrowserMemoryEditor: View {
    @Environment(\.dismiss) private var dismiss
    let entry: ChappyMemory.Entry
    var onSave: () -> Void = {}

    @State private var title: String
    @State private var body_: String
    @State private var tagText: String
    @State private var pinned: Bool

    init(entry: ChappyMemory.Entry, onSave: @escaping () -> Void = {}) {
        self.entry = entry
        self.onSave = onSave
        _title = State(initialValue: entry.title)
        _body_ = State(initialValue: entry.body)
        _tagText = State(initialValue: entry.tags.joined(separator: ", "))
        _pinned = State(initialValue: entry.pinned)
    }

    private var changedClaim: Bool {
        title != entry.title || body_ != entry.body
    }

    var body: some View {
        NavigationView {
            Form {
                Section("What it says") {
                    TextField("Title", text: $title, axis: .vertical)
                        .lineLimit(1...3)
                    TextField("Detail", text: $body_, axis: .vertical)
                        .lineLimit(3...12)
                }

                Section {
                    TextField("Comma separated", text: $tagText)
                    Toggle("Keep this one for good", isOn: $pinned)
                } header: {
                    Text("Tags")
                } footer: {
                    Text("Pinned memories survive every sweep and every prune.")
                }

                Section {
                    // BUILD 222 — what kind of thing Chappy thinks this
                    // is, which decides how long it stays relevant and
                    // how highly it ranks when something is asked.
                    HStack {
                        Label(entry.meaning.label, systemImage: entry.meaning.icon)
                            .font(.footnote)
                        Spacer()
                        Text(entry.semantic == nil ? "worked out" : "recorded")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(entry.provenanceLine.prefix(1).uppercased() + entry.provenanceLine.dropFirst())
                        .font(.footnote)
                    if !entry.source.isEmpty {
                        Text("Recorded by: \(entry.source)")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let sup = entry.supersededAt {
                        Text("Replaced on \(sup.formatted(date: .abbreviated, time: .shortened))")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                } header: {
                    Text("Where this came from")
                } footer: {
                    Text(changedClaim
                         ? "Changing the words writes a new version. The old one is kept with the date it stopped being true, so nothing is lost."
                         : "Tags and pinning are labels — changing them doesn't create a new version.")
                }
            }
            .navigationTitle("Correct this")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func save() {
        let m = ChappyMemory.shared
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)

        if changedClaim {
            // A claim about the world changed — keep the old one.
            m.supersede(entry.id, with: t, body: body_, origin: .told, confidence: 1.0)
        }

        let tags = tagText.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        if tags != entry.tags {
            for tag in tags where !entry.tags.contains(tag) {
                m.addTag(id: entry.id, tag)
            }
        }
        if pinned != entry.pinned { m.setPinned(id: entry.id, pinned) }

        onSave()
        dismiss()
    }
}
