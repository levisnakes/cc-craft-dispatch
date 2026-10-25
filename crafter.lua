-- Crafter: a crafty turtle that crafts what the Dispatcher orders for it.
-- The Dispatcher reads the Factory Controller gauges, orders the ingredients for up to 64 crafts
-- from storage straight to this turtle's own address, and tells it the recipe over the modem
-- network. The turtle crafts once everything is in, sends the result to storage, and is free again.
-- Teach a recipe: put it in the turtle's 3x3 grid (slots 1-3, 5-7, 9-11) and press L.
--
-- One crafter: Crafty Turtle with its input Frogport on its front (standing on the input Packager,
-- which is attached to the Barrel under the turtle), an output Packager on its back (with its own
-- Frogport), and a wired modem connecting it to the Dispatcher.

OUT_ADDRESS = "MB-Storage-In"  -- where finished items and leftovers are sent
ADDRESS = nil                  -- this turtle's own address; nil = "MB-Crafter-<turtle id>"
INPUT_SIDE = "front"           -- the input Frogport (the turtle sets its address)
OUTPUT_SIDE = "back"           -- the output Packager
WAIT_MINUTES = 3               -- craft what has arrived if an order is still incomplete after this long
NOTHING_SECONDS = 60           -- give an order back if none of its ingredients arrived at all by then
STATION_NAME = nil             -- nil = the turtle's label, or "Crafter <id>"
AUTO_UPDATE = true             -- install new versions from GitHub automatically, keeping these settings

-- Settings in /config.lua override the ones above (one file can be shared by every computer);
-- /station.lua is this turtle's own settings and is loaded after it.
for _, path in ipairs({ "/config.lua", "/station.lua" }) do
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

local VERSION = "1.0.1"
local PROTOCOL = "craft-dispatch"
local DIR = "/crafter"
local GRID = { 1, 2, 3, 5, 6, 7, 9, 10, 11 }
local IS_GRID = {}  -- [turtle slot] = position 1..9 in the recipe
for k, s in ipairs(GRID) do IS_GRID[s] = k end
local SPARE = { 4, 8, 12, 13, 14, 15, 16 }
local MY_ID = os.getComputerID()
local MY_ADDRESS = ADDRESS or ("MB-Crafter-" .. MY_ID)

local function now() return os.epoch("utc") / 1000 end
local function stationName() return STATION_NAME or os.getComputerLabel() or ("Crafter " .. MY_ID) end
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

local job = readFile(DIR .. "/job", nil)  -- { id, grid = {9}, crafts, done, out, outCount, t }
local stats = readFile(DIR .. "/stats", { total = 0, day = "", today = 0 })
local function saveJob() if job then writeFile(DIR .. "/job", job) elseif fs.exists(DIR .. "/job") then fs.delete(DIR .. "/job") end end

local logLines = {}
local LOG_PATH = DIR .. "/log.txt"
local function writeLogLine(text)
  pcall(function()
    if fs.exists(LOG_PATH) and fs.getSize(LOG_PATH) > 150000 then
      if fs.exists(LOG_PATH .. ".old") then fs.delete(LOG_PATH .. ".old") end
      fs.move(LOG_PATH, LOG_PATH .. ".old")
    end
    local f = fs.open(LOG_PATH, "a")
    f.writeLine(os.date("!%H:%M:%S") .. string.format(".%03d ", os.epoch("utc") % 1000) .. text)
    f.close()
  end)
end
local function log(kind, text)
  table.insert(logLines, 1, { kind = kind, text = text })
  while #logLines > 40 do table.remove(logLines) end
  writeLogLine("[" .. kind .. "] " .. text)
end
local function dbg(text) writeLogLine("  " .. text) end

