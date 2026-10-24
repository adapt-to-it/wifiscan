# Specifica del motore di diagnosi

Stato: bozza 2, 2026-10-16. Recepisce la revisione della bozza 1.

Modifiche principali rispetto alla bozza 1:

- Il modello di inferenza è un noisy-OR su insiemi di cause enumerati. Sostituisce punteggio additivo, dominanza degli strati, explaining away iterativo e regole sulle cause concomitanti.
- Le firme usano un vocabolario chiuso di sintomi e un'algebra esplicita. Le feature correlate confluiscono in un solo sintomo.
- I dati che descrivono il contesto, per esempio l'exit node attivo, AWDL attivo o Ethernet, non sono sintomi. Abilitano le cause e ne modificano il prior.
- Il primo rilascio copre 10 cause più la causa ignota. Il resto del catalogo passa alla fase 2.
- Il criterio di accettazione si basa sulle sessioni reali. Gli scenari sintetici servono solo come test di regressione.
- Il protocollo di misura corregge i difetti della bozza 1: scansioni che sporcano il monitor, rate a link fermo, aggregazione dei bersagli internet, gateway che penalizza ICMP, MTU di Tailscale.

## 0. Scopo e promessa

Il motore risponde alla domanda pratica: "il problema è il Wi-Fi, il router, il provider, il DNS o la VPN?".
Restituisce un esito della sezione 7. Ogni causa riportata ha:

- una probabilità a posteriori;
- le evidenze che la sostengono e quelle che la contraddicono;
- un'azione per l'utente, in forma affermativa o prudente secondo l'esito;
- il test che la conferma o la esclude, quando serve.

Il motore promette tre cose verificabili:

1. Copre un catalogo esplicito di cause. Ogni causa ha una firma sui sintomi della sezione 5.
2. Non dà una diagnosi sicura e sbagliata. Quando le evidenze non bastano o non corrispondono a nessuna causa nota, lo dichiara.
3. Supera i criteri di accettazione della sezione 12 sulle sessioni reali.

Le probabilità diventano "calibrate" solo dopo la taratura sulle sessioni reali. Prima di allora l'interfaccia mostra livelli qualitativi (alta, media, bassa), non percentuali.

## 1. Principi

1. **Nessuna soglia secca.** Le misure entrano come gradi tra 0 e 1 tramite rampe lineari.
2. **Il contesto cambia il significato.** Le dipendenze stanno nelle feature derivate, per esempio l'efficienza del rate rispetto all'SNR e al PHY, e nei fatti di contesto.
3. **Un fenomeno fisico, un sintomo.** Feature che derivano dalla stessa grandezza non si sommano come evidenze indipendenti.
4. **Tempo, non istantanee.** Le feature si calcolano su finestre, e i campioni contaminati si scartano.
5. **Incertezza esplicita.** Ogni sintomo ha una confidenza. Un sintomo senza confidenza non sposta le probabilità.
6. **Spiegabilità.** Ogni causa riportata mostra i sintomi che spiega e il loro contributo.
7. **Prima i dati, poi i pesi.** Nessun peso si considera tarato prima del confronto con sessioni reali.

## 2. Fasi di sviluppo

| Fase | Contenuto | Criterio di uscita |
|---|---|---|
| 0. Misure | Monitor e registrazione delle sessioni: N1, N2, N13, M1, M6, M10, stato di `awdl0`, contatori di byte, eventi di collegamento, marcatura delle scansioni. Studio delle misure (3.5) | Studio completato su almeno due Mac. Almeno 10 sessioni reali registrate ed etichettate |
| 1. Nucleo | Motore noisy-OR, 10 cause della sezione 8 più la causa ignota, esiti, interfaccia | Criteri 12.4 sulle sessioni reali |
| 2. Estensione | Cause della sezione 9, test guidati, storico | Ogni nuova causa entra con almeno 3 sessioni reali che la contengono |

Le sessioni reali si registrano fin dalla fase 0, prima di scrivere il motore.

## 3. Osservabilità e protocollo di misura

### 3.1 Misure

| ID | Misura | Fonte | Fase |
|---|---|---|---|
| M1 | RSSI, rumore, rate di trasmissione, PHY, canale, banda, larghezza, SSID, BSSID | `LinkMonitor.snapshot()` | 0 |
| M2 | Reti vicine | `ScanResult.networks` | 0 |
| M3 | Information Element: BSS Load, generazione, sicurezza, 802.11k/v/r | `BeaconInfo` | 0 |
| M6 | Throughput, RPM, RTT di base, interfaccia | `NetworkQualityRunner` | 0 |
| M7 | Gateway e subnet | `LocalNetwork` | 0 |
| M10 | Tailscale: peer, subnet, exit node | `Tailscale` | 0 |
| N1 | Ping ogni secondo verso il gateway, 1.1.1.1 e 8.8.8.8 | socket ICMP esistente | 0 |
| N2 | Latenza DNS per resolver su nome casuale: resolver di sistema e 1.1.1.1 | socket UDP | 0 |
| N13 | Ping sotto carico: N1 in parallelo a M6 | N1 + M6 | 0 |
| N14 | Stato di `awdl0`: flag `IFF_UP` e `IFF_RUNNING`, byte trasmessi | `getifaddrs`, `if_data` | 0 |
| N15 | Contatori di byte dell'interfaccia Wi-Fi e di quella della route predefinita | `getifaddrs`, `if_data` | 0 |
| N16 | Eventi di collegamento: disconnessione, riconnessione, cambio BSSID | `CWEventDelegate` (`linkDidChange`, `bssidDidChange`) | 0 |
| N17 | Interfaccia della route predefinita, Ethernet attiva | tabella di routing, `getifaddrs` | 0 |
| N3–N10 | DNS di sistema, lease DHCP, traceroute, IP WAN via UPnP, IPv6, MTU, portale captive, Tailscale diretto o relay | come bozza 1 | 2 |

Il nome dell'interfaccia Wi-Fi si legge da `CWInterface.interfaceName`. Non si presume `en0`: su Mac mini, iMac e Mac Pro è spesso `en1`.

### 3.2 Protocollo del monitor

