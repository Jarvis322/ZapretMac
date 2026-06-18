import AppKit
import Foundation
import SwiftUI

// MARK: - Yerelleştirme / Localization

enum Lang: String { case tr, en }

enum AppLang {
    static let key = "appLanguage"
    /// Kayıtlı dil; yoksa sistem diline göre (Türkçe → tr, aksi halde en).
    static var current: Lang {
        if let raw = UserDefaults.standard.string(forKey: key), let l = Lang(rawValue: raw) { return l }
        return (Locale.preferredLanguages.first ?? "en").lowercased().hasPrefix("tr") ? .tr : .en
    }
}

/// İki dilli metin seçici. / Bilingual string picker.
private func L(_ tr: String, _ en: String) -> String { AppLang.current == .tr ? tr : en }

private enum ZapretPaths {
    static let base = "/opt/zapret"
    static let executable = "/opt/zapret/init.d/macos/zapret"
    static let hostlist = "/opt/zapret/ipset/zapret-hosts-user.txt"
    /// Root sahipli, sudoers ile şifresiz çağrılabilen ayrıcalıklı yardımcı.
    static let helper = "/opt/zapret/zapret-mgr-helper.sh"
    static let sudoers = "/etc/sudoers.d/zapret-manager"
    /// tpws'i izleyip ölürse yeniden başlatan watchdog.
    static let watchdog = "/opt/zapret/zapret-watchdog.sh"
    static let watchdogPlist = "/Library/LaunchDaemons/zapret-watchdog.plist"
    /// İstenen-durum bayrağı: varsa koruma açık olmalı (watchdog tpws'i diri tutar);
    /// yoksa kullanıcı bilerek durdurmuş demektir (watchdog dokunmaz).
    static let protectFlag = "/opt/zapret/.mgr-protect-enabled"
}

private struct EndpointCheck: Identifiable {
    let id = UUID()
    let name: String
    let result: String
    let succeeded: Bool
}

private struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
    }
}

@MainActor
private final class ZapretManager: ObservableObject {
    @Published var isInstalled = false
    @Published var isRunning = false
    @Published var isAutoStartEnabled = false
    @Published var domains = ""
    @Published var message = L("Hazır", "Ready")
    @Published var isBusy = false
    @Published var checks: [EndpointCheck] = []

    private var discordPreset: [String] { Self.discordPresetStatic }

    init() {
        refresh()
    }

    func refresh() {
        isInstalled = FileManager.default.isExecutableFile(atPath: ZapretPaths.executable)
        isRunning = Self.processIsRunning()
        isAutoStartEnabled = FileManager.default.fileExists(atPath: "/Library/LaunchDaemons/zapret.plist")
        if let contents = try? String(contentsOfFile: ZapretPaths.hostlist, encoding: .utf8) {
            domains = contents
                .split(whereSeparator: \ .isNewline)
                .map(String.init)
                .joined(separator: "\n")
        }
    }

    func addDiscordPreset() { addPreset(discordPreset) }

    func start() { performServiceAction("start", success: L("Zapret başlatıldı", "Zapret started")) }
    func stop() { performServiceAction("stop", success: L("Zapret durduruldu", "Zapret stopped")) }
    func restart() { performServiceAction("restart", success: L("Zapret yeniden başlatıldı", "Zapret restarted")) }

    func installZapret() {
        guard !isInstalled else {
            message = L("Zapret zaten kurulu", "Zapret is already installed")
            return
        }
        isBusy = true
        message = L("Resmi Zapret paketi indiriliyor ve doğrulanıyor...",
                    "Downloading and verifying the official Zapret package…")

        Task {
            var temporaryDirectory: URL?
            do {
                let prepared = try await Self.prepareInstallerPayload()
                temporaryDirectory = prepared.temporaryDirectory
                message = L("Zapret kuruluyor; yönetici onayı gerekiyor...",
                            "Installing Zapret; administrator approval required…")
                let source = Self.shellQuote(prepared.sourceDirectory.path)
                let staged = try Self.stageHelperPayload(in: prepared.temporaryDirectory)
                let command = "set -e; "
                    + "test ! -e /opt/zapret; "
                    + "mkdir -p /opt; cp -R \(source) /opt/zapret; "
                    + "chown -R root:wheel /opt/zapret; "
                    + "xattr -dr com.apple.quarantine /opt/zapret 2>/dev/null || true; "
                    + "sh /opt/zapret/install_bin.sh; "
                    + "install -o root -g wheel -m 644 /opt/zapret/init.d/macos/zapret.plist /Library/LaunchDaemons/zapret.plist; "
                    + "launchctl bootout system/zapret >/dev/null 2>&1 || true; "
                    // enable, bootstrap'tan ÖNCE: önceki bir kaldırmadan kalan "disabled" durumunu temizler,
                    // aksi halde bootstrap reddedilir. Tüm launchctl adımları ölümcül değil (|| true).
                    + "launchctl enable system/zapret >/dev/null 2>&1 || true; "
                    + "launchctl bootstrap system /Library/LaunchDaemons/zapret.plist >/dev/null 2>&1 || true; "
                    + "launchctl kickstart -k system/zapret >/dev/null 2>&1 || true; "
                    + ": > \(ZapretPaths.protectFlag); "   // koruma açık: watchdog tpws'i diri tutsun
                    + Self.helperInstallSnippet(staged: staged)
                _ = try await Task.detached { try Self.runAdministratorCommandInline(command) }.value
                message = L("Zapret \(prepared.version) kuruldu ve otomatik başlatma etkinleştirildi",
                            "Zapret \(prepared.version) installed and auto-start enabled")
            } catch {
                message = L("Kurulum başarısız: \(error.localizedDescription)",
                            "Installation failed: \(error.localizedDescription)")
            }
            if let temporaryDirectory {
                try? FileManager.default.removeItem(at: temporaryDirectory)
            }
            isBusy = false
            refresh()
            // tpws launchd üzerinden birkaç yüz ms sonra ayağa kalkar; durumu kısa süre sonra
            // tazele ki kullanıcı "Yenile"ye basmadan "Korunuyor" görünsün.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            refreshStatusOnly()
        }
    }

