# Session Notes (Control4 / HA) — e-Safe_ws + e-mini_light

Data: 2026-01-16  
Workspace: `Driver 2026\`  

## Obiettivo
- `e-Safe_ws`: driver Control4 che si connette a Home Assistant via WebSocket + token e crea **connessioni dinamiche** (RELAY/CONTACT) per entità HA selezionate.
- `e-mini_light`: driver Control4 che appare come **Luce (LIGHT_V2)** e comanda un **relay bindato** (es: verso le uscite dinamiche create da `e-Safe_ws`).

## Stato attuale

### e-Safe_ws (repo `e-Safe_ws/`)
- Connessione HA via WS funzionante (SUBSCRIBED + `state_changed`).
- Gestione entità tramite Properties (no Programming/Device Specific).
- Creazione connessioni dinamiche:
  - `binary_sensor` → `CONTACT_SENSOR`
  - `switch` / `light` → `RELAY`
- Aggiornamento nome connessioni con `friendly_name` di HA: quando cambia, il driver forza la ricreazione del binding per aggiornare il nome in Composer.
- Logging:
  - Rimossa la riga spam `WS->HA type=event id=...` (non loggata).
  - Aggiunto debug mirato per uscite con prefisso `OUT:` visibile in `Debug Verbose=Yes`.
- Mapping comandi in input sulle uscite:
  - Gestiti anche `SET_LEVEL / SET_LEVEL_TARGET / RAMP_TO_LEVEL`: `LEVEL>0 => ON`, `LEVEL==0 => OFF` (utile quando qualcuno binda una porta tipo light/dimmer per errore).
- Proprietà `Entity ID` usata come “monitor”: `Last Entity / Last State` vengono aggiornati sempre per quell’entità anche in modalità registry.

**Versione corrente nel codice:** `000039`  
**Pacchetto da installare:** `e-Safe_ws/dist/c4z/e-Safe_ws.c4z`

### e-mini_light (repo `e-mini_light/`)
- Driver convertito/riscritto in `.c4z` (non decrittazione `.c4i`): XML + Lua.
- Deve apparire come lampadina e aprire finestra controllo luce (proxy `light_v2`).
- Problema principale risolto: UI che non vedeva lo stato e rispediva comandi ON.
  - Fix: aggiornare la UI LIGHT_V2 usando solo:
    - `C4:SendToProxy(5101, "LIGHT_BRIGHTNESS_CHANGED", { LIGHT_BRIGHTNESS_CURRENT="0|100" }, "NOTIFY")`
  - Non inviare più verso la luce: `STATE_CHANGED`, `LIGHT_LEVEL_CHANGED`, `ON`, `OFF` (non aggiornano correttamente il proxy LIGHT_V2).
  - Stato aggiornato solo su feedback relay (non optimistic).
- Binding usati:
  - Luce (LIGHT_V2) binding: `5101`
  - Relay binding: `1`
- Consigliato bind in Composer:
  - `e-mini_light: Relay` → uscita dinamica `RELAY` di `e-Safe_ws`
  - Non usare `e-mini_light: Light` per comandare e-Safe (porta sbagliata).

**Versione corrente nel codice:** `000020`  
**Pacchetto da installare:** `e-mini_light/dist/c4z/e-mini_light.c4z`

## Cose importanti imparate (debug/troubleshooting)
- `Last Proxy Binding / Command / Params` in `e-Safe_ws` indicano l’ultimo comando ricevuto via connessione Control4 (NON da HA).
  - Esempio visto: `WATTS` con `{"JUST_BOUND":"True","RATE":"0"}` → tipico di proxy energia/dimmer o handshake; indica binding/porta sbagliata collegata all’uscita.
- Per verificare stato HA:
  - Usare `Refresh Status Now = Yes` (fa `get_states`).
  - Con `Entity ID` impostata, `Last Entity/Last State` seguono quell’entità (v000039+).
- Per vedere attività sulle uscite dinamiche:
  - Mettere `Debug=Yes` e `Debug Verbose=Yes` in `e-Safe_ws`, cercare log `OUT:`.

## Come ripartire dopo riavvio (checklist)
1) Installare/aggiornare in Composer:
   - `e-Safe_ws/dist/c4z/e-Safe_ws.c4z` (verifica `Driver Version = 000039`)
   - `e-mini_light/dist/c4z/e-mini_light.c4z` (verifica `Driver Version = 000020`)
2) In `e-Safe_ws`:
   - Impostare Host/Port/Token corretti
   - `Add Entity ID` + `Add Entity Type` + `Add Entity Now = Yes`
   - `Refresh Status Now = Yes`
3) Connessioni Composer:
   - Collegare `e-mini_light: Relay` → uscita dinamica `RELAY` creata da `e-Safe_ws` (bindingId es. 5100+)
4) Debug se non funziona:
   - `e-Safe_ws`: `Debug Verbose=Yes` e verificare:
     - `OUT: ReceivedFromProxy target=... cmd=...`
     - `OUT: call_service ...`
     - `OUT: notify binding=...`

