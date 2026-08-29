--!nonstrict
-- clockmost — home-server status on the Noctalia bar.
--
-- One call per refresh: `ssh <ssh_host> clockmost-status` -> a JSON snapshot
-- (deploy state, container health, failed units, disk, pending Renovate PRs,
-- Zabbix problems). The server script holds every token; the desktop only needs
-- its existing passwordless SSH to `clockmost-claude`.
--
-- The glyph is the glance; left-click opens the detail panel (main.luau), which
-- reads the same snapshot from shared state ("clockmost.snapshot").
--
-- The refresh loop is Noctalia's re-arming one-shot: `update()` (NOT `onUpdate`)
-- is the tick hook, and it must call setUpdateInterval() again every tick or the
-- timer stops after one fire.

local STATE_KEY = "clockmost.snapshot"
local PANEL = "benylin/clockmost:main"

local function cfg(k, d)
  local v = noctalia.getConfig(k)
  if v == nil then return d end
  return v
end

local SSH_HOST, POLL_MS, SHOW_COUNT, ARCANE_URL, PRS_URL

local function loadCfg()
  SSH_HOST   = tostring(cfg("ssh_host", "clockmost-claude"))
  POLL_MS    = math.floor((tonumber(cfg("poll_seconds")) or 90) * 1000)
  if POLL_MS < 30000 then POLL_MS = 30000 end
  SHOW_COUNT = cfg("show_count", true) == true
  ARCANE_URL = tostring(cfg("arcane_url", "https://arcane.clockmost.com"))
  PRS_URL    = tostring(cfg("prs_url", "https://git.clockmost.com/Benylin/clockmost-infra/pulls"))
end
loadCfg()

local data = nil
local err  = nil
local inFlight = false

local GLYPH = { ok = "server", warn = "alert-triangle", crit = "alert-octagon" }
local COLOR = { ok = "primary", warn = "warning", crit = "error" }

local function log(m) if noctalia.log then noctalia.log("clockmost/widget: " .. m) end end

local function render()
  if not data then
    barWidget.setGlyph(err and "cloud-off" or "server")
    barWidget.setGlyphColor("on_surface_variant")
    barWidget.setText("")
    barWidget.setTooltip(err and ("clockmost: " .. err .. "  (left-click for panel)")
      or "clockmost: loading…")
    return
  end
  local d = data
  local nUp = (d.updates and d.updates.n) or 0
  local nAl = (d.alerts and d.alerts.n) or 0
  barWidget.setGlyph(GLYPH[d.status] or "server")
  barWidget.setGlyphColor(COLOR[d.status] or "on_surface_variant")
  barWidget.setText((SHOW_COUNT and (nUp + nAl) > 0) and tostring(nUp + nAl) or "")
  local c = d.containers or {}
  local tip = string.format(
    "clockmost — %s\n%d update%s · %d alert%s · %d/%d containers",
    tostring(d.status):upper(),
    nUp, (nUp == 1 and "" or "s"),
    nAl, (nAl == 1 and "" or "s"),
    (c.up or 0), (c.total or 0))
  local nt = (d.notify and d.notify.list) or {}
  if nt[1] and nt[1].ti then
    tip = tip .. "\nlatest: " .. tostring(nt[1].ti)
  end
  barWidget.setTooltip(tip .. "\nleft-click for detail")
end

-- Accept the result whenever stdout parses as our snapshot — some Noctalia
-- builds don't put `exitCode` on a successful runAsync result.
local function adopt(res)
  inFlight = false
  if not res or res.timedOut then
    err = "ssh timed out"; log("timeout"); render(); return
  end
  local out = res.stdout
  if type(out) ~= "string" or out == "" then
    err = "no output (exit " .. tostring(res.exitCode) .. ")"; log(err); render(); return
  end
  local ok, d = pcall(function() return noctalia.json.decode(out) end)
  if ok and type(d) == "table" and d.status then
    data, err = d, nil
    if noctalia.state and noctalia.state.set then noctalia.state.set(STATE_KEY, out) end
    log("ok status=" .. tostring(d.status)
      .. " updates=" .. tostring(d.updates and d.updates.n)
      .. " alerts=" .. tostring(d.alerts and d.alerts.n))
  else
    err = "bad JSON from clockmost-status"; log(err .. ": " .. out:sub(1, 120))
  end
  render()
end

local function poll()
  if inFlight then return end
  inFlight = true
  local cmd = "ssh -o ConnectTimeout=6 -o BatchMode=yes -o StrictHostKeyChecking=accept-new "
    .. SSH_HOST .. " clockmost-status"
  noctalia.runAsync(cmd, adopt, 15000)
end

-- Noctalia's tick hook. Re-arm the interval every call or the loop dies.
function update()
  noctalia.setUpdateInterval(POLL_MS)
  poll()
end

function onClick()
  noctalia.runAsync("noctalia msg panel-open '" .. PANEL .. "'", function() end, 5000)
end

function onRightClick()
  noctalia.runAsync("xdg-open '" .. ARCANE_URL:gsub("'", "'\\''") .. "'", function() end, 5000)
end

function onMiddleClick()
  noctalia.runAsync("xdg-open '" .. PRS_URL:gsub("'", "'\\''") .. "'", function() end, 5000)
end

function onConfigChanged()
  loadCfg()
  noctalia.setUpdateInterval(POLL_MS)
  poll()
end

-- A panel refresh republishes the snapshot; reflect it on the glyph immediately.
if noctalia.state and noctalia.state.watch then
  noctalia.state.watch(STATE_KEY, function(raw)
    if type(raw) ~= "string" or raw == "" then return end
    local ok, d = pcall(function() return noctalia.json.decode(raw) end)
    if ok and type(d) == "table" and d.status then data, err = d, nil; render() end
  end)
end

noctalia.setUpdateInterval(POLL_MS)
render()
poll()
