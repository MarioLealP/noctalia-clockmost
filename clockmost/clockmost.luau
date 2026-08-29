--!nonstrict
-- clockmost — home-server status on the Noctalia bar.
--
-- Data comes from one call: `ssh <ssh_host> clockmost-status`, which prints a
-- JSON snapshot (deploy state, container health, failed units, disk, pending
-- Renovate PRs, Zabbix problems). The server script keeps all the tokens; the
-- desktop just needs its existing passwordless SSH to `clockmost-claude`.

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

local data = nil     -- last decoded snapshot
local err  = nil     -- last error string

local GLYPH = { ok = "server", warn = "alert-triangle", crit = "alert-octagon" }
local COLOR = { ok = "primary", warn = "warning", crit = "error" }
local SEV   = { [1] = "Info", [2] = "Warning", [3] = "Average", [4] = "High", [5] = "Disaster" }

local function plural(n) return (n == 1) and "" or "s" end

local function summary(d)
  local L = { "clockmost — " .. tostring(d.status):upper() }
  local u, a, c = d.updates or {}, d.alerts or {}, d.containers or {}

  if (u.n or 0) > 0 then
    L[#L + 1] = ""
    L[#L + 1] = u.n .. " update" .. plural(u.n) .. " to review:"
    for _, p in ipairs(u.list or {}) do L[#L + 1] = "  #" .. p.n .. "  " .. p.t end
  end
  if (a.n or 0) > 0 then
    L[#L + 1] = ""
    L[#L + 1] = a.n .. " alert" .. plural(a.n) .. ":"
    for _, x in ipairs(a.list or {}) do L[#L + 1] = "  [" .. (SEV[x.s] or ("sev" .. x.s)) .. "] " .. x.n end
  end
  if c.down and #c.down > 0 then
    L[#L + 1] = ""
    L[#L + 1] = "DOWN: " .. table.concat(c.down, ", ")
  end
  if c.unhealthy and #c.unhealthy > 0 then
    L[#L + 1] = "UNHEALTHY: " .. table.concat(c.unhealthy, ", ")
  end
  if d.units_failed and #d.units_failed > 0 then
    L[#L + 1] = "failed units: " .. table.concat(d.units_failed, ", ")
  end
  if d.deploy then
    L[#L + 1] = ""
    L[#L + 1] = "deploy: " .. tostring(d.deploy.last or "?")
    L[#L + 1] = "        @ " .. tostring(d.deploy.commit or "?")
    if (d.deploy.rollback_recent or 0) > 0 then L[#L + 1] = "        (!) rollback in recent log" end
  end
  L[#L + 1] = ""
  L[#L + 1] = string.format("containers %d/%d  ·  / %d%%  ·  /home %d%%",
    (c.up or 0), (c.total or 0), (d.disk and d.disk.root or 0), (d.disk and d.disk.home or 0))
  return table.concat(L, "\n")
end

local function render()
  if err then
    barWidget.setGlyph("cloud-off")
    barWidget.setGlyphColor("on_surface_variant")
    barWidget.setText("")
    barWidget.setTooltip("clockmost: " .. err)
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
  barWidget.setGlyph(GLYPH[d.status] or "server")
  barWidget.setGlyphColor(COLOR[d.status] or "on_surface_variant")
  local n = (d.updates and d.updates.n or 0) + (d.alerts and d.alerts.n or 0)
  barWidget.setText((SHOW_COUNT and n > 0) and tostring(n) or "")
  barWidget.setTooltip(summary(d))
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
    else
      err = "bad JSON from clockmost-status"
    end
    render()
  end, 15000)
end

function onUpdate() poll() end

function onClick()
  if data then noctalia.notify("clockmost", summary(data)) end
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
