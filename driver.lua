-- e_safe_contact_mqtt - MQTT listener (DriverWorks Lua only, main: driver.lua)
-- Target: MQTT 3.1.1 over TCP (usually port 1883), QoS 0 subscribe.
--
-- Limitations (Lua-only):
-- - No MQTT over TLS (8883) unless your Control4 runtime exposes TLS sockets (usually it doesn't).
-- - No external Lua libraries; MQTT framing is implemented here.

local CONTACT_PROXY_BINDING_ID = 5001
local NETWORK_CONNECTION_ID = 6001
local BERTO_AGENT_BINDING_ID = 999

local TIMER_RECONNECT = 101
local TIMER_KEEPALIVE = 102

local RECONNECT_MIN_SEC = 5
local RECONNECT_MAX_SEC = 60

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
    if type(C4.DebugLog) == "function" then
      pcall(function() C4:DebugLog(msg) end)
      return
    end
    if type(C4.PrintToLog) == "function" then
      pcall(function() C4:PrintToLog(msg) end)
      return
    end
  end
  print(msg)
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

local function debugLog(msg)
  if isTruthyProperty(Properties and Properties["Debug"] or "") then
    log("DEBUG MQTT: " .. tostring(msg))
  end
end

local function shouldLogPayload()
  return isTruthyProperty(Properties and Properties["Log Payload"] or "")
end

local function setStatus(s)
  setProperty("MQTT Status", s)
end

local function setAgentBound(value)
  setProperty("Berto Agent Bound", value)
end

local function setBertoRegistryStatus(value)
  setProperty("Berto Registry", value)
end

local function setBertoRegistryType(value)
  setProperty("Berto Registry Type", value)
end

local function setBertoRegistryPreview(value)
  setProperty("Berto Registry Preview", value)
end

local function previewValue(v, maxLen)
  maxLen = maxLen or 240
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
  if #s > maxLen then
    s = s:sub(1, maxLen) .. "…"
  end
  return s
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

local mqtt = {
  rx = "",
  connected_tcp = false,
  connected_mqtt = false,
  packet_id = 1,
  reconnect_sec = RECONNECT_MIN_SEC,
  keepalive_sec = 30,
  pending_subscribe = false,
  subscribed_topic = nil,
  allow_wildcards = false,
  last_log_ts = 0,
  suppressed_logs = 0,
}

local function u16(n)
  local hi = math.floor(n / 256) % 256
  local lo = n % 256
  return string.char(hi, lo)
end

local function encodeString(s)
  s = s or ""
  return u16(#s) .. s
end

local function encodeRemainingLength(len)
  local out = {}
  repeat
    local digit = len % 128
    len = math.floor(len / 128)
    if len > 0 then digit = digit + 128 end
    out[#out + 1] = string.char(digit)
  until len == 0
  return table.concat(out)
end

local function nextPacketId()
  mqtt.packet_id = mqtt.packet_id + 1
  if mqtt.packet_id > 0xFFFF then mqtt.packet_id = 1 end
  return mqtt.packet_id
end

local function mqttConnectPacket()
  local clientId = trim(Properties and Properties["Client ID"] or "")
  if clientId == "" or lower(clientId) == "auto" then
    clientId = "c4_" .. tostring(os.time()) .. "_" .. tostring(math.random(1000, 9999))
  end

  local keepAlive = tonumber(trim(Properties and Properties["Keep Alive (sec)"] or "")) or 30
  if keepAlive < 5 then keepAlive = 5 end
  if keepAlive > 3600 then keepAlive = 3600 end
  mqtt.keepalive_sec = keepAlive

  local protocolName = encodeString("MQTT")
  local protocolLevel = string.char(4)

  local connectFlags = 0
  connectFlags = connectFlags + 0x02 -- Clean Session

  local variableHeader = protocolName .. protocolLevel .. string.char(connectFlags) .. u16(keepAlive)
  local payload = encodeString(clientId)

  local remaining = #variableHeader + #payload
  local fixedHeader = string.char(0x10) .. encodeRemainingLength(remaining)
  return fixedHeader .. variableHeader .. payload
end

local function mqttSubscribePacket(topic)
  local pid = nextPacketId()
  local variableHeader = u16(pid)
  local payload = encodeString(topic) .. string.char(0) -- QoS 0
  local remaining = #variableHeader + #payload
  local fixedHeader = string.char(0x82) .. encodeRemainingLength(remaining)
  return fixedHeader .. variableHeader .. payload
end

local function mqttPingReqPacket()
  return string.char(0xC0, 0x00)
end

local function sendToNetwork(data)
  if not (C4 and type(C4.SendToNetwork) == "function") then
    setStatus("ERROR: no C4.SendToNetwork")
    return
  end
  C4:SendToNetwork(NETWORK_CONNECTION_ID, data)
end

local function getBrokerUri()
  local explicit = trim(Properties and Properties["Broker URI"] or "")
  if explicit ~= "" then
    return explicit
  end

  local selected = trim(Properties and Properties["Selected Broker"] or "")
  if selected ~= "" then
    local ok, reg = pcall(function()
      return C4 and C4.RegistryGetValue and C4:RegistryGetValue("BERTO") or nil
    end)
    if ok and type(reg) == "string" and C4 and type(C4.JsonDecode) == "function" then
      local ok2, decoded = pcall(function() return C4:JsonDecode(reg) end)
      if ok2 then reg = decoded end
    end
    if ok and type(reg) == "table" then
      local brokers = reg.Brokers or reg.brokers
      if type(brokers) == "table" then
        local entry = brokers[selected] or brokers[trim(selected)]
        if type(entry) == "string" then
          return entry
        end
        if type(entry) == "table" then
          local uri = entry.URI or entry.Uri or entry.uri or entry.Server or entry.server or entry.BROKER or entry.broker
          if type(uri) == "string" and trim(uri) ~= "" then
            return uri
          end
        end
      end
    end
  end

  local addr = trim(Properties and Properties["Broker Address"] or "")
  local port = tonumber(trim(Properties and Properties["Broker Port"] or "")) or 1883
  if addr == "" then return nil end
  return "mqtt://" .. addr .. ":" .. tostring(port)
end

local function getSubscribeTopics()
  local topics = trim(Properties and Properties["Subscribe To Topics"] or "")
  if topics ~= "" then return topics end
  return trim(Properties and Properties["Topic"] or "")
end

local function getQoS()
  local qos = tonumber(trim(Properties and Properties["Quality Of Service"] or ""))
  if qos == nil then qos = 0 end
  if qos < 0 then qos = 0 end
  if qos > 2 then qos = 2 end
  return qos
end

local function bertoSend(command, params)
  if not (C4 and type(C4.SendToProxy) == "function") then
    setStatus("ERROR: no C4.SendToProxy")
    return false
  end
  params = params or {}
  local ok, err = pcall(function()
    C4:SendToProxy(BERTO_AGENT_BINDING_ID, command, params)
  end)
  if not ok then
    debugLog(err)
    return false
  end
  return true
end

local function getDriverId()
  if C4 and type(C4.GetDeviceID) == "function" then
    local ok, id = pcall(function() return C4:GetDeviceID() end)
    if ok and id ~= nil then return id end
  end
  return nil
end

local function connectViaBertoAgent()
  local topics = getSubscribeTopics()
  if topics == "" then
    setStatus("ERROR: Topic empty")
    return true
  end

  local brokerName = trim(Properties and Properties["Selected Broker"] or "")
  if brokerName == "" then
    setStatus("ERROR: seleziona 'MQTT Brokers Available'")
    return true
  end

  local brokerUri = getBrokerUri()
  setStatus("AGENT CONNECT " .. brokerName)
  log("MQTT (via Berto Agent) connect broker=" .. brokerName .. " uri=" .. tostring(brokerUri) .. " topics=" .. topics)

  -- Matches Berto_MQTT driver params keys.
  local ok = bertoSend("MQTT_CONNECT", {
    BROKER = brokerName,
    URI = brokerUri,
    TOPICS = topics,
    QOS = getQoS(),
    ID = getDriverId(),
  })
  if not ok then
    setStatus("ERROR: agent send failed")
  end
  return true
end

local function refreshBertoBrokers()
  if not (C4 and type(C4.RegistryGetValue) == "function" and type(C4.UpdatePropertyList) == "function") then
    setBertoRegistryStatus("no RegistryGetValue/UpdatePropertyList")
    return
  end

  local ok, reg = pcall(function()
    return C4:RegistryGetValue("BERTO")
  end)
  if not ok then
    setBertoRegistryStatus("RegistryGetValue error")
    debugLog("RegistryGetValue(BERTO) failed")
    return
  end

  setBertoRegistryType(type(reg))
  setBertoRegistryPreview(previewValue(reg))

  if type(reg) == "string" then
    if C4 and type(C4.JsonDecode) == "function" then
      local ok2, decoded = pcall(function() return C4:JsonDecode(reg) end)
      if ok2 then
        reg = decoded
      end
    end
  end

  local brokers
  pcall(function()
    if reg ~= nil then
      brokers = reg.Brokers or reg.brokers
    end
  end)
  if brokers == nil then
    setBertoRegistryStatus("BERTO registry: no Brokers")
    return
  end

  local brokersEmpty = true
  pcall(function()
    brokersEmpty = (next(brokers) == nil)
  end)
  setBertoRegistryStatus("OK (" .. tostring(brokersEmpty and "empty" or "non-empty") .. ")")

  local names = {}
  pcall(function()
    for name, _ in pairs(brokers) do
      if type(name) == "string" and trim(name) ~= "" then
        table.insert(names, name)
      end
    end
  end)
  table.sort(names)

  local list = table.concat(names, ",")
  pcall(function()
    C4:UpdatePropertyList("MQTT Brokers Available", list, "")
  end)

  -- If not selected, default to first entry
  local selected = trim(Properties and Properties["Selected Broker"] or "")
  if selected == "" and #names > 0 then
    setProperty("Selected Broker", names[1])
  end
end

local function connectTcp()
  -- If Berto Agent is present/bound, use it instead of direct sockets.
  if C4 and type(C4.GetBoundProviderDevice) == "function" then
    local agent = C4:GetBoundProviderDevice(0, BERTO_AGENT_BINDING_ID)
    if agent and agent ~= 0 then
      setAgentBound("YES (" .. tostring(agent) .. ")")
      refreshBertoBrokers()
      return connectViaBertoAgent()
    end
    setAgentBound("NO")
  else
    setAgentBound("unknown (no GetBoundProviderDevice)")
  end

  mqtt.connected_mqtt = false
  mqtt.pending_subscribe = false
  mqtt.rx = ""

  local addr = trim(Properties and Properties["Broker Address"] or "")
  local port = tonumber(trim(Properties and Properties["Broker Port"] or "")) or 1883

  if addr == "" then
    setStatus("ERROR: Broker Address empty")
    return
  end

  if not (C4 and type(C4.NetConnect) == "function") then
    setStatus("ERROR: no C4.NetConnect")
    return
  end

  setStatus("TCP CONNECT " .. addr .. ":" .. tostring(port))
  debugLog("NetConnect(" .. addr .. ":" .. tostring(port) .. ")")

  -- Different firmwares/driver types expose different NetConnect signatures.
  -- Try a few common variants and treat a truthy return as success.
  local attempts = {
    { "NetConnect(id, addr, port)", function() return C4:NetConnect(NETWORK_CONNECTION_ID, addr, port) end },
    { "NetConnect(addr, port)", function() return C4:NetConnect(addr, port) end },
    { "NetConnect(id, addr, tostring(port))", function() return C4:NetConnect(NETWORK_CONNECTION_ID, addr, tostring(port)) end },
    { "NetConnect(addr, tostring(port))", function() return C4:NetConnect(addr, tostring(port)) end },
    { "NetConnect(id, addr, port, TCP)", function() return C4:NetConnect(NETWORK_CONNECTION_ID, addr, port, "TCP") end },
    { "NetConnect(addr, port, TCP)", function() return C4:NetConnect(addr, port, "TCP") end },
  }

  for _, a in ipairs(attempts) do
    local label = a[1]
    local fn = a[2]
    local ok, retOrErr = pcall(fn)
    if ok and retOrErr ~= false and retOrErr ~= nil then
      setStatus("TCP CONNECTING (" .. label .. ")")
      debugLog("NetConnect OK via " .. label .. " ret=" .. tostring(retOrErr))
      return
    end
    debugLog("NetConnect failed via " .. label .. " err/ret=" .. tostring(retOrErr))
  end

  setStatus("ERROR: NetConnect failed (all variants) - usa Berto Agent")
end

local function scheduleReconnect()
  mqtt.connected_tcp = false
  mqtt.connected_mqtt = false
  mqtt.pending_subscribe = false
  setStatus("RECONNECT in " .. tostring(mqtt.reconnect_sec) .. "s")
  C4:AddTimer(TIMER_RECONNECT, mqtt.reconnect_sec, "SECONDS", false)
  mqtt.reconnect_sec = math.min(mqtt.reconnect_sec * 2, RECONNECT_MAX_SEC)
end

local function parsePayloadValue(payload)
  payload = trim(payload)
  if payload == "" then return "" end

  -- Minimal JSON-ish parsing: {"state":"OPEN"} / {"contact":"CLOSED"}
  if payload:sub(1, 1) == "{" then
    local v = payload:match('%"state%"%s*:%s*%"(.-)%"')
    if v and v ~= "" then return v end
    v = payload:match('%"contact%"%s*:%s*%"(.-)%"')
    if v and v ~= "" then return v end
    v = payload:match('%"STA%"%s*:%s*%"(.-)%"')
    if v and v ~= "" then return v end
  end

  return payload
end

local function topicMatches(sub, actual)
  if not sub or sub == "" then return false end
  if not actual then return false end
  if not mqtt.allow_wildcards then
    return actual == sub
  end

  -- Minimal wildcard support: + and # (MQTT rules)
  -- Keep it simple: split by '/', match +, allow trailing #.
  local function splitTopic(t)
    local parts = {}
    for p in string.gmatch(t, "([^/]+)") do
      parts[#parts + 1] = p
    end
    return parts
  end

  local sp = splitTopic(sub)
  local ap = splitTopic(actual)

  local i = 1
  while i <= #sp do
    local s = sp[i]
    if s == "#" then
      return i == #sp
    end
    local a = ap[i]
    if not a then return false end
    if s ~= "+" and s ~= a then return false end
    i = i + 1
  end
  return i > #ap
end

local function logPublish(topic, payload)
  if not shouldLogPayload() then return end

  -- Simple throttle: at most 1 log/sec (prevents Director/Composer overload).
  local now = os.time()
  if mqtt.last_log_ts == now then
    mqtt.suppressed_logs = mqtt.suppressed_logs + 1
    return
  end

  local suppressed = mqtt.suppressed_logs
  mqtt.suppressed_logs = 0
  mqtt.last_log_ts = now

  local p = payload or ""
  if #p > 512 then
    p = p:sub(1, 512) .. "...(truncated)"
  end

  if suppressed > 0 then
    log("MQTT[" .. tostring(topic) .. "]: " .. tostring(p) .. " (+" .. tostring(suppressed) .. " suppressed)")
  else
    log("MQTT[" .. tostring(topic) .. "]: " .. tostring(p))
  end
end

local function setContactState(isOpen, topic, payload)
  local stateStr = isOpen and "OPEN" or "CLOSED"

  setProperty("Last Topic", topic or "")
  setProperty("Last Payload", payload or "")

  if C4 and type(C4.SetVariable) == "function" then
    C4:SetVariable("CONTACT_STATE", isOpen and "1" or "0")
  end

  -- This is the only part that depends on the CONTACT_SENSOR proxy notification name.
  -- If Composer doesn't react, replace "CONTACT_STATE_CHANGED" and/or parameter keys with the proxy spec.
  if C4 and type(C4.SendToProxy) == "function" then
    local attempts = {
      { "CONTACT_STATE_CHANGED", { STATE = stateStr } },
      { "STATE_CHANGED", { STATE = stateStr } },
      { stateStr, {} }, -- sometimes proxies accept "OPEN"/"CLOSED"
      { "SET_STATE", { STATE = stateStr } },
    }
    for _, a in ipairs(attempts) do
      pcall(function()
        C4:SendToProxy(CONTACT_PROXY_BINDING_ID, a[1], a[2])
      end)
    end
  end
end

local function handlePublish(topic, payload)
  if mqtt.subscribed_topic and not topicMatches(mqtt.subscribed_topic, topic) then
    return
  end

  logPublish(topic, payload)

  local parsed = parsePayloadValue(payload)
  local key = lower(parsed)
  debugLog("PUBLISH topic=" .. tostring(topic) .. " payload=" .. tostring(payload) .. " parsed=" .. tostring(parsed))

  if TRUESET[key] then
    setContactState(true, topic, payload)
  elseif FALSESET[key] then
    setContactState(false, topic, payload)
  else
    setProperty("Last Topic", topic or "")
    setProperty("Last Payload", payload or "")
  end
end

local function decodeRemainingLength(buf, idx)
  local multiplier = 1
  local value = 0
  local consumed = 0

  while true do
    local b = buf:byte(idx + consumed)
    if not b then return nil end
    consumed = consumed + 1
    value = value + (b % 128) * multiplier
    if b < 128 then break end
    multiplier = multiplier * 128
    if multiplier > 128 * 128 * 128 then return nil end
  end

  return value, consumed
end

local function processRx()
  while true do
    if #mqtt.rx < 2 then return end
    local b1 = mqtt.rx:byte(1)
    local remaining, consumed = decodeRemainingLength(mqtt.rx, 2)
    if not remaining then return end

    local headerLen = 1 + consumed
    local frameLen = headerLen + remaining
    if #mqtt.rx < frameLen then return end

    local body = mqtt.rx:sub(headerLen + 1, frameLen)
    mqtt.rx = mqtt.rx:sub(frameLen + 1)

    local packetType = math.floor(b1 / 16)

    if packetType == 2 then
      -- CONNACK: ack flags, return code
      local rc = body:byte(2) or 255
      if rc == 0 then
        mqtt.connected_mqtt = true
        mqtt.reconnect_sec = RECONNECT_MIN_SEC
        setStatus("MQTT CONNECTED")
        mqtt.pending_subscribe = true
      else
        setStatus("MQTT CONNACK rc=" .. tostring(rc))
        scheduleReconnect()
      end
    elseif packetType == 9 then
      -- SUBACK
      mqtt.pending_subscribe = false
      setStatus("SUBSCRIBED")
    elseif packetType == 3 then
      -- PUBLISH
      local tlen = (body:byte(1) or 0) * 256 + (body:byte(2) or 0)
      local topic = body:sub(3, 2 + tlen)

      local qos = math.floor((b1 % 16) / 2)
      local pos = 3 + tlen
      if qos > 0 then
        pos = pos + 2 -- packet id (not supported beyond skipping)
      end
      local payload = body:sub(pos)
      handlePublish(topic, payload)
    elseif packetType == 13 then
      -- PINGRESP
      debugLog("PINGRESP")
    else
      debugLog("Unhandled packetType=" .. tostring(packetType))
    end
  end
end

local function maybeSubscribe()
  if not mqtt.connected_mqtt then return end
  if not mqtt.pending_subscribe then return end
  local topic = trim(Properties and Properties["Topic"] or "")
  if topic == "" then
    setStatus("ERROR: Topic empty")
    return
  end

  mqtt.allow_wildcards = isTruthyProperty(Properties and Properties["Allow Topic Wildcards"] or "")
  if (topic:find("#", 1, true) or topic:find("+", 1, true)) and not mqtt.allow_wildcards then
    setStatus("ERROR: wildcard topic blocked")
    return
  end

  mqtt.subscribed_topic = topic
  setStatus("SUBSCRIBE " .. topic)
  sendToNetwork(mqttSubscribePacket(topic))
end

local function startKeepAlive()
  C4:AddTimer(TIMER_KEEPALIVE, mqtt.keepalive_sec, "SECONDS", false)
end

local function onKeepAlive()
  if mqtt.connected_mqtt then
    sendToNetwork(mqttPingReqPacket())
    startKeepAlive()
  end
end

local function onTcpConnected()
  mqtt.connected_tcp = true
  mqtt.connected_mqtt = false
  mqtt.pending_subscribe = false
  mqtt.rx = ""
  setStatus("TCP CONNECTED (CONNECT)")
  sendToNetwork(mqttConnectPacket())
end

local function onTcpDisconnected()
  scheduleReconnect()
end

local function handleNetworkData(id, data)
  if id ~= NETWORK_CONNECTION_ID then return end
  mqtt.rx = mqtt.rx .. (data or "")
  processRx()
  maybeSubscribe()
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

function OnDriverInit()
  local okSeed = pcall(function()
    math.randomseed(os.time())
  end)
  if not okSeed then
    math.randomseed(1)
  end
  if C4 and type(C4.AddVariable) == "function" then
    C4:AddVariable("CONTACT_STATE", "0", "BOOL")
  end

  setStatus("INIT (lua_gen)")
  log("e-safe MQTT driver avviato")
  debugLog("C4.DebugLog=" .. tostring(C4 and type(C4.DebugLog)) .. " C4.UpdateProperty=" .. tostring(C4 and type(C4.UpdateProperty)))
  debugLog("C4.NetConnect=" .. tostring(C4 and type(C4.NetConnect)) .. " C4.SendToNetwork=" .. tostring(C4 and type(C4.SendToNetwork)))

  TRUESET = setFromCSV(Properties and Properties["True Values"] or "")
  FALSESET = setFromCSV(Properties and Properties["False Values"] or "")

  if C4 and type(C4.CreateNetworkConnection) == "function" then
    local ok, err = pcall(function()
      C4:CreateNetworkConnection(NETWORK_CONNECTION_ID, "TCP")
    end)
    if not ok then
      setStatus("ERROR: CreateNetworkConnection failed")
      debugLog(err)
    end
  else
    setStatus("ERROR: no C4.CreateNetworkConnection")
  end
end

function OnDriverLateInit()
  mqtt.reconnect_sec = RECONNECT_MIN_SEC
  refreshBertoBrokers()
  connectTcp()
end

-- If this prints, the Lua file is being loaded by Director.
pcall(function() log("e-safe MQTT driver.lua caricato") end)

function OnPropertyChanged(name)
  if name == "MQTT Brokers Available" then
    -- In Berto drivers, selecting from the dynamic list sets the selected broker.
    setProperty("Selected Broker", trim(Properties and Properties["MQTT Brokers Available"] or ""))
    mqtt.reconnect_sec = RECONNECT_MIN_SEC
    connectTcp()
    return
  end

  if name == "True Values" or name == "False Values" then
    TRUESET = setFromCSV(Properties["True Values"])
    FALSESET = setFromCSV(Properties["False Values"])
    return
  end

  if name == "Allow Topic Wildcards" then
    mqtt.allow_wildcards = isTruthyProperty(Properties["Allow Topic Wildcards"])
    return
  end

  if name == "Broker URI" or name == "Broker Address" or name == "Broker Port" or name == "Topic" or name == "Subscribe To Topics" or name == "Quality Of Service" or name == "Client ID" or name == "Keep Alive (sec)" then
    mqtt.reconnect_sec = RECONNECT_MIN_SEC
    connectTcp()
  end
end

-- Berto Agent messages arrive via proxy callbacks (like Berto_MQTT).
function ReceivedFromProxy(idBinding, strCommand, tParams)
  if isTruthyProperty(Properties and Properties["Debug"] or "") then
    debugLog("ReceivedFromProxy id=" .. tostring(idBinding) .. " cmd=" .. tostring(strCommand) .. " params=" .. previewValue(tParams))
  end
  if strCommand == "MQTT_CONNECTED" and tParams and tParams.BROKER then
    setStatus("AGENT CONNECTED " .. tostring(tParams.BROKER))
    return
  end
  if strCommand == "MQTT_DISCONNECTED" and tParams and tParams.BROKER then
    setStatus("AGENT DISCONNECTED " .. tostring(tParams.BROKER))
    return
  end
  if strCommand == "MQTT_SUBSCRIBED" and tParams and tParams.TOPICS then
    setStatus("AGENT SUBSCRIBED " .. tostring(tParams.TOPICS))
    return
  end
  if strCommand == "MQTT_RECEIVED" and tParams and tParams.TOPIC and tParams.MESSAGE then
    handlePublish(tParams.TOPIC, tParams.MESSAGE)
    return
  end
end

function OnConnectionStatusChanged(id, status)
  if id ~= NETWORK_CONNECTION_ID then return end
  if isConnectedStatus(status) then
    onTcpConnected()
    startKeepAlive()
  else
    onTcpDisconnected()
  end
end

function OnNetworkConnectionStatusChanged(id, status)
  OnConnectionStatusChanged(id, status)
end

function ReceivedFromNetwork(id, data)
  handleNetworkData(id, data)
end

function OnReceivedFromNetwork(id, data)
  handleNetworkData(id, data)
end

function OnTimerExpired(id)
  if id == TIMER_RECONNECT then
    connectTcp()
    return
  end
  if id == TIMER_KEEPALIVE then
    onKeepAlive()
    return
  end
end