1. **Scansioni.** Con il monitor attivo l'app non avvia scansioni periodiche. Usa `cachedScanResults()` e al massimo una scansione attiva ogni 60 s. I campioni N1 tra l'inizio della scansione e 500 ms dopo la sua fine sono marcati `contaminato` e non entrano in nessuna feature.
2. **Rate.** Le feature basate su `txRate` usano solo i campioni con traffico reale in trasmissione: byte trasmessi sull'interfaccia Wi-Fi sopra 1 Mbit/s nel secondo, da N15. In pratica servono i campioni raccolti durante M6.
3. **Direzione.** `txRate` riguarda la direzione Mac → AP. Si confronta solo con l'upload di M6, mai con il download.
4. **Bersagli internet.** La perdita, il p50 e il jitter si calcolano per ogni bersaglio sull'intera finestra. Poi si prende il minimo tra i bersagli. Un bersaglio che filtra ICMP resta così neutralizzato senza ridurre la perdita misurata.
5. **Traffico del Mac.** Se i byte su N15, esclusi quelli del monitor e di M6, superano 2 Mbit/s di media durante M6, il fatto K5 vale 1. La confidenza dei sintomi sotto carico si dimezza.
6. **Gateway che penalizza ICMP.** Il traffico verso internet attraversa lo stesso collegamento del ping al gateway. Il gateway sta quindi penalizzando le risposte ICMP se vale almeno una delle condizioni:
   - perdita al gateway maggiore della perdita verso internet di almeno 1 punto percentuale, con un eccesso di almeno 3 pacchetti persi al gateway rispetto alla perdita verso internet (grado pieno da 6). Su 120 campioni uno scarto di 1–2 pacchetti è rumore, anche con perdite alte;
   - `p50_gw > p50_inet`: grado `rampUp(p50_gw / p50_inet, 1, 1,3)`. Un rapporto vicino a 1 è normale quando il collegamento locale è lento, perché il suo ritardo si somma a entrambi i bersagli (osservato nella sessione far-from-router-1).
   Il grado di questa condizione è il fatto K6. I sintomi del gateway hanno confidenza moltiplicata per `1 − K6`.

### 3.3 Limiti di macOS

- Ritrasmissioni, MCS effettivo e numero di stream richiedono `sudo wdutil info`. Il motore non li usa.
- SSID e BSSID richiedono il permesso di localizzazione. Senza permesso, le feature che li usano risultano mancanti e l'interfaccia lo dichiara.
- RSSI e rumore si aggiornano più lentamente di una volta al secondo, e su alcuni Mac il rumore è quantizzato o costante. La fase 0 lo misura (3.5).
- Con distribuzione sandboxed via App Store, l'app non può eseguire `scutil`, `ipconfig` e `tailscale`. Le misure N3, N4, N10 e M10 diventano mancanti, e il fatto K2 si ricava solo dalla route predefinita su `utun`.

### 3.4 Fatti di contesto

I fatti di contesto non sono sintomi. Abilitano o disabilitano le cause (campo `gate`) e ne modificano il prior.

| ID | Fatto | Fonte |
|---|---|---|
| K1 | Mac collegato via Ethernet: route predefinita su un'interfaccia cablata | N17 |
| K2 | Exit node o altra VPN con route predefinita su `utun` | M10, N17 |
| K3 | `awdl0` attivo con traffico negli ultimi 60 s | N14 |
| K4 | Permesso di localizzazione concesso | CoreLocation |
| K5 | Traffico del Mac in background durante M6 | N15 |
| K6 | Gateway che penalizza ICMP, grado tra 0 e 1 | 3.2.6 |
| K7 | Banda corrente: 2.4, 5 o 6 GHz | M1 |

### 3.5 Studio delle misure (fase 0)

Prima di fissare i parametri delle cause, la fase 0 misura su almeno due Mac:

1. la frequenza reale di aggiornamento di RSSI e rumore, e la variabilità del rumore. Se il rumore cambia meno di 2 dB in 10 minuti su un canale noto per essere disturbato, il rumore non entra come sintomo;
2. l'andamento di `txRate` a riposo e sotto traffico;
3. l'effetto di una scansione attiva su RTT e perdita al gateway, per tarare la finestra di contaminazione;
4. la firma dei picchi di latenza con AWDL attivo: AirDrop aperto, Handoff, Sidecar. Va misurato il periodo dei picchi;
5. la correlazione reale tra le serie di SNR e di RTT, per decidere se la correlazione regge come sintomo.

#### 3.5.1 Risultati sul primo Mac (MacBookPro18,1, macOS 15.7.9, 2026-10-16)

Mac fermo a 5 GHz sul canale 36, exit node Tailscale attivo, AWDL attivo.

| Punto | Misura | Conseguenza per la specifica |
|---|---|---|
| 1. RSSI | Cambia in media ogni 0,4 s (115 cambi in 60 s), escursione −56…−53 dBm | Il campionamento a 1 s non duplica i valori. I campioni minimi su valori distinti (4.1) restano validi |
| 1. Rumore | Costante a −89 dBm per 60 s | Il rumore non entra come sintomo. R2 resta in fase 2 e richiede la conferma su un canale disturbato |
| 2. txRate a riposo | 5 valori distinti tra 104 e 585 Mbit/s | Confermata la regola 3.2.2: a riposo il dato non è utilizzabile |
| 2. txRate sotto carico | Costante a 520 Mbit/s | Sotto traffico il dato è stabile e utilizzabile |
| 3. Scansione | Durata 3,4 s. RTT al gateway p50 103 ms e massimo 127 ms durante la scansione, contro 4,2 ms fuori. Nessun effetto residuo dopo la fine | La finestra di contaminazione di 0,5 s è sufficiente. Senza marcatura, una scansione basterebbe a far scattare S4 |
| 4. AWDL | Nessun picco sopra p50 + 10 ms in 531 campioni a circa 15 Hz. Autocorrelazione massima 36 % intorno a 1 s | Inconcludente: serve il confronto con AirDrop impostato su "Nessuno", e una sessione con AirDrop o Handoff in uso. Il periodo di F60 resta da fissare |
| 5. SNR e RTT | Non misurabile con il Mac fermo: l'SNR varia di 3 dB | Va misurato nella sessione "lontano-dal-router", camminando |

Difetto trovato durante lo studio: `ICMPProber` attendeva sempre l'intero timeout anche con tutte le risposte arrivate. Ora esce appena le riceve.

Restano da fare: lo studio su un secondo Mac e i punti 4 e 5.

## 4. Feature

### 4.1 Funzioni di base

```
rampUp(x, a, b)   = 0 se x ≤ a, 1 se x ≥ b, lineare in mezzo
rampDown(x, a, b) = 1 − rampUp(x, a, b)
confidenza        = min(1, campioniValidi / campioniMinimi) × freschezza
freschezza        = 1 se età ≤ finestra, poi lineare fino a 0 a 3 × finestra
```

