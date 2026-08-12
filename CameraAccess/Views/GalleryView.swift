/*
 * Gallery View
 *
 * BUILD 155 — RESURRECTED. The old Gallery was a shell from the original
 * project: its load function was an empty TODO, so the tab showed
 * "No photos yet" forever while the real photos sat in memory. Now it is
 * what the tab always claimed to be: every snap, burst, clip and scan
 * Chappy has ever kept, straight from the memory brain, in an Apple
 * Photos style grid — newest first, play badges on clips, tap to
 * enlarge with the caption.
 */

import SwiftUI

struct GalleryView: View {

    @ObservedObject private var memory = ChappyMemory.shared
    @AppStorage("chappy_theme") private var themeName = "Midnight Jade"
    private var theme: ChappyTheme { ChappyTheme.named(themeName) }

    @State private var filter: Filter = .all
    @State private var selected: ChappyMemory.Entry?

    enum Filter: String, CaseIterable {
        case all = "All", photos = "Photos", clips = "Clips", scans = "Scans"
        func matches(_ e: ChappyMemory.Entry) -> Bool {
            switch self {
            case .all:    return e.kind == .photo || e.kind == .video || e.kind == .scan
            case .photos: return e.kind == .photo
            case .clips:  return e.kind == .video
            case .scans:  return e.kind == .scan
            }
        }
    }

    private var items: [ChappyMemory.Entry] {
        memory.recent
            .filter { filter.matches($0) }
            .filter { ChappyMemory.shared.thumbnail(for: $0.id) != nil }
            .sorted { $0.at > $1.at }
    }

    private let columns = [GridItem(.flexible(), spacing: 3),
                           GridItem(.flexible(), spacing: 3),
                           GridItem(.flexible(), spacing: 3)]

    var body: some View {
        NavigationView {
            ZStack {
                AuroraBackdrop(theme: theme)
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        ForEach(Filter.allCases, id: \.rawValue) { f in
                            Button {
                                withAnimation(.easeInOut(duration: 0.15)) { filter = f }
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            } label: {
                                Text(f.rawValue)
                                    .font(.footnote).fontWeight(.semibold)
                                    .padding(.horizontal, 14).padding(.vertical, 7)
                                    .background(Capsule().fill(filter == f
                                        ? theme.accent.opacity(0.25) : Color.white.opacity(0.06)))
                                    .foregroundColor(filter == f ? theme.accent : theme.textSecondary)
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)

                    if items.isEmpty {
                        Spacer()
                        VStack(spacing: 14) {
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.system(size: 52))
                                .foregroundColor(theme.textSecondary.opacity(0.6))
                            Text(emptyLine)
                                .font(.subheadline)
                                .foregroundColor(theme.textSecondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 40)
                        }
                        Spacer()
                    } else {
                        ScrollView(showsIndicators: false) {
                            LazyVGrid(columns: columns, spacing: 3) {
                                ForEach(items) { e in
                                    GalleryCell(entry: e)
                                        .onTapGesture {
                                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                            selected = e
                                        }
                                }
                            }
                            .padding(3)
                        }
                    }
                }
            }
            .navigationTitle("Gallery")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $selected) { e in
                GalleryDetail(entry: e, theme: theme)
            }
        }
    }

    private var emptyLine: String {
        switch filter {
        case .all:    return "Snaps, bursts, clips and scans land here.\nSay \u{201C}take a photo\u{201D} or hold the Snap button."
        case .photos: return "No photos yet — say \u{201C}take a photo\u{201D}, or hold Snap for a burst."
        case .clips:  return "No clips yet — say \u{201C}record a clip\u{201D} or tap Video on Home."
        case .scans:  return "No scans yet — say \u{201C}read this\u{201D} or \u{201C}scan this\u{201D}."
        }
    }
}

// MARK: - Grid cell

private struct GalleryCell: View {
    let entry: ChappyMemory.Entry

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                if let img = ChappyMemory.shared.thumbnail(for: entry.id) {
                    Image(uiImage: img)
                        .resizable().scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.width)
                        .clipped()
                }
                if entry.kind == .video {
                    Image(systemName: "play.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.9))
                        .shadow(radius: 3)
                        .padding(6)
                } else if entry.kind == .scan {
                    Image(systemName: "doc.text.fill")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                        .shadow(radius: 3)
                        .padding(6)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

// MARK: - Detail viewer

private struct GalleryDetail: View {
    let entry: ChappyMemory.Entry
    let theme: ChappyTheme
    @Environment(\.dismiss) private var dismiss
    @State private var zoom: CGFloat = 1

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer()
                if let img = ChappyMemory.shared.thumbnail(for: entry.id) {
                    Image(uiImage: img)
                        .resizable().scaledToFit()
                        .scaleEffect(zoom)
                        .gesture(MagnificationGesture()
                            .onChanged { zoom = max(1, min($0, 5)) }
                            .onEnded { _ in withAnimation(.spring()) { zoom = 1 } })
                }
                Spacer()
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: entry.kind == .video ? "video.fill"
                                        : entry.kind == .scan ? "doc.text.fill" : "camera.fill")
                            .font(.caption).foregroundColor(theme.accent)
                        Text(Self.stamp(entry.at))
                            .font(.caption).foregroundColor(.white.opacity(0.65))
                        Spacer()
                    }
                    if !entry.title.isEmpty {
                        Text(entry.title)
                            .font(.subheadline)
                            .foregroundColor(.white)
                    }
                    if let spot = entry.place ?? entry.street ?? entry.city {
                        Label(spot, systemImage: "mappin")
                            .font(.caption).foregroundColor(.white.opacity(0.65))
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.ultraThinMaterial)
            }
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(14)
            }
        }
    }

    private static func stamp(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "EEEE d MMMM · h:mm a"
        return f.string(from: d)
    }
}

// MARK: - Legacy model kept for compatibility

struct GalleryPhoto: Identifiable {
    let id = UUID()
    let image: UIImage?
    let date: Date
}