local function fmtCounts(counts)
  local parts = {}
  for name, n in pairs(counts or {}) do parts[#parts + 1] = n .. " " .. short(name) end
  table.sort(parts)
  return #parts > 0 and table.concat(parts, ", ") or "nothing"
end

local state = { status = "Starting", problem = nil, paused = false, lastBeat = 0, dispatcherAt = 0, sendAll = false, learn = false }

-- ============================================================ peripherals

local inputFrogport, outputPackager, buffer, bufferSide

local function findPeripherals()
  inputFrogport, outputPackager, buffer, bufferSide = nil, nil, nil, nil
  for _, side in ipairs({ "front", INPUT_SIDE }) do
    if not inputFrogport and peripheral.hasType(side, "Create_Frogport") then inputFrogport = peripheral.wrap(side) end
  end
  if peripheral.hasType(OUTPUT_SIDE, "Create_Packager") then outputPackager = peripheral.wrap(OUTPUT_SIDE) end
  for _, side in ipairs({ "bottom", "top" }) do
    if not buffer and peripheral.hasType(side, "inventory") and not peripheral.hasType(side, "Create_Packager") then
      buffer, bufferSide = peripheral.wrap(side), side
    end
  end
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.hasType(name, "modem") and not rednet.isOpen(name) then pcall(rednet.open, name) end
  end
end

-- The input Frogport carries this turtle's own address, so the Dispatcher can send to it.
local function claimAddress()
  if not inputFrogport then return end
  local ok, current = pcall(inputFrogport.getAddress)
  if ok and current ~= MY_ADDRESS then
    if pcall(inputFrogport.setAddress, MY_ADDRESS) then log("info", "Frogport address set to " .. MY_ADDRESS) end
  end
end

local function setupProblem()
  if not turtle then return "This program needs a turtle" end
  if not turtle.craft then return "No crafting table: use a Crafty Turtle" end
  if not outputPackager then return "No output Packager on the turtle's " .. OUTPUT_SIDE end
  if not buffer then return "No Barrel under the turtle" end
  return nil
end

-- ============================================================ inventory

local function bufferCounts()
  local counts = {}
  local ok, list = pcall(buffer.list)
  if ok and list then for _, it in pairs(list) do counts[it.name] = (counts[it.name] or 0) + it.count end end
  return counts
end

local function turtleCounts()
  local counts = {}
  for i = 1, 16 do
    local d = turtle.getItemDetail(i)
    if d then counts[d.name] = (counts[d.name] or 0) + d.count end
  end
  return counts
end

local function turtleEmpty()
  for i = 1, 16 do if turtle.getItemCount(i) > 0 then return false end end
  return true
end

local function bufferEmpty()
  local ok, list = pcall(buffer.list)
  return not ok or not list or next(list) == nil
end

local function dropToBuffer(count)
  if bufferSide == "top" then return turtle.dropUp(count) end
  return turtle.dropDown(count)
end

local function suckFromBuffer(count)
  if bufferSide == "top" then return turtle.suckUp(count) end
  return turtle.suckDown(count)
end

local function parkAll()
  local ok = true
  for i = 1, 16 do
    if turtle.getItemCount(i) > 0 then
      turtle.select(i)
      if not dropToBuffer() then ok = false end
    end
  end
  turtle.select(1)
  return ok
end

local maxStackCache = {}
local function maxStack(name)
  if maxStackCache[name] then return maxStackCache[name] end
  local ok, list = pcall(buffer.list)
  if ok and list then
    for slot, it in pairs(list) do
      if it.name == name then
        local okD, d = pcall(buffer.getItemDetail, slot)
        if okD and d and d.maxCount then maxStackCache[name] = d.maxCount return d.maxCount end
      end
    end
  end
  return 64
end

-- Pull `count` of `name` from the barrel into turtle slot `target`. A suck takes the first filled
-- barrel slot, so each one lands in a spare slot first; the wanted item moves on to `target`.
local function fetch(name, count, target)
  local got = 0
  for _ = 1, 12 do
    if got >= count then break end
    local ok, list = pcall(buffer.list)
    if not ok or not list then break end
    local from
    for slot, it in pairs(list) do
      if it.name == name and (not from or slot < from) then from = slot end
    end
    if not from then break end
    if from ~= 1 then
      if list[1] then
        local empty
        for s = buffer.size(), 2, -1 do if not list[s] then empty = s break end end
        if empty then pcall(buffer.pushItems, bufferSide, 1, 64, empty) end
      end
      pcall(buffer.pushItems, bufferSide, from, 64, 1)
    end
    local spare
    for _, s in ipairs(SPARE) do if turtle.getItemCount(s) == 0 then spare = s break end end
    if not spare then break end
    turtle.select(spare)
    if not suckFromBuffer(64) then break end
    local d = turtle.getItemDetail(spare)
    if d and d.name == name then
      local before = turtle.getItemCount(target)
      turtle.transferTo(target, count - got)
      local moved = turtle.getItemCount(target) - before
      got = got + moved
      if turtle.getItemCount(spare) > 0 then dropToBuffer() end
      if moved <= 0 then break end
    end
  end
  return got
end

-- Package everything in the turtle and send it to OUT_ADDRESS.
local function sendTurtle()
  pcall(outputPackager.setAddress, OUT_ADDRESS)
  for _ = 1, 40 do
    if turtleEmpty() then return true end
    local ok, made = pcall(outputPackager.makePackage)
    if not (ok and made) then sleep(0.5) end
  end
  log("error", "Couldn't send items to " .. OUT_ADDRESS .. " (output Packager or its Frogport stuck)")
  return false
end

-- Send everything in the turtle and the barrel to OUT_ADDRESS.
local function sendAllHome()
  if not parkAll() then sendTurtle() end
  local any = false
  for _ = 1, 60 do
    if bufferEmpty() then break end
    local slot
    for i = 1, 16 do if turtle.getItemCount(i) == 0 then slot = i break end end
    if not slot then
      sendTurtle()
      slot = 1
    end
    turtle.select(slot)
    if not suckFromBuffer() then break end
    any = true
  end
  turtle.select(1)
  if not turtleEmpty() then sendTurtle() end
  return any
end

-- ============================================================ crafting

local function perCraft(grid)
  local need = {}
  for i = 1, 9 do
    if grid[i] then need[grid[i]] = (need[grid[i]] or 0) + 1 end
  end
  return need
end

local function haveCounts()
  local have = bufferCounts()
  for name, n in pairs(turtleCounts()) do have[name] = (have[name] or 0) + n end
  return have
end

local function craftable(grid, have)
  local can
  for name, per in pairs(perCraft(grid)) do
    local k = math.floor((have[name] or 0) / per)
    can = can and math.min(can, k) or k
  end
  return can or 0
end

-- Craft `n` crafts of `grid` and send the results home. Returns crafts done.
local function craftBatch(grid, n)
  if not parkAll() then
    log("error", "Barrel is full")
    return 0
  end
  for i = 1, 9 do
    if grid[i] then fetch(grid[i], n, GRID[i]) end
  end
  turtle.select(1)
  local crafts = n
  for i = 1, 9 do
    if grid[i] then
      local d = turtle.getItemDetail(GRID[i])
      if not d or d.name ~= grid[i] then crafts = 0 else crafts = math.min(crafts, d.count) end
    end
  end
  if crafts <= 0 then
    dbg("grid incomplete, turtle [" .. fmtCounts(turtleCounts()) .. "]")
    parkAll()
    return 0
  end
  for i = 1, 16 do
    local wanted = IS_GRID[i] and grid[IS_GRID[i]]
    local extra = wanted and (turtle.getItemCount(i) - crafts) or turtle.getItemCount(i)
    if extra > 0 then turtle.select(i) dropToBuffer(extra) end
  end
  turtle.select(4)
  local ok, why = turtle.craft(crafts)
  turtle.select(1)
  if not ok then
    log("error", "Craft failed: " .. tostring(why))
    parkAll()
    return 0
  end
  -- results (and leftovers like empty buckets) are what's in the turtle now
  local results = {}
  for i = 1, 16 do
    local d = turtle.getItemDetail(i)
    if d then results[d.name] = (results[d.name] or 0) + d.count end
  end
  dbg("crafted " .. crafts .. "x: " .. fmtCounts(results))
  sendTurtle()
  local day = os.date("!%Y-%m-%d")
  if stats.day ~= day then stats.day, stats.today = day, 0 end
  local made = 0
  for name, cnt in pairs(results) do if name == (job and job.out) then made = made + cnt end end
  if made == 0 then for _, cnt in pairs(results) do made = math.max(made, cnt) end end
  stats.today, stats.total = stats.today + made, stats.total + made
  writeFile(DIR .. "/stats", stats)
  return crafts
end

-- ============================================================ messages

local function send(msg)
  msg.id, msg.version = MY_ID, VERSION
  pcall(rednet.broadcast, msg, PROTOCOL)
end

local function heartbeat()
  state.lastBeat = now()
  send({ kind = "station", address = MY_ADDRESS, name = stationName(), free = job == nil and not state.paused
    and not state.problem, job = job and job.id })
end

local function finishJob(crafted, why)
  if not job then return end
  local items = crafted * (job.outCount or 1)
  if why then
    log("warn", "Order " .. job.id .. " ended early: " .. why .. " (" .. crafted .. " of " .. job.crafts .. " crafts)")
    send({ kind = "failed", job = job.id, crafted = crafted, reason = why })
  else
    log("craft", "Crafted " .. items .. "x " .. short(job.out))
    send({ kind = "done", job = job.id, crafted = crafted, out = job.out, count = items })
  end
  job = nil
  saveJob()
  state.lastBeat = 0
end

local function onMessage(msg)
  if type(msg) ~= "table" then return end
  if msg.kind == "dispatcher" then
    state.dispatcherAt = now()
  elseif msg.kind == "job" and msg.to == MY_ID then
    if job and job.id ~= msg.job then
      send({ kind = "failed", job = msg.job, crafted = 0, reason = "busy with order " .. job.id })
      return
    end
    job = { id = msg.job, grid = msg.grid, crafts = msg.crafts, done = 0, out = msg.out, outCount = msg.outCount or 1, t = now() }
    saveJob()
    log("info", "Order " .. job.id .. ": " .. job.crafts .. " crafts of " .. short(job.out))
    state.lastBeat = 0
  elseif msg.kind == "learned" and msg.by == MY_ID then
    log("craft", "Dispatcher saved the recipe for " .. short(msg.out))
  end
end

-- ============================================================ work

-- Learn: the recipe sits in the 3x3 grid; craft it once to see what it makes.
local function learn()
  if job then log("warn", "Can't learn while an order is running") return end
  local grid, any = {}, false
  for k, slot in ipairs(GRID) do
    local d = turtle.getItemDetail(slot)
    grid[k] = d and d.name or false
    if d then any = true end
  end
  for _, s in ipairs(SPARE) do
    if turtle.getItemCount(s) > 0 then
      log("warn", "Learn: only the recipe may be in the turtle (slots 1-3, 5-7, 9-11)")
      return
    end
  end
  if not any then log("warn", "Learn: put the recipe in the 3x3 grid first") return end
  turtle.select(4)
  local ok, why = turtle.craft(1)
  turtle.select(1)
  if not ok then log("warn", "Learn: that's not a crafting recipe (" .. tostring(why) .. ")") return end
  local out, outCount
  for _, s in ipairs(SPARE) do
    local d = turtle.getItemDetail(s)
    if d and (not outCount or d.count > outCount) then out, outCount = d.name, d.count end
  end
  if not out then log("warn", "Learn: crafted, but couldn't see the result") return end
  send({ kind = "learn", grid = grid, out = out, outCount = outCount })
  log("info", "Learned: " .. outCount .. "x " .. short(out) .. ". Sent to the Dispatcher.")
  sendTurtle()
end

local function work()
  if state.learn then
    state.learn = false
    learn()
    return
  end
  if state.sendAll then
    state.sendAll = false
    if job then finishJob(job.done, "sent everything back") end
    if sendAllHome() then log("info", "Sent everything back to " .. OUT_ADDRESS) end
    return
  end
  if not job then
    -- anything left over with no order goes home
    if (not bufferEmpty() or not turtleEmpty()) and now() - (state.idleSince or now()) > 20 then
      if sendAllHome() then log("info", "Sent leftovers back to " .. OUT_ADDRESS) end
    end
    state.status = "Ready, waiting for the Dispatcher"
    return
  end
  local have = haveCounts()
  local remaining = job.crafts - job.done
  local can = math.min(remaining, craftable(job.grid, have))
  local waited = now() - job.t
  local anyArrived = false
  for name in pairs(perCraft(job.grid)) do if (have[name] or 0) > 0 then anyArrived = true end end
  if not anyArrived and job.done == 0 and waited >= NOTHING_SECONDS then
    finishJob(0, "nothing arrived (storage short of an ingredient?)")
    return
  end
  if can < remaining and waited < WAIT_MINUTES * 60 then
    state.status = "Order " .. job.id .. ": waiting for ingredients (" .. can .. "/" .. remaining .. ")"
    return
  end
  local limit = 64
  for name in pairs(perCraft(job.grid)) do limit = math.min(limit, maxStack(name)) end
  while can > 0 do
    local n = math.min(can, limit)
    state.status = "Crafting " .. n .. "x " .. short(job.out)
    local done = craftBatch(job.grid, n)
    if done <= 0 then break end
    job.done = job.done + done
    can = can - done
    saveJob()
  end
  sendAllHome()  -- leftovers
  if job.done >= job.crafts then
    finishJob(job.done)
  else
    finishJob(job.done, waited >= WAIT_MINUTES * 60 and "not all ingredients arrived" or "crafting failed")
  end
end

-- ============================================================ loops

local function eventLoop()
  while true do
    local e = { os.pullEvent() }
    if e[1] == "rednet_message" and e[4] == PROTOCOL then
      pcall(onMessage, e[3])
    elseif e[1] == "peripheral" or e[1] == "peripheral_detach" then
      findPeripherals()
    end
  end
end

local function workLoop()
  local lastClaim = 0
  while true do
    state.problem = setupProblem()
    if now() - lastClaim > 30 then lastClaim = now() pcall(claimAddress) end
    if job or not bufferEmpty() or not turtleEmpty() then
      if not state.idleSince then state.idleSince = now() end
    else
      state.idleSince = nil
    end
    if state.problem then
      state.status = state.problem
    elseif state.paused and not state.sendAll and not state.learn then
      state.status = "Paused"
    else
      local ok, err = pcall(work)
      if not ok then log("error", "Error: " .. tostring(err)) end
    end
    if now() - state.lastBeat >= 2 then heartbeat() end
    sleep(0.5)
  end
end

-- ============================================================ upload log to Pastebin

local function uploadLog()
  local body = "Crafter " .. VERSION .. " | " .. stationName() .. " | id " .. MY_ID .. " | address " .. MY_ADDRESS
    .. "\njob: " .. textutils.serialize(job) .. "\nturtle [" .. fmtCounts(turtleCounts()) .. "] barrel ["
    .. fmtCounts(buffer and bufferCounts() or {}) .. "]\n---- log ----\n"
  for _, path in ipairs({ LOG_PATH .. ".old", LOG_PATH }) do
    if fs.exists(path) then
      local f = fs.open(path, "r")
      body = body .. f.readAll() .. "\n"
      f.close()
    end
  end
  local post = "api_option=paste&api_dev_key=0ec2eb25b6166c0c27a394ae118ad829&api_paste_format=text"
    .. "&api_paste_name=" .. textutils.urlEncode(stationName() .. " log") .. "&api_paste_code=" .. textutils.urlEncode(body)
  local ok, res = pcall(http.post, "https://pastebin.com/api/api_post.php", post,
    { ["Content-Type"] = "application/x-www-form-urlencoded" })
  if ok and res then
    local code = res.readAll():match("pastebin%.com/(%w+)")
    res.close()
    if code then state.pasteCode = code log("info", "Log uploaded: pastebin code " .. code) return end
  end
  log("error", "Upload failed. Run: pastebin put crafter/log.txt")
end

local function uploadLoop()
  while true do
    if state.uploadWanted then
      state.uploadWanted = false
      pcall(uploadLog)
    end
    sleep(0.5)
  end
end

-- ============================================================ screen

local page = "home"
local buttons = {}

local function put(x, y, s, fg, bg)
  term.setCursorPos(x, y)
  if bg then term.setBackgroundColor(bg) end
  if fg then term.setTextColor(fg) end
  term.write(s)
end

local function fit(s, w)
  s = tostring(s)
  if #s > w then return s:sub(1, w - 1) .. "." end
  return s
end

local function button(x, y, label, fg, bg, action)
  put(x, y, label, fg, bg)
  table.insert(buttons, { x1 = x, x2 = x + #label - 1, y = y, action = action })
end

local function draw()
  local w, h = term.getSize()
  buttons = {}
  term.setBackgroundColor(colors.black)
  term.clear()
  put(1, 1, string.rep(" ", w), colors.white, colors.blue)
  put(2, 1, fit("CRAFTER  " .. stationName(), w - 8), colors.white, colors.blue)
  put(w - #VERSION, 1, VERSION, colors.lightBlue, colors.blue)
  put(1, 2, string.rep(" ", w), colors.white, colors.gray)
  local x = 1
  for _, t in ipairs({ { "home", "Status" }, { "setup", "Setup" }, { "log", "Log" } }) do
    local on = page == t[1]
    local label = " " .. t[2] .. " "
    button(x, 2, label, on and colors.black or colors.white, on and colors.white or colors.gray, function() page = t[1] end)
    x = x + #label
  end
  term.setBackgroundColor(colors.black)
  local y = 3
  if page == "setup" then
    local function row(label, ok, value)
      put(2, y, ok and "\7" or "x", ok and colors.lime or colors.red, colors.black)
      put(4, y, label, colors.lightGray)
      put(15, y, fit(value, w - 15), ok and colors.white or colors.red)
      y = y + 1
    end
    row("Address", true, MY_ADDRESS)
    row("Input", inputFrogport ~= nil, inputFrogport and ("Frogport " .. INPUT_SIDE) or ("set Frogport to " .. MY_ADDRESS))
    row("Output", outputPackager ~= nil, outputPackager and ("Packager " .. OUTPUT_SIDE) or ("Packager on the " .. OUTPUT_SIDE))
    row("Barrel", buffer ~= nil, buffer and bufferSide or "under the turtle")
    row("Crafting", turtle and turtle.craft ~= nil, (turtle and turtle.craft) and "crafting table" or "use a Crafty Turtle")
    row("Dispatcher", now() - state.dispatcherAt < 10, now() - state.dispatcherAt < 10 and "online" or "not heard from")
    row("Sends to", true, OUT_ADDRESS)
  elseif page == "log" then
    for _, l in ipairs(logLines) do
      if y > h - 2 then break end
      local c = l.kind == "error" and colors.red or l.kind == "warn" and colors.orange or l.kind == "craft" and colors.lime or colors.lightGray
      put(2, y, fit(l.text, w - 2), c, colors.black)
      y = y + 1
    end
  else
    local c = state.problem and colors.red or state.paused and colors.orange or job and colors.yellow or colors.lime
    put(2, y, fit(state.status, w - 2), c, colors.black)
    y = y + 2
    if job then
      put(2, y, fit("Order " .. job.id .. ": " .. job.crafts .. " crafts of " .. short(job.out), w - 2), colors.white)
      put(2, y + 1, fit("Done " .. job.done .. ", waiting " .. math.floor(now() - job.t) .. "s", w - 2), colors.lightGray)
      y = y + 3
    end
    put(2, y, fit("Address " .. MY_ADDRESS, w - 2), colors.lightGray)
    put(2, y + 1, "Today " .. stats.today .. "   All time " .. stats.total, colors.lightGray)
    if now() - state.dispatcherAt > 10 then put(2, y + 3, fit("Dispatcher not heard from", w - 2), colors.orange) end
    if state.pasteCode then put(2, y + 4, "Log on Pastebin: " .. state.pasteCode, colors.yellow) end
  end
  put(1, h, string.rep(" ", w), colors.white, colors.gray)
  button(1, h, " Learn ", colors.white, colors.green, function() state.learn = true end)
  button(9, h, " Send back ", colors.white, colors.red, function() state.sendAll = true end)
  button(21, h, state.paused and " Resume " or " Pause ", colors.white, colors.gray, function() state.paused = not state.paused end)
  button(w - 7, h, " Upload ", colors.white, colors.blue, function() state.uploadWanted = true end)
  term.setBackgroundColor(colors.black)
end

local function uiLoop()
  local timer = os.startTimer(0)
  while true do
    local e = { os.pullEvent() }
    if e[1] == "timer" and e[2] == timer then
      draw()
      timer = os.startTimer(0.5)
    elseif e[1] == "mouse_click" then
      for _, b in ipairs(buttons) do
        if e[4] == b.y and e[3] >= b.x1 and e[3] <= b.x2 then b.action() break end
      end
      draw()
    elseif e[1] == "key" then
      if e[2] == keys.l then state.learn = true
      elseif e[2] == keys.s then state.sendAll = true
      elseif e[2] == keys.p then state.paused = not state.paused
      elseif e[2] == keys.u then state.uploadWanted = true
      elseif e[2] == keys.one then page = "home"
      elseif e[2] == keys.two then page = "setup"
      elseif e[2] == keys.three then page = "log" end
      draw()
    end
  end
end

-- ============================================================ start

findPeripherals()
pcall(claimAddress)
log("info", "Started " .. stationName() .. " v" .. VERSION .. " on " .. MY_ADDRESS)
if job then log("info", "Resuming order " .. job.id) end

local function readyToUpdate()
  return job == nil
end

-- ============================================================ auto-update

-- Every UPDATE_CHECK_MINUTES this checks GitHub for a newer version. A new
-- version is downloaded, checked that it loads, given your current settings
-- (the UPPERCASE lines at the top of this file), saved, and the computer
-- reboots into it. Set AUTO_UPDATE = false at the top to turn this off.
local UPDATE_REPO = "levisnakes/cc-craft-dispatch"
local UPDATE_FILE = "crafter.lua"
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
parallel.waitForAny(eventLoop, workLoop, uploadLoop, uiLoop, updateLoop)