Un campione è valido se non è contaminato (3.2.1) e, per le feature di rate, se ha traffico (3.2.2).
Con confidenza sotto 0,3 la feature conta come mancante.
Per RSSI, rumore e SNR i campioni minimi si contano sui valori distinti consecutivi, non sui secondi.

### 4.2 Feature della fase 1

| ID | Feature | Definizione | Finestra, campioni minimi |
|---|---|---|---|
| F1 | SNR basso | `rampDown(snr_p50, 15, 28)` | 60 s, 10 valori distinti |
| F5 | Efficienza del rate | `eff = txRate_p50 / rateRif`, con `rateRif` dalla 4.3 | campioni con traffico, 10 |
| F6 | Rate sotto le attese per SNR e PHY | `rampUp(effAttesa(snr, phy, larghezza) − eff, 0.15, 0.40)`, tabella 4.4 | come F5 |
| F9 | Canale occupato | Vedi 4.5 | ultimo beacon o ultimo scan |
| F20 | Perdita al gateway | `rampUp(loss_gw, 0.5 %, 5 %)` | 120 s, 60 validi |
| F22 | Latenza al gateway a riposo | `rampUp(p50_gw, 8 ms, 30 ms)` | 120 s, 60 |
| F23 | Jitter al gateway | `rampUp(p95_gw − p50_gw, 10 ms, 50 ms)` | 120 s, 60 |
| F24 | Perdita oltre il gateway | `rampUp(loss_inet − loss_gw, 0,3 %, 2 %) · rampUp(n_eccesso, 1, 3)`, con `loss_inet` dalla 3.2.4 e `n_eccesso` i pacchetti persi oltre il gateway sulla finestra. Su 120 campioni 2 pacchetti persi valgono l'1,6 %, ma restano rumore (osservato nella sessione healthy-home-1). I campioni dentro un'interruzione di F61 sono esclusi: l'interruzione è già il sintomo S9 | 120 s, 60 |
| F25 | Latenza oltre il gateway a riposo | `rampUp(p50_inet − p50_gw, 40 ms, 120 ms)` | 120 s, 60 |
| F28 | Gonfiamento al gateway sotto carico | `Δgw = p90_gw_carico − p50_gw_riposo`, grado `rampUp(Δgw, 20 ms, 100 ms)` | durante M6, 15 |
| F29x | Gonfiamento aggiuntivo oltre il gateway | `Δinet = p90_inet_carico − p50_inet_riposo`, grado `rampUp(Δinet − Δgw, 30 ms, 150 ms)` | durante M6, 15 |
| F63 | Reattività bassa sotto carico | `min(rampDown(RPM, 150, 400), 1 − F28)` dall'ultimo `networkQuality` (M6). Manca se il test non ha dato RPM. Il termine `1 − F28` lo limita alla coda oltre il router | durante M6, 1 test |
| F40 | DNS di sistema lento | `rampUp(p50_dns_sistema, 60 ms, 250 ms)` | 10 query |
| F41 | DNS di sistema più lento dell'alternativa | `rampUp(p50_dns_sistema − p50_dns_1111, 30 ms, 150 ms)` | 10 query per resolver |
| F60 | Picchi periodici al gateway | Autocorrelazione della serie RTT al gateway: massimo per periodi tra 0,5 s e 5 s, sopra la soglia di rumore. Grado `rampUp(picco, 0.2, 0.5)`. Il periodo si fissa dopo lo studio 3.5.4 | 120 s, 100 |
| F61 | Interruzioni di internet con gateway raggiungibile | Numero di intervalli di almeno 10 s con perdita 100 % verso tutti i bersagli e gateway che risponde ad almeno l'80 % dei ping nello stesso intervallo, per ora. Grado `rampUp(n, 0.5, 3)`. Confidenza 1 se c'è almeno un'interruzione; senza interruzioni, durata osservata / 60 min, minimo 0,3 | 60 min, da 2 min |
| F62 | Deriva della latenza a riposo | Per gateway e bersagli internet, il massimo di `min(rampUp(ρ, 0,6, 0,8), rampUp(Δ, 50 ms, 100 ms))`: `ρ` è la correlazione di rango tra tempo e RTT, `Δ` la differenza tra le mediane dell'ultimo e del primo quinto della serie | 10 min, 60 |

Nessuna feature usa il throughput assoluto in fase 1.

### 4.3 Rate di riferimento e numero di stream

`rateRif = rateMax1ss(phy, larghezza) × nss`.

- `rateMax1ss` è la metà dei valori della tabella 4.4.1, che riportano 2 stream.
- `nss` si stima dal rate più alto osservato: `nss = ceil(txRate_p99 / rateMax1ss − 0,05)`, limitato tra 1 e 4. Si usano i campioni con traffico degli ultimi 30 giorni, sullo stesso PHY e larghezza.
- Finché non ci sono 100 campioni con traffico, `nss = 2` e la confidenza di F5 e F6 si dimezza.

### 4.4 Tabelle di riferimento

#### 4.4.1 Rate massimo per 2 stream (Mbit/s, intervallo di guardia corto)

| PHY | 20 MHz | 40 MHz | 80 MHz | 160 MHz | 320 MHz |
|---|---|---|---|---|---|
| 802.11n | 144 | 300 | — | — | — |
| 802.11ac | 173 | 400 | 867 | 1733 | — |
| 802.11ax | 287 | 574 | 1201 | 2402 | — |
| 802.11be | 344 | 688 | 1441 | 2882 | 5765 |

#### 4.4.2 Efficienza attesa per SNR e PHY

La bozza 1 usava una sola tabella e avrebbe fatto scattare C1 su tutti gli AP Wi-Fi 7. Ora l'efficienza attesa dipende dal PHY:

```
snrEff        = snr − 3 · log2(larghezza / 20) − 3      // rumore su banda più larga, margine 3 dB
mcsMax(snr)   = MCS più alto con snrMin ≤ snrEff, limitato al massimo del PHY
effAttesa     = bit(mcsMax) / bit(mcsTop del PHY)
mcsTop        = 7 per 802.11n, 9 per ac, 11 per ax, 13 per be
```