    func uninstall() {
        isBusy = true
        message = L("Zapret kaldırılıyor; yönetici onayı gerekiyor...",
                    "Removing Zapret; administrator approval required…")
        Task {
            do {
                // ÖNEMLİ: Dosyaları silmeden önce `zapret stop` çalıştırılmalı; bu, PF firewall
                // yönlendirmesini (tüm 443/80 → tpws:988 rdr) geri alır. Aksi halde tpws ölünce
                // yönlendirme kalır ve TÜM HTTPS trafiği reddedilir (internet kopar).
                // Ardından garanti olarak zapret PF anchor'ını ve pf.conf satırlarını da temizleriz.
                let command = [
                    // ÖNCE watchdog'u sustur: bayrağı kaldır + watchdog'u boot-out et, yoksa tpws'i
                    // öldürdüğümüzde watchdog onu yeniden başlatabilir (yarış).
                    "rm -f \(ZapretPaths.protectFlag)",
                    "launchctl bootout system/zapret-watchdog 2>/dev/null || true",
                    "rm -f \(ZapretPaths.watchdogPlist)",
                    // Firewall'ı geri al (PF rdr kalırsa internet kopar), sonra daemon'u durdur.
                    "[ -x \(ZapretPaths.executable) ] && \(ZapretPaths.executable) stop 2>/dev/null || true",
                    "launchctl bootout system/zapret 2>/dev/null || true",
                    "launchctl disable system/zapret 2>/dev/null || true",
                    "pkill -f /opt/zapret/tpws/tpws 2>/dev/null || true",
                    "sleep 1",
                    "pkill -9 -f /opt/zapret/tpws/tpws 2>/dev/null || true",
                    "pfctl -a zapret -F all 2>/dev/null || true",
                    "sed -i '' '/anchor \"zapret\"/d' /etc/pf.conf 2>/dev/null || true",
                    "pfctl -f /etc/pf.conf 2>/dev/null || true",
                    "rm -f /Library/LaunchDaemons/zapret.plist",
                    "rm -rf /opt/zapret",
                    "rm -f \(ZapretPaths.sudoers)"
                ].joined(separator: "; ")
                _ = try await Task.detached { try Self.runAdministratorCommandInline(command) }.value
                domains = ""
                checks = []
                message = L("Zapret tamamen kaldırıldı", "Zapret completely removed")
            } catch {
                message = L("Kaldırma başarısız: \(error.localizedDescription)",
                            "Removal failed: \(error.localizedDescription)")
            }
            isBusy = false
            refresh()
        }
    }

