--!nonstrict
-- clockmost — live ntfy toasts.
--
-- A headless [[service]]: every `toast_poll_seconds` it runs
--   ssh <ssh_host> clockmost-notifications <window>
-- (a server-side helper that reads the ntfy token and returns recent messages
-- on the `clockmost` topic as JSON), and raises a Noctalia desktop notification
-- for each message it has not seen before.
--
-- The desktop never holds the ntfy token — the server helper does. This is a
-- ~25s poll, not a live SSE stream: fine for server alerts, and it survives an
-- SSH blip with no reconnect logic.
--
-- First run seeds the "seen" set WITHOUT toasting, so enabling the plugin (or a
-- Noctalia restart) never dumps the backlog at you.

local function cfg(k, d)
  local v = noctalia.getConfig(k)
  if v == nil then return d end
  return v
end

local SSH_HOST, POLL_MS, ENABLED, MIN_PRIO

local function loadCfg()
  SSH_HOST = tostring(cfg("ssh_host", "clockmost-claude"))
  POLL_MS  = math.floor((tonumber(cfg("toast_poll_seconds")) or 25) * 1000)
  if POLL_MS < 10000 then POLL_MS = 10000 end
  ENABLED  = cfg("toasts_enabled", true) == true
  MIN_PRIO = math.floor(tonumber(cfg("toast_min_priority")) or 3)
end
loadCfg()

local function log(m) if noctalia.log then noctalia.log("clockmost/toasts: " .. m) end end

-- seen message ids: a set for lookup + a ring for bounded eviction
local seen = {}
local ring = {}
local RING_MAX = 250
local primed = false
local inFlight = false

local function markSeen(id)
  if seen[id] then return end
  seen[id] = true
  ring[#ring + 1] = id
  if #ring > RING_MAX then
    local old = table.remove(ring, 1)
    seen[old] = nil
  end
end

local function tagged(msg, name)
  for _, t in ipairs(msg.tags or {}) do
    if tostring(t) == name then return true end
  end
  return false
end

local function toast(msg)
  local title = tostring(msg.ti or "clockmost")
  local body  = tostring(msg.m or "")
  if body == "" or body == title then body = "clockmost" end
  local prio = tonumber(msg.p) or 3
  if prio >= 4 or tagged(msg, "rotating_light") or tagged(msg, "warning") then
    if noctalia.notifyError then noctalia.notifyError(title, body)
    else noctalia.notify(title, body) end
  else
    noctalia.notify(title, body)
  end
end

local function poll()
  if inFlight or not ENABLED then return end
  inFlight = true
  -- window ~= 3x the poll interval so a slow/stalled tick can't drop a message
  local window = tostring(math.max(120, math.floor(POLL_MS / 1000) * 3)) .. "s"
  local cmd = "ssh -o ConnectTimeout=6 -o BatchMode=yes -o StrictHostKeyChecking=accept-new "
    .. SSH_HOST .. " clockmost-notifications " .. window
  noctalia.runAsync(cmd, function(res)
    inFlight = false
    local out = res and res.stdout
    if not out or out == "" or (res and res.timedOut) then
      log("poll: no output"); return
    end
    local ok, list = pcall(function() return noctalia.json.decode(out) end)
    if not ok or type(list) ~= "table" then
      log("poll: bad JSON"); return
    end
    -- helper returns newest-first; toast oldest-first so notifications stack in order
    local n = #list
    local fresh = 0
    for i = n, 1, -1 do
      local m = list[i]
      if type(m) == "table" and m.id and not seen[m.id] then
        markSeen(m.id)
        if primed and (tonumber(m.p) or 3) >= MIN_PRIO then
          toast(m); fresh = fresh + 1
        end
      end
    end
    if not primed then
      primed = true
      log("primed with " .. tostring(n) .. " recent message(s) (no toast)")
    elseif fresh > 0 then
      log("raised " .. tostring(fresh) .. " toast(s)")
    end
  end, 15000)
end

-- Service tick. Re-arm each call (safe whether the host treats the interval as
-- repeating or one-shot).
function update()
  noctalia.setUpdateInterval(POLL_MS)
  poll()
end

function onConfigChanged()
  loadCfg()
  noctalia.setUpdateInterval(POLL_MS)
  poll()
end

noctalia.setUpdateInterval(POLL_MS)
poll()