| MCS | Modulazione | Codifica | Bit per simbolo | SNR minimo (dB) |
|---|---|---|---|---|
| 0 | BPSK | 1/2 | 0,5 | 5 |
| 1 | QPSK | 1/2 | 1,0 | 8 |
| 2 | QPSK | 3/4 | 1,5 | 11 |
| 3 | 16-QAM | 1/2 | 2,0 | 14 |
| 4 | 16-QAM | 3/4 | 3,0 | 17 |
| 5 | 64-QAM | 2/3 | 4,0 | 21 |
| 6 | 64-QAM | 3/4 | 4,5 | 23 |
| 7 | 64-QAM | 5/6 | 5,0 | 25 |
| 8 | 256-QAM | 3/4 | 6,0 | 29 |
| 9 | 256-QAM | 5/6 | 6,67 | 32 |
| 10 | 1024-QAM | 3/4 | 7,5 | 35 |
| 11 | 1024-QAM | 5/6 | 8,33 | 38 |
| 12 | 4096-QAM | 3/4 | 9,0 | 41 |
| 13 | 4096-QAM | 5/6 | 10,0 | 43 |

Gli SNR minimi sono indicativi. La fase 0 verifica se lo SNR riportato da CoreWLAN è riferito a 20 MHz o all'intero canale, e corregge `snrEff` di conseguenza.

### 4.5 Canale occupato (F9)

La bozza 1 trattava le reti sullo stesso canale come rumore. Non lo sono: due AP sullo stesso canale si alternano nell'uso del canale, e un vicino conta per quanto trasmette, non per la sua potenza. Una rete inattiva costa solo i beacon.
F9 misura quindi la contesa per il canale, con tre fonti in ordine di preferenza:

1. `channelUtilization` del BSS Load dell'AP corrente. Include tutto il traffico sul canale, vicini compresi. Confidenza 1.
2. Senza il BSS Load dell'AP corrente: il massimo `channelUtilization` tra i vicini con lo stesso canale primario. Confidenza 0,7.
3. Senza BSS Load: numero di vicini sullo stesso canale primario con RSSI ≥ −82 dBm, la soglia di rilevamento del preambolo a 20 MHz. Grado `rampUp(n, 2, 6)`, confidenza 0,4.

Grado con le fonti 1 e 2: `rampUp(utilizzo, 0.45, 0.75)`.

L'interferenza da canali parzialmente sovrapposti e da segnali sotto −82 dBm è un fenomeno diverso. Passa alla fase 2 come F8b (sezione 9).

## 5. Sintomi e algebra

### 5.1 Algebra delle espressioni

Ogni sintomo è un'espressione su feature. Le operazioni sono:

| Operazione | Grado | Confidenza |
|---|---|---|
| `f` | grado di `f` | confidenza di `f` |
| `not(f)` | `1 − grado(f)` | confidenza di `f` |
| `and(f, g)` | `min(grado(f), grado(g))` | `min(conf(f), conf(g))` |
| `or(f, g)` | `max(grado(f), grado(g))` | confidenza del termine che dà il massimo |
| `gruppo(f, g, …)` | `max` dei gradi dei termini disponibili | massimo delle confidenze |
| `scala(f, k)` | `grado(f)` | `k · conf(f)` |

`gruppo` serve per le feature correlate: lo stesso fenomeno conta una volta sola. Nessun'altra forma è ammessa nelle firme.

### 5.2 Vocabolario dei sintomi (fase 1)

| ID | Sintomo | Espressione | Fenomeno |
|---|---|---|---|
| S1 | Radio debole | `F1` | SNR basso |
| S2 | Perdita al gateway | `scala(F20, 1 − K6)` | perdita sul collegamento locale |
| S3 | Gateway lento a riposo | `scala(F22, 1 − K6)` | latenza locale costante |
| S4 | Jitter al gateway | `scala(F23, 1 − K6)` | variabilità locale |
| S5 | Gonfiamento locale sotto carico | `scala(F28, 1 − K6)`, confidenza dimezzata con K5 | coda nel Wi-Fi o nel router |
| S6 | Gonfiamento della linea sotto carico | `gruppo(F29x, F63)`, confidenza dimezzata con K5 | coda oltre il gateway |
| S7 | Perdita oltre il gateway | `F24` | perdita sulla linea |
| S8 | Latenza oltre il gateway | `F25` | linea lenta o percorso lungo |
| S9 | Interruzioni di internet | `F61` | linea che cade |
| S10 | DNS lento | `and(F40, F41)` | resolver lento rispetto all'alternativa |
| S11 | Picchi periodici | `F60` | radio fuori canale a intervalli regolari |
| S12 | Canale conteso | `F9` | airtime condiviso |
| S13 | Rate sotto le attese | `F6` | collegamento negoziato male |
| S14 | Deriva della latenza | `F62` | guasto che peggiora nel tempo, fuori catalogo |

Requisito del modello: i sintomi devono essere indipendenti tra loro, date le cause. La fase 0 lo verifica sulle sessioni reali: due sintomi con correlazione residua sopra 0,5, a parità di cause etichettate, si fondono in un `gruppo`.

## 6. Modello di inferenza

### 6.1 Componenti

- `H`: insieme delle cause del catalogo, più la causa ignota `U`.
- `π_h`: prior della causa `h`, cioè la probabilità che sia presente in una sessione in cui l'utente cerca un problema. Può dipendere dai fatti di contesto.
- `gate_h`: espressione sui fatti di contesto. Se è falsa, `h` non è valutabile e non entra negli insiemi.
- `q_h,s`: probabilità che `h`, se presente, produca il sintomo `s`.
- `λ_s`: probabilità che il sintomo `s` compaia senza nessuna causa del catalogo, cioè la perdita del noisy-OR.
- `E`: matrice di esclusione, cioè coppie di cause che non possono coesistere.

### 6.2 Verosimiglianza

Per un insieme di cause `C` con al massimo 3 elementi, ammesso da `E`:

```
P(s | C)  = 1 − (1 − λ_s) · Π_{h ∈ C} (1 − q_h,s)
L_s(C)    = [ g_s · P(s | C) + (1 − g_s) · (1 − P(s | C)) ] ^ c_s
prior(C)  = Π_{h ∈ C} π_h · Π_{h ∉ C} (1 − π_h)
post(C)  ∝ prior(C) · Π_s L_s(C)
P(h)      = Σ_{C ∋ h} post(C)
```

`g_s` e `c_s` sono grado e confidenza del sintomo. Con `c_s = 0` il sintomo non conta, perché `L_s = 1`.

