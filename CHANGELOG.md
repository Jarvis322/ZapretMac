# Changelog

All notable changes to Zapret Manager are documented here.

## v0.5.0

- **In-app updates.** On launch the app checks GitHub for a newer release and, if one exists, shows an **Update → vX.Y.Z** button that downloads the new DMG and opens it for drag-to-install. Silent on failure.

## v0.4.0

- **DNS-block bypass.** Some sites (e.g. Discord in Türkiye) are blocked by ISP DNS poisoning, not DPI — a case `tpws` cannot fix. The app now detects poisoned DNS (system resolver vs. a trusted DoH answer queried over an IP literal) and can switch the primary network service to clean resolvers (`1.1.1.1`, `1.0.0.1`, `8.8.8.8`, `8.8.4.4`) in one click, restoring the original DNS on revert or uninstall. Install auto-enables clean DNS when poisoning is detected.
- **Honest connection test.** A dedicated DNS row reports whether a failure is DNS- or DPI-based.
- **Smarter auto-tune.** DPI-strategy probing resolves via DoH so DNS poisoning no longer sabotages strategy detection.

## v0.3.0

- **Auto-tuned install.** Probes the connection and picks a DPI-bypass strategy that works on the user's ISP instead of guessing.

## v0.2.2

- **Bilingual UI.** English and Turkish, auto-selected from the system language with an in-app switch.

## v0.2.1

- **tpws watchdog.** A LaunchDaemon restarts `tpws` if it dies while protection is on, so a leftover PF redirect can't cut off HTTPS.

## v0.2

- Initial Zapret Manager for macOS: one-click install/uninstall, start/stop, domain list editor, password-free control, and connection tests.
