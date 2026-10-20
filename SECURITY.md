# Security and privacy

Dropy moves other apps' windows, can capture the pixels of windows a person chooses, and installs signed updates. Treat captured content, window titles and text as sensitive: they must stay on the Mac, must not appear in default logs, and must never be uploaded.

## Reporting a vulnerability

Please report vulnerabilities privately through GitHub's **[Report a vulnerability](https://github.com/solnikhil/Dropy/security/advisories/new)** form, not in a public issue. Include the affected revision, macOS version, steps to reproduce and the impact. Don't post exploit details or anyone's captured content publicly.

You should get a reply within a week. Once a fix is released, the advisory will be published with credit to the reporter, unless they prefer otherwise.

Especially relevant areas:

- The update channel: Sparkle feed and archive signing, and the `SUPublicEDKey` trust root.
- Anything that could move, hide or lose a window the person didn't choose, or send input to the wrong one.
- Captured content or titles leaking into logs, files or other processes.
- The `Dropy animation` command line and the watched animations folder, which read untrusted files.

## Supported versions

There is no public release yet. Once releases begin, only the latest release gets security fixes, delivered through automatic updates.

## Design rules

Don't bypass macOS capture or protected-content behavior to implement a feature. A failed capture or a denied permission is an ordinary product state. Updates must be signed with Sparkle's Ed25519 key and, for public builds, by a notarized Developer ID; an unconfigured build never falls back to an unsigned download.
