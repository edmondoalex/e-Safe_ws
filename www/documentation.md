# e-Safe_ws (Home Assistant WebSocket)

Control4 driver to connect to Home Assistant (HASS/HAOS) using the Home Assistant WebSocket API (`ws://` or `wss://`) with a Long-Lived Access Token.

#### Requirements:
- Control4 OS 3.x (DriverWorks Lua)
- Home Assistant reachable on the network (default `8123`)
- A Home Assistant Long-Lived Access Token

#### Setup:
- Add the driver to the project.
- Set:
  - `Home Assistant Host` (IP/hostname)
  - `Home Assistant Port` (default `8123`)
  - `WebSocket Path` (default `/api/websocket`)
  - `Access Token` (Home Assistant profile → Long-Lived Access Tokens)
  - `Entity ID` (example: `binary_sensor.front_door`)
- The driver maps the entity `state` to the CONTACT proxy:
  - values in `True Values` => `OPEN`
  - values in `False Values` => `CLOSED`

#### Release Notes:
- Version 2: Home Assistant WebSocket + token
