--!nonstrict
-- clockmost — home-server status on the Noctalia bar.
--
-- One call per refresh: `ssh <ssh_host> clockmost-status` -> a JSON snapshot
-- (deploy state, container health, failed units, disk, pending Renovate PRs,
-- Zabbix problems). The server script holds every token; the desktop only needs
-- its existing passwordless SSH to `clockmost-claude`.
--
-- The glyph is the glance; left-click opens the detail panel (main.luau), which
-- reads the same snapshot from shared state.

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
  SHOW_COUNT = cfg("show_count", true) == true
  ARCANE_URL = tostring(cfg("arcane_url", "https://arcane.clockmost.com"))
  PRS_URL    = tostring(cfg("prs_url", "https://git.clockmost.com/Benylin/clockmost-infra/pulls"))
end
loadCfg()

local data = nil
local err  = nil

local GLYPH = { ok = "server", warn = "alert-triangle", crit = "alert-octagon" }
local COLOR = { ok = "primary", warn = "warning", crit = "error" }

local function render()
  if err then
    barWidget.setGlyph("cloud-off")
    barWidget.setGlyphColor("on_surface_variant")
    barWidget.setText("")
    barWidget.setTooltip("clockmost: " .. err .. "  (left-click for panel)")
    return
  end
  if not data then
    barWidget.setGlyph("server")
    barWidget.setGlyphColor("on_surface_variant")
    barWidget.setText("")
    barWidget.setTooltip("clockmost: loading…")
    return
  end
  local d = data
  local nUp = (d.updates and d.updates.n) or 0
  local nAl = (d.alerts and d.alerts.n) or 0
  barWidget.setGlyph(GLYPH[d.status] or "server")
  barWidget.setGlyphColor(COLOR[d.status] or "on_surface_variant")
  barWidget.setText((SHOW_COUNT and (nUp + nAl) > 0) and tostring(nUp + nAl) or "")
  local c = d.containers or {}
  barWidget.setTooltip(string.format(
    "clockmost — %s\n%d update%s · %d alert%s · %d/%d containers · left-click for detail",
    tostring(d.status):upper(),
    nUp, (nUp == 1 and "" or "s"),
    nAl, (nAl == 1 and "" or "s"),
    (c.up or 0), (c.total or 0)))
end

local function poll()
  local cmd = "ssh -o ConnectTimeout=6 -o BatchMode=yes -o StrictHostKeyChecking=accept-new "
    .. SSH_HOST .. " clockmost-status"
  noctalia.runAsync(cmd, function(res)
    if not res or res.timedOut then
      err, data = "ssh timed out", nil
      render(); return
    end
    if (res.exitCode or 1) ~= 0 or not res.stdout or res.stdout == "" then
      err, data = "ssh exit " .. tostring(res.exitCode), nil
      render(); return
    end
    local ok, d = pcall(function() return noctalia.json.decode(res.stdout) end)
    if ok and type(d) == "table" and d.status then
      data, err = d, nil
      if noctalia.state and noctalia.state.set then
        noctalia.state.set(STATE_KEY, res.stdout)
      end
    else
      err = "bad JSON from clockmost-status"
    end
    render()
  end, 15000)
end

function onUpdate() poll() end

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

noctalia.setUpdateInterval(POLL_MS)
render()
poll()
