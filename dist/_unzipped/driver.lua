-- e-Safe_ws - Home Assistant WebSocket (ws/wss) bridge for Control4
-- Maps a Home Assistant entity state to a Control4 CONTACT_SENSOR proxy.

local CONTACT_PROXY_BINDING_ID = 5001
local NETWORK_CONNECTION_ID = 6001

local TIMER_RECONNECT = 101

local DRIVER_VERSION = "000022"

local WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

local BIT = bit or bit32
if not BIT then
  local function bxor(a, b)
    local res = 0
    local p = 1
    while a > 0 or b > 0 do
      local aa = a % 2
      local bb = b % 2
      if aa ~= bb then res = res + p end
      a = (a - aa) / 2
      b = (b - bb) / 2
      p = p * 2
    end
    return res
  end
  local function band(a, b)
    local res = 0
    local p = 1
    while a > 0 and b > 0 do
      local aa = a % 2
      local bb = b % 2
      if aa == 1 and bb == 1 then res = res + p end
      a = (a - aa) / 2
      b = (b - bb) / 2
      p = p * 2
    end
    return res
  end
  local function bor(a, b) return a + b - band(a, b) end
  local function rshift(a, n) return math.floor(a / (2 ^ n)) end
  BIT = { bxor = bxor, band = band, bor = bor, rshift = rshift }
end