    func saveDomains() {
        let result = Self.validatedDomains(from: domains)
        guard result.invalid.isEmpty else {
            message = L("Geçersiz alan adı: \(result.invalid.joined(separator: ", "))",
                        "Invalid domain: \(result.invalid.joined(separator: ", "))")
            return
        }
        guard !result.valid.isEmpty else {
            message = L("Hostlist boş bırakılamaz", "The domain list can’t be empty")
            return
        }

        isBusy = true
        message = L("Alan adları kaydediliyor...", "Saving domains…")
        let contents = result.valid.joined(separator: "\n") + "\n"

        Task {
            do {
                let stagingDirectory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("zapret-hosts-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(
                    at: stagingDirectory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                let temporaryURL = stagingDirectory.appendingPathComponent("hosts.txt")
                try contents.write(to: temporaryURL, atomically: true, encoding: .utf8)
                _ = try await Self.runPrivileged(helperArgs: ["apply-hostlist", temporaryURL.path])
                try? FileManager.default.removeItem(at: stagingDirectory)
                domains = result.valid.joined(separator: "\n")
                message = L("Hostlist kaydedildi ve Zapret yeniden başlatıldı",
                            "Domain list saved and Zapret restarted")
            } catch {
                message = L("Kaydetme başarısız: \(error.localizedDescription)",
                            "Save failed: \(error.localizedDescription)")
            }
            isBusy = false
            refreshStatusOnly()
        }
    }

    func runDiagnostics() {
        isBusy = true
        checks = []
        message = L("Bağlantılar test ediliyor...", "Testing connections…")
        Task {
            let targets = [
                ("Discord", "https://discord.com/api/v10/gateway", [200]),
                ("OpenAI / Codex", "https://api.openai.com/v1/models", [401]),
                ("Anthropic / Claude", "https://api.anthropic.com", [404]),
                ("GitHub", "https://github.com", [200])
            ]
            var output: [EndpointCheck] = []
            for target in targets {
                let code = await Self.httpStatus(for: target.1)
                output.append(EndpointCheck(
                    name: target.0,
                    result: code == 0 ? L("Bağlantı kurulamadı", "Unreachable") : "HTTP \(code)",
                    succeeded: target.2.contains(code)
                ))
            }
            checks = output
            message = output.allSatisfy(\ .succeeded)
                ? L("Tüm bağlantılar sağlıklı", "All connections healthy")
                : L("Bazı bağlantılar başarısız", "Some connections failed")
            isBusy = false
            refreshStatusOnly()
        }
    }

    private func addPreset(_ preset: [String]) {
        var current = Set(domains.split(whereSeparator: \ .isNewline).map(String.init))
        current.formUnion(preset)
        domains = current.sorted().joined(separator: "\n")
        message = L("Profil editöre eklendi; uygulamak için Kaydet'e basın",
                    "Profile added to the editor; press Save to apply")
    }

    private func performServiceAction(_ action: String, success: String) {
        guard ["start", "stop", "restart"].contains(action) else { return }
        isBusy = true
        message = L("İşlem yapılıyor...", "Working…")
        Task {
            do {
                _ = try await Self.runPrivileged(helperArgs: [action])
                message = success
            } catch {
                message = L("İşlem başarısız: \(error.localizedDescription)",
                            "Operation failed: \(error.localizedDescription)")
            }
            isBusy = false
            refreshStatusOnly()
        }
    }

    private func refreshStatusOnly() {
        isInstalled = FileManager.default.isExecutableFile(atPath: ZapretPaths.executable)
        isRunning = Self.processIsRunning()
        isAutoStartEnabled = FileManager.default.fileExists(atPath: "/Library/LaunchDaemons/zapret.plist")
    }

    private static func validatedDomains(from text: String) -> (valid: [String], invalid: [String]) {
        let candidates = text
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
        let pattern = #"^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$"#
        let valid = candidates.filter { $0.range(of: pattern, options: .regularExpression) != nil }
        let invalid = candidates.filter { $0.range(of: pattern, options: .regularExpression) == nil }
        return (Array(Set(valid)).sorted(), Array(Set(invalid)).sorted())
    }

    nonisolated private static func processIsRunning() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", "/opt/zapret/tpws/tpws.*--port=988"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    nonisolated private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    nonisolated private static func prepareInstallerPayload() async throws -> (
        temporaryDirectory: URL,
        sourceDirectory: URL,
        version: String
    ) {
        let apiURL = URL(string: "https://api.github.com/repos/bol-van/zapret/releases/latest")!
        var request = URLRequest(url: apiURL)
        request.setValue("ZapretManager/0.2", forHTTPHeaderField: "User-Agent")
        let (releaseData, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "ZapretMac", code: 20, userInfo: [NSLocalizedDescriptionKey: "GitHub sürüm bilgisi alınamadı"])
        }
        let release = try JSONDecoder().decode(GitHubRelease.self, from: releaseData)
        guard let archiveAsset = release.assets.first(where: {
            $0.name.hasSuffix(".tar.gz") && !$0.name.contains("openwrt")
        }), let checksumAsset = release.assets.first(where: { $0.name == "sha256sum.txt" }) else {
            throw NSError(domain: "ZapretMac", code: 21, userInfo: [NSLocalizedDescriptionKey: "Uygun macOS yayın paketi bulunamadı"])
        }

        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("zapret-manager-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let archiveURL = directory.appendingPathComponent(archiveAsset.name)
        let checksumsURL = directory.appendingPathComponent("sha256sum.txt")
        try await download(archiveAsset.browserDownloadURL, to: archiveURL)
        try await download(checksumAsset.browserDownloadURL, to: checksumsURL)
        _ = try runProcess("/usr/bin/tar", arguments: ["-xzf", archiveURL.path, "-C", directory.path])

        let candidates = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        guard let source = candidates.first(where: {
            let isDirectory = (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            return $0.lastPathComponent.hasPrefix("zapret-") && isDirectory
        }) else {
            throw NSError(domain: "ZapretMac", code: 22, userInfo: [NSLocalizedDescriptionKey: "İndirilen paket açılamadı"])
        }

        let checksumText = try String(contentsOf: checksumsURL, encoding: .utf8)
        let relativeBinary = "\(source.lastPathComponent)/binaries/mac64/tpws"
        try verifyChecksums(checksumText, baseDirectory: directory, requiredPath: relativeBinary)

        try configureFreshInstall(at: source)
        return (directory, source, release.tagName)
    }

    /// `sha256sum.txt` içindeki her kayıt için ilgili dosyanın hash'ini doğrular.
    /// Tek bir ikiliyle yetinmek yerine root olarak çalışacak tüm scriptleri (install_bin.sh vb.)
    /// kapsar; ayrıca kritik macOS ikilisinin (`requiredPath`) listede yer aldığını ve doğrulandığını
    /// garanti eder, böylece kurcalanmış bir checksum dosyası kaydı çıkararak doğrulamayı atlatamaz.
    nonisolated private static func verifyChecksums(
        _ checksumText: String,
        baseDirectory: URL,
        requiredPath: String
    ) throws {
        var verifiedCount = 0
        var requiredVerified = false

        for line in checksumText.split(whereSeparator: \ .isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let expected = parts[0].lowercased()
            var relativePath = parts[1].trimmingCharacters(in: .whitespaces)
            if relativePath.hasPrefix("*") { relativePath.removeFirst() } // ikili mod işareti
            guard !expected.isEmpty, !relativePath.isEmpty else { continue }

            let fileURL = baseDirectory.appendingPathComponent(relativePath)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                continue // listede olup arşivde olmayan kayıtları atla (ör. diğer platform dosyaları)
            }

            let hashOutput = try runProcess("/usr/bin/shasum", arguments: ["-a", "256", fileURL.path])
            let actual = (hashOutput.split(separator: " ").first.map(String.init) ?? "").lowercased()
            guard actual == expected else {
                throw NSError(domain: "ZapretMac", code: 24, userInfo: [
                    NSLocalizedDescriptionKey: "Hash doğrulaması başarısız: \(relativePath)"
                ])
            }

            verifiedCount += 1
            if relativePath == requiredPath { requiredVerified = true }
        }

        guard requiredVerified else {
            throw NSError(domain: "ZapretMac", code: 23, userInfo: [
                NSLocalizedDescriptionKey: "macOS ikilisi (\(requiredPath)) için SHA-256 kaydı bulunamadı"
            ])
        }
        guard verifiedCount > 0 else {
            throw NSError(domain: "ZapretMac", code: 27, userInfo: [
                NSLocalizedDescriptionKey: "Doğrulanacak dosya bulunamadı; checksum listesi boş veya bozuk"
            ])
        }
    }

