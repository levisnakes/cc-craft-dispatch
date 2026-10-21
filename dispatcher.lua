-- Dispatcher: keeps the Factory Controller gauges stocked using crafty turtles (crafter.lua).
-- Every few seconds it reads the gauges (target and stock), and for every item that is short and
-- has a learned recipe it orders the ingredients for up to BATCH crafts from storage through the
-- Stock Ticker, straight to a free crafter's own address, and tells that crafter the recipe.
-- Set the gauges to Passive: the Dispatcher does the ordering.
--
-- Needs: a Stock Ticker and the Factory Controller on this computer's modem network, and the
-- crafters on the same network (they find each other over rednet).

BATCH = 64                     -- most crafts ordered for one crafter at a time
ORDER_TIMEOUT_MINUTES = 10     -- forget an order its crafter never finished after this long
MONITOR = nil                  -- nil = the biggest attached monitor, if any; the terminal shows the same
AUTO_UPDATE = true             -- install new versions from GitHub automatically, keeping these settings

for _, path in ipairs({ "/config.lua" }) do
  if fs.exists(path) then
    local fn, err = loadfile(path, "t", _ENV)
    if fn then
      local ok, runErr = pcall(fn)
      if not ok then printError(path .. ": " .. tostring(runErr)) sleep(3) end
    else
      printError(path .. ": " .. tostring(err))
      sleep(3)
    end
  end
end

-- ============================================================ basics

local VERSION = "1.0.0"
local PROTOCOL = "craft-dispatch"
local DIR = "/dispatch"
local function now() return os.epoch("utc") / 1000 end
local function short(name) return (tostring(name):gsub("^[^:]+:", ""):gsub("_", " ")) end

local function readFile(path, default)
  if not fs.exists(path) then return default end
  local f = fs.open(path, "r")
  local data = textutils.unserialize(f.readAll())
  f.close()
  if data == nil then return default end
  return data
end

local function writeFile(path, data)
  local f = fs.open(path .. ".tmp", "w")
  f.write(textutils.serialize(data))
  f.close()
  if fs.exists(path) then fs.delete(path) end
  fs.move(path .. ".tmp", path)
end

if not fs.exists(DIR) then fs.makeDir(DIR) end

local recipes = readFile(DIR .. "/recipes", {})  -- [output] = { grid = {9}, outCount, by, t }
local jobs = readFile(DIR .. "/jobs", {})         -- [id] = { id, station, out, crafts, outCount, t }
local nextJob = readFile(DIR .. "/next", 1)
local stations = {}                               -- [computer id] = { address, name, free, job, t, assigned }
local recent = {}                                 -- finished orders still on their way to storage
local items = {}                                  -- what the screen shows per gauge item
local function saveRecipes() writeFile(DIR .. "/recipes", recipes) end
local function saveJobs() writeFile(DIR .. "/jobs", jobs) writeFile(DIR .. "/next", nextJob) end

local logLines = {}
local function log(kind, text)
  table.insert(logLines, 1, { kind = kind, text = os.date("!%H:%M ") .. text })
  while #logLines > 60 do table.remove(logLines) end
  pcall(function()
    local f = fs.open(DIR .. "/log.txt", "a")
    f.writeLine(os.date("!%Y-%m-%d %H:%M:%S ") .. "[" .. kind .. "] " .. text)
    f.close()
    if fs.getSize(DIR .. "/log.txt") > 150000 then
      if fs.exists(DIR .. "/log.old") then fs.delete(DIR .. "/log.old") end
      fs.move(DIR .. "/log.txt", DIR .. "/log.old")
    end
  end)
end

local state = { problem = nil, paused = false }

-- ============================================================ peripherals

local ticker
local controllers = {}

local function findPeripherals()
  ticker = peripheral.find("Create_StockTicker")
  controllers = { peripheral.find("factory_controller") }
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.hasType(name, "modem") and not rednet.isOpen(name) then pcall(rednet.open, name) end
  end
end

