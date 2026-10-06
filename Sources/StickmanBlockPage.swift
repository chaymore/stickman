import AppKit

/// The "Blocked by Stickman" page both blockers redirect browser tabs to.
/// Stickman squares up in his guard stance and throws a jab every few seconds.
enum StickmanBlockPage {
    private static let lock = NSLock()
    private static var frames: [String] = []

    /// Renders the fighting pose from the real skeleton. Call once on the main thread at launch.
    @MainActor
    static func prepare() {
        let rendered = StickmanView.fightingPoseFrames()
        lock.lock()
        frames = rendered
        lock.unlock()
    }

    static func html(site: String, detail: String, footnote: String?) -> String {
        lock.lock()
        let poses = frames
        lock.unlock()

        let fighter: String
        if poses.count == 3 {
            fighter = """
            <g class="pose f1">\(poses[0])</g><g class="pose f2">\(poses[1])</g>\
            <g class="pose f3">\(poses[2])<g class="swish"><path d="M18 54 L44 51"/><path d="M14 66 L40 63"/><path d="M20 78 L42 75"/></g></g>
            """
        } else {
            fighter = #"<g class="pose"><circle cx="80" cy="28" r="17"/><polyline points="80,50 78,93"/><polyline points="80,50 64,62 74,48"/><polyline points="80,50 98,60 92,45"/><polyline points="78,93 62,118 50,145"/><polyline points="78,93 96,116 108,145"/></g>"#
        }

        let footnoteHTML = footnote.map { #"<p class="small">\#(escape($0))</p>"# } ?? ""
        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Blocked by Stickman</title>
        <style>
        :root { color-scheme: light dark; --bg: #f3f0e8; --ink: #121212; --muted: #5f5f5f; --line: rgba(0,0,0,.14); }
        @media (prefers-color-scheme: dark) { :root { --bg: #0e0f11; --ink: #f2f2f2; --muted: #a0a0a0; --line: rgba(255,255,255,.16); } }
        * { box-sizing: border-box; }
        body { margin: 0; min-height: 100vh; display: grid; place-items: center; background: var(--bg); color: var(--ink);
               font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", "Helvetica Neue", sans-serif; }
        main { width: min(720px, calc(100vw - 48px)); padding: 40px 0 56px; text-align: center; }
        .fighter { width: min(260px, 60vw); aspect-ratio: 1; margin: 0 auto; color: var(--ink); }
        .fighter svg { width: 100%; height: 100%; overflow: visible; }
        .pose { fill: none; stroke: currentColor; stroke-width: 7.5; stroke-linecap: round; stroke-linejoin: round; opacity: 0;
                animation: 2.4s linear infinite; }
        .swish path { stroke-width: 2.5; opacity: .45; }
        .ground { stroke: var(--line); stroke-width: 2; stroke-linecap: round; }
        .f1 { animation-name: f1; } .f2 { animation-name: f2; } .f3 { animation-name: f3; }
        @keyframes f1 { 0%, 29.9% { opacity: 1 } 30%, 59.9% { opacity: 0 } 60%, 77.9% { opacity: 1 } 78%, 100% { opacity: 0 } }
        @keyframes f2 { 0%, 29.9% { opacity: 0 } 30%, 59.9% { opacity: 1 } 60%, 89.9% { opacity: 0 } 90%, 100% { opacity: 1 } }
        @keyframes f3 { 0%, 77.9% { opacity: 0 } 78%, 89.9% { opacity: 1 } 90%, 100% { opacity: 0 } }
        @media (prefers-reduced-motion: reduce) { .pose { animation: none; } .f1 { opacity: 1; } }
        h1 { margin: 6px 0 22px; font-size: clamp(46px, 9vw, 92px); line-height: .92; letter-spacing: -.035em; font-weight: 800; }
        .site { display: inline-block; margin-bottom: 22px; padding: 7px 16px; border: 2.5px solid var(--ink); border-radius: 999px;
                font-size: 18px; font-weight: 700; }
        p { max-width: 540px; margin: 0 auto 10px; font-size: 20px; line-height: 1.5; color: var(--muted); }
        .small { margin-top: 26px; font-size: 14px; }
        </style>
        </head>
        <body>
        <main>
        <div class="fighter" aria-hidden="true">
        <svg viewBox="0 0 160 160" xmlns="http://www.w3.org/2000/svg">\(fighter)<line class="ground" x1="34" y1="152" x2="126" y2="152"/></svg>
        </div>
        <h1>Blocked by Stickman</h1>
        <div class="site">\(escape(site))</div>
        <p>\(escape(detail))</p>
        \(footnoteHTML)
        </main>
        </body>
        </html>
        """
    }

    static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
