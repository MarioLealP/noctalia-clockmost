--!nonstrict
-- clockmost — the detail panel. Opened by a left-click on the bar widget.
--
-- Reads the shared snapshot the widget stores (state key "clockmost.snapshot"),
-- and also re-polls `ssh <host> clockmost-status` itself on open / refresh so
-- the panel is never stale. Actions shell out over the same SSH:
--   * open a PR / Arcane / the PR list  -> xdg-open
--   * "Deploy now"  -> sudo systemctl start clockmost-deploy.service

local STATE_KEY = "clockmost.snapshot"
local WRAP = 400
local PAD  = 14

local function cfg(k, d)
  local v = noctalia.getConfig(k)
  if v == nil then return d end
  return v
end

local SSH_HOST   = tostring(cfg("ssh_host", "clockmost-claude"))
local ARCANE_URL = tostring(cfg("arcane_url", "https://arcane.clockmost.com"))
local PRS_URL    = tostring(cfg("prs_url", "https://git.clockmost.com/Benylin/clockmost-infra/pulls"))

local SEV        = { [1] = "Info", [2] = "Warning", [3] = "Average", [4] = "High", [5] = "Disaster" }
local STATUS_GLY = { ok = "circle-check", warn = "alert-triangle", crit = "alert-octagon" }
local STATUS_COL = { ok = "primary", warn = "warning", crit = "error" }

local data = nil       -- decoded snapshot
local note = nil       -- transient status line (e.g. "deploy triggered")
local busy = false