local function setupProblem()
  if not ticker then return "No Stock Ticker on the network" end
  if #controllers == 0 then return "No Factory Controller on the network" end
  local anyModem = false
  for _, name in ipairs(peripheral.getNames()) do if peripheral.hasType(name, "modem") then anyModem = true end end
  if not anyModem then return "No modem: crafters can't be reached" end
  return nil
end

local function send(msg) pcall(rednet.broadcast, msg, PROTOCOL) end

-- ============================================================ reading

-- [item] = { target, stock, passive }
local function readGauges()
  local wanted = {}
  for _, fc in ipairs(controllers) do
    local ok, gauges = pcall(fc.getGauges)
    if ok and type(gauges) == "table" then
      for _, g in pairs(gauges) do
        if type(g) == "table" and g.item and g.item ~= "" and g.item ~= "minecraft:air" then
          local mult = (g.unit == "STACKS") and 64 or ((g.unit == "ITEMS" or g.unit == nil) and 1 or nil)
          if mult then
            local w = wanted[g.item] or { target = 0, stock = g.stock or 0, passive = true }
            w.target = math.max(w.target, (g.count or 0) * mult)
            w.stock = math.max(w.stock, g.stock or 0)
            if g.requestMode == "NORMAL" then w.passive = false end
            wanted[g.item] = w
          end
        end
      end
    end
  end
  return wanted
end

local function readStock()
  local counts = {}
  local ok, list = pcall(ticker.stock)
  if ok and type(list) == "table" then
    for _, it in pairs(list) do
      if type(it) == "table" and it.name then counts[it.name] = (counts[it.name] or 0) + (it.count or 0) end
    end
  end
  return counts
end

local function perCraft(grid)
  local need = {}
  for i = 1, 9 do if grid[i] then need[grid[i]] = (need[grid[i]] or 0) + 1 end end
  return need
end

local function freeStation()
  local best
  for id, s in pairs(stations) do
    if s.free and not s.assigned and now() - s.t < 8 and (not best or id < best) then best = id end
  end
  return best
end

-- ============================================================ ordering

local lastStock = {}  -- gauge stock per item, last read

-- Crafts running, plus finished results not yet showing in the gauge's stock.
local function inFlight(out)
  local n = 0
  for _, j in pairs(jobs) do if j.out == out then n = n + j.crafts * (j.outCount or 1) end end
  for _, r in ipairs(recent) do
    if r.out == out then
      local arrived = math.max(0, (lastStock[out] or 0) - (r.stockAt or 0))
      n = n + math.max(0, r.count - arrived)
    end
  end
  return n
end

local function order(out, crafts, station, stock)
  local r = recipes[out]
  local s = stations[station]
  local filters, total = {}, 0
  for name, per in pairs(perCraft(r.grid)) do
    table.insert(filters, { name = name, _requestCount = per * crafts })
    total = total + per * crafts
  end
  local ok, sent = pcall(ticker.requestFiltered, s.address, table.unpack(filters))
  if not ok or not sent or sent == 0 then
    log("error", "Stock Ticker couldn't send ingredients for " .. short(out) .. " to " .. s.address .. ": " .. tostring(sent))
    return false
  end
  for name, per in pairs(perCraft(r.grid)) do stock[name] = (stock[name] or 0) - per * crafts end
  local id = nextJob
  nextJob = nextJob + 1
  jobs[id] = { id = id, station = station, out = out, crafts = crafts, outCount = r.outCount or 1, t = now() }
  saveJobs()
  s.assigned, s.assignedAt = id, now()
  send({ kind = "job", to = station, job = id, grid = r.grid, crafts = crafts, out = out, outCount = r.outCount or 1 })
  log("info", "Order " .. id .. ": " .. crafts .. "x " .. short(out) .. " -> " .. s.name .. (sent < total and (" (only " .. sent .. "/" .. total .. " items sent)") or ""))
  return true
end