    nonisolated private static func download(_ remoteURL: URL, to localURL: URL) async throws {
        var request = URLRequest(url: remoteURL)
        request.setValue("ZapretManager/0.2", forHTTPHeaderField: "User-Agent")
        let (temporaryURL, response) = try await URLSession.shared.download(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "ZapretMac", code: 25, userInfo: [NSLocalizedDescriptionKey: "Dosya indirilemedi: \(remoteURL.lastPathComponent)"])
        }
        try FileManager.default.moveItem(at: temporaryURL, to: localURL)
    }

    nonisolated private static func configureFreshInstall(at source: URL) throws {
        let defaultConfigURL = source.appendingPathComponent("config.default")
        let configURL = source.appendingPathComponent("config")
        var config = try String(contentsOf: defaultConfigURL, encoding: .utf8)
        let interfaceOutput = try? runProcess("/sbin/route", arguments: ["-n", "get", "default"])
        let interface = interfaceOutput?
            .split(whereSeparator: \ .isNewline)
            .first(where: { $0.contains("interface:") })?
            .split(separator: ":", maxSplits: 1)
            .last?
            .trimmingCharacters(in: .whitespaces) ?? "en0"
        let replacements = [
            "GZIP_LISTS=1": "GZIP_LISTS=0",
            "#LISTS_RELOAD=\"pfctl -f /etc/pf.conf\"": "LISTS_RELOAD=\"/opt/zapret/init.d/macos/zapret reload-fw-tables\"",
            "--filter-tcp=443 --split-pos=1,midsld --disorder <HOSTLIST>": "--filter-tcp=443 --tlsrec=midsld --disorder <HOSTLIST>",
            "TPWS_ENABLE=0": "TPWS_ENABLE=1",
            "MODE_FILTER=none": "MODE_FILTER=hostlist",
            "#IFACE_LAN=eth0": "IFACE_LAN=\(interface)"
        ]
        for (old, new) in replacements {
            guard config.contains(old) else {
                throw NSError(domain: "ZapretMac", code: 26, userInfo: [NSLocalizedDescriptionKey: "Resmi config biçimi değişmiş: \(old)"])
            }
            config = config.replacingOccurrences(of: old, with: new)
        }
        try config.write(to: configURL, atomically: true, encoding: .utf8)

        let hostlist = discordPresetStatic.joined(separator: "\n") + "\n"
        try hostlist.write(
            to: source.appendingPathComponent("ipset/zapret-hosts-user.txt"),
            atomically: true,
            encoding: .utf8
        )
        let exclude = source.appendingPathComponent("ipset/zapret-hosts-user-exclude.txt")
        if !FileManager.default.fileExists(atPath: exclude.path) {
            try FileManager.default.copyItem(
                at: source.appendingPathComponent("ipset/zapret-hosts-user-exclude.txt.default"),
                to: exclude
            )
        }
    }

    nonisolated private static let discordPresetStatic = [
        "discord.com", "discord.gg", "discordapp.com",
        "discordapp.net", "discord.media", "discordcdn.com"
    ]

    // MARK: - Ayrıcalıklı çalıştırma

    /// Ayrıcalıklı bir işlemi çalıştırır.
    ///
    /// Önce şifresiz yolu dener: sudoers'taki NOPASSWD kuralıyla root sahipli yardımcıyı
    /// `sudo -n` ile çağırır — hiç istem çıkmaz. Yardımcı kurulu değilse (ör. ilk kullanım ya da
    /// eski kurulum) tek seferlik yönetici istemine düşer; bu istemde hem işi yapar hem de
    /// yardımcıyı + sudoers kuralını kurar, böylece sonraki çağrılar şifresiz olur.
    nonisolated private static func runPrivileged(helperArgs: [String]) async throws -> String {
        try await Task.detached {
            if canUseHelper() {
                return try runProcess("/usr/bin/sudo", arguments: ["-n", ZapretPaths.helper] + helperArgs)
            }
            // Şifresiz yol yok (ilk kullanım, eski kurulum ya da sürüm güncellemesi):
            // tek seferlik yönetici istemiyle yardımcıyı kur ve aynı root oturumunda çağır.
            // Böylece iş mantığı tek kaynakta (yardımcı script) kalır.
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("zapret-helper-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            defer { try? FileManager.default.removeItem(at: directory) }
            let staged = try stageHelperPayload(in: directory)
            let invocation = ([ZapretPaths.helper] + helperArgs).map(shellQuote).joined(separator: " ")
            let command = helperInstallSnippet(staged: staged) + "; " + invocation
            return try runAdministratorCommandInline(command)
        }.value
    }

    /// Yardımcının şifresiz çağrılabilir **ve güncel sürümde** olup olmadığını sessizce sınar.
    /// Kurulu yardımcı eski sürümse (sürüm damgası eşleşmezse) `false` döner; böylece bir sonraki
    /// işlem yardımcıyı tek seferlik istemle günceller. `sudo -n` interaktif olmadığından yetki
    /// yoksa istem çıkmadan hata döner.
    nonisolated private static func canUseHelper() -> Bool {
        guard FileManager.default.isExecutableFile(atPath: ZapretPaths.helper) else { return false }
        guard let installed = try? String(contentsOfFile: ZapretPaths.helper, encoding: .utf8),
              installed.contains(helperVersionToken) else { return false }
        return (try? runProcess("/usr/bin/sudo", arguments: ["-n", ZapretPaths.helper, "noop"])) != nil
    }

    /// Komutu yönetici istemiyle (osascript) çalıştırır. Komut yalnızca bizim ürettiğimiz,
    /// doğrulanmış değerlerden oluşur; AppleScript dizesi için yalnızca `\` ve `"` kaçışlanır.
    nonisolated private static func runAdministratorCommandInline(_ command: String) throws -> String {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        return try runProcess("/usr/bin/osascript", arguments: ["-e", script])
    }

    /// Yardımcı, sudoers, watchdog script ve watchdog plist'ini sahibine özel (0700) geçici dizine yazar.
    nonisolated private static func stageHelperPayload(in directory: URL)
        throws -> (helper: URL, sudoers: URL, watchdog: URL, watchdogPlist: URL) {
        let helperURL = directory.appendingPathComponent("zapret-mgr-helper.sh")
        let sudoersURL = directory.appendingPathComponent("zapret-manager.sudoers")
        let watchdogURL = directory.appendingPathComponent("zapret-watchdog.sh")
        let watchdogPlistURL = directory.appendingPathComponent("zapret-watchdog.plist")
        try helperScript.write(to: helperURL, atomically: true, encoding: .utf8)
        try sudoersRule().write(to: sudoersURL, atomically: true, encoding: .utf8)
        try watchdogScript.write(to: watchdogURL, atomically: true, encoding: .utf8)
        try watchdogPlistContent.write(to: watchdogPlistURL, atomically: true, encoding: .utf8)
        return (helperURL, sudoersURL, watchdogURL, watchdogPlistURL)
    }

    /// Geçici dosyalardan yardımcıyı, sudoers kuralını ve watchdog'u yerine kuran kabuk parçası.
    /// Idempotent: her ayrıcalıklı işlemde güvenle yeniden çalıştırılabilir. Geçersiz sudoers
    /// dosyası `visudo -c` ile reddedilir ve silinir, böylece sudo bozulmaz.
    nonisolated private static func helperInstallSnippet(
        staged: (helper: URL, sudoers: URL, watchdog: URL, watchdogPlist: URL)
    ) -> String {
        [
            "install -o root -g wheel -m 755 \(shellQuote(staged.helper.path)) \(ZapretPaths.helper)",
            "install -o root -g wheel -m 440 \(shellQuote(staged.sudoers.path)) \(ZapretPaths.sudoers)",
            "visudo -cf \(ZapretPaths.sudoers) >/dev/null 2>&1 || rm -f \(ZapretPaths.sudoers)",
            // watchdog kur + launchd'e yükle (idempotent)
            "install -o root -g wheel -m 755 \(shellQuote(staged.watchdog.path)) \(ZapretPaths.watchdog)",
            "install -o root -g wheel -m 644 \(shellQuote(staged.watchdogPlist.path)) \(ZapretPaths.watchdogPlist)",
            "launchctl bootout system/zapret-watchdog >/dev/null 2>&1 || true",
            "launchctl enable system/zapret-watchdog >/dev/null 2>&1 || true",
            "launchctl bootstrap system \(ZapretPaths.watchdogPlist) >/dev/null 2>&1 || true"
        ].joined(separator: "; ")
    }

    /// Kurulu yardımcının sürümünü işaretler. Script mantığı değişince artırılır; `canUseHelper`
    /// bu damgayı arar ve eşleşmezse eski yardımcıyı tek seferlik istemle günceller.
    nonisolated private static let helperVersionToken = "zapret-mgr-helper v4"

    /// Root olarak (sudo ile) çalışan yardımcı. Yalnızca beyaz listedeki alt komutları kabul eder;
    /// tüm argümanlar tırnaklanır, `eval` yoktur. Root sahipli ve 0755 olduğundan yalnızca root
    /// değiştirebilir; sudoers kuralı yalnızca kuran kullanıcıya şifresiz çağrı izni verir.
    ///
    /// `hard_stop`: upstream `zapret stop` daemon'u yalnızca pidfile'dan öldürür; pidfile
    /// kaybolur/eskimezse tpws hayatta kalır (ve pidfile yokken `restart` ikinci kopya başlatabilir).
    /// Ayrıca tpws SIGTERM'i yok sayıyor, bu yüzden önce SIGTERM dener, hâlâ ayaktaysa SIGKILL ile
    /// kesin sonlandırırız.
    nonisolated private static let helperScript = """
    #!/bin/sh
    # zapret-mgr-helper v4
    set -e
    ZAPRET="/opt/zapret/init.d/macos/zapret"
    TPWS="/opt/zapret/tpws/tpws"
    HOSTLIST="/opt/zapret/ipset/zapret-hosts-user.txt"
    FLAG="/opt/zapret/.mgr-protect-enabled"

    hard_stop() {
        "$ZAPRET" stop 2>/dev/null || true
        pids=$(pgrep -f "$TPWS" 2>/dev/null || true)
        if [ -n "$pids" ]; then
            kill $pids 2>/dev/null || true
            sleep 1
            pids=$(pgrep -f "$TPWS" 2>/dev/null || true)
            [ -n "$pids" ] && kill -9 $pids 2>/dev/null || true
        fi
    }

    case "$1" in
        start)
            # İstenen durum: açık. Watchdog tpws ölürse yeniden başlatır.
            : > "$FLAG"
            exec "$ZAPRET" start
            ;;
        stop)
            # İstenen durum: kapalı. Bayrağı ÖNCE kaldır ki watchdog diriltmesin.
            rm -f "$FLAG"
            hard_stop
            ;;
        restart)
            : > "$FLAG"
            hard_stop
            exec "$ZAPRET" start
            ;;
        apply-hostlist)
            [ -f "$2" ] || { echo "kaynak dosya bulunamadi" >&2; exit 1; }
            ts="$(date +%Y%m%d-%H%M%S)"
            [ -f "$HOSTLIST" ] && cp "$HOSTLIST" "$HOSTLIST.backup-$ts"
            install -o root -g wheel -m 644 "$2" "$HOSTLIST"
            : > "$FLAG"
            hard_stop
            exec "$ZAPRET" start
            ;;
        noop)
            exit 0
            ;;
        *)
            echo "bilinmeyen komut: $1" >&2
            exit 2
            ;;
    esac

    """

    /// tpws watchdog'u: koruma açık olması gerekirken (bayrak var) tpws ölmüşse yeniden başlatır.
    /// launchd tarafından düzenli aralıkla çalıştırılır. PF yönlendirmesi aktifken tpws ölürse
    /// tüm HTTPS kopar; bu watchdog onu ~aralık kadar sürede geri getirir.
    nonisolated private static let watchdogScript = """
    #!/bin/sh
    # zapret-watchdog v1
    FLAG="/opt/zapret/.mgr-protect-enabled"
    TPWS="/opt/zapret/tpws/tpws"
    ZAPRET="/opt/zapret/init.d/macos/zapret"
    [ -f "$FLAG" ] || exit 0
    pgrep -f "$TPWS" >/dev/null 2>&1 && exit 0
    "$ZAPRET" start >/dev/null 2>&1
    exit 0

    """

    nonisolated private static let watchdogPlistContent = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>Label</key>
        <string>zapret-watchdog</string>
        <key>ProgramArguments</key>
        <array>
            <string>/bin/sh</string>
            <string>/opt/zapret/zapret-watchdog.sh</string>
        </array>
        <key>RunAtLoad</key>
        <true/>
        <key>StartInterval</key>
        <integer>10</integer>
    </dict>
    </plist>

    """

    nonisolated private static func sudoersRule() -> String {
        "\(NSUserName()) ALL=(root) NOPASSWD: \(ZapretPaths.helper)\n"
    }

    nonisolated private static func httpStatus(for url: String) async -> Int {
        await Task.detached {
            let output = try? runProcess(
                "/usr/bin/curl",
                arguments: ["-4", "--http1.1", "--max-time", "12", "-sS", "-o", "/dev/null", "-w", "%{http_code}", url]
            )
            return Int(output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
        }.value
    }

    nonisolated private static func runProcess(_ path: String, arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let stdout = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if process.terminationStatus != 0 {
            let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw NSError(domain: "ZapretMac", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: stderr.isEmpty ? stdout : stderr
            ])
        }
        return stdout
    }
}

// MARK: - Tasarım sistemi

private enum Theme {
    static let ink     = Color(red: 0.055, green: 0.063, blue: 0.082) // #0E1015 — sol ray
    static let surface = Color(red: 0.078, green: 0.090, blue: 0.118) // #14171E — sağ panel
    static let card    = Color(red: 0.102, green: 0.118, blue: 0.153) // #1A1E27
    static let stroke  = Color(red: 0.149, green: 0.169, blue: 0.212) // #262B36
    static let textHi  = Color(red: 0.933, green: 0.945, blue: 0.965) // #EEF1F6
    static let textLo  = Color(red: 0.545, green: 0.573, blue: 0.643) // #8B92A4
    static let active  = Color(red: 0.208, green: 0.878, blue: 0.753) // #35E0C0 — aurora teal
    static let warn    = Color(red: 1.000, green: 0.478, blue: 0.400) // #FF7A66 — mercan
    static let amber   = Color(red: 0.961, green: 0.725, blue: 0.302) // #F5B94D
    static let accent  = Color(red: 0.486, green: 0.514, blue: 1.000) // #7C83FF — indigo
    static let onBright = Color(red: 0.039, green: 0.047, blue: 0.063) // parlak zemin üstü koyu yazı
}

private enum Protection {
    case notInstalled, running, stopped

    var title: String {
        switch self {
        case .notInstalled: return L("Kurulu Değil", "Not Installed")
        case .running:      return L("Korunuyor", "Protected")
        case .stopped:      return L("Kapalı", "Off")
        }
    }

    var subtitle: String {
        switch self {
        case .notInstalled: return L("Başlamak için Zapret’i kur", "Install Zapret to get started")
        case .running:      return L("tpws etkin · trafik filtreleniyor", "tpws active · filtering traffic")
        case .stopped:      return L("Koruma şu an devre dışı", "Protection is currently off")
        }
    }

    var color: Color {
        switch self {
        case .notInstalled: return Theme.accent
        case .running:      return Theme.active
        case .stopped:      return Theme.warn
        }
    }

    var icon: String {
        switch self {
        case .notInstalled: return "tray.and.arrow.down.fill"
        case .running:      return "shield.lefthalf.filled"
        case .stopped:      return "shield.slash"
        }
    }
}

// MARK: - İmza öğesi: durum küresi

private struct StatusOrb: View {
    let color: Color
    let icon: String
    let pulsing: Bool
    @Environment(\ .accessibilityReduceMotion) private var reduceMotion
    @State private var animate = false

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.20))
                .frame(width: 176, height: 176)
                .blur(radius: 30)

            if pulsing && !reduceMotion {
                ForEach(0..<3, id: \ .self) { index in
                    Circle()
                        .stroke(color.opacity(0.5), lineWidth: 1.5)
                        .frame(width: 116, height: 116)
                        .scaleEffect(animate ? 1.65 : 1.0)
                        .opacity(animate ? 0 : 0.55)
                        .animation(
                            .easeOut(duration: 2.6)
                                .repeatForever(autoreverses: false)
                                .delay(Double(index) * 0.85),
                            value: animate
                        )
                }
            }

            Circle()
                .fill(
                    RadialGradient(
                        colors: [color, color.opacity(0.5)],
                        center: .center, startRadius: 6, endRadius: 62
                    )
                )
                .frame(width: 116, height: 116)
                .overlay(Circle().stroke(.white.opacity(0.14), lineWidth: 1))
                .shadow(color: color.opacity(0.55), radius: 26)

            Image(systemName: icon)
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 176, height: 176)
        .onAppear { animate = pulsing }
        .onChange(of: pulsing) { _, newValue in animate = newValue }
    }
}

// MARK: - Yeniden kullanılabilir bileşenler

private struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color
    var fg: Color = Theme.onBright
    var fullWidth: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(fg)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .padding(.vertical, 12)
            .padding(.horizontal, fullWidth ? 0 : 18)
            .background(
                tint.opacity(configuration.isPressed ? 0.82 : 1),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .shadow(color: tint.opacity(0.35), radius: 12, y: 4)
            .contentShape(Rectangle())
    }
}

private struct ChipButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                Text(title)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.textHi)
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(Theme.card, in: Capsule())
            .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct Card<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: systemImage).font(.system(size: 12, weight: .semibold))
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.6)
            }
            .foregroundStyle(Theme.textLo)
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
    }
}

// MARK: - Ana ekran

private struct ContentView: View {
    @StateObject private var manager = ZapretManager()
    @State private var confirmUninstall = false
    // Dil değişince tüm L(...) çağrıları yeniden değerlenir (body yeniden çizilir).
    @AppStorage(AppLang.key) private var langRaw = AppLang.current.rawValue

    private var state: Protection {
        guard manager.isInstalled else { return .notInstalled }
        return manager.isRunning ? .running : .stopped
    }

    var body: some View {
        HStack(spacing: 0) {
            identityRail
            controlPanel
        }
        .frame(minWidth: 780, minHeight: 600)
        .preferredColorScheme(.dark)
        .confirmationDialog(L("Zapret tamamen kaldırılsın mı?", "Remove Zapret completely?"),
                            isPresented: $confirmUninstall, titleVisibility: .visible) {
            Button(L("Kaldır", "Remove"), role: .destructive) { manager.uninstall() }
            Button(L("Vazgeç", "Cancel"), role: .cancel) {}
        } message: {
            Text(L("/opt/zapret, açılışta otomatik başlatma ve şifresiz erişim kuralı kaldırılır.",
                   "Removes /opt/zapret, auto-start at login, and the password-free access rule."))
        }
    }

    // TR / EN değiştirici.
    private var languageToggle: some View {
        HStack(spacing: 0) {
            ForEach([Lang.tr, Lang.en], id: \ .self) { lang in
                let active = langRaw == lang.rawValue
                Text(lang.rawValue.uppercased())
                    .font(.system(size: 10, weight: .bold)).tracking(1)
                    .foregroundStyle(active ? Theme.onBright : Theme.textLo)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(active ? Theme.active : Color.clear, in: Capsule())
                    .contentShape(Capsule())
                    .onTapGesture { langRaw = lang.rawValue }
            }
        }
        .padding(2)
        .background(Theme.card, in: Capsule())
        .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
    }

    // Sol koyu kimlik rayı — uygulamanın kalbi: durum.
    private var identityRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("ZAPRET")
                        .font(.system(size: 19, weight: .heavy)).tracking(4)
                        .foregroundStyle(Theme.textHi)
                    Text("MANAGER · v0.2")
                        .font(.system(size: 10, weight: .semibold)).tracking(3)
                        .foregroundStyle(Theme.textLo)
                }
                Spacer()
                languageToggle
            }

            Spacer()

            VStack(spacing: 22) {
                StatusOrb(color: state.color, icon: state.icon, pulsing: state == .running)
                VStack(spacing: 6) {
                    Text(state.title)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.textHi)
                    Text(state.subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textLo)
                        .multilineTextAlignment(.center)
                }
                controlCluster
                    .disabled(manager.isBusy)
                    .opacity(manager.isBusy ? 0.55 : 1)
            }

            Spacer()

            if manager.isInstalled {
                HStack(spacing: 8) {
                    Image(systemName: manager.isAutoStartEnabled ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(manager.isAutoStartEnabled ? Theme.active : Theme.amber)
                    Text(manager.isAutoStartEnabled
                         ? L("Açılışta otomatik başlar", "Starts automatically at login")
                         : L("Otomatik başlatma kapalı", "Auto-start is off"))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textLo)
                    Spacer()
                }
                .padding(.bottom, 10)

                Button { confirmUninstall = true } label: {
                    Label(L("Zapret’i Kaldır", "Uninstall Zapret"), systemImage: "trash")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.warn.opacity(0.85))
                .disabled(manager.isBusy)
                .padding(.bottom, 12)
            }

            Rectangle().fill(Theme.stroke).frame(height: 1)

            HStack(spacing: 8) {
                if manager.isBusy { ProgressView().controlSize(.small) }
                Text(manager.message)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textLo)
                    .lineLimit(2)
                Spacer()
            }
            .padding(.top, 12)
        }
        .padding(24)
        .frame(width: 320)
        .frame(maxHeight: .infinity)
        .background(Theme.ink)
    }

    @ViewBuilder private var controlCluster: some View {
        if state == .notInstalled {
            Button(action: manager.installZapret) {
                Label(L("Zapret’i Kur", "Install Zapret"), systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(PrimaryButtonStyle(tint: Theme.accent, fg: .white))
        } else {
            VStack(spacing: 10) {
                if manager.isRunning {
                    Button(action: manager.stop) {
                        Label(L("Korumayı Durdur", "Stop Protection"), systemImage: "stop.fill")
                    }
                    .buttonStyle(PrimaryButtonStyle(tint: Theme.warn))
                } else {
                    Button(action: manager.start) {
                        Label(L("Korumayı Başlat", "Start Protection"), systemImage: "play.fill")
                    }
                    .buttonStyle(PrimaryButtonStyle(tint: Theme.active))
                }
                HStack(spacing: 8) {
                    ChipButton(title: L("Yeniden Başlat", "Restart"), systemImage: "arrow.clockwise", action: manager.restart)
                    ChipButton(title: L("Yenile", "Refresh"), systemImage: "arrow.triangle.2.circlepath", action: manager.refresh)
                }
            }
        }
    }

    // Sağ panel — alan adları ve tanılama.
    private var controlPanel: some View {
        ScrollView {
            VStack(spacing: 16) {
                domainsCard
                diagnosticsCard
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surface)
    }

    private var domainsCard: some View {
        Card(title: L("Hedef alan adları", "Target domains"), systemImage: "globe") {
            Text(L("Her satıra bir kök alan adı yazın. Alt alan adları otomatik kapsanır.",
                   "One root domain per line. Subdomains are covered automatically."))
                .font(.system(size: 12))
                .foregroundStyle(Theme.textLo)

            TextEditor(text: $manager.domains)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Theme.textHi)
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(minHeight: 220)
                .background(Theme.ink, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.stroke, lineWidth: 1))

            HStack {
                ChipButton(title: L("Discord profili", "Discord profile"), systemImage: "bolt.fill", action: manager.addDiscordPreset)
                Spacer()
                Button(action: manager.saveDomains) {
                    Text(L("Kaydet ve Uygula", "Save & Apply"))
                }
                .buttonStyle(PrimaryButtonStyle(tint: Theme.accent, fg: .white, fullWidth: false))
            }
        }
        .disabled(manager.isBusy)
        .opacity(manager.isBusy ? 0.7 : 1)
    }

    private var diagnosticsCard: some View {
        Card(title: L("Bağlantı testi", "Connection test"), systemImage: "dot.radiowaves.left.and.right") {
            if manager.checks.isEmpty {
                Text(L("Discord, OpenAI, Anthropic ve GitHub erişimini kontrol et.",
                       "Check access to Discord, OpenAI, Anthropic, and GitHub."))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textLo)
            } else {
                VStack(spacing: 8) {
                    ForEach(manager.checks) { check in
                        HStack(spacing: 10) {
                            Circle()
                                .fill(check.succeeded ? Theme.active : Theme.warn)
                                .frame(width: 8, height: 8)
                            Text(check.name)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Theme.textHi)
                            Spacer()
                            Text(check.result)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Theme.textLo)
                        }
                        .padding(.vertical, 9)
                        .padding(.horizontal, 12)
                        .background(Theme.ink, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                }
            }

            ChipButton(title: L("Bağlantıları Test Et", "Run Connection Test"), systemImage: "play.circle", action: manager.runDiagnostics)
                .disabled(!manager.isInstalled || manager.isBusy)
                .opacity(manager.isInstalled ? 1 : 0.5)
        }
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
private struct ZapretMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}