local function trim(s)
  if not s then return "" end
  return (tostring(s):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function lower(s) return string.lower(trim(s)) end

local function isTruthyProperty(v)
  v = lower(v)
  return v == "1" or v == "yes" or v == "true" or v == "on"
end

local function log(msg)
  msg = tostring(msg)
  if C4 then
    if type(C4.PrintToLog) == "function" then
      pcall(function() C4:PrintToLog(msg) end)
    end
    if type(C4.DebugLog) == "function" then
      pcall(function() C4:DebugLog(msg) end)
    end
  end
  pcall(function() print(msg) end)
end

local function debugLog(msg)
  if isTruthyProperty(Properties and Properties["Debug"] or "") then
    log("DEBUG HA_WS: " .. tostring(msg))
  end
end

local function debugVerbose(msg)
  if isTruthyProperty(Properties and Properties["Debug"] or "") and isTruthyProperty(Properties and Properties["Debug Verbose"] or "") then
    log("DEBUGV HA_WS: " .. tostring(msg))
  end
end

local function maskToken(token)
  token = tostring(token or "")
  token = trim(token)
  if token == "" then return "(empty)" end
  if #token <= 8 then return "(len=" .. tostring(#token) .. ")" end
  return token:sub(1, 4) .. "…" .. token:sub(-4) .. " (len=" .. tostring(#token) .. ")"
end

local function previewValue(v, maxLen)
  maxLen = maxLen or 200
  if v == nil then return "nil" end
  local s
  if type(v) == "string" then
    s = v
  elseif type(v) == "table" and C4 and type(C4.JsonEncode) == "function" then
    local ok, encoded = pcall(function() return C4:JsonEncode(v, false, true) end)
    if ok and type(encoded) == "string" and encoded ~= "" then
      s = encoded
    else
      s = tostring(v)
    end
  else
    s = tostring(v)
  end
  s = s:gsub("[\r\n\t]", " ")
  if #s > maxLen then s = s:sub(1, maxLen) .. "..." end
  return s
end

local function setProperty(name, value)
  value = tostring(value or "")
  if C4 and type(C4.UpdateProperty) == "function" then
    pcall(function() C4:UpdateProperty(name, value) end)
    return
  end
  if Properties then
    Properties[name] = value
  end
end

local function setStatus(s)
  setProperty("WS Status", s)
end

-- Forward declaration (needed because some helpers are defined before state initialization).
local state

local function addTimerCompat(timerId, seconds)
  seconds = tonumber(seconds) or 1
  if seconds < 1 then seconds = 1 end
  if not C4 then return false end

  -- Firmware differences:
  -- - AddTimer(id, interval, units, bRepeat)
  -- - AddTimer(id, bRepeat, interval, units)
  local attempts = {
    { "AddTimer(id, seconds, SECONDS, false)", function() return C4:AddTimer(timerId, seconds, "SECONDS", false) end },
    { "AddTimer(id, false, seconds, SECONDS)", function() return C4:AddTimer(timerId, false, seconds, "SECONDS") end },
    { "AddTimer(id, false, seconds)", function() return C4:AddTimer(timerId, false, seconds) end },
  }

  if type(C4.AddTimer) == "function" then
    for _, a in ipairs(attempts) do
      local label, fn = a[1], a[2]
      local ok, ret = pcall(fn)
      if ok then
        debugLog("Timer scheduled via " .. label .. " ret=" .. tostring(ret))
        return ret ~= false
      end
      debugLog("Timer failed via " .. label .. " err=" .. tostring(ret))
    end
  end

  -- Fallback: C4:SetTimer(milliseconds, callback)
  if type(C4.SetTimer) == "function" then
    if state and state.reconnect_timer and type(state.reconnect_timer.Cancel) == "function" then
      pcall(function() state.reconnect_timer:Cancel() end)
    end
    local ms = math.floor(seconds * 1000)
    local ok, t = pcall(function()
      return C4:SetTimer(ms, function()
        OnTimerExpired(timerId)
      end)
    end)
    if ok and t then
      if state then state.reconnect_timer = t end
      debugLog("Timer scheduled via SetTimer ms=" .. tostring(ms))
      return true
    end
    debugLog("Timer scheduling failed via SetTimer err=" .. tostring(t))
    return false
  end
  return false
end

local function shouldLogPayload()
  return isTruthyProperty(Properties and Properties["Log Payload"] or "")
end

local function setFromCSV(csv)
  local m = {}
  csv = csv or ""
  for v in string.gmatch(csv, "([^,]+)") do
    m[lower(v)] = true
  end
  return m
end

local TRUESET = {}
local FALSESET = {}

state = {
  connected = false,
  running = false,
  buf = "",
  fragment = nil,
  key = nil,
  port = nil,
  reconnect_timer = nil,

  reconnect_sec = 5,
  reconnect_min = 5,
  reconnect_max = 60,

  ha_authed = false,
  next_msg_id = 1,
  sub_id = nil,
  get_states_id = nil,
}

local function ensurePersist()
  if PersistData == nil then PersistData = {} end
  if PersistData.ha == nil then PersistData.ha = {} end
  if PersistData.ha.entities == nil then PersistData.ha.entities = {} end
  if PersistData.ha.nextBindingId == nil then PersistData.ha.nextBindingId = 5100 end
end

local function sanitizeVarName(entityId)
  local s = tostring(entityId or "")
  s = s:gsub("[^%w_]+", "_")
  if #s > 48 then s = s:sub(1, 48) end
  return "HA__" .. s
end

local function entityDomain(entityId)
  local d = tostring(entityId or ""):match("^([%w_]+)%.")
  return d or ""
end

local function guessTypeFromEntity(entityId)
  local d = entityDomain(entityId)
  if d == "binary_sensor" then return "binary_sensor" end
  if d == "switch" then return "switch" end
  if d == "input_number" then return "input_number" end
  if d == "light" then return "light" end
  if d == "sensor" then return "sensor" end
  return "sensor"
end

local function getRegistry()
  ensurePersist()
  return PersistData.ha.entities
end

local function registrySummary(maxItems)
  maxItems = maxItems or 20
  local reg = getRegistry()
  local keys = {}
  for k in pairs(reg) do keys[#keys + 1] = k end
  table.sort(keys)
  local out = {}
  for i, k in ipairs(keys) do
    if i > maxItems then
      out[#out + 1] = "... (" .. tostring(#keys - maxItems) .. " more)"
      break
    end
    local e = reg[k]
    out[#out + 1] = k .. " [" .. tostring(e and e.type or "?") .. "]"
  end
  return table.concat(out, ", ")
end

local function updateRegistryProperties()
  local reg = getRegistry()
  local count = 0
  for _ in pairs(reg) do count = count + 1 end
  setProperty("Entities Count", tostring(count))
  setProperty("Entities Preview", registrySummary(20))
end

local function addVariableIfPossible(name, value, varType)
  if not (C4 and type(C4.AddVariable) == "function") then return end
  varType = varType or "STRING"
  value = tostring(value or "")
  local ok = pcall(function()
    -- rw flag not consistent across firmwares; omit to keep compatible.
    C4:AddVariable(name, value, varType)
  end)
  if not ok then
    pcall(function() C4:AddVariable(name, value, varType, 0) end)
  end
end

local function setVariableIfPossible(name, value)
  if C4 and type(C4.SetVariable) == "function" then
    pcall(function() C4:SetVariable(name, tostring(value or "")) end)
  end
end

local function sendProxyState(bindingId, kind, isOn)
  if not (C4 and type(C4.SendToProxy) == "function") then return end
  local stateStr = isOn and "ON" or "OFF"
  local openStr = isOn and "OPEN" or "CLOSED"

  local attempts = {}
  if kind == "contact" then
    attempts = {
      { "OPENED", "NOTIFY" },
      { "CLOSED", "NOTIFY" },
      { "CONTACT_STATE_CHANGED", { STATE = openStr } },
      { "STATE_CHANGED", { STATE = openStr } },
      { openStr, {} },
      { "SET_STATE", { STATE = openStr } },
    }
    -- pick first two based on isOn
    attempts[1] = { isOn and "OPENED" or "CLOSED", "NOTIFY" }
    attempts[2] = { isOn and "OPEN" or "CLOSED", {} }
  elseif kind == "relay" then
    attempts = {
      { isOn and "CLOSED" or "OPENED", "NOTIFY" },
      { isOn and "ON" or "OFF", {} },
      { "STATE_CHANGED", { STATE = stateStr } },
      { "SET_STATE", { STATE = stateStr } },
    }
  end

  for _, a in ipairs(attempts) do
    pcall(function() C4:SendToProxy(bindingId, a[1], a[2]) end)
  end
end

local function allocateBindingId()
  ensurePersist()
  local id = tonumber(PersistData.ha.nextBindingId) or 5100
  PersistData.ha.nextBindingId = id + 1
  if PersistData.ha.nextBindingId > 5999 then
    PersistData.ha.nextBindingId = 5100
  end
  return id
end

local function createDynamicBindingIfNeeded(entity)
  if not (C4 and type(C4.AddDynamicBinding) == "function") then return end

  if entity.type == "binary_sensor" then
    entity.bindingId = entity.bindingId or allocateBindingId()
    pcall(function()
      C4:AddDynamicBinding(entity.bindingId, "CONTROL", true, entity.name, "CONTACT_SENSOR", false, false)
    end)
    debugLog("EnsureDynamicBinding CONTACT_SENSOR id=" .. tostring(entity.bindingId) .. " name=" .. tostring(entity.name))
    return
  end

  if entity.type == "switch" or entity.type == "light" then
    entity.bindingId = entity.bindingId or allocateBindingId()
    pcall(function()
      C4:AddDynamicBinding(entity.bindingId, "CONTROL", true, entity.name, "RELAY", false, false)
    end)
    debugLog("EnsureDynamicBinding RELAY id=" .. tostring(entity.bindingId) .. " name=" .. tostring(entity.name))
    return
  end
end

local function registerEntity(entityId, entityType)
  entityId = trim(entityId)
  if entityId == "" then return false, "empty entity_id" end

  ensurePersist()
  local reg = getRegistry()

  entityType = trim(entityType)
  if entityType == "" or entityType == "auto" then
    entityType = guessTypeFromEntity(entityId)
  end

  local existing = reg[entityId]
  if existing then
    existing.type = entityType
    existing.name = existing.name or entityId
    existing.var = existing.var or sanitizeVarName(entityId)
    createDynamicBindingIfNeeded(existing)
    addVariableIfPossible(existing.var, existing.last_state or "", "STRING")
    updateRegistryProperties()
    return true, "updated"
  end

  local e = {
    entity_id = entityId,
    type = entityType,
    name = entityId,
    var = sanitizeVarName(entityId),
    bindingId = nil,
    last_state = "",
  }

  createDynamicBindingIfNeeded(e)
  addVariableIfPossible(e.var, "", "STRING")

  reg[entityId] = e
  updateRegistryProperties()
  return true, "added"
end

local function unregisterEntity(entityId)
  entityId = trim(entityId)
  if entityId == "" then return false, "empty entity_id" end
  ensurePersist()
  local reg = getRegistry()
  if not reg[entityId] then return true, "missing" end
  reg[entityId] = nil
  updateRegistryProperties()
  return true, "removed"
end

local function sendToNetwork(payload)
  if not (C4 and type(C4.SendToNetwork) == "function") then
    setStatus("ERROR: no C4.SendToNetwork")
    return false
  end

  debugVerbose("SendToNetwork bytes=" .. tostring(type(payload) == "string" and #payload or "n/a"))
  local attempts = {
    function() return C4:SendToNetwork(NETWORK_CONNECTION_ID, payload) end,
    function() return state.port and C4:SendToNetwork(NETWORK_CONNECTION_ID, state.port, payload) end,
  }

  for _, fn in ipairs(attempts) do
    local ok, ret = pcall(fn)
    if ok and ret ~= false and ret ~= nil then return true end
  end
  return false
end

local function scheduleReconnect(reason)
  state.connected = false
  state.running = false
  state.buf = ""
  state.fragment = nil
  state.key = nil
  state.ha_authed = false
  state.next_msg_id = 1
  state.sub_id = nil
  state.get_states_id = nil

  local msg = "RECONNECT in " .. tostring(state.reconnect_sec) .. "s"
  if reason and reason ~= "" then msg = msg .. " (" .. tostring(reason) .. ")" end
  setStatus(msg)
  debugLog("scheduleReconnect reason=" .. tostring(reason) .. " next=" .. tostring(state.reconnect_sec))
  addTimerCompat(TIMER_RECONNECT, state.reconnect_sec)
  state.reconnect_sec = math.min(state.reconnect_sec * 2, state.reconnect_max)
end

local function setContactState(isOpen, entityId, haState)
  local stateStr = isOpen and "OPEN" or "CLOSED"

  setProperty("Last Entity", entityId or "")
  setProperty("Last State", haState or "")

  if C4 and type(C4.SetVariable) == "function" then
    C4:SetVariable("CONTACT_STATE", isOpen and "1" or "0")
  end

  if C4 and type(C4.SendToProxy) == "function" then
    local attempts = {
      { "CONTACT_STATE_CHANGED", { STATE = stateStr } },
      { "STATE_CHANGED", { STATE = stateStr } },
      { stateStr, {} },
      { "SET_STATE", { STATE = stateStr } },
    }
    for _, a in ipairs(attempts) do
      pcall(function()
        C4:SendToProxy(CONTACT_PROXY_BINDING_ID, a[1], a[2])
      end)
    end
  end
end

local function parseHttpHeaders(raw)
  local headers = {}
  for line in string.gmatch(raw, "(.-)\r\n") do
    local k, v = string.match(line, "^%s*(.-)%s*:%s*(.+)%s*$")
    if k and v then
      headers[string.upper(k)] = v
    end
  end
  return headers
end

local function wsMakeKey()
  local k = ""
  for _ = 1, 16 do
    k = k .. string.char(math.random(33, 125))
  end
  if C4 and type(C4.Base64Encode) == "function" then
    return C4:Base64Encode(k)
  end
  return k
end

local function wsMakeHeaders(host, port, resource)
  state.key = wsMakeKey()
  local head = {
    "GET " .. resource .. " HTTP/1.1",
    "Host: " .. host .. ":" .. tostring(port),
    "Connection: Upgrade",
    "Upgrade: websocket",
    "Sec-WebSocket-Key: " .. state.key,
    "Sec-WebSocket-Version: 13",
    "User-Agent: C4WebSocket/1",
    "\r\n",
  }
  debugLog("WS headers host=" .. tostring(host) .. " port=" .. tostring(port) .. " resource=" .. tostring(resource))
  debugVerbose("WS key=" .. tostring(state.key))
  return table.concat(head, "\r\n")
end

local function wsComputeAccept(key)
  local check = tostring(key or "") .. WS_GUID
  if C4 and type(C4.Hash) == "function" then
    local ok, hash = pcall(function()
      return C4:Hash("sha1", check, { ["return_encoding"] = "BASE64" })
    end)
    if ok then return hash end
  end
  return nil
end

local function wsMaskPayload(s, mask)
  local out = {}
  local mlen = 4
  for i = 1, #s do
    local mi = ((i - 1) % mlen) + 1
    out[i] = string.char(BIT.bxor(s:byte(i), mask[mi]))
  end
  return table.concat(out)
end

local function wsEncodeFrameText(payload)
  local len = #payload
  local header
  if len <= 125 then
    header = string.char(0x81, BIT.bor(len, 0x80))
  elseif len <= 65535 then
    header = string.char(0x81, BIT.bor(126, 0x80), BIT.rshift(len, 8) % 256, len % 256)
  else
    -- 64-bit length; we send (high 32-bit=0) + (low 32-bit=len).
    local lo = len
    header = string.char(
      0x81,
      BIT.bor(127, 0x80),
      0, 0, 0, 0,
      BIT.rshift(lo, 24) % 256, BIT.rshift(lo, 16) % 256, BIT.rshift(lo, 8) % 256, lo % 256
    )
  end

  local mask = { math.random(0, 255), math.random(0, 255), math.random(0, 255), math.random(0, 255) }
  return header
    .. string.char(mask[1], mask[2], mask[3], mask[4])
    .. wsMaskPayload(payload, mask)
end

local function wsTryParseOneFrame()
  if #state.buf < 2 then return false end
  local h1 = state.buf:byte(1)
  local h2 = state.buf:byte(2)

  local final = BIT.band(h1, 0x80) == 0x80
  local opcode = BIT.band(h1, 0x0F)
  local masked = BIT.band(h2, 0x80) == 0x80
  local len = BIT.band(h2, 0x7F)

  local idx = 3
  local msglen
  if len <= 125 then
    msglen = len
  elseif len == 126 then
    if #state.buf < 4 then return false end
    msglen = state.buf:byte(3) * 256 + state.buf:byte(4)
    idx = 5
  else
    if #state.buf < 10 then return false end
    -- ignore >32-bit lengths; treat as not enough data
    msglen = 0
    for i = 3, 10 do msglen = msglen * 256 + state.buf:byte(i) end
    idx = 11
  end

  local mask
  if masked then
    if #state.buf < idx + 3 then return false end
    mask = { state.buf:byte(idx), state.buf:byte(idx + 1), state.buf:byte(idx + 2), state.buf:byte(idx + 3) }
    idx = idx + 4
  end

  if #state.buf < (idx - 1) + msglen then return false end
  local fragment = state.buf:sub(idx, idx + msglen - 1)
  state.buf = state.buf:sub(idx + msglen)

  if masked and mask then
    fragment = wsMaskPayload(fragment, mask)
  end

  if opcode == 0x08 then
    local code, reason
    if #fragment >= 2 then
      code = fragment:byte(1) * 256 + fragment:byte(2)
      if #fragment > 2 then
        reason = fragment:sub(3)
      end
    end
    debugLog("WS CLOSE code=" .. tostring(code) .. " reason=" .. previewValue(reason))
    scheduleReconnect("CLOSE" .. (code and (":" .. tostring(code)) or ""))
    return true
  end

  if opcode == 0x09 then
    -- Ping from server -> Pong
    -- Minimal pong frame (masked, empty payload)
    sendToNetwork(string.char(0x8A, 0x80, 0x00, 0x00, 0x00, 0x00))
    return true
  end

  if opcode == 0x0A then
    return true
  end

  if opcode == 0x00 then
    if not state.fragment then
      state.fragment = ""
    end
    state.fragment = state.fragment .. fragment
  elseif opcode == 0x01 then
    state.fragment = fragment
  else
    -- ignore binary frames
    return true
  end

  if final then
    local msg = state.fragment or ""
    state.fragment = nil
    return msg
  end

  return true
end

local function haSend(tbl)
  if not (C4 and type(C4.JsonEncode) == "function") then
    setStatus("ERROR: no C4.JsonEncode")
    return
  end
  local ok, json = pcall(function() return C4:JsonEncode(tbl, false, true) end)
  if not ok then
    debugLog("JsonEncode failed: " .. tostring(json))
    return
  end
  if shouldLogPayload() then
    setProperty("Last JSON", (json and #json > 512) and (json:sub(1, 512) .. "...") or json)
  end
  debugLog("HA->WS " .. tostring(tbl and tbl.type or "nil") .. " id=" .. tostring(tbl and tbl.id or ""))
  sendToNetwork(wsEncodeFrameText(json))
end

local function haNextId()
  local id = state.next_msg_id
  state.next_msg_id = state.next_msg_id + 1
  return id
end

local function haCallService(domain, service, entityId)
  local id = haNextId()
  haSend({
    id = id,
    type = "call_service",
    domain = domain,
    service = service,
    service_data = { entity_id = entityId },
  })
end

local function haSubscribe()
  state.sub_id = haNextId()
  haSend({ id = state.sub_id, type = "subscribe_events", event_type = "state_changed" })
  setStatus("SUBSCRIBED (pending)")
end

local function haGetStates()
  state.get_states_id = haNextId()
  haSend({ id = state.get_states_id, type = "get_states" })
end

local function haHandleEntityState(entityId, haState)
  local reg = getRegistry()
  local e = reg[entityId]

  -- haState can be either a string (old callers) or a table (full HA state object)
  local stateVal = nil
  local attrs = nil
  if type(haState) == "table" then
    stateVal = tostring(haState.state or "")
    attrs = haState.attributes
  else
    stateVal = tostring(haState or "")
  end

  if not e then
    -- Fallback to single-entity mode if registry is empty.
    local wanted = trim(Properties and Properties["Entity ID"] or "")
    if wanted ~= "" and entityId ~= wanted then return end

    local key = lower(stateVal)
    if TRUESET[key] then
      setContactState(true, entityId, stateVal)
    elseif FALSESET[key] then
      setContactState(false, entityId, stateVal)
    else
      setProperty("Last Entity", entityId or "")
      setProperty("Last State", stateVal or "")
    end
    return
  end

  -- If HA provided attributes with a friendly name, prefer it for the entity's name
  if type(attrs) == "table" then
    local friendly = attrs["friendly_name"] or attrs["title"] or attrs["name"]
      if friendly and trim(friendly) ~= "" and friendly ~= e.name then
      debugLog("Updating entity name from HA: " .. tostring(entityId) .. " -> " .. tostring(friendly))
      e.name = tostring(friendly)
      -- If binding exists, try to remove and recreate it to ensure name updates
      if e.bindingId and type(C4) == "table" then
        -- Prefer RemoveDynamicBinding if available
        if type(C4.RemoveDynamicBinding) == "function" then
          pcall(function() C4:RemoveDynamicBinding(e.bindingId) end)
        end
        if type(C4.AddDynamicBinding) == "function" then
          pcall(function()
            C4:AddDynamicBinding(e.bindingId, "CONTROL", true, e.name, (e.type == "binary_sensor") and "CONTACT_SENSOR" or "RELAY", false, false)
          end)
        end
      end
      updateRegistryProperties()
    end
  end

  e.last_state = tostring(stateVal or "")
  setVariableIfPossible(e.var, e.last_state)

  local key = lower(stateVal)
  local truthy = TRUESET[key] and true or false
  local falsy = FALSESET[key] and true or false

  if e.type == "binary_sensor" and e.bindingId then
    if truthy then
      sendProxyState(e.bindingId, "contact", true)
    elseif falsy then
      sendProxyState(e.bindingId, "contact", false)
    end
  elseif e.type == "switch" and e.bindingId then
    if truthy then
      sendProxyState(e.bindingId, "relay", true)
    elseif falsy then
      sendProxyState(e.bindingId, "relay", false)
    end
  end
end

local function haHandleJson(jsonText)
  if shouldLogPayload() then
    setProperty("Last JSON", (jsonText and #jsonText > 1024) and (jsonText:sub(1, 1024) .. "...") or (jsonText or ""))
  end

  if not (C4 and type(C4.JsonDecode) == "function") then
    debugLog("No C4.JsonDecode; cannot parse HA JSON")
    return
  end

  local ok, msg = pcall(function() return C4:JsonDecode(jsonText) end)
  if not ok or type(msg) ~= "table" then
    debugLog("JsonDecode failed: " .. tostring(msg))
    return
  end

  local t = msg.type
  debugLog("WS->HA type=" .. tostring(t) .. " id=" .. tostring(msg.id or ""))
  if t == "auth_required" then
    setStatus("AUTH_REQUIRED")
    local token = trim(Properties and Properties["Access Token"] or "")
    debugLog("auth_required token=" .. maskToken(token))
    if token == "" then
      setStatus("ERROR: Access Token empty")
      return
    end
    haSend({ type = "auth", access_token = token })
    return
  end

  if t == "auth_ok" then
    state.ha_authed = true
    setStatus("AUTH_OK")
    haSubscribe()
    haGetStates()
    return
  end

  if t == "auth_invalid" then
    setStatus("AUTH_INVALID")
    debugLog("auth_invalid msg=" .. tostring(msg.message or (msg.error and msg.error.message) or ""))
    scheduleReconnect("AUTH_INVALID")
    return
  end

  if t == "ping" then
    haSend({ type = "pong" })
    return
  end

  -- Results
  if t == "result" and msg.id then
    if msg.id == state.sub_id then
      setStatus(msg.success and "SUBSCRIBED" or ("SUBSCRIBE_ERROR: " .. tostring(msg.error and msg.error.message or "")))
      debugLog("subscribe result success=" .. tostring(msg.success))
      return
    end
    if msg.id == state.get_states_id and msg.success and type(msg.result) == "table" then
      debugLog("get_states success count=" .. tostring(#msg.result))
      local reg = getRegistry()
      local hasRegistry = false
      for _ in pairs(reg) do hasRegistry = true break end

      if hasRegistry then
        for _, st in ipairs(msg.result) do
          if type(st) == "table" and st.entity_id and reg[st.entity_id] then
            -- pass full state object so we can extract attributes/friendly_name
            haHandleEntityState(st.entity_id, st)
          end
        end
      else
        local wanted = trim(Properties and Properties["Entity ID"] or "")
        for _, st in ipairs(msg.result) do
          if type(st) == "table" and st.entity_id == wanted then
            haHandleEntityState(st.entity_id, st)
            break
          end
        end
      end
      return
    end
  end

  -- Events
  if t == "event" and msg.event and msg.event.event_type == "state_changed" then
    local e = msg.event.data
    if type(e) ~= "table" then return end
    local entityId = e.entity_id
    local reg = getRegistry()
    local hasRegistry = false
    for _ in pairs(reg) do hasRegistry = true break end

    if hasRegistry then
      if not reg[entityId] then
        debugVerbose("state_changed ignored (not registered): " .. tostring(entityId))
        return
      end
    else
      local wanted = trim(Properties and Properties["Entity ID"] or "")
      if wanted ~= "" and entityId ~= wanted then return end
    end
    if e.new_state and type(e.new_state) == "table" then
      debugLog("state_changed entity=" .. tostring(entityId) .. " state=" .. tostring(e.new_state.state))
      -- pass full state object (contains attributes) so we can get friendly_name
      haHandleEntityState(entityId, e.new_state)
    end
  end
end

local function wsParseHttpIfReady()
  debugVerbose("wsParseHttpIfReady buf_len=" .. tostring(type(state.buf) == "string" and #state.buf or "n/a"))
  local eoh = state.buf:find("\r\n\r\n", 1, true)
  if not eoh then return end
  local headerBlob = state.buf:sub(1, eoh + 3)
  state.buf = state.buf:sub(eoh + 4)

  local headers = parseHttpHeaders(headerBlob)
  local accept = headers["SEC-WEBSOCKET-ACCEPT"]
  local expected = wsComputeAccept(state.key)
  debugLog("WS handshake accept=" .. tostring(accept) .. " expected=" .. tostring(expected) .. " upgrade=" .. tostring(headers["UPGRADE"]) .. " conn=" .. tostring(headers["CONNECTION"]))

  if accept and expected and accept == expected and headers["UPGRADE"] == "websocket" then
    state.running = true
    setStatus("WS_ESTABLISHED")
    -- Important: HA may send the first WS frame in the same TCP packet as the HTTP 101 response.
    -- We already stripped HTTP headers into state.buf, so process any leftover immediately.
    debugVerbose("WS_ESTABLISHED leftover_bytes=" .. tostring(#state.buf))
  else
    setStatus("ERROR: WS handshake failed")
    debugLog("WS handshake headers: accept=" .. tostring(accept) .. " expected=" .. tostring(expected) .. " upgrade=" .. tostring(headers["UPGRADE"]))
    scheduleReconnect("HANDSHAKE")
  end
end

local function wsProcessRx()
  if not state.running then
    wsParseHttpIfReady()
    -- If handshake just completed, fall through to parse WS frames already in the buffer.
    if not state.running then return end
  end

  while true do
    local r = wsTryParseOneFrame()
    if r == false then return end
    if type(r) == "string" then
      haHandleJson(r)
    end
  end
end

local function connectTcp()
  local host = trim(Properties and Properties["Home Assistant Host"] or "")
  local port = tonumber(trim(Properties and Properties["Home Assistant Port"] or "")) or 8123
  local resource = trim(Properties and Properties["WebSocket Path"] or "")
  if resource == "" then resource = "/api/websocket" end
  if resource:sub(1, 1) ~= "/" then resource = "/" .. resource end

  state.reconnect_min = tonumber(trim(Properties and Properties["Reconnect Min (sec)"] or "")) or 5
  state.reconnect_max = tonumber(trim(Properties and Properties["Reconnect Max (sec)"] or "")) or 60
  if state.reconnect_min < 1 then state.reconnect_min = 1 end
  if state.reconnect_max < state.reconnect_min then state.reconnect_max = state.reconnect_min end
  state.reconnect_sec = state.reconnect_min

  state.port = port
  state.buf = ""
  state.fragment = nil
  state.running = false
  state.ha_authed = false
  state.next_msg_id = 1
  state.sub_id = nil
  state.get_states_id = nil

  if host == "" then
    setStatus("ERROR: Home Assistant Host empty")
    return
  end

  local useTls = isTruthyProperty(Properties and Properties["Use TLS (wss)"] or "")
  debugLog("connectTcp host=" .. tostring(host) .. " port=" .. tostring(port) .. " path=" .. tostring(resource) .. " tls=" .. tostring(useTls))

  if not (C4 and type(C4.CreateNetworkConnection) == "function") then
    setStatus("ERROR: no C4.CreateNetworkConnection")
    return
  end
  if not (C4 and type(C4.NetConnect) == "function") then
    setStatus("ERROR: no C4.NetConnect")
    return
  end

  -- Most reliable pattern (as seen in Ksenia drivers):
  -- - CreateNetworkConnection(id, host [, 'SSL'])
  -- - (optional) NetPortOptions(id, port, 'SSL')
  -- - NetDisconnect(id, port)
  -- - NetConnect(id, port)
  local createdOk = false
  if useTls then
    local ok = pcall(function() C4:CreateNetworkConnection(NETWORK_CONNECTION_ID, host, "SSL") end)
    createdOk = ok
    if C4 and type(C4.NetPortOptions) == "function" then
      pcall(function() C4:NetPortOptions(NETWORK_CONNECTION_ID, port, "SSL") end)
    end
    setStatus("TCP CONNECT (SSL) " .. host .. ":" .. tostring(port))
  else
    local ok = pcall(function() C4:CreateNetworkConnection(NETWORK_CONNECTION_ID, host) end)
    createdOk = ok
    setStatus("TCP CONNECT " .. host .. ":" .. tostring(port))
  end
  debugLog("CreateNetworkConnection ok=" .. tostring(createdOk) .. " tls=" .. tostring(useTls))

  pcall(function() C4:NetDisconnect(NETWORK_CONNECTION_ID, port) end)
  local okConnect, ret = pcall(function() return C4:NetConnect(NETWORK_CONNECTION_ID, port) end)
  if not okConnect or ret == false or ret == nil then
    -- last-resort variants on older firmware
    debugLog("NetConnect(id,port) failed ret=" .. tostring(ret))
    local ok2, ret2 = pcall(function() return C4:NetConnect(NETWORK_CONNECTION_ID, host, port) end)
    if not ok2 or ret2 == false or ret2 == nil then
      debugLog("NetConnect(id,host,port) failed ret=" .. tostring(ret2))
      setStatus("ERROR: NetConnect failed")
      return
    end
    debugLog("NetConnect(id,host,port) OK ret=" .. tostring(ret2))
  else
    debugLog("NetConnect(id,port) OK ret=" .. tostring(ret))
  end

  -- Prepare handshake header (sent when ONLINE)
  state._handshake = wsMakeHeaders(host, port, resource)
end

function ExecuteCommand(strCommand, tParams)
  strCommand = tostring(strCommand or "")
  tParams = tParams or {}

  if strCommand == "Reconnect" then
    connectTcp()
    return
  end

  if strCommand == "Add Entity" then
    local id = tParams["ENTITY_ID"] or tParams["Entity ID"] or tParams["ID"] or ""
    local ty = tParams["TYPE"] or tParams["Type"] or "auto"
    local ok, msg = registerEntity(id, ty)
    log("Add Entity: " .. tostring(id) .. " -> " .. tostring(ok) .. " (" .. tostring(msg) .. ")")
    if state.ha_authed then haGetStates() end
    return
  end

  if strCommand == "Remove Entity" then
    local id = tParams["ENTITY_ID"] or tParams["Entity ID"] or tParams["ID"] or ""
    local ok, msg = unregisterEntity(id)
    log("Remove Entity: " .. tostring(id) .. " -> " .. tostring(ok) .. " (" .. tostring(msg) .. ")")
    return
  end

  if strCommand == "Clear Entities" then
    ensurePersist()
    PersistData.ha.entities = {}
    updateRegistryProperties()
    log("Clear Entities: OK")
    return
  end

  if strCommand == "Refresh States" then
    if state.ha_authed then
      haGetStates()
      log("Refresh States: requested")
    else
      log("Refresh States: not authed")
    end
    return
  end
end

function OnDriverInit()
  pcall(function() math.randomseed(os.time()) end)
  TRUESET = setFromCSV(Properties and Properties["True Values"] or "")
  FALSESET = setFromCSV(Properties and Properties["False Values"] or "")

  setProperty("Driver Version", DRIVER_VERSION)
  ensurePersist()
  updateRegistryProperties()

  if C4 and type(C4.AddVariable) == "function" then
    C4:AddVariable("CONTACT_STATE", "0", "BOOL")
  end
  setStatus("INIT")
  log("e-Safe_ws driver avviato (Home Assistant WS) v" .. DRIVER_VERSION)
  debugLog("C4.NetConnect=" .. tostring(C4 and type(C4.NetConnect)) .. " C4.CreateNetworkConnection=" .. tostring(C4 and type(C4.CreateNetworkConnection)) .. " C4.SendToNetwork=" .. tostring(C4 and type(C4.SendToNetwork)))
end

function OnDriverLateInit()
  -- Restore dynamic bindings/variables
  local reg = getRegistry()
  for _, e in pairs(reg) do
    if type(e) == "table" and e.entity_id then
      e.type = e.type or guessTypeFromEntity(e.entity_id)
      e.name = e.name or e.entity_id
      e.var = e.var or sanitizeVarName(e.entity_id)
      createDynamicBindingIfNeeded(e)
      addVariableIfPossible(e.var, e.last_state or "", "STRING")
    end
  end
  updateRegistryProperties()
  connectTcp()
end

function OnPropertyChanged(name)
  if name == "True Values" or name == "False Values" then
    TRUESET = setFromCSV(Properties and Properties["True Values"] or "")
    FALSESET = setFromCSV(Properties and Properties["False Values"] or "")
    return
  end
  if name == "Debug" or name == "Log Payload" then return end
  connectTcp()
end

function ReceivedFromProxy(idBinding, strCommand, tParams)
  setProperty("Last Proxy Binding", tostring(idBinding or ""))
  setProperty("Last Proxy Command", tostring(strCommand or ""))
  setProperty("Last Proxy Params", previewValue(tParams))

  -- Handle RELAY control for dynamically created switch bindings.
  local reg = getRegistry()
  local target
  for _, e in pairs(reg) do
    if type(e) == "table" and e.bindingId == idBinding then
      target = e
      break
    end
  end
  if not target then
    debugVerbose("ReceivedFromProxy ignored (no target) id=" .. tostring(idBinding) .. " cmd=" .. tostring(strCommand))
    return
  end
  if target.type ~= "switch" and target.type ~= "light" then
    debugVerbose("ReceivedFromProxy ignored (type=" .. tostring(target.type) .. ") id=" .. tostring(idBinding) .. " cmd=" .. tostring(strCommand))
    return
  end

  strCommand = tostring(strCommand or "")
  local cmd = string.upper(strCommand)
  debugLog("ReceivedFromProxy id=" .. tostring(idBinding) .. " cmd=" .. cmd .. " params=" .. previewValue(tParams))

  -- Handle TOGGLE directly via HA service (switch.toggle / light.toggle)
  if cmd == "TOGGLE" or cmd == "TGL" then
    if not state.ha_authed then
      debugLog("Proxy cmd ignored (not authed)")
      return
    end
    local domain = (target.type == "light") and "light" or "switch"
    debugLog("HA call_service " .. domain .. ".toggle entity_id=" .. tostring(target.entity_id))
    haCallService(domain, "toggle", target.entity_id)
    return
  end

  local wantOn
  if cmd == "ON" or cmd == "CLOSE" or cmd == "CLOSED" then wantOn = true end
  if cmd == "OFF" or cmd == "OPEN" or cmd == "OPENED" then wantOn = false end

  -- Common relay proxy variants from Programming:
  if wantOn == nil and tParams and type(tParams) == "table" then
    local val = tParams.STATE or tParams.VALUE or tParams.Val or tParams.level or tParams.LEVEL
    if val ~= nil then
      local s = string.upper(tostring(val))
      if s == "ON" or s == "1" or s == "TRUE" or s == "CLOSED" then wantOn = true end
      if s == "OFF" or s == "0" or s == "FALSE" or s == "OPEN" or s == "OPENED" then wantOn = false end
    end
  end

  if wantOn == nil and (cmd == "SET_TO" or cmd == "SET_VALUE" or cmd == "SET_TO_VALUE") and tParams then
    local s = string.upper(tostring(tParams.VALUE or tParams.STATE or ""))
    if s == "ON" or s == "1" or s == "TRUE" then wantOn = true end
    if s == "OFF" or s == "0" or s == "FALSE" then wantOn = false end
  end

  if cmd == "SET_STATE" and tParams and tParams.STATE then
    local s = string.upper(tostring(tParams.STATE))
    if s == "ON" or s == "1" or s == "TRUE" then wantOn = true end
    if s == "OFF" or s == "0" or s == "FALSE" then wantOn = false end
  end

  if wantOn == nil then
    debugVerbose("ReceivedFromProxy unhandled cmd=" .. cmd .. " params=" .. previewValue(tParams))
    return
  end
  if not state.ha_authed then
    debugLog("Proxy cmd ignored (not authed)")
    return
  end

  local domain = (target.type == "light") and "light" or "switch"
  local service = wantOn and "turn_on" or "turn_off"
  debugLog("HA call_service " .. domain .. "." .. service .. " entity_id=" .. tostring(target.entity_id))
  haCallService(domain, service, target.entity_id)
end

local function isConnectedStatus(status)
  if status == true then return true end
  if status == 1 then return true end
  if type(status) == "string" then
    local s = string.upper(status)
    return s == "ONLINE" or s == "CONNECTED" or s == "UP"
  end
  return false
end

local function normalizeConnStatusArgs(statusOrPort, maybeStatus)
  if maybeStatus ~= nil then
    return statusOrPort, maybeStatus
  end
  return nil, statusOrPort
end

function OnConnectionStatusChanged(id, statusOrPort, maybeStatus)
  if id ~= NETWORK_CONNECTION_ID then return end
  local port, status = normalizeConnStatusArgs(statusOrPort, maybeStatus)
  debugLog("OnConnectionStatusChanged id=" .. tostring(id) .. " port=" .. tostring(port) .. " status=" .. tostring(status))
  if isConnectedStatus(status) then
    state.connected = true
    state.running = false
    state.buf = ""
    setStatus("TCP ONLINE (WS handshake)")
    debugLog("OnConnectionStatusChanged ONLINE; sending handshake")
    if state._handshake then
      sendToNetwork(state._handshake)
    end
  else
    debugLog("OnConnectionStatusChanged OFFLINE port=" .. tostring(port) .. " status=" .. tostring(status))
    scheduleReconnect("OFFLINE")
  end
end

function OnNetworkConnectionStatusChanged(id, statusOrPort, maybeStatus)
  OnConnectionStatusChanged(id, statusOrPort, maybeStatus)
end

local function handleNetworkData(id, data)
  if id ~= NETWORK_CONNECTION_ID then return end
  debugVerbose("RX type=" .. tostring(type(data)) .. " bytes=" .. tostring(type(data) == "string" and #data or "n/a") .. " running=" .. tostring(state.running) .. " preview=" .. previewValue(data))
  if type(data) == "string" then
    state.buf = (state.buf or "") .. data
  end
  wsProcessRx()
end

local function normalizeNetworkRxArgs(dataOrPort, maybeData)
  -- Some firmwares call ReceivedFromNetwork/OnReceivedFromNetwork as (idBinding, port, data)
  if maybeData ~= nil then
    return dataOrPort, maybeData
  end
  return nil, dataOrPort
end

function ReceivedFromNetwork(id, dataOrPort, maybeData)
  local port, data = normalizeNetworkRxArgs(dataOrPort, maybeData)
  debugVerbose("ReceivedFromNetwork id=" .. tostring(id) .. " port=" .. tostring(port))
  handleNetworkData(id, data)
end

function OnReceivedFromNetwork(id, dataOrPort, maybeData)
  local port, data = normalizeNetworkRxArgs(dataOrPort, maybeData)
  debugVerbose("OnReceivedFromNetwork id=" .. tostring(id) .. " port=" .. tostring(port))
  handleNetworkData(id, data)
end

function OnTimerExpired(id)
  if id == TIMER_RECONNECT then
    connectTcp()
  end
end