local function tick()
  -- forget stations we stopped hearing from, orders that took far too long, delivered results
  for id, j in pairs(jobs) do
    if now() - j.t > ORDER_TIMEOUT_MINUTES * 60 then
      log("warn", "Order " .. id .. " (" .. short(j.out) .. ") never finished; forgetting it")
      jobs[id] = nil
      saveJobs()
    end
  end
  for i = #recent, 1, -1 do if now() - recent[i].t > 60 then table.remove(recent, i) end end

  local wanted = readGauges()
  for out, w in pairs(wanted) do lastStock[out] = w.stock end
  local stock = readStock()
  items = {}
  local list = {}
  for out, w in pairs(wanted) do
    local r = recipes[out]
    local info = { out = out, target = w.target, stock = w.stock, passive = w.passive, flying = inFlight(out), recipe = r ~= nil }
    items[#items + 1] = info
    if r and not state.paused then table.insert(list, info) end
  end
  table.sort(items, function(a, b) return a.out < b.out end)
  -- biggest shortfall first
  table.sort(list, function(a, b) return (a.target - a.stock) / math.max(1, a.target) > (b.target - b.stock) / math.max(1, b.target) end)

  for _, info in ipairs(list) do
    local r = recipes[info.out]
    local deficit = info.target - info.stock - inFlight(info.out)
    info.state = deficit > 0 and "short" or "stocked"
    while deficit > 0 do
      local station = freeStation()
      if not station then info.state = "waiting for a free crafter" break end
      local crafts = math.min(BATCH, math.ceil(deficit / (r.outCount or 1)))
      local missing = {}
      for name, per in pairs(perCraft(r.grid)) do
        local can = math.floor((stock[name] or 0) / per)
        if can < crafts then crafts = can end
        if can <= 0 then table.insert(missing, short(name)) end
      end
      if crafts <= 0 then info.state = "missing " .. table.concat(missing, ", ") break end
      if not order(info.out, crafts, station, stock) then info.state = "order failed" break end
      deficit = deficit - crafts * (r.outCount or 1)
      info.state = "crafting"
    end
    info.flying = inFlight(info.out)
  end
end

-- ============================================================ messages

local function onMessage(from, msg)
  if type(msg) ~= "table" then return end
  if msg.kind == "station" then
    local s = stations[from] or {}
    s.address, s.name, s.t, s.version = msg.address, msg.name or ("Crafter " .. from), now(), msg.version
    s.free, s.job = msg.free, msg.job
    -- a job was just sent: wait until the crafter confirms it before trusting "free"
    if s.assigned and (msg.job == s.assigned or now() - (s.assignedAt or 0) > 10) then s.assigned = nil end
    if s.assigned then s.free = false end
    stations[from] = s
  elseif msg.kind == "done" or msg.kind == "failed" then
    local j = jobs[msg.job]
    if j then
      local made = (msg.crafted or 0) * (j.outCount or 1)
      if made > 0 then table.insert(recent, { out = j.out, count = made, t = now(), stockAt = lastStock[j.out] or 0 }) end
      jobs[msg.job] = nil
      saveJobs()
      if msg.kind == "failed" then
        log("warn", "Order " .. msg.job .. " (" .. short(j.out) .. "): " .. tostring(msg.reason) .. ", " .. made .. " made")
      else
        log("craft", "Order " .. msg.job .. " done: " .. made .. "x " .. short(j.out))
      end
    end
    if stations[from] then stations[from].assigned = nil end
  elseif msg.kind == "learn" and type(msg.grid) == "table" and msg.out then
    recipes[msg.out] = { grid = msg.grid, outCount = msg.outCount or 1, by = from, t = now() }
    saveRecipes()
    log("craft", "Learned " .. short(msg.out) .. " (" .. (msg.outCount or 1) .. " per craft) from " .. tostring(stations[from] and stations[from].name or from))
    send({ kind = "learned", by = from, out = msg.out })
  end
end

-- ============================================================ loops

local function eventLoop()
  while true do
    local e = { os.pullEvent() }
    if e[1] == "rednet_message" and e[4] == PROTOCOL then
      pcall(onMessage, e[2], e[3])
    elseif e[1] == "peripheral" or e[1] == "peripheral_detach" then
      findPeripherals()
    end
  end
end

local function mainLoop()
  while true do
    state.problem = setupProblem()
    send({ kind = "dispatcher" })
    if not state.problem then
      local ok, err = pcall(tick)
      if not ok then log("error", "Error: " .. tostring(err)) end
    end
    sleep(2)
  end
end

-- ============================================================ screen

local page = "items"
local buttons = {}
local scroll = 0

local function fit(s, w)
  s = tostring(s)
  if #s > w then return s:sub(1, math.max(1, w - 1)) .. "." end
  return s
end

local function drawOn(t)
  local w, h = t.getSize()
  local function put(x, y, s, fg, bg)
    t.setCursorPos(x, y)
    if bg then t.setBackgroundColor(bg) end
    if fg then t.setTextColor(fg) end
    t.write(s)
  end
  local function button(x, y, label, fg, bg, action)
    put(x, y, label, fg, bg)
    if t == term then table.insert(buttons, { x1 = x, x2 = x + #label - 1, y = y, action = action }) end
  end
  t.setBackgroundColor(colors.black)
  t.clear()
  put(1, 1, string.rep(" ", w), colors.white, colors.blue)
  put(2, 1, fit("CRAFT DISPATCHER", w - 8), colors.white, colors.blue)
  put(w - #VERSION, 1, VERSION, colors.lightBlue, colors.blue)
  put(1, 2, string.rep(" ", w), colors.white, colors.gray)
  local x = 1
  for _, tab in ipairs({ { "items", "Items" }, { "crafters", "Crafters" }, { "recipes", "Recipes" }, { "log", "Log" } }) do
    local on = page == tab[1]
    local label = " " .. tab[2] .. " "
    button(x, 2, label, on and colors.black or colors.white, on and colors.white or colors.gray, function() page, scroll = tab[1], 0 end)
    x = x + #label
  end
  t.setBackgroundColor(colors.black)
  local y = 3
  if state.problem then put(2, y, fit(state.problem, w - 2), colors.red) y = y + 1 end
  local rows = {}
  if page == "items" then
    for _, i in ipairs(items) do
      local c = not i.recipe and colors.gray or i.state == "stocked" and colors.lime
        or (i.state or ""):find("missing") and colors.orange or colors.yellow
      local txt = fit(short(i.out), 16) .. string.rep(" ", math.max(1, 17 - #fit(short(i.out), 16)))
        .. i.stock .. "/" .. i.target .. (i.flying > 0 and (" +" .. i.flying) or "")
      local note = not i.recipe and "no recipe: teach a crafter" or (not i.passive and "gauge not Passive!") or i.state or ""
      rows[#rows + 1] = { txt .. "  " .. note, c }
    end
    if #items == 0 then rows[1] = { "No gauges found on the Factory Controller", colors.gray } end
  elseif page == "crafters" then
    for id, s in pairs(stations) do
      local alive = now() - s.t < 8
      local what = not alive and "offline" or s.job and ("order " .. s.job) or s.free and "free" or "busy"
      rows[#rows + 1] = { fit(s.name, 14) .. " " .. fit(s.address or "?", 18) .. " " .. what, alive and (s.free and colors.lime or colors.yellow) or colors.red }
    end
    if #rows == 0 then rows[1] = { "No crafters heard yet (modem network?)", colors.gray } end
  elseif page == "recipes" then
    local names = {}
    for out in pairs(recipes) do names[#names + 1] = out end
    table.sort(names)
    for _, out in ipairs(names) do
      rows[#rows + 1] = { (recipes[out].outCount or 1) .. "x " .. short(out), colors.white, out }
    end
    if #rows == 0 then rows[1] = { "None yet: on a crafter, put a recipe in its grid, press L", colors.gray } end
  else
    for _, l in ipairs(logLines) do
      rows[#rows + 1] = { l.text, l.kind == "error" and colors.red or l.kind == "warn" and colors.orange or l.kind == "craft" and colors.lime or colors.lightGray }
    end
  end
  local visible = h - y - 1
  scroll = math.max(0, math.min(scroll, #rows - visible))
  for i = 1 + scroll, math.min(#rows, scroll + visible) do
    put(2, y, fit(rows[i][1], w - (rows[i][3] and 10 or 2)), rows[i][2])
    if rows[i][3] and t == term then
      local out = rows[i][3]
      button(w - 7, y, " Forget ", colors.white, colors.red, function()
        recipes[out] = nil
        saveRecipes()
        log("info", "Forgot the recipe for " .. short(out))
      end)
    end
    y = y + 1
  end
  put(1, h, string.rep(" ", w), colors.white, colors.gray)
  button(1, h, state.paused and " Resume " or " Pause ", colors.white, state.paused and colors.orange or colors.gray, function()
    state.paused = not state.paused
    log("info", state.paused and "Paused: no new orders" or "Resumed")
  end)
  local jobsN = 0
  for _ in pairs(jobs) do jobsN = jobsN + 1 end
  put(11, h, fit(jobsN .. " orders running", w - 11), colors.white, colors.gray)
  t.setBackgroundColor(colors.black)
end

local function uiLoop()
  local timer = os.startTimer(0)
  while true do
    local e = { os.pullEvent() }
    if e[1] == "timer" and e[2] == timer then
      buttons = {}
      drawOn(term)
      local mon = MONITOR and peripheral.wrap(MONITOR) or peripheral.find("monitor")
      if mon then pcall(function() mon.setTextScale(0.5) drawOn(mon) end) end
      timer = os.startTimer(1)
    elseif e[1] == "mouse_click" then
      for _, b in ipairs(buttons) do
        if e[4] == b.y and e[3] >= b.x1 and e[3] <= b.x2 then b.action() break end
      end
      buttons = {}
      drawOn(term)
    elseif e[1] == "mouse_scroll" then
      scroll = scroll + e[2]
    elseif e[1] == "key" then
      if e[2] == keys.one then page = "items"
      elseif e[2] == keys.two then page = "crafters"
      elseif e[2] == keys.three then page = "recipes"
      elseif e[2] == keys.four then page = "log"
      elseif e[2] == keys.p then state.paused = not state.paused end
    end
  end
end

-- ============================================================ start

findPeripherals()
log("info", "Started Dispatcher v" .. VERSION)

local function readyToUpdate()
  return true
end

-- ============================================================ auto-update

-- Every UPDATE_CHECK_MINUTES this checks GitHub for a newer version. A new
-- version is downloaded, checked that it loads, given your current settings
-- (the UPPERCASE lines at the top of this file), saved, and the computer
-- reboots into it. Set AUTO_UPDATE = false at the top to turn this off.
local UPDATE_REPO = "levisnakes/cc-craft-dispatch"
local UPDATE_FILE = "dispatcher.lua"
local UPDATE_CHECK_MINUTES = 15
local PROGRAM_PATH = (shell and shell.getRunningProgram()) or "startup.lua"
local SHA_FILE = "/.version_" .. UPDATE_FILE

-- Settings are the top-of-file assignments to UPPERCASE names, before the
-- first "local" line or "-- ====" section. Tables can span several lines.
local function splitSettings(src)
  local settings, rest = {}, {}
  local inSettings = true
  for line in (src .. "\n"):gmatch("(.-)\n") do
    if inSettings and (line:match("^local ") or line:match("^%-%- ====")) then inSettings = false end
    table.insert(inSettings and settings or rest, line)
  end
  return settings, rest
end

local function braceDelta(line)
  local code = line:gsub('"[^"]*"', ""):gsub("%-%-.*$", "")
  local _, opens = code:gsub("{", "")
  local _, closes = code:gsub("}", "")
  return opens - closes
end

-- [NAME] = the full statement text, possibly several lines
local function statements(lines)
  local out = {}
  local i = 1
  while i <= #lines do
    local name = lines[i]:match("^([%u_][%u%d_]*)%s*=")
    if name then
      local block = { lines[i] }
      local depth = braceDelta(lines[i])
      while depth > 0 and i < #lines do
        i = i + 1
        table.insert(block, lines[i])
        depth = depth + braceDelta(lines[i])
      end
      out[name] = table.concat(block, "\n")
    end
    i = i + 1
  end
  return out
end

-- New file, with each setting that already exists replaced by your value.
local function mergeSettings(oldSrc, newSrc)
  local oldSettings = statements((splitSettings(oldSrc)))
  local newSettings, rest = splitSettings(newSrc)
  local out = {}
  local i = 1
  while i <= #newSettings do
    local line = newSettings[i]
    local name = line:match("^([%u_][%u%d_]*)%s*=")
    if name and oldSettings[name] then
      table.insert(out, oldSettings[name])
      local depth = braceDelta(line)
      while depth > 0 and i < #newSettings do
        i = i + 1
        depth = depth + braceDelta(newSettings[i])
      end
    else
      table.insert(out, line)
    end
    i = i + 1
  end
  for _, line in ipairs(rest) do table.insert(out, line) end
  local merged = table.concat(out, "\n")
  -- splitting added one trailing newline's worth of empty line; match the source
  if newSrc:sub(-1) == "\n" and merged:sub(-1) ~= "\n" then merged = merged .. "\n" end
  return (merged:gsub("\n\n$", "\n"))
end

local function fetch(url, headers)
  local ok, h = pcall(http.get, url, headers)
  if not ok or not h then return nil end
  local body = h.readAll()
  h.close()
  return body
end

local function readText(path)
  if not fs.exists(path) then return nil end
  local f = fs.open(path, "r")
  local t = f.readAll()
  f.close()
  return t
end

local function writeText(path, text)
  local f = fs.open(path, "w")
  f.write(text)
  f.close()
end

local function checkForUpdate(atBoot)
  if AUTO_UPDATE == false or not http then return end
  local sha = fetch("https://api.github.com/repos/" .. UPDATE_REPO .. "/commits/main",
    { ["Accept"] = "application/vnd.github.sha", ["User-Agent"] = "cc-auto-update" })
  if not sha then return end
  sha = sha:match("^%s*(%x+)%s*$")
  if not sha or #sha < 40 or readText(SHA_FILE) == sha then return end

  local newSrc = fetch("https://raw.githubusercontent.com/" .. UPDATE_REPO .. "/" .. sha .. "/" .. UPDATE_FILE)
  if not newSrc or not load(newSrc, UPDATE_FILE) then return end
  local oldSrc = readText(PROGRAM_PATH)
  if not oldSrc then return end
  local merged = mergeSettings(oldSrc, newSrc)
  if not load(merged, UPDATE_FILE) then return end
  if merged == oldSrc then
    writeText(SHA_FILE, sha)
    return
  end

  -- at boot nothing is running yet, so there is nothing to wait for
  while not atBoot and not readyToUpdate() do sleep(5) end
  writeText(PROGRAM_PATH .. ".old", oldSrc)
  writeText(PROGRAM_PATH, merged)
  writeText(SHA_FILE, sha)
  term.setBackgroundColor(colors.black)
  term.clear()
  term.setCursorPos(1, 1)
  print("Updated to " .. sha:sub(1, 7) .. ", restarting...")
  if not atBoot then sleep(1) end
  os.reboot()
end

local function updateLoop()
  while true do
    sleep(UPDATE_CHECK_MINUTES * 60)
    pcall(checkForUpdate)
  end
end

-- Check for a new version as soon as the computer starts, before the
-- program runs, so a restart always picks up the latest version.
local function bootUpdate()
  if AUTO_UPDATE == false or not http then return end
  term.setBackgroundColor(colors.black)
  term.clear()
  term.setCursorPos(1, 1)
  print("Checking for updates...")
  pcall(checkForUpdate, true)
end

bootUpdate()
parallel.waitForAny(eventLoop, mainLoop, uiLoop, updateLoop)
