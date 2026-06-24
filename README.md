# Zapret Manager for macOS

A native macOS app for installing and managing [Zapret](https://github.com/bol-van/zapret) — a tool that helps bypass DPI-based censorship. Zapret Manager wraps the command-line setup in a simple graphical interface: install, start, stop, edit the target domain list, and remove it again, all without touching a terminal.

> **Requires an Apple Silicon (M1 or later) Mac running macOS 14 (Sonoma) or newer.** Intel Macs are not supported.

## Features

- **One-click install.** Downloads the official Zapret release from GitHub, verifies every file against its `sha256sum.txt` checksum, and installs it to `/opt/zapret`.
- **Auto-tuned to your connection.** Before installing, it probes your network and picks a DPI-bypass strategy that actually works on your ISP, instead of guessing — no terminal, no trial and error.
- **Password-free control.** After a single administrator approval at install time, starting, stopping, and saving no longer prompt for your password (see [How privileges work](#how-privileges-work)).
- **Self-healing.** A lightweight watchdog restarts `tpws` automatically if it ever crashes, so your connection is never left half-broken (see [Resilience](#resilience)).
- **Domain list editor.** Edit the list of domains to route through Zapret. Every save is backed up with a timestamp, and there is a built-in Discord profile to get started quickly.
- **DNS-block bypass.** Some sites (e.g. Discord in Türkiye) are blocked by ISP DNS poisoning, not DPI — a case `tpws` cannot fix. The app detects poisoned DNS and can switch your connection to clean DoH-capable resolvers (1.1.1.1 / 8.8.8.8) in one click, restoring the original setting on revert or uninstall (see [DNS-based blocks](#dns-based-blocks)).
- **Connection tests.** Check reachability of Discord, OpenAI, Anthropic, and GitHub from inside the app — with a dedicated DNS row that tells you whether a failure is DNS- or DPI-based.
- **In-app updates.** On launch the app checks GitHub for a newer release; if one exists, an **Update → vX.Y.Z** button appears that downloads the new DMG and opens it for drag-to-install.
- **Clean uninstall.** Removes everything it installed, restoring your system to its original state.
- **Bilingual.** English and Turkish, auto-selected from your system language with a one-tap switch in the app.

## Installation

1. Download `Zapret Manager.dmg` from the [latest release](https://github.com/Jarvis322/ZapretMac/releases/latest).
2. Open the DMG and drag **Zapret Manager** into your **Applications** folder.
3. Launch it (see [First launch](#first-launch) below), then click **Install Zapret**. The app downloads, verifies, and configures Zapret for you.

### First launch

The app is not signed with an Apple Developer ID, so macOS blocks it the first time you open it. This is expected and only happens once:

1. **Right-click** the app and choose **Open**, then confirm **Open** in the dialog that appears.
2. If it is still blocked, go to **System Settings → Privacy & Security**, scroll to the bottom, and click **Open Anyway** next to the Zapret Manager notice.

## How it works

Zapret runs `tpws`, a transparent proxy, and uses the macOS packet filter (PF) to route selected traffic through it. Zapret Manager handles the moving parts around that:

### Auto-tuning

DPI-based censorship varies by ISP, so a single fixed bypass strategy won't work for everyone. Before installing, Zapret Manager runs `tpws` as a local SOCKS proxy (no root, no system changes) and tests a series of bypass strategies against a known-blocked domain, keeping the first one that actually succeeds on your connection. That strategy is written into the install configuration. If none succeed, it falls back to a sensible default and tells you.

### How privileges work

Installing, starting, and stopping Zapret require root access. Rather than asking for your password every time, the app installs a small root-owned helper script and a tightly scoped `sudoers` rule **once**, during the initial admin-approved install. From then on, routine actions run without a prompt.

This is a deliberate trade-off: anyone who can run the app on this Mac can run these specific Zapret commands as root without a password. That is appropriate for a single-user machine and keeps everyday use friction-free.

### Resilience

If `tpws` stops unexpectedly — a crash, or coming back from sleep — the leftover PF redirect would otherwise send all HTTPS traffic to a process that is no longer there, cutting off your connection. To prevent this, a watchdog `LaunchDaemon` (`zapret-watchdog`) checks `tpws` every ~10 seconds and restarts it whenever protection is supposed to be on but the process is gone. If you stopped protection yourself, the watchdog leaves it alone.

### DNS-based blocks

Not every block is a DPI block. In Türkiye, for example, Discord is blocked by **DNS poisoning**: the ISP's resolver answers `discord.com` with a sinkhole IP (e.g. `195.175.254.2`) instead of Discord's real Cloudflare addresses, so the connection never reaches Discord at all. `tpws` only manipulates the TLS handshake of connections that are *already* heading to the right server — it cannot fix a poisoned lookup, so no bypass strategy will ever unblock a DNS-blocked site.

Zapret Manager detects this by comparing your system resolver's answer for a known-blocked domain against a trusted DNS-over-HTTPS answer (queried over an IP literal so it can't itself be poisoned). If they disagree, your DNS is poisoned. The app then offers a one-click switch to clean resolvers (`1.1.1.1`, `1.0.0.1`, `8.8.8.8`, `8.8.4.4`) on your primary network service, backing up your previous DNS so **Revert to System DNS** and uninstall restore exactly what you had. During install, if poisoning is detected, clean DNS is enabled automatically.

### Uninstall

The **Uninstall Zapret** button in the app removes everything: `/opt/zapret`, the auto-start `LaunchDaemon`, the watchdog, and the `sudoers` rule. It unapplies the PF firewall first, so your connection is never left in a broken state. If the app changed your DNS, it restores your original resolver before removing its files.

## Building from source

```sh
./build_app.sh          # build the .app only
./build_app.sh --dmg    # build the .app and a distributable .dmg
```

Outputs land in `dist/`: `Zapret Manager.app` and, with `--dmg`, `Zapret Manager.dmg`. The app icon is generated on every build by `Icon/make_icon.swift` and embedded in the bundle. The DMG ships with the app and an `Applications` shortcut for drag-to-install.

Requires the Swift toolchain (Xcode or Xcode Command Line Tools).

## Project status

Version 0.5.0 supports auto-tuned install, uninstall, persistent auto-start, password-free control, automatic recovery, DNS-poisoning detection with one-click clean DNS, in-app update checks against GitHub releases, and a bilingual (English/Turkish) interface. For broad public distribution, a Developer ID signature and notarization would remove the first-launch security prompt — this is not yet included.
