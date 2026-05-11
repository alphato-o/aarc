import Foundation
import OSLog

/// Fetches lyrics for a track from a chain of free / freemium providers.
/// First positive result wins.
///
/// Provider chain (each step only runs if previous returned nothing):
///   1. LRCLib            (free, no key) — synced LRC when available.
///                         Tries strict get → loose get → normalized
///                         title → /search by title alone.
///   2. NetEase           (no key) — unofficial web endpoints
///                         music.163.com/api/{search,song/lyric}. Best
///                         Chinese coverage with synced LRC. Prioritised
///                         over Musixmatch/ovh when the track's title or
///                         artist contains Han characters.
///   3. Musixmatch        (free tier, 2000/day, requires API key in
///                         Settings) — plain unsynced; broader catalog.
///                         Skipped silently when no key is configured.
///   4. lyrics.ovh        (free, no key) — plain unsynced; English-leaning.
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
        case synced(lines: [SyncedLine], source: String)
        case unsynced(lines: [String], source: String)
        case instrumental(source: String)
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

        var firstInstrumental: String?
        let looksChinese = Self.containsHan(track.title) || Self.containsHan(track.artist)

        // Run each provider in sequence. NetEase moves to the front for
        // Chinese tracks because LRCLib's Mandopop coverage is thin.
        // Musixmatch is conditional on a key being configured; we treat
        // a nil return as "skip silently, try next".
        let providers: [LyricProvider] = looksChinese
            ? [.netease, .lrclib, .musixmatch, .lyricsOvh]
            : [.lrclib, .netease, .musixmatch, .lyricsOvh]

        for provider in providers {
            let outcome: Lyrics?
            switch provider {
            case .lrclib:     outcome = await fetchFromLRCLib(track: track)
            case .netease:    outcome = await fetchFromNetEase(track: track)
            case .musixmatch: outcome = await fetchFromMusixmatch(track: track)
            case .lyricsOvh:  outcome = await fetchFromLyricsOvh(track: track)
            }
            guard let outcome else { continue }
            switch outcome {
            case .synced, .unsynced:
                cache[key] = outcome
                return outcome
            case .instrumental(let s):
                if firstInstrumental == nil { firstInstrumental = s }
            case .notFound, .error:
                continue
            }
        }

        if let source = firstInstrumental {
            return .instrumental(source: source)
        }
        return .notFound
    }

    private enum LyricProvider {
        case lrclib, netease, musixmatch, lyricsOvh
    }

    private static func containsHan(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) {
                return true
            }
        }
        return false
    }

    private func cacheKey(for track: Track) -> String {
        "\(track.artist.lowercased())|\(track.title.lowercased())"
    }

    // MARK: - Provider 1: LRCLib

    /// Wrapper that walks the LRCLib ladder. Returns:
    ///   .synced/.unsynced  → real lyrics
    ///   .instrumental      → track is genuinely instrumental on LRCLib
    ///   .notFound          → nothing matched (caller tries next provider)
    ///   .error             → transient
    private func fetchFromLRCLib(track: Track) async -> Lyrics {
        let firstArtist = Self.firstArtist(track.artist)
        let normalizedTitle = Self.normalizeTitle(track.title)
        var sawInstrumental = false

        func consider(_ wire: LRCLibWire?) -> Lyrics? {
            guard let wire else { return nil }
            if wire.instrumental == true {
                sawInstrumental = true
                return nil
            }
            if let synced = wire.syncedLyrics, !synced.isEmpty {
                let parsed = Self.parseLRC(synced)
                if !parsed.isEmpty {
                    return .synced(lines: parsed, source: "lrclib")
                }
            }
            if let plain = wire.plainLyrics, !plain.isEmpty {
                let lines = Self.splitPlainLyrics(plain)
                if !lines.isEmpty {
                    return .unsynced(lines: lines, source: "lrclib")
                }
            }
            return nil
        }

        // 1. Strict.
        if let l = consider(await lrclibGet(
            artist: firstArtist, title: track.title,
            album: track.album, duration: track.durationSeconds
        )) { return l }

        // 2. Drop album + duration.
        if let l = consider(await lrclibGet(
            artist: firstArtist, title: track.title, album: nil, duration: nil
        )) { return l }

        // 3. Normalized title (strips "- Remastered N", "(feat. X)", etc.).
        if normalizedTitle != track.title {
            if let l = consider(await lrclibGet(
                artist: firstArtist, title: normalizedTitle, album: nil, duration: nil
            )) { return l }
            if let l = consider(await lrclibGet(
                artist: nil, title: normalizedTitle, album: nil, duration: nil
            )) { return l }
        }

        // 4. Search by title alone — catches covers + odd spellings.
        let candidates = await lrclibSearch(normalizedTitle, durationHint: track.durationSeconds)
        for hit in candidates.prefix(8) {
            if let l = consider(hit) { return l }
        }

        return sawInstrumental ? .instrumental(source: "lrclib") : .notFound
    }

    private func lrclibGet(
        artist: String?, title: String, album: String?, duration: Int?
    ) async -> LRCLibWire? {
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
        return await fetchJSON(at: url, as: LRCLibWire.self, label: "lrclib.get")
    }

    private func lrclibSearch(_ title: String, durationHint: Int?) async -> [LRCLibWire] {
        var comps = URLComponents(string: "https://lrclib.net/api/search")!
        comps.queryItems = [URLQueryItem(name: "track_name", value: title)]
        guard let url = comps.url else { return [] }

        let hits = await fetchJSON(at: url, as: [LRCLibWire].self, label: "lrclib.search") ?? []
        if hits.isEmpty { return [] }

        var ranked = hits
        if let hint = durationHint {
            let hintD = Double(hint)
            ranked.sort { a, b in
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
            ranked.sort { a, b in
                let aSynced = !(a.syncedLyrics ?? "").isEmpty
                let bSynced = !(b.syncedLyrics ?? "").isEmpty
                return aSynced && !bSynced
            }
        }
        log.info("LRCLib search \"\(title, privacy: .public)\" → \(ranked.count, privacy: .public) hits")
        return ranked
    }

    // MARK: - Provider 2: Musixmatch

    /// Returns nil when no API key is configured — so the chain treats
    /// it as "skip silently" rather than "tried and failed".
    private func fetchFromMusixmatch(track: Track) async -> Lyrics? {
        guard let apiKey = UserDefaults.standard
            .string(forKey: "musixmatch.apiKey")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.isEmpty else {
            return nil
        }

        let artist = Self.firstArtist(track.artist)
        let title = Self.normalizeTitle(track.title)

        var comps = URLComponents(string: "https://api.musixmatch.com/ws/1.1/matcher.lyrics.get")!
        comps.queryItems = [
            URLQueryItem(name: "q_track", value: title),
            URLQueryItem(name: "q_artist", value: artist),
            URLQueryItem(name: "apikey", value: apiKey),
        ]
        guard let url = comps.url else { return .error("musixmatch URL build failed") }

        guard let wire = await fetchJSON(at: url, as: MxmEnvelope.self, label: "musixmatch") else {
            return .notFound
        }
        let status = wire.message.header.status_code
        guard status == 200 else {
            // 404 = not found. 401/402 = key issue. Don't spam; just bail.
            log.info("Musixmatch status \(status, privacy: .public)")
            return status == 404 ? .notFound : .error("musixmatch status \(status)")
        }
        guard let raw = wire.message.body?.lyrics?.lyrics_body, !raw.isEmpty else {
            return .notFound
        }
        let cleaned = Self.cleanMusixmatchBody(raw)
        let lines = Self.splitPlainLyrics(cleaned)
        guard !lines.isEmpty else { return .notFound }
        return .unsynced(lines: lines, source: "musixmatch")
    }

    /// Musixmatch free-tier bodies end with a watermark stanza:
    ///     ...
    ///     ******* This Lyrics is NOT for Commercial use *******
    ///     (1409625334720)
    /// Strip everything from the watermark down. Also strip trailing
    /// "..." that signals the free-tier truncation.
    private static func cleanMusixmatchBody(_ raw: String) -> String {
        var kept: [Substring] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.contains("This Lyrics is NOT for Commercial use") { break }
            if trimmed.hasPrefix("****") { break }
            if !trimmed.isEmpty,
               trimmed.allSatisfy({ $0.isNumber || $0 == "(" || $0 == ")" }) {
                // Pure numeric trailer like "(1409625334720)"
                break
            }
            kept.append(line)
        }
        return kept.joined(separator: "\n")
            .replacingOccurrences(of: "\n...", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Provider: NetEase Cloud Music (unofficial web endpoints)

    /// Two-step: /api/search/get → song id → /api/song/lyric.
    /// Both endpoints are the same calls the music.163.com web player
    /// makes — no auth required, but the server insists on a Referer
    /// header. We prefer the result with the closest duration to the
    /// Spotify track so a cover doesn't displace the original.
    private func fetchFromNetEase(track: Track) async -> Lyrics {
        let firstArtist = Self.firstArtist(track.artist)
        let normalizedTitle = Self.normalizeTitle(track.title)

        // Try title + artist first; if that returns nothing usable, try
        // title alone.  Each search returns ranked candidates we then
        // probe for lyric content.
        let queries = [
            "\(normalizedTitle) \(firstArtist)",
            normalizedTitle,
        ]
        var sawInstrumentalish = false

        for query in queries {
            let songs = await neteaseSearch(query: query)
            // Sort by duration closeness when we know it. NetEase reports
            // duration in ms.
            let ranked: [NeteaseSong] = {
                guard let dur = track.durationSeconds else { return songs }
                let hintMs = Double(dur * 1000)
                return songs.sorted { a, b in
                    abs(Double(a.duration ?? 0) - hintMs) < abs(Double(b.duration ?? 0) - hintMs)
                }
            }()

            for song in ranked.prefix(5) {
                let lyric = await neteaseLyric(songId: song.id)
                switch lyric {
                case .synced, .unsynced:
                    return lyric
                case .instrumental:
                    sawInstrumentalish = true
                case .notFound, .error:
                    continue
                }
            }
        }
        return sawInstrumentalish ? .instrumental(source: "netease") : .notFound
    }

    private struct NeteaseSong {
        let id: Int
        let name: String
        let artistName: String
        let duration: Int?   // ms
    }

    private func neteaseSearch(query: String) async -> [NeteaseSong] {
        var comps = URLComponents(string: "https://music.163.com/api/search/get")!
        comps.queryItems = [
            URLQueryItem(name: "s", value: query),
            URLQueryItem(name: "type", value: "1"),
            URLQueryItem(name: "limit", value: "10"),
        ]
        guard let url = comps.url else { return [] }

        var req = URLRequest(url: url)
        req.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 8

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else { return [] }
            let wire = try JSONDecoder().decode(NeteaseSearchWire.self, from: data)
            let songs = wire.result?.songs ?? []
            log.info("NetEase search \"\(query, privacy: .public)\" → \(songs.count, privacy: .public) hits")
            return songs.map { s in
                let artistName = (s.artists ?? []).compactMap(\.name).joined(separator: ", ")
                return NeteaseSong(id: s.id, name: s.name ?? "", artistName: artistName, duration: s.duration)
            }
        } catch {
            log.info("NetEase search error: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private func neteaseLyric(songId: Int) async -> Lyrics {
        var comps = URLComponents(string: "https://music.163.com/api/song/lyric")!
        comps.queryItems = [
            URLQueryItem(name: "id", value: String(songId)),
            URLQueryItem(name: "lv", value: "1"),
            URLQueryItem(name: "kv", value: "1"),
            URLQueryItem(name: "tv", value: "-1"),
        ]
        guard let url = comps.url else { return .error("netease lyric URL build failed") }

        var req = URLRequest(url: url)
        req.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 8

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else {
                return .notFound
            }
            let wire = try JSONDecoder().decode(NeteaseLyricWire.self, from: data)
            // Signals NetEase uses for "no lyrics on file":
            if wire.nolyric == true { return .notFound }
            if wire.uncollected == true {
                // Uncollected ≈ "we don't have this transcribed". Coach
                // should treat as missing, not instrumental.
                return .notFound
            }
            if let raw = wire.lrc?.lyric, !raw.isEmpty {
                let parsed = Self.parseLRC(raw)
                if !parsed.isEmpty {
                    return .synced(lines: parsed, source: "netease")
                }
                // LRC field present but no timestamps — fall back to lines.
                let lines = Self.splitPlainLyrics(Self.stripLRCTimestamps(raw))
                if !lines.isEmpty {
                    return .unsynced(lines: lines, source: "netease")
                }
            }
            return .notFound
        } catch {
            log.info("NetEase lyric error: \(error.localizedDescription, privacy: .public)")
            return .error(error.localizedDescription)
        }
    }

    /// LRC lyrics on NetEase frequently include a `作词 : ...` (lyricist)
    /// header block at top — kept here because users sometimes get
    /// roasted for credits. parseLRC already handles header lines; this
    /// helper is only for the unsynced fallback.
    private static func stripLRCTimestamps(_ raw: String) -> String {
        let pattern = #"\[\d{1,2}:\d{2}(?:\.\d{1,3})?\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return raw }
        let ns = raw as NSString
        return regex.stringByReplacingMatches(
            in: raw,
            range: NSRange(location: 0, length: ns.length),
            withTemplate: ""
        )
    }

    // MARK: - Provider 3: lyrics.ovh

    private func fetchFromLyricsOvh(track: Track) async -> Lyrics {
        let artist = Self.firstArtist(track.artist)
        let title = Self.normalizeTitle(track.title)
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        guard
            let aEsc = artist.addingPercentEncoding(withAllowedCharacters: allowed),
            let tEsc = title.addingPercentEncoding(withAllowedCharacters: allowed),
            let url = URL(string: "https://api.lyrics.ovh/v1/\(aEsc)/\(tEsc)")
        else {
            return .error("lyrics.ovh URL build failed")
        }

        guard let wire = await fetchJSON(at: url, as: OvhWire.self, label: "lyrics.ovh") else {
            return .notFound
        }
        guard let raw = wire.lyrics, !raw.isEmpty else { return .notFound }
        let lines = Self.splitPlainLyrics(raw)
        guard !lines.isEmpty else { return .notFound }
        return .unsynced(lines: lines, source: "lyrics.ovh")
    }

    // MARK: - HTTP

    private func fetchJSON<T: Decodable>(
        at url: URL,
        as type: T.Type,
        label: String
    ) async -> T? {
        var req = URLRequest(url: url)
        req.setValue("AARC/0.1 (https://aarun.club)", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 8
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { return nil }
            if http.statusCode == 404 { return nil }
            guard (200...299).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
                log.info("\(label, privacy: .public) non-200 \(http.statusCode, privacy: .public) body=\(body, privacy: .public)")
                return nil
            }
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            log.info("\(label, privacy: .public) error: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Pick line

    /// Pick a line of lyrics appropriate to roast right now. For synced
    /// lyrics this is the line being sung at `progressSec` (or just
    /// before — we accept up to ~1.5s of lookahead grace). For unsynced
    /// lyrics with a progress hint we approximate position by
    /// (progress / duration) * lineCount.
    func pickLine(
        for track: Track,
        lyrics: Lyrics,
        progressSec: TimeInterval?,
        rotation: Int = 0
    ) -> Selection? {
        switch lyrics {
        case .synced(let lines, let source):
            guard !lines.isEmpty else { return nil }
            guard let progress = progressSec else {
                let idx = abs(rotation) % lines.count
                return contextSelection(lines: lines.map(\.text), index: idx, source: source, synced: true)
            }
            var chosenIndex: Int = 0
            var found = false
            for (i, line) in lines.enumerated() {
                if line.timestamp <= progress + 1.5 {
                    chosenIndex = i
                    found = true
                } else {
                    break
                }
            }
            if !found { chosenIndex = 0 }
            return contextSelection(lines: lines.map(\.text), index: chosenIndex, source: source, synced: true)

        case .unsynced(let lines, let source):
            guard !lines.isEmpty else { return nil }
            // Approximate sync via proportional position when we know the
            // track duration; otherwise rotate.
            let idx: Int
            if let progress = progressSec,
               let duration = track.durationSeconds, duration > 0 {
                let frac = max(0, min(1, progress / TimeInterval(duration)))
                idx = min(lines.count - 1, Int(Double(lines.count) * frac))
            } else {
                idx = abs(track.title.hashValue &+ rotation) % lines.count
            }
            return contextSelection(lines: lines, index: idx, source: source, synced: false)

        case .instrumental, .notFound, .error:
            return nil
        }
    }

    struct Selection: Sendable {
        /// The single line the DJ should roast.
        let line: String
        /// 2-3 lines around it (including the chosen line) for the LLM's
        /// situational context.
        let context: [String]
        /// "en" | "zh" — the only two we ship in this commit.
        let language: String
        /// Which provider the line came from — surfaced in the playground
        /// for debugging coverage gaps.
        let source: String
        /// True if the line was timestamped (LRC); false if we picked it
        /// from unsynced text via proportional / rotation heuristics.
        let synced: Bool
    }

    private func contextSelection(
        lines: [String],
        index: Int,
        source: String,
        synced: Bool
    ) -> Selection? {
        let pick = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pick.isEmpty else { return nil }
        guard let language = detectLanguage(pick) else { return nil }
        let lo = max(0, index - 1)
        let hi = min(lines.count - 1, index + 1)
        let context = Array(lines[lo...hi])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Selection(
            line: pick,
            context: context,
            language: language,
            source: source,
            synced: synced
        )
    }

    /// Returns "en", "zh", or nil (skip). We're deliberately narrow per
    /// product spec — Spanish/Japanese/etc. tracks are ignored for now.
    private func detectLanguage(_ text: String) -> String? {
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) {
                return "zh"
            }
        }
        var letters = 0
        var nonLatin = 0
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if (0x0041...0x005A).contains(v) || (0x0061...0x007A).contains(v) {
                letters += 1
            } else if v > 0x007F && !scalar.properties.isWhitespace {
                nonLatin += 1
            }
        }
        guard letters >= 4 else { return nil }
        if nonLatin > letters / 4 { return nil }
        return "en"
    }

    // MARK: - Title / artist normalization

    private static func firstArtist(_ artist: String) -> String {
        let separators: [Character] = [",", "&", ";"]
        for sep in separators {
            if let idx = artist.firstIndex(of: sep) {
                return String(artist[..<idx]).trimmingCharacters(in: .whitespaces)
            }
        }
        return artist.trimmingCharacters(in: .whitespaces)
    }

    /// Strips Spotify suffixes that lyric DBs' primary entries don't have.
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

    // MARK: - LRC parsing

    private static func parseLRC(_ raw: String) -> [SyncedLine] {
        var out: [SyncedLine] = []
        let pattern = #"\[(\d{1,2}):(\d{2})(?:\.(\d{1,3}))?\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return out }

        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let nsLine = line as NSString
            let range = NSRange(location: 0, length: nsLine.length)
            let matches = regex.matches(in: line, range: range)
            guard !matches.isEmpty else { continue }
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

    // MARK: - Wire types

    private struct LRCLibWire: Decodable {
        let instrumental: Bool?
        let plainLyrics: String?
        let syncedLyrics: String?
        let duration: Double?
    }

    private struct MxmEnvelope: Decodable {
        let message: MxmMessage
    }
    private struct MxmMessage: Decodable {
        let header: MxmHeader
        let body: MxmBody?
    }
    private struct MxmHeader: Decodable {
        let status_code: Int
    }
    private struct MxmBody: Decodable {
        let lyrics: MxmLyrics?
    }
    private struct MxmLyrics: Decodable {
        let lyrics_body: String?
    }

    private struct OvhWire: Decodable {
        let lyrics: String?
    }

    private struct NeteaseSearchWire: Decodable {
        let result: NeteaseSearchResult?
    }
    private struct NeteaseSearchResult: Decodable {
        let songs: [NeteaseSearchSong]?
    }
    private struct NeteaseSearchSong: Decodable {
        let id: Int
        let name: String?
        let artists: [NeteaseSearchArtist]?
        let duration: Int?
    }
    private struct NeteaseSearchArtist: Decodable {
        let name: String?
    }

    private struct NeteaseLyricWire: Decodable {
        let lrc: NeteaseLrcBlock?
        let nolyric: Bool?
        let uncollected: Bool?
    }
    private struct NeteaseLrcBlock: Decodable {
        let lyric: String?
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