Gli insiemi si enumerano tutti. Con le 10 cause della fase 1 più `U`, che sta sempre da sola, sono al massimo 1 + 11 + 45 + 120 = 177. Con 45 cause sono circa 15.000. Il calcolo resta sotto il millisecondo.

### 6.3 Proprietà che il modello dà per costruzione

- **Explaining away.** Se R1 spiega già S2, aggiungere A1 all'insieme aumenta poco `P(S2 | C)`. A1 quindi riceve poco credito da S2.
- **Dominanza degli strati.** Una causa a monte ha `q` alto sui sintomi a valle che produce. Non serve una regola separata.
- **Cause concomitanti.** Un insieme di due cause vince quando ognuna spiega sintomi che l'altra non produce.
- **Bufferbloat della linea con radio debole.** W1 usa S6, che misura il gonfiamento oltre quello locale. Il gonfiamento prodotto dalla radio non lo sopprime, e la contraddizione della bozza 1 sparisce.

La monotonia (12.3.2) non deriva dalla costruzione in ogni caso. Resta un invariante da verificare.

### 6.4 Causa ignota

`U` rappresenta un guasto fuori catalogo. Ha `π_U = 0,02` e `q_U,s = 0,3` su tutti i sintomi tranne S14, dove vale 0,8, e non coesiste con altre cause. Vince quando i sintomi osservati non corrispondono a nessuna combinazione di cause note: in quel caso il motore dichiara un'anomalia non riconosciuta, invece di forzare una diagnosi.

### 6.5 Copertura

```
copertura          = Σ_s c_s · imp_s / Σ_s imp_s      su tutti i sintomi delle cause valutabili
imp_s              = max_h q_h,s
copertura(h)       = Σ_s c_s · q_h,s / Σ_s q_h,s
```

### 6.6 Taratura

- Prima delle sessioni reali, `π`, `q` e `λ` sono valori di esperto, quelli della sezione 8.
- La taratura si fa solo sulle sessioni reali etichettate, per massima verosimiglianza con regolarizzazione verso i valori di esperto.
- Gli scenari sintetici non servono a tarare.

## 7. Esiti

Il motore valuta le condizioni in quest'ordine e restituisce il primo esito che corrisponde.

| Ordine | Esito | Condizione | Cosa mostra |
|---|---|---|---|
| 1 | Dati insufficienti | `copertura < 0,5`, oppure monitor attivo da meno di 60 s | Quali misure mancano e quanto attendere |
| 2 | Anomalia non riconosciuta | `P(U) ≥ 0,4` | I sintomi anomali, senza una causa |
| 3 | Rete sana | `post(∅) ≥ 0,6` | Misure in ordine. Se l'utente ha segnalato un problema, l'esito diventa "La rete è sana, il servizio no", con il test T12 sul servizio |
| 4 | Ambigua | Siano `C1` e `C2` i due insiemi con `post` maggiore. `post(C1) < 0,6`, `post(C2) ≥ 0,4 · post(C1)`, ed esiste un test della sezione 11 che li separa | Le due spiegazioni e il test. Se il test è automatico, il motore lo esegue |
| 5 | Diagnosi | Almeno una causa con `P(h) ≥ 0,7` e `copertura(h) ≥ 0,6` | Le cause con `P(h) ≥ 0,7`, azioni in forma affermativa |
| 6 | Probabile | Causa migliore con `P(h) ≥ 0,4`, oppure con `P(h) ≥ 0,7` e `copertura(h) < 0,6` | La causa e il test che la conferma, azione in forma prudente |
| 7 | Indeterminato | Nessuna delle precedenti | I test più informativi, in ordine di guadagno di informazione atteso |

L'ordine elimina i buchi e le sovrapposizioni della bozza 1: ogni combinazione di valori produce esattamente un esito.

## 8. Catalogo della fase 1

Ogni causa ha due testi d'azione: affermativo per l'esito Diagnosi, prudente per l'esito Probabile. Sintomi non elencati hanno `q = 0`.

`λ_s` vale 0,02 per tutti i sintomi, con queste eccezioni: S4 0,05, S8 0,05, S13 0,05.

### Matrice di esclusione

| Coppia | Motivo |
|---|---|
| U con qualsiasi causa | La causa ignota sta sempre da sola |
| W6 con W1 | Con la linea interrotta il gonfiamento della linea non è misurabile |

Le cause con `gate` falso non entrano negli insiemi, quindi non servono altre esclusioni.

### R1. Radio debole

- `gate`: `not(K1)`. `π`: 0,15.
- `q`: S1 0,95 · S2 0,5 · S3 0,3 · S4 0,4 · S5 0,5 · S13 0,2.
- Test: T2 (utente), T8 (utente).
- Affermativo: "Il segnale arriva debole rispetto al rumore. Avvicina il Mac al router o aggiungi un nodo mesh."
- Prudente: "Il segnale sembra debole. Prova ad avvicinarti al router e ripeti la misura."

### R3. Canale conteso

- `gate`: `not(K1)`. `π`: 0,15.
- `q`: S12 0,9 · S4 0,5 · S3 0,3 · S5 0,5 · S2 0,15 · S13 0,3.
- Test: T8 (utente).
- Affermativo: "Il canale <c> è occupato per il <u> % del tempo. Il canale <c'> è il più libero: impostalo nel router."
- Prudente: "Il canale <c> sembra affollato. Prova il canale <c'> nel router."
- Il canale consigliato viene da `Scoring` per la banda corrente.

### A1. Router lento

- `gate`: nessuno. `π`: 0,08.
- `q`: S3 0,7 · S4 0,5 · S5 0,3 · S2 0,2. Un router lento non forma per forza code sotto carico.
- Test: T1 (utente).
- Affermativo: "Il router risponde lento anche con un buon segnale. Riavvialo e verifica gli aggiornamenti del firmware."
- Prudente: "Il router potrebbe essere lento. Riavvialo e ripeti la misura."

### G1. Bufferbloat locale

- `gate`: nessuno. `π`: 0,10.
- `q`: S5 0,9 · S4 0,2.
- Test: T4 (automatico), T1 (utente).
- Affermativo: "La latenza verso il router sale quando la rete è carica. Attiva SQM o QoS nel router, oppure riduci il carico sul Wi-Fi."
- Prudente: "La latenza locale sembra salire sotto carico. Ripeti il test con il Mac vicino al router."

### W1. Bufferbloat della linea

