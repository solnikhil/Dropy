# Dropy launch film

A 39-second, 1080p60 launch film with an original score, black with white, drawn entirely in code. One white
shape carries the whole film: a point of light becomes a line, the Dropy mark, the
notch, the overlay, and finally the app icon.

- `film.html` is the film. Open it in a browser to play and scrub it (Space plays/pauses).
  Every frame is a pure function of time, so the preview and the render match exactly.
- `render.mjs` renders it in headless Chromium (Playwright):
  `node render.mjs frames <dir>` writes every frame, `stills <dir> <t…>` single frames,
  and `sheet <dir> <t…>` a labelled contact sheet for review.
- The score is synthesised in the same file with Web Audio and cued to the picture
  (pads, a pulse from the moment the notch opens, a sound for every morph, click and key).
  It plays along in the browser preview; `render.mjs audio <dir>` writes it as `score.wav`.
- `encode.swift` turns the frames into an H.264 MP4 with AVFoundation, with any audio file
  as the soundtrack (trimmed to the picture), so a licensed track can replace the score:
  `swiftc -O -swift-version 5 encode.swift -o encode && ./encode <dir> out/film.mp4 60 [bitsPerSecond] [audio]`

The main timeline is written in "story" seconds (0–50). Two scenes are inserted into it
(`INSERTS`, each drawn by an entry in `SCENES`) while it holds still, and `SPEED` plays
everything 1.4× faster except the end card, so the film runs 39 s. Four stretches of the story (`CUTS`) are cut out, including a full-screen demo.

Rendered films go in `out/` (ignored by git). Set `PLAYWRIGHT_DIR` to a
`node_modules/playwright` folder if Playwright is not installed next to the script.

## Beats (real seconds)

| Time | Beat |
| --- | --- |
| 0–4.5 s | A point of light stretches into a line; the line gathers into a point that draws the Dropy mark like a pen; the mark rises to become the notch. "Meet Dropy." |
| 5.5–11.5 s | Dropy's overlay pours out of the notch and flows as one liquid graphite shape to the right edge, both bottom corners and the left edge (each labelled, each with an app), then flows home. "Any edge. Any corner. Anywhere." |
| 11.5–16 s | "Even the notch.": it squashes and springs open straight into Notes; the camera leans in on the typing |
| 16–20.5 s | Montage: the overlay reshapes for Music, Messages and Terminal, and bounces home |
| 20.5–23 s | The shortcut, ⌥ ' (Option-Quote), as two large light glyphs: pressed, they pull the overlay up into the notch with them, then drop back out and open it again, text intact |
| 23.5–30 s | The screen steps back. A pointer picks Rapid, Balanced, Smooth; each opening traces its own curve, tied to the overlay's edge by a beam |
| 30–39 s | The notch becomes the mark and the icon lands in a ring of sparks. "Dropy" drops letter by letter out from under the icon; the tagline rises word by word; the footer draws together; the card leans slowly in |

Overlays have a plain hairline edge (no glow). Captions drop in word by word, and every
frame is motion-blurred (four instants across a half-frame shutter; `SUB=1` turns it off
for quick previews). The picture is not cut to the music's beat; the score follows the
picture's cues instead.