-- ------------------------------------------------------------------ helpers ---
local function sh(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
local function openUrl(u) noctalia.runAsync("xdg-open " .. sh(u), function() end, 5000) end

local function decode(str)
  local ok, d = pcall(function() return noctalia.json.decode(str) end)
  if ok and type(d) == "table" and d.status then return d end
  return nil
end

local render  -- fwd

local function repoll()
  busy = true; if render then render() end
  local cmd = "ssh -o ConnectTimeout=6 -o BatchMode=yes " .. SSH_HOST .. " clockmost-status"
  noctalia.runAsync(cmd, function(res)
    busy = false
    if res and not res.timedOut and (res.exitCode or 1) == 0 and res.stdout and res.stdout ~= "" then
      local d = decode(res.stdout)
      if d then
        data = d
        if noctalia.state and noctalia.state.set then noctalia.state.set(STATE_KEY, res.stdout) end
      end
    end
    if render then render() end
  end, 15000)
end

function onDeploy()
  if busy then return end
  busy = true; note = "deploy triggered…"; if render then render() end
  noctalia.runAsync(
    "ssh -o ConnectTimeout=6 -o BatchMode=yes " .. SSH_HOST
      .. " sudo -n systemctl start clockmost-deploy.service",
    function(res)
      busy = false
      note = ((res and (res.exitCode or 1) == 0) and "deploy started — refreshing in a moment"
        or "deploy failed to start")
      if render then render() end
      noctalia.runAsync("sleep 12", function() repoll() end, 20000)
    end, 30000)
end

function onRefresh()   if not busy then repoll() end end
function onArcane()     openUrl(ARCANE_URL) end
function onPRs()        openUrl(PRS_URL) end
function onClosePanel() noctalia.runAsync("noctalia msg panel-close 'benylin/clockmost:main'", function() end, 3000) end

-- --------------------------------------------------------------------- view ---
local function sectionTitle(t)
  return ui.label({ text = t, fontWeight = "bold", color = "primary" })
end

local function body()
  if not data then
    return ui.column({ gap = 8 }, {
      ui.label({ text = busy and "loading…" or "no data — press Refresh", opacity = 0.7 }),
    })
  end
  local d = data
  local rows = {}
  local function add(x) rows[#rows + 1] = x end
  local function sep() if #rows > 0 then add(ui.separator({})) end end

  -- updates
  local u = d.updates or {}
  if (u.n or 0) > 0 then
    add(sectionTitle(u.n .. " update" .. (u.n == 1 and "" or "s") .. " to review"))
    for _, p in ipairs(u.list or {}) do
      local n = p.n
      add(ui.row({ gap = 8, align = "center" }, {
        ui.label({ text = "#" .. n .. "  " .. p.t, maxWidth = WRAP - 60, maxLines = 2, flexGrow = 1 }),
        ui.button({ glyph = "external-link", variant = "secondary",
          onClick = function() openUrl(PRS_URL .. "/" .. tostring(n)) end }),
      }))
    end
  end

  -- alerts
  local a = d.alerts or {}
  if (a.n or 0) > 0 then
    sep()
    add(sectionTitle(a.n .. " alert" .. (a.n == 1 and "" or "s")))
    for _, x in ipairs(a.list or {}) do
      add(ui.label({
        text = "[" .. (SEV[x.s] or ("sev" .. x.s)) .. "]  " .. x.n,
        color = (x.s and x.s >= 4) and "error" or nil,
        maxWidth = WRAP, maxLines = 2,
      }))
    end
  end

  -- container / unit trouble
  local c = d.containers or {}
  local trouble = {}
  for _, x in ipairs(c.down or {}) do trouble[#trouble + 1] = x .. " (down)" end
  for _, x in ipairs(c.unhealthy or {}) do trouble[#trouble + 1] = x .. " (unhealthy)" end
  for _, x in ipairs(d.units_failed or {}) do trouble[#trouble + 1] = x .. " (unit failed)" end
  if #trouble > 0 then
    sep()
    add(sectionTitle("Trouble"))
    for _, x in ipairs(trouble) do add(ui.label({ text = x, color = "error", maxWidth = WRAP })) end
  end

  -- deploy
  if d.deploy then
    sep()
    add(sectionTitle("Deploy"))
    add(ui.label({ text = tostring(d.deploy.last or "?"), maxWidth = WRAP, maxLines = 2 }))
    add(ui.label({ text = tostring(d.deploy.commit or "?"), opacity = 0.65, maxWidth = WRAP, maxLines = 2 }))
    if (d.deploy.rollback_recent or 0) > 0 then
      add(ui.label({ text = "(!) a rollback appears in the recent deploy log", color = "error" }))
    end
  end

  -- footer stats
  sep()
  add(ui.label({
    text = string.format("containers %d/%d   ·   / %d%%   ·   /home %d%%",
      (c.up or 0), (c.total or 0),
      (d.disk and d.disk.root or 0), (d.disk and d.disk.home or 0)),
    opacity = 0.8,
  }))
  if d.status == "ok" and (u.n or 0) == 0 and (a.n or 0) == 0 then
    add(ui.label({ text = "All clear.", color = "primary" }))
  end

  return ui.column({ gap = 6 }, rows)
end

render = function()
  local d = data
  local statusWord = d and tostring(d.status):upper() or "…"
  local header = ui.row({ gap = 8, align = "center" }, {
    ui.glyph({ name = d and (STATUS_GLY[d.status] or "server") or "server", size = 20,
      color = d and (STATUS_COL[d.status] or "on_surface_variant") or "on_surface_variant" }),
    ui.label({ text = "clockmost", fontSize = 16, fontWeight = "bold", color = "primary" }),
    ui.label({ text = statusWord, color = d and (STATUS_COL[d.status] or "on_surface_variant") or "on_surface_variant",
      flexGrow = 1 }),
    ui.button({ glyph = busy and "loader" or "refresh", variant = "secondary", onClick = "onRefresh" }),
    ui.button({ glyph = "close", variant = "secondary", onClick = "onClosePanel" }),
  })

  local footer = ui.row({ gap = 8, align = "center" }, {
    ui.button({ text = "Deploy now", glyph = "rocket", onClick = "onDeploy" }),
    ui.button({ text = "Arcane", glyph = "layout-dashboard", variant = "secondary", onClick = "onArcane" }),
    ui.button({ text = "PRs", glyph = "git-pull-request", variant = "secondary", onClick = "onPRs" }),
  })

  local kids = { header, ui.separator({}), ui.scroll({ flexGrow = 1 }, { body() }) }
  if note then
    kids[#kids + 1] = ui.label({ text = note, opacity = 0.8 })
  end
  kids[#kids + 1] = ui.separator({})
  kids[#kids + 1] = footer

  panel.render(ui.column({ padding = PAD, gap = 8, flexGrow = 1 }, kids))
end

function onOpen(_context)
  panel.setWantsSecondTicks(false)
  note = nil
  local raw = noctalia.state.get and noctalia.state.get(STATE_KEY)
  if type(raw) == "string" and raw ~= "" then data = decode(raw) end
  render()
  repoll()
end

function update() end
