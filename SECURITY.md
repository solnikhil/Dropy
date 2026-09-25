# Security and privacy

Dropy can observe pixels from apps a person chooses to mirror. Future interaction features may need Accessibility access. Treat captured content, window titles and text as sensitive: they must remain local, must not enter default logs, and must not be uploaded by diagnostics.

Please report a vulnerability privately through GitHub's **Report a vulnerability** option in this repository's Security tab. Include the affected revision, macOS version, steps to reproduce and impact. Avoid posting exploit details or captured user content in a public issue. The project has no production release yet; supported versions will be listed here when releases begin.

Do not bypass macOS capture or protected-content behavior to implement a feature. A failed capture or permission denial should be handled as an ordinary product state.
