# First-launch onboarding

The welcome flow introduces the app, explains permissions, teaches the saved keyboard
shortcut, and offers the production animation demo with sample content. It shares the
accent and preview renderer with Settings but has its own expressive surface.

## Visuals

Dark and monochrome on a solid near-black window with a still overhead light; the
background never moves. Surfaces are machined (hairline edges, lit top edges) and white
metal marks the lit step pill and primary actions. The window has no title-bar controls;
the step track sits at the top, and pages are laid out to fit without scrolling.

Welcome opens on the title and a Get to Know More button. Clicking it pulls both into a
notch at the page's top edge, and the notch opens like Dropy to show the title, line and
three feature cards inside it. Going back to Welcome later shows it already open.
Permissions shows a shield that turns green once both grants are
in. Shortcut shows keycaps that press the real shortcut in order and asks for a press:
while that step is visible, the global shortcut plays the selected animation on the notch
instead of opening the overlay, and the prompt confirms it. Try it loops the production
notch animation on sample content.

Get Started fades the window out and drops the real notch (or a notch-sized body at the top
center of a display without one) to show "Dropy is ready" with the shortcut's keycaps. It
holds three seconds, and setup finishes and Settings opens as it tucks back. Reduce Motion
stops continuous effects, uses fades between pages and opens Welcome without the morph. Shared
effects live in OnboardingEffects.

## Lifecycle

`OnboardingProgress` persists a step and a separate completion flag in versioned keys.
Closing a window or quitting saves the last reached step without completing setup.
Get Started and Set Up Later complete it; a replay starts at Welcome and preserves the
existing completion flag. Resetting app preferences does not clear onboarding.

Ordinary launches present incomplete setup. Explicit Settings/Studio launches and
benchmark/debug launches skip it. `--onboarding` forces presentation outside a check
launch. Help and the menu-bar menu provide Welcome to Dropy for replay. Finder/Dock
reopening resumes incomplete setup, and otherwise retains the existing Settings behavior.

The onboarding window participates in the app's Dock activation policy. It stops shortcut
recording when moving between steps, losing focus or closing. Closing also stops a demo.
Get Started opens Opening Settings when permissions are allowed, or Permissions when
access is still missing. Set Up Later opens General without requesting access.

## Permissions and preferences

Showing setup never requests a grant. The Allow Access buttons invoke the existing
SettingsModel permission actions. Current grants are refreshed when the window becomes
key after returning from System Settings. A Screen Recording request can expose a
relaunch action; progress has already been saved before that request.

Permission grants are optional for completing the tour. The shortcut is the real saved
shortcut, and recording uses the production SettingsModel recorder. The tour explains
the current notch-trigger pause instead of presenting hover/click opening as available.
Other app choices, login items, pinning and animation preferences are not changed.

## Verification

The full local suite passed, including new isolated-defaults checks for resume,
completion, replay, invalid stored steps and launch suppression. The installed app's
four screens were reviewed in dark appearance. Quitting on Shortcut and relaunching
resumed that step. Get Started opened Opening, and Help replay returned to Welcome.
The machine already had both grants, so fresh macOS permission prompts and grant/relaunch
were not exercised; those actions reuse the existing permission implementation.
