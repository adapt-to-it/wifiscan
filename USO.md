# wifiscan

Analisi saturazione canali Wi-Fi su macOS 15 (Sequoia) e successivi. Due interfacce:

- **`wifiscan`** — CLI per terminale (originale)
- **`WifiScanner.app`** — App SwiftUI con sidebar e dashboard, Liquid Glass

Entrambe condividono il modulo `WifiScanCore` (scan, scoring, raccomandazioni).

## Build

```sh
swift build -c release        # tutto
swift build --target wifiscan # solo CLI
```

Output: `.build/release/wifiscan` (CLI) e `.build/release/WifiScannerApp` (binario UI).

## App SwiftUI

```sh
open WifiScanner.app
```

La prima volta:
1. Gatekeeper avvisa che l'app non è notarizzata → Impostazioni → Privacy e Sicurezza → "Apri comunque"
2. macOS chiederà permesso Location → consenti per vedere gli SSID reali

L'app ha 7 sezioni in sidebar:
- **Panoramica** — card della rete connessa, riepilogo bande, preview raccomandazioni
- **2.4 GHz / 5 GHz** — bar chart saturazione + tabella canali, badge DFS
- **Reti vicine** — elenco completo con SSID, BSSID, RSSI, badge "TU"
- **Raccomandazioni** — canale ottimale per banda con confronto rispetto al corrente
- **Dispositivi LAN** — scan ARP+ping+mDNS+OUI con tabella IP/Hostname/MAC/Vendor/Servizi.
  **Click su un device** → sheet con dettagli, nome custom, ping live, port scan, Wake-on-LAN.
  Badge **NUOVO** quando un MAC appare per la prima volta (o dopo > 7 giorni).
- **Diagnostica** — ping al gateway + 1.1.1.1 + 8.8.8.8, grafico latency live al gateway,
  IP pubblico + ISP via ipinfo.io, speed test ~10 MB su Cloudflare.

Toolbar: bottone *Scansiona* (.glassProminent, ⌘R) e *Impostazioni* (.glass).
Impostazioni: override manuali SSID/canale per quando Location non è attivo.

### Persistenza locale

L'app salva uno storico dei device LAN visti in:
`~/Library/Application Support/WifiScanner/wifiscan.sqlite`

Per ogni MAC: IP/hostname/vendor ultimi, prima e ultima volta visto, contatore avvistamenti, nome custom.

## CLI

```sh
.build/release/wifiscan -e                  # scan + raccomandazioni
.build/release/wifiscan -c                  # continuo ogni 10s
.build/release/wifiscan --my-ssid HS_5G -e  # identifica la tua rete
```

| Flag | Effetto |
|---|---|
| `-c, --continuous` | Scan ripetuto ogni 10s |
| `-e, --explain` | Raccomandazioni operative |
| `--my-ssid <SSID>` | Identifica la tua rete per nome |
| `--my-bssid <BSSID>` | Identifica per BSSID |
| `--my-channel <N>` | Identifica come rete più forte sul canale |
| `-h, --help` | Help |

## Icona

`swift scripts/make-icon.swift Resources` rigenera `Resources/AppIcon-1024.png` e `Resources/AppIcon.icns`.

## Aggiornare il bundle .app dopo modifiche

Il repository contiene solo `Resources/Info.plist` e l'icona: `mkdir -p WifiScanner.app/Contents/{MacOS,Resources}` crea il bundle la prima volta.

```sh
swift build -c release
cp .build/release/WifiScannerApp WifiScanner.app/Contents/MacOS/WifiScanner
cp .build/release/wifiscan_WifiScanCore.bundle/oui.plist WifiScanner.app/Contents/Resources/
cp Resources/Info.plist WifiScanner.app/Contents/
cp Resources/AppIcon.icns WifiScanner.app/Contents/Resources/
codesign --force --deep --options runtime --timestamp \
    --entitlements WifiScanner.entitlements \
    --sign "Developer ID Application: MARCO ABBATTISTA (38C8C426NW)" \
    WifiScanner.app
```

⚠️ **Non dimenticare `--entitlements WifiScanner.entitlements`**: senza l'entitlement
`com.apple.security.personal-information.location` macOS non mostra il prompt
Location e l'app non vede SSID/BSSID reali.

### Notarizzazione (per distribuire ad altri Mac)

Le credenziali stanno nel portachiavi con profilo `notary`.

```sh
ditto -c -k --keepParent WifiScanner.app /tmp/WifiScanner.zip
xcrun notarytool submit /tmp/WifiScanner.zip --keychain-profile notary --wait
xcrun stapler staple WifiScanner.app
ditto -c -k --keepParent WifiScanner.app ~/Desktop/WifiScanner.zip   # zip da inviare
```

Ogni rebuild invalida firma e ticket: rifirmare, notarizzare e graffare di nuovo.

## Logica di scoring

- Soglia CCA: reti < −85 dBm ignorate
- Pesi: co-channel 1.0, overlap 80 MHz 0.7, adjacent 2.4 GHz 0.3
- Dedup: BSSID virtuali sullo stesso AP fisico
- Auto-detect rete propria via canale corrente; override via flag o Impostazioni

## Struttura del progetto

```
Sources/
  WifiScanCore/        # libreria condivisa
    Models.swift       # ScannedNetwork, ConnectedNetwork, ScanResult
    Scanner.swift      # WiFiScanner (wrapper CoreWLAN)
    Scoring.swift      # ChannelLoad, Scoring, SelfDetector, ChannelAnalyzer, ChannelClass
    ScanRunner.swift   # ScanRunner + Recommender
  wifiscan/            # CLI executable
    main.swift
  WifiScannerApp/      # App SwiftUI executable
    App.swift          # @main, WindowGroup
    ContentView.swift  # NavigationSplitView + sidebar + toolbar
    ScanViewModel.swift
    OverviewView.swift
    BandView.swift
    NetworksView.swift
    RecommendationsView.swift
WifiScanner.app/       # bundle firmato per distribuzione
```
