#if os(macOS)
import AppKit
import SwiftUI
import Testing
import LibraryCore
@testable import PlayerUI

@Suite(.serialized) @MainActor struct SourceListLayoutTests {
    private func track(_ path: String) -> LibraryTrack {
        LibraryTrack(name: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
                     reference: TrackReference(bookmark: nil, lastKnownURL: URL(fileURLWithPath: path)), registration: .folder)
    }
    private let width = 360, height = 300

    /// Renders the list on black and returns the bitmap, also written for review when asked.
    private func render(query: String, selecting: Bool = false, snapshot: String) throws -> NSBitmapImageRep {
        let tracks = (1...4).map { track("/Music/Alpha/\($0).wav") } + (1...3).map { track("/Music/Beta/\($0).mp3") }
        let selection = Binding<Set<UUID>>(get: { [tracks[0].id] }, set: { _ in })
        let root = SourceFolderList(tracks: tracks, unavailable: [:], query: query, selection: selecting ? selection : nil, select: { _ in })
            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.85)).frame(width: CGFloat(width), height: CGFloat(height), alignment: .topLeading)
            .background(Color.black).preferredColorScheme(.dark)
        let host = NSHostingView(rootView: root); host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host; host.layoutSubtreeIfNeeded()
        defer { window.contentView = nil }
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        if let directory = ProcessInfo.processInfo.environment["LCMP_UI_SNAPSHOTS"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try #require(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent(snapshot))
        }
        return rep
    }
    /// The free width, in points, between the rightmost lit pixel and the right edge.
    private func rightMargin(_ rep: NSBitmapImageRep) -> CGFloat {
        let scale = CGFloat(rep.pixelsWide) / CGFloat(width)
        for x in stride(from: rep.pixelsWide - 1, through: 0, by: -1) {
            for y in 0..<rep.pixelsHigh {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                // Raw components: converting to sRGB dims faint colors below the threshold.
                if max(color.redComponent, color.greenComponent, color.blueComponent) > 0.2 {
                    return CGFloat(rep.pixelsWide - 1 - x) / scale
                }
            }
        }
        return CGFloat(width)
    }

    /// The right edge, in points, of each row's trash glyph: the group row is 24pt high and each
    /// track row below it 40pt. Lit columns of a row form runs; the chevron is the last run of a
    /// track row, and the trash the run before it.
    private func trashEdges(_ rep: NSBitmapImageRep, tracks: Int) -> [Int] {
        let scale = rep.pixelsWide / width
        let bands = [0..<24] + (0..<tracks).map { 24 + 40 * $0 ..< 24 + 40 * ($0 + 1) }
        return bands.enumerated().map { index, band in
            let lit = (0..<width).filter { x in
                band.contains { y in
                    (0..<scale).contains { d in
                        rep.colorAt(x: x * scale + d, y: y * scale + d).map { max($0.redComponent, $0.greenComponent, $0.blueComponent) > 0.2 } ?? false
                    }
                }
            }
            var runs: [ClosedRange<Int>] = []
            for x in lit {
                if let last = runs.last, x - last.upperBound <= 2 { runs[runs.count - 1] = last.lowerBound...x } else { runs.append(x...x) }
            }
            if index > 0 { runs.removeLast() }
            return runs.last?.upperBound ?? -1
        }
    }
    /// The overlay scroller of macOS draws a thin knob but takes clicks across its whole width at
    /// the right edge. The trash buttons stay clear of it: with only group rows shown, the rightmost
    /// thing drawn is a trash glyph, which sits 6pt inside its 24pt button.
    @Test func trashButtonsStayClearOfTheScroller() throws {
        let scroller = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay)
        let groups = try render(query: "", snapshot: "source-trash-groups.png")
        #expect(rightMargin(groups) - 6 >= scroller, "group rows leave \(rightMargin(groups))pt for a \(scroller)pt scroller")
        // Track rows put their own trash in the same column, with the chevron after it, still clear of the scroller.
        let open = try render(query: "wav", snapshot: "source-trash-tracks.png")
        let edges = trashEdges(open, tracks: 4)
        #expect(Set(edges).count == 1, "trash edges \(edges)")
        #expect(rightMargin(open) >= scroller, "track rows leave \(rightMargin(open))pt for a \(scroller)pt scroller")
        _ = try render(query: "", selecting: true, snapshot: "source-selection.png")
        _ = try render(query: "wav", selecting: true, snapshot: "source-selection-open.png")
    }
}
#endif