- `gate`: nessuno. `π`: 0,20, oppure 0,10 con K2.
- `q`: S6 0,9 · S8 0,1.
- Test: T4 (automatico), T3 (utente) con K2.
- Affermativo: "La latenza verso internet esplode quando la linea è carica, mentre il collegamento locale resta stabile. Attiva SQM nel router con un limite al 90 % della banda."
- Prudente: "La linea sembra soffrire sotto carico. Ripeti il test quando nessun altro usa la rete."

### W2. Perdita sulla linea

- `gate`: nessuno. `π`: 0,08.
- `q`: S7 0,9 · S8 0,3 · S10 0,2.
- Test: T5 (automatico, fase 2).
- Affermativo: "Il collegamento al router è pulito, ma la linea perde il <x> % dei pacchetti. Il guasto è del provider: apri una segnalazione."
- Prudente: "La linea sembra perdere pacchetti. Ripeti la misura più tardi; se il dato resta, segnalalo al provider."

### W6. Interruzioni di linea

- `gate`: nessuno. `π`: 0,05.
- `q`: S9 0,95 · S7 0,1. S7 esclude i periodi di interruzione, quindi W6 produce poca perdita residua.
- Affermativo: "Internet si è interrotto <n> volte nell'ultima ora, mentre il router è rimasto raggiungibile. È un guasto di linea."
- Prudente: "Ci sono state interruzioni verso internet. Lascia il monitor attivo per un'ora per confermarlo."

### D1. DNS lento

- `gate`: nessuno. `π`: 0,10.
- `q`: S10 0,9.
- Test: T6 (automatico).
- Affermativo: "Il DNS impiega <t> ms contro <t'> ms di 1.1.1.1. Imposta un DNS alternativo nel router."
- Prudente: "Il DNS sembra più lento del normale. Prova un DNS alternativo."

### V1. Exit node o VPN che limita la connessione

- `gate`: `K2`. `π`: 0,6.
- `q`: S8 0,8 · S6 0,4 · S10 0,3 · S7 0,5. I tunnel via relay perdono pacchetti: osservato nella sessione reale exit-node-1.
- Test: T3 (utente).
- Affermativo: "Il traffico passa dall'exit node <nome>, che aggiunge <t> ms. Disattivalo quando non serve, o scegli un exit node più vicino."
- Prudente: "L'exit node <nome> potrebbe rallentare la connessione. Disattivalo e ripeti la misura."
- Con K2, l'interfaccia segnala anche che M6 misura la VPN e non la linea di casa.

### P5. AWDL (AirDrop, Handoff, Sidecar)

- `gate`: `and(not(K1), K3)`. `π`: 0,3.
- `q`: S11 0,9 · S4 0,7 · S3 0,1.
- Test: T11 (utente).
- Affermativo: "AirDrop, Handoff o Sidecar portano periodicamente la radio su un altro canale e causano picchi di latenza. Disattivali durante chiamate e giochi."
- Prudente: "I picchi di latenza regolari potrebbero dipendere da AirDrop o Handoff. Disattivali e ripeti la misura."

### U. Causa ignota

- `gate`: nessuno. `π`: 0,02. `q`: 0,3 su tutti i sintomi. Non coesiste con altre cause.

### 8.x Taratura del 2026-10-20 (sessioni no-exit-node-1 ed exit-node-2)

- **F28 e F29x sul 90° percentile sotto carico.** In entrambe le sessioni la coda si forma dopo 8–11 s di saturazione. La mediana cadeva nella parte iniziale del test e su no-exit-node-1 escludeva W1 (P da 0,18 a 0,02) con internet a 120–240 ms. Il riposo resta sulla mediana.
- **F63 da RPM, nel gruppo di S6.** L'RPM e F29x misurano lo stesso fenomeno, quindi non si sommano. Il vincolo `1 − F28` è dentro la feature: con `and` l'RPM mancante lasciava il solo termine "router stabile" e S6 valeva 1.
- **Esiti:** no-exit-node-1 passa da "rete sana" ad "Ambiguo" con W1 a 0,57 e test T4. exit-node-2 (exit node diretto, non DERP) dà V1 a 0,83.

## 9. Catalogo della fase 2

Le cause seguenti entrano solo con almeno 3 sessioni reali che le contengono. Per ognuna riporto le correzioni emerse dalla revisione.

