import Foundation
import OSLog

/// Fetches lyrics for a track from lrclib.net — a free, no-auth,
/// community-maintained lyrics database that hosts both plain text
/// and time-synced LRC format. Used to drive the DJ commentary so the
/// coach can roast the specific line being sung right now rather than
/// just the song title.
///
/// API: https://lrclib.net/docs
///   GET /api/get?track_name=...[&artist_name=...&album_name=...&duration=...]
///     200 → { plainLyrics, syncedLyrics, instrumental, ... }
///     404 → not found (params too strict, or genuinely missing)
///   GET /api/search?track_name=...   → array of candidates
///
/// Fallback ladder (each step only runs if previous returned no lyrics):
///   1. Strict get: first artist + title + album + duration
///   2. Loose get:  first artist + title (drop album & duration)
///   3. Normalize title (strip "- Remastered", "(feat. X)", etc.) and retry
///   4. /search by title alone — catches covers and odd artist spellings;
///      pick the candidate closest to the original duration that actually
///      has lyrics.
///
/// LRC format (per line):
///   [mm:ss.xx] Lyric text
///   [mm:ss.xx][mm:ss.yy] Repeated line       (multiple timestamps)
///   [ar:Artist] / [ti:Title] / etc.           (metadata, ignored)
actor LyricsClient {
    static let shared = LyricsClient()

    struct Track: Hashable, Sendable {
        let artist: String
        let title: String
        let album: String?
        /// In seconds; helps LRCLib disambiguate cover versions.
        let durationSeconds: Int?
    }

    struct SyncedLine: Sendable, Hashable {
        let timestamp: TimeInterval
        let text: String
    }

    enum Lyrics: Sendable {
        case synced(lines: [SyncedLine])
        case unsynced(lines: [String])
        case instrumental
        case notFound
        case error(String)
    }

    /// Keyed by lowercased "<artist>|<title>" so trivial casing diffs
    /// don't re-hit the network. Only positive results are cached —
    /// .notFound and .error always retry so a transient miss doesn't
    /// poison the rest of the song.
    private var cache: [String: Lyrics] = [:]
    private let log = Logger(subsystem: "club.aarun.AARC", category: "LyricsClient")

    func fetch(track: Track) async -> Lyrics {
        let key = cacheKey(for: track)
        if let cached = cache[key], cached.isPositive { return cached }

        let firstArtist = Self.firstArtist(track.artist)
        let normalizedTitle = Self.normalizeTitle(track.title)
        var sawInstrumental = false

        func consider(_ wire: Wire?) -> Lyrics? {
            guard let wire else { return nil }
            if wire.instrumental == true {
                sawInstrumental = true
                return nil
            }
            if let synced = wire.syncedLyrics, !synced.isEmpty {
                let parsed = Self.parseLRC(synced)
                if !parsed.isEmpty { return .synced(lines: parsed) }
            }
            if let plain = wire.plainLyrics, !plain.isEmpty {
                let lines = Self.splitPlainLyrics(plain)
                if !lines.isEmpty { return .unsynced(lines: lines) }
            }
            return nil
        }

        // 1. Strict get — what the original commit did.
        if let l = consider(await getExact(
            artist: firstArtist,
            title: track.title,
            album: track.album,
            duration: track.durationSeconds
        )) {
            cache[key] = l
            return l
        }

        // 2. Loose get — drop album + duration. Spotify often serves
        //    deluxe editions / region releases whose album names don't
        //    match LRCLib's primary entry.
        if let l = consider(await getExact(
            artist: firstArtist,
            title: track.title,
            album: nil,
            duration: nil
        )) {
            cache[key] = l
            return l
        }

        // 3. Normalized title — strips "- Remastered 2011", "(feat. X)",
        //    "- Acoustic", etc. that Spotify appends. Skip if already
        //    identical.
        if normalizedTitle != track.title {
            if let l = consider(await getExact(
                artist: firstArtist,
                title: normalizedTitle,
                album: nil,
                duration: nil
            )) {
                cache[key] = l
                return l
            }
            // 3b. Normalized title without artist either — catches the
            // case where the artist string on Spotify ("Beyoncé, Jay-Z")
            // doesn't match LRCLib's primary entry.
            if let l = consider(await getExact(
                artist: nil,
                title: normalizedTitle,
                album: nil,
                duration: nil
            )) {
                cache[key] = l
                return l
            }
        }

        // 4. Search by title alone — returns ranked array, often picks
        //    up covers + obscure entries the exact-match endpoint misses.
        //    We pre-rank by duration closeness so a 4-minute cover doesn't
        //    win when the original is 4:30.
        let candidates = await searchByTitle(normalizedTitle, durationHint: track.durationSeconds)
        for hit in candidates.prefix(8) {
            if let l = consider(hit) {
                cache[key] = l
                return l
            }
        }

        // Truly nothing. If we saw an instrumental entry along the way,
        // report that explicitly so the coach skips politely rather than
        // re-trying as if it were a transient miss. Don't cache it
        // either — the user might switch to a non-instrumental edit.
        return sawInstrumental ? .instrumental : .notFound
    }

    private func cacheKey(for track: Track) -> String {
        "\(track.artist.lowercased())|\(track.title.lowercased())"
    }

    // MARK: - HTTP

    private func getExact(
        artist: String?,
        title: String,
        album: String?,
        duration: Int?
    ) async -> Wire? {
        var comps = URLComponents(string: "https://lrclib.net/api/get")!
        var items: [URLQueryItem] = [URLQueryItem(name: "track_name", value: title)]
        if let artist, !artist.isEmpty {
            items.append(URLQueryItem(name: "artist_name", value: artist))
        }
        if let album, !album.isEmpty {
            items.append(URLQueryItem(name: "album_name", value: album))
        }
        if let duration {
            items.append(URLQueryItem(name: "duration", value: String(duration)))
        }
        comps.queryItems = items
        guard let url = comps.url else { return nil }
        return await fetchWire(at: url)
    }

    private func searchByTitle(_ title: String, durationHint: Int?) async -> [Wire] {
        var comps = URLComponents(string: "https://lrclib.net/api/search")!
        comps.queryItems = [URLQueryItem(name: "track_name", value: title)]
        guard let url = comps.url else { return [] }

        var req = URLRequest(url: url)
        req.setValue("AARC/0.1 (https://aarun.club)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 8

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else { return [] }
            var hits = try JSONDecoder().decode([Wire].self, from: data)
            if let hint = durationHint {
                let hintD = Double(hint)
                hits.sort { a, b in
                    let da = abs((a.duration ?? 0) - hintD)
                    let db = abs((b.duration ?? 0) - hintD)
                    if da != db { return da < db }
                    let aSynced = !(a.syncedLyrics ?? "").isEmpty
                    let bSynced = !(b.syncedLyrics ?? "").isEmpty
                    if aSynced != bSynced { return aSynced }
                    let aPlain = !(a.plainLyrics ?? "").isEmpty
                    let bPlain = !(b.plainLyrics ?? "").isEmpty
                    return aPlain && !bPlain
                }
            } else {
                hits.sort { a, b in
                    let aSynced = !(a.syncedLyrics ?? "").isEmpty
                    let bSynced = !(b.syncedLyrics ?? "").isEmpty
                    return aSynced && !bSynced
                }
            }
            log.info("LRCLib search \"\(title, privacy: .public)\" → \(hits.count, privacy: .public) hits")
            return hits
        } catch {
            log.info("LRCLib search error: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private func fetchWire(at url: URL) async -> Wire? {
        var req = URLRequest(url: url)
        req.setValue("AARC/0.1 (https://aarun.club)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 8
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { return nil }
            if http.statusCode == 404 { return nil }
            guard (200...299).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
                log.info("LRCLib get non-200 \(http.statusCode, privacy: .public) body=\(body, privacy: .public)")
                return nil
            }
            return try JSONDecoder().decode(Wire.self, from: data)
        } catch {
            log.info("LRCLib get error: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Title / artist normalization

    private static func firstArtist(_ artist: String) -> String {
        // Spotify joins multiple artists with ", " — LRCLib expects a
        // single artist (primary). Take everything before the first
        // separator we recognise.
        let separators: [Character] = [",", "&", ";"]
        for sep in separators {
            if let idx = artist.firstIndex(of: sep) {
                return String(artist[..<idx]).trimmingCharacters(in: .whitespaces)
            }
        }
        return artist.trimmingCharacters(in: .whitespaces)
    }

    /// Strips Spotify suffixes that LRCLib's primary entry doesn't have.
    /// Examples handled:
    ///   "Bohemian Rhapsody - Remastered 2011"          → "Bohemian Rhapsody"
    ///   "Shake It Off (feat. Bleachers)"                → "Shake It Off"
    ///   "Levitating - Acoustic"                         → "Levitating"
    ///   "Lose Yourself - From '8 Mile' Soundtrack"      → "Lose Yourself"
    ///   "Hey Jude - Mono Version"                       → "Hey Jude"
    static func normalizeTitle(_ raw: String) -> String {
        var s = raw
        let dashPatterns: [String] = [
            #" - Remaster(ed)?( Version)?( \d{4})?$"#,
            #" - \d{4} Remaster(ed)?( Version)?$"#,
            #" - Live( at .+)?( \d{4})?$"#,
            #" - Acoustic( Version)?$"#,
            #" - Radio Edit$"#,
            #" - Single Version$"#,
            #" - Mono( Version)?$"#,
            #" - Stereo( Version)?$"#,
            #" - From .+$"#,
            #" - Original .+$"#,
            #" - Extended( Mix| Version)?$"#,
            #" - Edit$"#,
            #" - Demo$"#,
            #" - Bonus Track$"#,
        ]
        for pat in dashPatterns {
            if let r = s.range(of: pat, options: [.regularExpression, .caseInsensitive]) {
                s.removeSubrange(r)
            }
        }
        let parenPatterns: [String] = [
            #" \(feat\.? [^)]+\)"#,
            #" \(featuring [^)]+\)"#,
            #" \(with [^)]+\)"#,
            #" \(ft\.? [^)]+\)"#,
            #" \(prod\.? [^)]+\)"#,
            #" \(Remaster(ed)?( \d{4})?\)"#,
            #" \(Live( at .+)?\)"#,
            #" \(Acoustic( Version)?\)"#,
            #" \(Radio Edit\)"#,
            #" \(Single Version\)"#,
            #" \(Mono( Version)?\)"#,
            #" \(Bonus Track\)"#,
        ]
        for pat in parenPatterns {
            while let r = s.range(of: pat, options: [.regularExpression, .caseInsensitive]) {
                s.removeSubrange(r)
            }
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Pick a line of lyrics appropriate to roast right now. For synced
    /// lyrics this is the line being sung at `progressSec` (or just
    /// before — we accept up to ~10s of lag). For unsynced lyrics it
    /// returns a stable line based on a hash of the track + a rotation
    /// counter so multiple riffs on the same song hit different lines.
    func pickLine(
        for track: Track,
        lyrics: Lyrics,
        progressSec: TimeInterval?,
        rotation: Int = 0
    ) -> Selection? {
        switch lyrics {
        case .synced(let lines):
            guard !lines.isEmpty else { return nil }
            guard let progress = progressSec else {
                let idx = abs(rotation) % lines.count
                return contextSelection(lines: lines.map(\.text), index: idx)
            }
            // Pick the most recent line whose timestamp <= progress.
            var chosenIndex: Int = 0
            var found = false
            for (i, line) in lines.enumerated() {
                if line.timestamp <= progress + 1.5 { // allow ~1.5s look-ahead grace
                    chosenIndex = i
                    found = true
                } else {
                    break
                }
            }
            if !found {
                // We're earlier than the very first line — pick line 0.
                chosenIndex = 0
            }
            return contextSelection(lines: lines.map(\.text), index: chosenIndex)

        case .unsynced(let lines):
            guard !lines.isEmpty else { return nil }
            // No timing info — rotate through the song. Hash of title +
            // rotation lets us pick something stable but different each
            // riff so the same song doesn't get the same line twice.
            let idx = abs(track.title.hashValue &+ rotation) % lines.count
            return contextSelection(lines: lines, index: idx)

        case .instrumental, .notFound, .error:
            return nil
        }
    }

    struct Selection: Sendable {
        /// The single line the DJ should roast.
        let line: String
        /// The 2-3 lines around it, including the chosen line, for the
        /// LLM's situational context.
        let context: [String]
        /// "en" | "zh" — the only two we ship in this commit.
        let language: String
    }

    private func contextSelection(lines: [String], index: Int) -> Selection? {
        let pick = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pick.isEmpty else { return nil }
        guard let language = detectLanguage(pick) else { return nil }
        let lo = max(0, index - 1)
        let hi = min(lines.count - 1, index + 1)
        let context = Array(lines[lo...hi])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Selection(line: pick, context: context, language: language)
    }

    /// Returns "en", "zh", or nil (skip). We're deliberately narrow per
    /// product spec — Spanish/Japanese/etc. tracks are ignored for now.
    private func detectLanguage(_ text: String) -> String? {
        // Han characters → Chinese.
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) {
                return "zh"
            }
        }
        // Strip whitespace/punctuation and check if the remaining
        // characters are dominated by basic Latin letters.
        var letters = 0
        var nonLatin = 0
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if (0x0041...0x005A).contains(v) || (0x0061...0x007A).contains(v) {
                letters += 1
            } else if v > 0x007F && !scalar.properties.isWhitespace {
                // Non-ASCII letter — could be French accent etc. We're
                // conservative: a handful of accents is fine, but if the
                // line is dominated by non-Latin, skip.
                nonLatin += 1
            }
        }
        guard letters >= 4 else { return nil }
        if nonLatin > letters / 4 { return nil }
        return "en"
    }

    // MARK: - LRC parsing

    private static func parseLRC(_ raw: String) -> [SyncedLine] {
        var out: [SyncedLine] = []
        // Match [mm:ss.xx] or [mm:ss.xxx] or [mm:ss]
        let pattern = #"\[(\d{1,2}):(\d{2})(?:\.(\d{1,3}))?\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return out }

        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let nsLine = line as NSString
            let range = NSRange(location: 0, length: nsLine.length)
            let matches = regex.matches(in: line, range: range)
            guard !matches.isEmpty else { continue }
            // Strip metadata lines like [ar:Artist] — these don't match
            // the timing pattern (letters not digits) so we already
            // skipped them above.
            let lastEnd = matches.last!.range.upperBound
            let textNS = nsLine.substring(from: lastEnd)
            let text = textNS.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            for m in matches {
                let mmRange = m.range(at: 1)
                let ssRange = m.range(at: 2)
                guard mmRange.location != NSNotFound, ssRange.location != NSNotFound else { continue }
                let mm = Int(nsLine.substring(with: mmRange)) ?? 0
                let ss = Int(nsLine.substring(with: ssRange)) ?? 0
                var fractional: Double = 0
                let fracRange = m.range(at: 3)
                if fracRange.location != NSNotFound {
                    let fracString = nsLine.substring(with: fracRange)
                    let denom = pow(10.0, Double(fracString.count))
                    fractional = (Double(fracString) ?? 0) / denom
                }
                let timestamp = TimeInterval(mm * 60 + ss) + fractional
                out.append(SyncedLine(timestamp: timestamp, text: text))
            }
        }
        return out.sorted { $0.timestamp < $1.timestamp }
    }

    private static func splitPlainLyrics(_ raw: String) -> [String] {
        raw.split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Wire

    private struct Wire: Decodable {
        let instrumental: Bool?
        let plainLyrics: String?
        let syncedLyrics: String?
        /// Present on /search results; lets us prefer the candidate
        /// closest to the original track duration.
        let duration: Double?
    }
}

extension LyricsClient.Lyrics {
    /// True iff this is a usable answer that's worth caching. Negative
    /// results (.notFound, .error) intentionally re-fetch on the next
    /// probe so a transient miss can recover.
    var isPositive: Bool {
        switch self {
        case .synced, .unsynced, .instrumental:
            return true
        case .notFound, .error:
            return false
        }
    }
}
