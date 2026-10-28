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

    private let tracks = (1...4).map { LibraryTrack(name: "\($0)", reference: TrackReference(bookmark: nil, lastKnownURL: URL(fileURLWithPath: "/Music/Alpha/\($0).wav")), registration: .folder) }
        + (1...3).map { LibraryTrack(name: "\($0)", reference: TrackReference(bookmark: nil, lastKnownURL: URL(fileURLWithPath: "/Music/Beta/\($0).mp3")), registration: .folder) }

    /// Renders the list on black and returns the bitmap, also written for review when asked.
    private func render(query: String, selecting: Bool = false, marks: SourceMarks = SourceMarks(), snapshot: String) throws -> NSBitmapImageRep {
        let tracks = tracks
        let selection = Binding<Set<UUID>>(get: { [tracks[0].id] }, set: { _ in })
        let root = SourceFolderList(tracks: tracks, unavailable: [:], query: query, selection: selecting ? selection : nil, marks: marks, select: { _ in })
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
    /// The second line of a row tells how many playlists hold the track and marks a duplicate in amber.
    @Test func rowsMarkPlaylistMembershipAndDuplicates() throws {
        let marks = SourceMarks(memberships: [tracks[0].id: 2, tracks[1].id: 1], duplicates: [tracks[1].id])
        let plain = try render(query: "alpha", snapshot: "source-unmarked.png")
        let marked = try render(query: "alpha", marks: marks, snapshot: "source-marks.png")
        let scale = marked.pixelsWide / width
        /// Lit pixels and amber pixels in the second line of a track row, right of the format.
        func count(_ rep: NSBitmapImageRep, row: Int) -> (lit: Int, amber: Int) {
            var lit = 0, amber = 0
            for y in (24 + 40 * row + 22) * scale ..< (24 + 40 * row + 36) * scale {
                for x in 60 * scale ..< 160 * scale {
                    guard let c = rep.colorAt(x: x, y: y) else { continue }
                    if max(c.redComponent, c.greenComponent, c.blueComponent) > 0.2 { lit += 1 }
                    if c.redComponent > 0.5 && c.redComponent - c.blueComponent > 0.25 { amber += 1 }
                }
            }
            return (lit, amber)
        }
        #expect(count(plain, row: 0).lit == 0 && count(plain, row: 1).lit == 0)
        #expect(count(marked, row: 0).lit > 20 && count(marked, row: 0).amber == 0)
        #expect(count(marked, row: 1).amber > 20)
        #expect(count(marked, row: 2).lit == 0)
    }

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

    /// The search and selection buttons light like the shuffle LED while their mode is on.
    @Test func searchAndSelectionButtonsLightLikeLEDs() throws {
        func litPixels(_ isOn: Bool, _ symbol: String) throws -> Int {
            let root = LEDToggle(symbol: symbol, label: symbol, isOn: isOn, action: {}).padding(8).background(Color.black)
            let host = NSHostingView(rootView: root); host.frame = NSRect(x: 0, y: 0, width: 48, height: 32)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host; host.layoutSubtreeIfNeeded()
            defer { window.contentView = nil }
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            if let directory = ProcessInfo.processInfo.environment["LCMP_UI_SNAPSHOTS"] {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                try #require(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("led-\(symbol)-\(isOn ? "on" : "off").png"))
            }
            var count = 0
            for x in 0..<rep.pixelsWide { for y in 0..<rep.pixelsHigh {
                // Raw components, as in the shuffle test: green clearly above red and blue.
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                if c.greenComponent > 0.6, c.greenComponent - c.redComponent > 0.15, c.greenComponent - c.blueComponent > 0.08 { count += 1 }
            } }
            return count
        }
        for symbol in ["magnifyingglass", "checkmark.circle"] {
            #expect(try litPixels(false, symbol) == 0, "\(symbol) is lit while off")
            #expect(try litPixels(true, symbol) > 20, "\(symbol) is dark while on")
        }
    }
}
#endif