| ID | Causa | Note per la specifica completa |
|---|---|---|
| P1 | 2.4 GHz con 5 o 6 GHz disponibile | Richiede K4. F11 corretta: grado `rampUp(rssi_5GHz, −75, −65)`, senza la condizione "≥ −70". Nuova feature F11b per l'SNR della rete alternativa, al posto del riferimento a F1 |
| P2 | Risparmio energetico | Invariata |
| P3 | Interfaccia o servizio prioritario errato | Invariata |
| P4 | Portale captive | Invariata |
| P6 | Traffico del Mac stesso (iCloud, Time Machine, aggiornamenti) | Da N15. In fase 1 K5 serve solo a scartare M6 |
| P7 | Disconnessioni Wi-Fi | Da N16: numero di disconnessioni per ora. È la lamentela più comune |
| P8 | Coesistenza Bluetooth su 2.4 GHz | Dispositivi Bluetooth connessi da IOBluetooth, solo con K7 = 2.4 GHz |
| R2 | Rumore di fondo alto | Solo se lo studio 3.5.1 conferma che il rumore varia sui Mac reali |
| R3b | Interferenza da canali parzialmente sovrapposti | Nuova F8b: SIR calcolato solo su reti con canale primario diverso e banda sovrapposta, e su segnali sotto −82 dBm, pesati per la frazione di banda condivisa |
| R4 | AP affollato dai propri client | `stationCount` alto e utilizzo dell'AP corrente alto, con vicini scarichi |
| R5 | Cambio di canale DFS | Invariata |
| R6 | Larghezza di canale ridotta | Con `not(F31)` al posto di "F31 basso" |
| C1 | Rate sotto le attese | Usa S13 con la tabella 4.4.2 per PHY |
| C2 | Sicurezza o PHY obsoleti | F13 vale solo se il Mac supporta un PHY superiore, da `system_profiler SPAirPortDataType`. Un Mac solo 802.11n non è un guasto |
| C3 | Roaming eccessivo | Richiede K4. Il supporto 802.11k/v/r è un fatto di contesto che riduce `q` sui sintomi di perdita, non un'evidenza con segno |
| C4 | Bloccato su un AP lontano | Richiede K4 |
| C5 | Segnale instabile | Solo se lo studio 3.5.1 mostra che la varianza di RSSI è misurabile |
| A2 | Backhaul mesh debole | Il numero di BSSID con lo stesso SSID diventa un fatto di contesto con grado `rampUp(n, 1, 3)`, non un'evidenza |
| L1 | Conflitto IP | Invariata |
| L2 | Doppio DHCP | Rimossa: il Mac vede solo il proprio lease |
| L3 | Dispositivo che satura la banda | Metrica separata: non può raggiungere il primo posto senza T10 |
| L4 | MAC del gateway cambiato | Testo riformulato come verifica: "Il MAC del router è cambiato. Se non hai cambiato router o ripetitore, controlla i dispositivi collegati." Esclude i ripetitori in modalità universale e i mesh tramite UPnP e il vendor del MAC |
| G2 | Linea saturata | Throughput rispetto a un riferimento: velocità del contratto indicata dall'utente, oppure p90 dello storico. Senza riferimento la causa non è valutabile. Confronto con il rate radio solo sull'upload |
| G3 | Doppio NAT | Peso principale sull'IP WAN letto via UPnP. I salti privati nel traceroute pesano poco, perché molti provider italiani usano indirizzi privati nella propria rete |
| G4 | CGNAT | Esclusa con K2 |
| G5 | Failover su rete mobile | Il cambio di ISP è escluso con K2 |
| W3 | Latenza alta a riposo | Invariata |
| W4 | Congestione serale | Metrica separata, richiede 3 giorni di storico |
| W5 | MTU di percorso ridotta | Rinominata: il ping con DF misura l'MTU ma non dimostra il blackhole PMTUD. Il blackhole richiede un test TCP con trasferimento grande. Esclusa con K2, perché Tailscale usa MTU 1280 |
| D2 | DNS che fallisce | Invariata |
| D3 | DNS imposto dalla VPN | Estesa a tutte le VPN |
| D4 | IPv6 rotto | Invariata |
| V2 | Exit node via relay DERP | Invariata |
| V4 | MTU del tunnel | Rimossa: l'MTU 1280 di Tailscale è normale. Resta solo il blackhole, sotto W5 |
| V5 | iCloud Private Relay | IP pubblico dentro gli intervalli di uscita pubblicati da Apple |
| V6 | Proxy di sistema | `SCDynamicStoreCopyProxies` |
| V7 | Altre VPN e filtri di contenuto | `utun` non Tailscale con route predefinita. Il rilevamento dei filtri di contenuto è parziale |

## 10. Interdipendenze

| Osservazione | Lettura ingenua | Il contesto che la cambia | Come la gestisce il modello |
|---|---|---|---|
| RSSI −70 dBm | Segnale debole | Rumore −95: SNR 25, buono. Rumore −80: SNR 10, critico | S1 usa l'SNR, l'RSSI resta descrittivo |
| Rate 54 Mbit/s | Wi-Fi lento | 2.4 GHz, 20 MHz, SNR 14: è il massimo per quel PHY | F6 confronta il rate con l'MCS consentito dall'SNR e dal PHY |
| Rate basso a riposo | Collegamento degradato | `txRate` riflette l'ultimo frame inviato | F5 e F6 usano solo campioni con traffico |
| 9 reti sul canale | Canale saturo | Reti inattive costano solo i beacon | F9 usa il BSS Load, non il conteggio |
| Vicino a −50 dBm sul canale | Interferenza forte | Contesa per l'airtime, non rumore | F9 per lo stesso canale, F8b (fase 2) per i canali sovrapposti |
| RPM 107 | Bufferbloat del provider | Gonfiamento già al gateway: Wi-Fi o router. Exit node: misura della VPN | W1 usa S6, che sottrae il gonfiamento locale. V1 ha prior alto con K2 |
| Perdita verso internet 5 % | Guasto del provider | Perdita al gateway 5 %: guasto locale | S7 è la differenza tra le due perdite |
| Perdita 5 % verso 1.1.1.1, 0 % verso 8.8.8.8 | Linea instabile | Un bersaglio filtra ICMP | Perdita per bersaglio, poi il minimo |
| Gateway lento o con perdita, internet pulito | Router lento | Il router penalizza le risposte ICMP | K6 riduce la confidenza dei sintomi del gateway |
| Picchi di jitter regolari | Interferenza | AWDL attivo | P5 con S11 e gate K3 |
| Jitter durante la scansione | Canale disturbato | La scansione dell'app porta la radio fuori canale | Campioni contaminati esclusi |
| DNS 200 ms | DNS lento | Linea con latenza alta: il DNS è proporzionato | S10 richiede anche F41, il confronto con 1.1.1.1 |
| networkQuality lento | Linea lenta | Time Machine o iCloud in background | K5 dimezza la confidenza dei sintomi sotto carico |
| MTU 1280 | MTU ridotta | Tailscale attivo | W5 esclusa con K2 |
| IP WAN diverso dall'IP pubblico | CGNAT | Exit node attivo | G4 esclusa con K2 |
| Mac via Ethernet | Nessun dato radio | Gli strati radio non si applicano | Le cause R e P5 non sono valutabili per gate |

## 11. Test discriminanti

| ID | Test | Tipo | Procedura | Separa |
|---|---|---|---|---|
| T1 | Cavo | Utente | Collegamento via Ethernet, poi ripetizione di monitor e M6 | R, G1, A1 da W |
| T2 | Avvicinamento | Utente | 30 s vicino al router, poi ritorno | R1 da R3, A1 |
| T3 | Senza exit node | Utente | Disattivazione dell'exit node, poi ripetizione | V1 da W1, W2 |
| T4 | Carico controllato | Automatico, con avviso | M6 con monitor in parallelo | G1 da W1 |
| T5 | Traceroute | Automatico (fase 2) | 6 salti con TTL crescente | W2 da A1 |
| T6 | DNS alternativo | Automatico | Query parallele al resolver di sistema e a 1.1.1.1 | D1 da W1, W2 |
| T7 | MTU | Automatico (fase 2) | Ping con DF a dimensioni decrescenti | W5 |
| T8 | Altra banda | Utente | Collegamento all'altra banda | R1, R3 da A1 |
| T9 | Ripetizione oraria | Automatico (fase 2) | Misure ogni ora per 3 giorni | W4 |
| T10 | Rete ferma | Utente | Pausa degli altri dispositivi | L3 |
| T11 | Senza AWDL | Utente | AirDrop su "Nessuno", Handoff disattivato, 2 minuti di monitor | P5 da R3 |
| T12 | Servizio specifico | Automatico | Ping, DNS e connessione TCP verso l'host indicato dall'utente | "Rete sana, servizio no" |

