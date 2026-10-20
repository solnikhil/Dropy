# Dropy launch film

A 34-second, 1080p60 launch film with an original score, black with white, drawn entirely in code. One white
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
(`INSERTS`, each drawn by an entry in `SCENES`) while it holds still, and five stretches
of the story (`CUTS`) are cut out, including a full-screen demo. `SPEEDS` sets the playback
speed through the film, eased between keys, so it keeps one pace: 2× through the quiet
opening, 1.75× through the edges, 1.55× for Notes, 1.28× for the busier second half, and
real time for the end card. The film runs 34.2 s.

Rendered films go in `out/` (ignored by git). Set `PLAYWRIGHT_DIR` to a
`node_modules/playwright` folder if Playwright is not installed next to the script.

## Beats (real seconds)

| Time | Beat |
| --- | --- |
| 0–4.2 s | A point of light stretches into a long line, which folds at every joint at once into the Dropy mark; the mark rises to become the notch. "Meet Dropy." |
| 4.4–9.2 s | Dropy's overlay pours out of the notch and flows as one liquid graphite shape to the right edge, both bottom corners and the left edge (each labelled, each with an app), then flows home. "Any edge. Any corner. Anywhere." |
| 9.3–12 s | "Even the notch.": it squashes and springs open straight into Notes; the camera leans in on quick typing |
| 12–17.2 s | Montage: the overlay reshapes for Music, Messages and Terminal, and bounces home; at each change one piece flies across and becomes the next app's |
| 17.2–20.3 s | The shortcut, ⌥ Space (Dropy's default), as two large light glyphs: pressed, they pull the overlay up into the notch with them, then drop back out and open it again |
| 20.4–25.5 s | The screen steps back. A pointer picks Rapid, Balanced, Smooth; each opening traces its own curve, tied to the overlay's edge by a beam, while the style's name lands with that style's own spring |
| 25.5–34.2 s | Smooth's curve lifts off the graph and flows into the Dropy mark as the screen falls away; the icon lands in a ring of sparks, "Dropy" drops out from under it, the download link and footer arrive, the card leans in |

Overlays have a plain hairline edge (no glow). Captions drop in word by word, and every
frame is motion-blurred (four instants across a half-frame shutter; `SUB=1` turns it off
for quick previews). The picture is not cut to the music's beat; the score follows the
picture's cues instead.
