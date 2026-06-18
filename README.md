# Zapret Manager for macOS

Zapret Manager, mevcut `/opt/zapret` kurulumunu güvenli bir macOS arayüzünden yönetir.

## Özellikler

- Zapret kurulu değilse resmi GitHub sürümünü indirir ve indirilen tüm dosyaları `sha256sum.txt` ile doğrulayarak kurar.
- Zapret ve `tpws` durumunu gösterir.
- Başlatma, durdurma ve yeniden başlatma işlemlerini yönetici onayıyla yapar.
- Hedefli hostlist düzenler ve her kayıttan önce zaman damgalı yedek oluşturur.
- Discord için hazır alan adı profili sunar; diğer alan adlarını kullanıcı kendisi ekler.
- Discord, OpenAI, Anthropic ve GitHub bağlantılarını test eder.
- Kullanıcı girdisini kabuk komutuna eklemeden önce alan adı olarak doğrular.

## Derleme

```sh
./build_app.sh          # yalnızca .app
./build_app.sh --dmg    # .app + dağıtılabilir .dmg
```

Çıktılar: `dist/Zapret Manager.app` ve (`--dmg` ile) `dist/Zapret Manager.dmg`.

Uygulama simgesi `Icon/make_icon.swift` ile her derlemede üretilir ve pakete gömülür.
DMG, sürükle-bırak kurulum için uygulamayı ve `Applications` kısayolunu içerir.

## Gereksinimler

- **Apple Silicon (M1 ve sonrası) Mac.** Uygulama yalnızca `arm64` derlenir; Intel Mac'ler desteklenmez.
- macOS 14 (Sonoma) veya üzeri.

## İlk açılış (Gatekeeper)

Uygulama Developer ID ile imzalanıp notarize edilmediği için, indirildikten sonra macOS ilk açılışı engeller. Açmak için:

1. `Zapret Manager.app`'i **Applications**'a sürükleyin.
2. Uygulamaya **sağ tıklayın → Aç**, sonra çıkan uyarıda tekrar **Aç**'a basın.
3. Engellenirse: **Sistem Ayarları → Gizlilik ve Güvenlik** → en altta "Zapret Manager engellendi" satırının yanındaki **Yine de Aç**'a basın.

Bu yalnızca ilk açılışta gereklidir.

## Dayanıklılık (watchdog)

tpws beklenmedik şekilde sonlanırsa (çökme, uyku/uyanma) PF yönlendirmesi nedeniyle tüm HTTPS kopabilir. Bunu önlemek için bir watchdog LaunchDaemon (`zapret-watchdog`) tpws'i ~10 saniyede bir izler ve koruma açık olması gerekirken (istenen-durum bayrağı) tpws ölmüşse otomatik yeniden başlatır. Kullanıcı korumayı bilerek durdurduysa watchdog dokunmaz.

## Kaldırma

Uygulamadaki sol paneldeki **Zapret’i Kaldır** düğmesi; `/opt/zapret`, LaunchDaemon (otomatik başlatma), watchdog ve sudoers (şifresiz erişim) kuralını tamamen siler.

## Mevcut sınır

Sürüm 0.2 sıfırdan kurulum, kaldırma ve kalıcı LaunchDaemon kaydı yapabilir. Geniş dağıtım için güncelleme, Developer ID imzası ve notarization ayrıca eklenebilir.