Con esito Ambiguo, il motore esegue da solo i test automatici che separano i due insiemi. Chiede all'utente solo i test di tipo Utente, uno alla volta.

## 12. Validazione

### 12.1 Ruoli

- I profili del generatore di scenari li scrive un agente diverso da chi scrive `π` e `q`, in una sessione separata. Riceve solo la descrizione fisica del guasto e la sezione 3, non la sezione 8.
- Le sessioni reali le etichetta Marco, con la causa nota provocata o verificata.

### 12.2 Scenari sintetici: test di regressione

Il generatore produce misure grezze, non feature:

1. una rete sana con parametri casuali di banda, PHY, larghezza, linea e RTT di base;
2. da 0 a 3 cause del catalogo, rispettando la matrice di esclusione;
3. rumore di misura, campioni mancanti fino al 10 %, campioni contaminati da scansioni simulate;
4. **scenari fuori catalogo**, almeno il 10 % del totale. Contengono guasti che il catalogo non descrive, per esempio:
   - perdita al 100 % per 2 s ogni 30 s;
   - DNS sano con connessioni TCP rifiutate;
   - latenza che cresce linearmente nel tempo;
   - perdita solo verso uno dei due bersagli e solo sotto carico.

Copertura: ogni causa singola con 200 scenari, ogni coppia ammessa con 30, le 20 triple più frequenti con 30, 2.000 scenari sani, 2.000 fuori catalogo.

### 12.3 Invarianti, da rispettare nel 100 % degli scenari

1. **Silenzio sulla rete sana:** nessuna causa con `P(h) ≥ 0,4`.
2. **Monotonia:** se il parametro principale di una causa vera peggiora di un passo, la sua `P(h)` non cala.
3. **Nessuna diagnosi sicura e sbagliata fuori catalogo:** negli scenari fuori catalogo nessuna causa riceve `P(h) ≥ 0,7`. Esiti ammessi: Anomalia non riconosciuta, Indeterminato, Ambigua, Probabile.
4. **Onestà:** con copertura sotto 0,5 l'esito è sempre "Dati insufficienti".
5. **Stabilità:** il 5 % di rumore sui valori grezzi cambia l'esito al massimo nel 3 % degli scenari.
6. **Spiegabilità:** ogni causa riportata ha almeno un sintomo con `g_s ≥ 0,5` e `q_h,s ≥ 0,5`.
7. **Gate:** nessuna causa con `gate` falso compare in un esito.

### 12.4 Criteri di accettazione sulle sessioni reali

Valgono per la fase 1, su almeno 30 sessioni reali etichettate.

| Metrica | Soglia |
|---|---|
| Successo: la causa vera è la prima, oppure l'esito è Ambiguo e il test proposto la separa | ≥ 80 % |
| Diagnosi sicura e sbagliata: una causa falsa con `P(h) ≥ 0,7` | ≤ 5 % |
| Falsi allarmi su reti sane | ≤ 5 % |
| Cause concomitanti: entrambe tra le prime 3 | ≥ 70 % |

Le soglie sintetiche (successo ≥ 90 %, falsi allarmi ≤ 2 %) servono solo come regressione: un calo segnala un errore nel codice, non nel modello.

L3 e W4 hanno una metrica separata: devono comparire tra le prime 3 o come esito Probabile.

### 12.5 Sessioni reali da registrare nella fase 0

1. Rete di casa sana, vicino al router.
2. Mac in una stanza lontana.
3. Exit node Tailscale attivo, diretto e via relay.
4. Failover LTE del FRITZ!Box 6890, con la linea fissa staccata.
5. Degrado della linea simulato con Network Link Conditioner: 3 % di perdita, 200 ms di latenza.
6. Canale 2.4 GHz affollato.
7. AirDrop e Handoff attivi durante una chiamata.
8. Mac via Ethernet.
9. DNS lento, con un resolver di sistema impostato su un server lontano.
10. Time Machine in esecuzione durante M6.

## 13. Privacy delle sessioni

Il file JSON di una sessione:

- non contiene SSID, MAC, IP pubblico, nomi Tailscale e nomi dei dispositivi;
- sostituisce i BSSID con pseudonimi `HMAC(sale, bssid)`. Il sale è casuale e vale solo per quella sessione: gli pseudonimi restano coerenti al suo interno, così si possono ricalcolare roaming e AP alternativi;
- riduce l'ISP a una categoria: fisso, mobile, VPN;
- delle reti vicine conserva solo pseudonimo, canale, larghezza, RSSI e BSS Load.

L'invio delle sessioni allo sviluppatore richiede un consenso esplicito e mostra il file prima dell'invio.

## 14. Architettura del codice

```
Sources/WifiScanCore/Diagnosis/
  Measurements.swift     // serie temporali grezze con marcatura dei campioni
  Monitor.swift          // raccolta delle misure, unico punto con I/O
  Context.swift          // fatti di contesto K1–K7
  Features.swift         // feature della sezione 4, funzioni pure
  Symptoms.swift         // algebra 5.1 e vocabolario 5.2
  Catalog.swift          // cause della sezione 8 come dati: π, gate, q, test, testi
  Engine.swift           // sezione 6: enumerazione, noisy-OR, marginali, copertura
  Outcome.swift          // sezione 7
  SessionRecorder.swift  // registrazione anonima della sezione 13
Tests/WifiScanCoreTests/Diagnosis/
  ScenarioGenerator.swift   // scritto da un agente separato, vedi 12.1
  EngineInvariantTests.swift
  RegressionTests.swift
  RecordedSessionTests.swift
```

Il catalogo è un elenco di dati. Aggiungere una causa significa aggiungere una voce, i suoi `q` e il suo profilo nel generatore.

## 15. Decisioni aperte

1. **Valori di esperto.** `π`, `q` e `λ` della sezione 8 sono il punto di partenza. Vanno rivisti prima della fase 1.
2. **Monitor in background.** Va deciso se il monitor gira solo con la finestra aperta o anche dalla barra dei menu.
3. **Storico.** Serve per `nss` (30 giorni di campioni con traffico) e per W4. Proposta: 30 giorni aggregati per minuto.
4. **Distribuzione.** Con l'App Store sandboxed alcune misure spariscono (3.3). La scelta del canale di vendita influenza la fase 2.
5. **Velocità del contratto.** Va deciso se chiederla all'utente al primo avvio, per G2.
