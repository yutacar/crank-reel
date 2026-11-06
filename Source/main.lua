import "CoreLibs/graphics"
import "CoreLibs/keyboard"
import "reelCode"


local pd = playdate
local gfx = pd.graphics
local SIZE, MAX_FRAMES = 16, 32
local STORE = "reels-v1"
local RULES = {"Flow", "Sway", "Blink"}

local function blank()
    local rows = {}
    for y = 1, SIZE do rows[y] = 0 end
    return rows
end

local function has(rows, x, y)
    return rows[y] & (1 << (x - 1)) ~= 0
end

local function transform(rows, rule, step)
    local result = blank()
    local sway = {0, 1, 2, 1, 0, -1, -2, -1}
    if rule == "Blink" and step >= 4 then return result end
    local dx = rule == "Flow" and step * 2 or rule == "Sway" and sway[step + 1] or 0
    for y = 1, SIZE do
        for x = 1, SIZE do
            if has(rows, x, y) then
                result[y] = result[y] | (1 << ((x - 1 + dx) % SIZE))
            end
        end
    end
    return result
end

local function sample(swayOnly)
    local rows = blank()
    rows[5], rows[6], rows[7], rows[8], rows[9] = 0x03c0, 0x07e0, 0x0ff0, 0x0db0, 0x0ff0
    rows[10], rows[11], rows[12] = 0x0520, 0x0520, 0x0280
    local frames = {}
    local bob = {0, -1, -2, -1, 0, 1, 2, 1}
    for step = 0, 7 do
        local shifted = transform(rows, "Sway", step)
        if swayOnly then
            frames[#frames + 1] = shifted
        else
            local frame = blank()
            for y = 5, 12 do frame[y + bob[step + 1]] = shifted[y] end
            frames[#frames + 1] = frame
        end
    end
    return {title = "Jellyfish", sampleId = "jellyfish", frames = frames, loop = true}
end

local library = pd.datastore.read(STORE) or {reels = {sample()}, nextNumber = 1}
local reels = library.reels
local sampleChanged = false
if not library.jellyfishDriftChecked then
    local original = sample(true)
    for _, item in ipairs(reels) do
        if item.title == original.title and #item.frames == #original.frames then
            local matches = true
            for i, rows in ipairs(original.frames) do
                for y, bits in ipairs(rows) do
                    if item.frames[i][y] ~= bits then matches = false end
                end
            end
            if matches then item.frames = sample().frames end
        end
    end
    library.jellyfishDriftChecked = true
    sampleChanged = true
end
-- Remove the retired built-in sample once from older installations.
if library.knockmanAdded then
    for i = #reels, 1, -1 do
        if reels[i].title == "Knockman" then table.remove(reels, i) end
    end
    library.knockmanAdded, library.knockmanUprightChecked = nil, nil
    sampleChanged = true
end
if not library.sampleIdsAssigned then
    for _, item in ipairs(reels) do
        if item.title == "Jellyfish" then item.sampleId = "jellyfish" end
    end
    library.sampleIdsAssigned, sampleChanged = true, true
end
for _, item in ipairs(reels) do
    item.holds = item.holds or {}
    for i = 1, #item.frames do item.holds[i] = item.holds[i] or 1 end
end

local shelf, frame, x, y = 1, 1, 8, 8
local screen, returnTo, crank = "title", "shelf", 0
local onion, dirty, redraw = true, sampleChanged, true
local history, moveFrom = {}, nil
local reelOption, reelActions = 1, nil
local incoming, setting, tweenDx, tweenDy
local playbackPosition, playbackStarts, playbackLength
local importPath, exportPath = "Import.crankreel", "Export.crankreel"
local menu, menuIndex, preview, ruleIndex
local notice, noticeUntil

-- Each score is scrubbed by crank angle rather than played by a timer.
local scoreNames = ReelCode.scoreNames
local scores = {
    Popcorn = {
        melody = {72, 76, 79, 81, 79, 76, 74, 79, 77, 81, 84, 81, 79, 74, 71, 74},
        bass = {48, 48, 53, 55},
        wave = pd.sound.kWaveTriangle, volume = 0.29, envelope = {0.005, 0.045, 0.42, 0.018},
    },
    ["Moon Drift"] = {
        melody = {67, 0, 72, 76, 74, 0, 72, 0, 69, 0, 72, 77, 76, 0, 74, 0},
        bass = {48, 45, 41, 43},
        wave = pd.sound.kWaveSine, volume = 0.24, envelope = {0.02, 0.08, 0.62, 0.03},
    },
    ["Dark Alley"] = {
        melody = {57, 60, 63, 60, 57, 0, 56, 59, 55, 58, 61, 58, 56, 0, 59, 56},
        bass = {45, 44, 43, 40},
        wave = pd.sound.kWaveTriangle, volume = 0.30, envelope = {0.01, 0.07, 0.5, 0.025},
    },
    ["Flash Bang"] = {
        melody = {48, 60, 0, 67, 46, 58, 70, 0, 45, 57, 0, 64, 43, 55, 67, 71},
        bass = {36, 34, 33, 31},
        wave = pd.sound.kWaveSquare, volume = 0.21, envelope = {0.002, 0.04, 0.22, 0.015},
        hits = true,
    },
}
local function reelScore(item)
    return scores[item.scoreName] and item.scoreName or scoreNames[1]
end

local legacyScore = scores[library.scoreName] and library.scoreName or scoreNames[1]
for _, item in ipairs(reels) do
    if not scores[item.scoreName] then
        if item.title == "Jellyfish" then item.scoreName = "Moon Drift"
        else item.scoreName = legacyScore end
        dirty = true
    end
end

local score = scores[scoreNames[1]]
local lead = pd.sound.synth.new(score.wave)
local bass = pd.sound.synth.new(pd.sound.kWaveSine)
local hit = pd.sound.synth.new(pd.sound.kWaveNoise)
lead:setADSR(table.unpack(score.envelope))
bass:setADSR(0.008, 0.05, 0.35, 0.022)
hit:setADSR(0.002, 0.035, 0, 0.012)
local degreesPerBeat = 30
local scorePosition = degreesPerBeat / 2
local lastMotion, lastUpdate

local function stopScore()
    if not lastMotion then return end
    lead:stop()
    bass:stop()
    hit:stop()
    lastMotion = nil
end

local function turnScore(change, now)
    local dt = lastUpdate and math.max(1, now - lastUpdate) or 33
    lastUpdate = now
    if change == 0 then
        if lastMotion and now - lastMotion >= 85 then stopScore() end
        return
    end

    local melody = score.melody
    local beat = math.floor(scorePosition / degreesPerBeat)
    local nextPosition = scorePosition + change
    local nextBeat = math.floor(nextPosition / degreesPerBeat)
    scorePosition = nextPosition % (#melody * degreesPerBeat)
    lastMotion = now
    if beat == nextBeat then return end

    local index = nextBeat % #melody
    local duration = math.max(0.035, math.min(0.18, 0.75 * degreesPerBeat * dt / (1000 * math.abs(change))))
    local note = melody[index + 1]
    if note == 0 then lead:noteOff()
    else lead:playMIDINote(note, score.volume, duration) end
    if score.hits and index % 4 == 0 then
        hit:playMIDINote(42, 0.24, math.min(duration, 0.06))
    end
    if index % 2 == 0 then
        bass:playMIDINote(score.bass[index // 4 + 1], 0.24, duration)
    else
        bass:noteOff()
    end
end

local function tell(message)
    notice, noticeUntil, redraw = message, pd.getCurrentTimeMilliseconds() + 1600, true
end

local function save()
    if not dirty then return true end
    if not pd.datastore.write(library, STORE) then
        tell("Save failed. Try Save again.")
        return false
    end
    dirty = false
    return true
end

local function useScore(name)
    score = scores[name]
    lead:setWaveform(score.wave)
    lead:setADSR(table.unpack(score.envelope))
end

pd.gameWillTerminate = save
local function suspend()
    stopScore()
    lastUpdate = nil
    save()
end

pd.deviceWillSleep = suspend
pd.gameWillPause = suspend

local function switch(nextScreen)
    if screen == "show" or screen == "title" then stopScore() end
    if nextScreen == "title" then useScore(scoreNames[1]) end
    if nextScreen == "show" or nextScreen == "title" then
        scorePosition = degreesPerBeat / 2
        lastUpdate = nil
    end
    screen, crank, redraw = nextScreen, 0, true
end

local function reel()
    return reels[shelf - 1]
end

local function isSample(item)
    return item.sampleId == "jellyfish"
end

local function editReel()
    frame, x, y = 1, 8, 8
    switch("edit")
end

local function renameReel()
    local item = reel()
    switch("rename")
    pd.keyboard.keyboardWillHideCallback = function(accepted)
        if not accepted then return end
        local name = pd.keyboard.text:match("^%s*(.-)%s*$")
        if name == "" or #name > 24 or name:find("%c") then
            tell("Use 1 to 24 characters")
            return
        end
        if name == "Jellyfish" then
            tell("That title is reserved")
            return
        end
        if item.title ~= name then
            local previous = item.title
            item.title, dirty = name, true
            if not save() then item.title = previous end
        end
    end
    pd.keyboard.keyboardDidHideCallback = function()
        pd.keyboard.keyboardWillHideCallback = nil
        pd.keyboard.keyboardDidHideCallback = nil
        switch("reelOptions")
    end
    pd.keyboard.show(item.title)
end

local function appendReel(item)
    table.insert(reels, item)
    dirty = true
    if not save() then
        table.remove(reels)
        return false
    end
    shelf = #reels + 1
    switch("shelf")
    return true
end

local function importReel()
    local size = pd.file.getSize(importPath)
    if not size or size < 0 then tell("Put Import.crankreel in app Data"); return end
    if size == 0 or size > 4096 then tell("Invalid reel file"); return end
    local file = pd.file.open(importPath, pd.file.kFileRead)
    if not file then tell("Cannot open Import.crankreel"); return end
    local code = file:read(size)
    file:close()
    incoming = ReelCode.decode(code)
    if not incoming then tell("Invalid or damaged reel code"); return end
    if incoming.title == "Jellyfish" then incoming.title = incoming.title .. " copy" end
    switch("import")
end

local function exportReel()
    local file = pd.file.open(exportPath, pd.file.kFileWrite)
    if not file then tell("Cannot open Export.crankreel"); return end
    local code = ReelCode.encode(reel()) .. "\n"
    local written = file:write(code)
    file:close()
    tell(written == #code and "Saved Export.crankreel" or "Export failed")
end

local function duplicateReel(editCopy)
    local item = reel()
    local title = item.title
    if #title > 19 then
        title = title:sub(1, (utf8.offset(title, 0, 20) or 20) - 1)
    end
    local copy = {
        title = title .. " copy",
        loop = item.loop,
        scoreName = reelScore(item),
        frames = {},
        holds = {table.unpack(item.holds)},
    }
    for i, rows in ipairs(item.frames) do copy.frames[i] = {table.unpack(rows)} end
    if appendReel(copy) then
        tell("Reel duplicated")
        if editCopy then editReel() end
    end
end

local function restoreSample()
    local item = reel()
    local original = sample()
    local previousFrames, previousHolds = item.frames, item.holds
    local backup = {title = "Jellyfish backup", frames = previousFrames, holds = previousHolds,
        loop = item.loop, scoreName = reelScore(item)}
    item.frames, item.holds = original.frames, {}
    for i = 1, #item.frames do item.holds[i] = 1 end
    if appendReel(backup) then
        tell("Sample restored; backup saved")
    else
        item.frames, item.holds = previousFrames, previousHolds
    end
end

local function sampleFramesChanged(item)
    local original = sample().frames
    if #item.frames ~= #original then return true end
    for i, rows in ipairs(original) do
        if item.holds[i] ~= 1 then return true end
        for y, bits in ipairs(rows) do
            if item.frames[i][y] ~= bits then return true end
        end
    end
    return false
end

local function manageReel()
    reelActions = {}
    if isSample(reel()) then
        table.insert(reelActions, {"Edit a copy", function() duplicateReel(true) end})
    else
        table.insert(reelActions, {"Edit frames", editReel})
    end
    if not isSample(reel()) then
        table.insert(reelActions, {"Rename reel", renameReel})
        table.insert(reelActions, {"Delete reel", function() switch("deleteReel") end})
    end
    table.insert(reelActions, {"Duplicate reel", duplicateReel})
    table.insert(reelActions, {"Export reel code", exportReel})
    table.insert(reelActions, {"BGM: " .. reelScore(reel()), function()
        for i, name in ipairs(scoreNames) do
            if name == reelScore(reel()) then setting = i; break end
        end
        switch("reelBgm")
    end})
    if isSample(reel()) and sampleFramesChanged(reel()) then
        table.insert(reelActions, {"Restore sample (keep backup)", restoreSample})
    end
    reelOption = 1
    switch("reelOptions")
end

local function pushUndo(entry)
    local item = reel()
    local stack = history[item] or {}
    history[item] = stack
    stack[#stack + 1] = entry
    if #stack > 128 then table.remove(stack, 1) end
end

local function remember(selected)
    local item = reel()
    -- Frame rows are restored by pixel undo entries before earlier structural edits.
    pushUndo({frames = {table.unpack(item.frames)}, holds = {table.unpack(item.holds)},
        selected = selected or frame})
end

local function undo()
    local stack = history[reel()]
    if not stack or #stack == 0 then
        tell("Nothing to undo")
        return
    end
    local snapshot = table.remove(stack)
    if snapshot.row then
        reel().frames[snapshot.selected][snapshot.row] = snapshot.bits
    else
        reel().frames, reel().holds = snapshot.frames, snapshot.holds
    end
    frame = snapshot.selected
    moveFrom, dirty = nil, true
    tell("Undone")
end

local function playbackTimeline()
    playbackStarts, playbackLength = {}, 0
    for i, hold in ipairs(reel().holds) do
        playbackStarts[i] = playbackLength
        playbackLength = playbackLength + hold
    end
    playbackPosition = playbackStarts[frame] + reel().holds[frame] / 2
end

local function play(from)
    useScore(reelScore(reel()))
    playbackTimeline()
    returnTo = from
    switch("show")
end

local function openReel()
    frame, x, y = 1, 8, 8
    if shelf == 1 then
        local number = library.nextNumber
        library.nextNumber = number + 1
        if appendReel({title = "Reel " .. number, frames = {blank()}, holds = {1},
            loop = true, scoreName = scoreNames[1]}) then
            switch("edit")
        else
            library.nextNumber = number
        end
    else
        play("shelf")
    end
end

local function insertFrames(newFrames, hold)
    local frames = reel().frames
    if #frames + #newFrames > MAX_FRAMES then
        tell("Not enough room (32 frames max).")
        return false
    end
    remember()
    for i, rows in ipairs(newFrames) do
        table.insert(frames, frame + i, rows)
        table.insert(reel().holds, frame + i, hold or 1)
    end
    frame, dirty = frame + 1, true
    return true
end

local function makePreview()
    preview = {frames = {}, index = 1}
    local source = reel().frames[frame]
    for step = 0, 7 do
        preview.frames[step + 1] = transform(source, RULES[ruleIndex], step)
    end
end

local function topLeft(rows)
    local left, top = SIZE + 1, nil
    for y, row in ipairs(rows) do
        if row ~= 0 then
            top = top or y
            for x = 1, left - 1 do
                if has(rows, x, y) then left = x; break end
            end
        end
    end
    return left, top
end

local function translate(rows, dx, dy)
    local result = blank()
    for y, row in ipairs(rows) do
        local target = y + dy
        if target >= 1 and target <= SIZE then
            result[target] = (dx < 0 and (row >> -dx) or (row << dx)) & 0xffff
        end
    end
    return result
end

local function startTween()
    local frames = reel().frames
    if frame == #frames or #frames >= MAX_FRAMES then
        tell("Need a next frame and free space")
        return
    end
    local ax, ay = topLeft(frames[frame])
    local bx, by = topLeft(frames[frame + 1])
    if not ay or not by then tell("Draw both poses first"); return end
    tweenDx, tweenDy = bx - ax, by - ay
    local shifted = translate(frames[frame], tweenDx, tweenDy)
    local restored = translate(frames[frame + 1], -tweenDx, -tweenDy)
    for y = 1, SIZE do
        if shifted[y] ~= frames[frame + 1][y] or restored[y] ~= frames[frame][y] then
            tell("Both poses need the same shape")
            return
        end
    end
    if tweenDx == 0 and tweenDy == 0 then tell("Move the second pose first"); return end
    setting = math.min(3, MAX_FRAMES - #frames, math.max(math.abs(tweenDx), math.abs(tweenDy)) - 1)
    if setting < 1 then tell("Poses are one dot apart"); return end
    switch("tween")
end

local function editMenu()
    menu = {
        {"Screen this reel", function() play("edit") end},
        {"Film strip", function()
            moveFrom = nil
            switch("strip")
        end},
        {"Duplicate frame", function()
            if insertFrames({{table.unpack(reel().frames[frame])}}, reel().holds[frame]) then switch("edit") end
        end},
        {"Insert blank frame", function()
            if insertFrames({blank()}) then switch("edit") end
        end},
        {"Generate motion", function()
            if #reel().frames + 7 > MAX_FRAMES then tell("Generation needs 7 free frames."); return end
            ruleIndex = 1
            makePreview()
            switch("generate")
        end},
        {onion and "Hide previous frame" or "Show previous frame", function()
            onion = not onion
            switch("edit")
        end},
        {"Delete frame", function()
            if #reel().frames == 1 then tell("Keep at least one frame."); return end
            switch("delete")
        end},
        {"Undo last edit", function() undo(); switch("edit") end},
        {"Save reel", function()
            if save() then tell("Reel saved") end
            switch("edit")
        end},
        {"Frame hold", function()
            setting = reel().holds[frame]
            switch("hold")
        end},
        {"In-between frames", startTween},
        {"Return to shelf", function()
            if save() then switch("shelf") end
        end},
    }
    menuIndex = 1
    switch("menu")
end

local function clamp(value, high)
    return math.max(1, math.min(high, value))
end

local function moveFrame(steps)
    if screen == "generate" then
        preview.index = (preview.index + steps - 1) % #preview.frames + 1
        return
    end
    local count = #reel().frames
    if screen == "show" and reel().loop then
        frame = (frame + steps - 1) % count + 1
    else
        frame = clamp(frame + steps, count)
    end
end

local repeatAt = {}
local function editDirection(key, tapped, now)
    if tapped then
        repeatAt[key] = now + 250
        return true
    end
    if not pd.buttonIsPressed(key) then
        repeatAt[key] = nil
        return false
    end
    if repeatAt[key] and now >= repeatAt[key] then
        repeatAt[key] = now + 65
        return true
    end
    return false
end

local function buttons()
    if screen == "rename" then return end
    local pressed = pd.buttonJustPressed
    local up, down = pressed(pd.kButtonUp), pressed(pd.kButtonDown)
    local left, right = pressed(pd.kButtonLeft), pressed(pd.kButtonRight)
    if screen == "edit" then
        local now = pd.getCurrentTimeMilliseconds()
        up, down = editDirection(pd.kButtonUp, up, now), editDirection(pd.kButtonDown, down, now)
        left, right = editDirection(pd.kButtonLeft, left, now), editDirection(pd.kButtonRight, right, now)
    elseif next(repeatAt) then
        repeatAt = {}
    end
    local a, b = pressed(pd.kButtonA), pressed(pd.kButtonB)
    local dx = (right and 1 or 0) - (left and 1 or 0)
    local dy = (down and 1 or 0) - (up and 1 or 0)
    if dx == 0 and dy == 0 and not a and not b then return end
    redraw = true

    if screen == "title" then
        if a then switch("shelf") end
    elseif screen == "shelf" then
        shelf = clamp(shelf + dy, #reels + 1)
        if a then openReel()
        elseif left then switch("title")
        elseif right and reel() then
            if isSample(reel()) then duplicateReel(true) else editReel() end
        elseif b then
            if reel() then manageReel() else importReel() end
        end
    elseif screen == "reelOptions" then
        reelOption = clamp(reelOption + dy, #reelActions)
        if b then switch("shelf")
        elseif a then reelActions[reelOption][2]() end
    elseif screen == "reelBgm" then
        setting = (setting + dx - 1) % #scoreNames + 1
        if b then switch("reelOptions")
        elseif a then
            local item = reel()
            local previous = item.scoreName
            item.scoreName, dirty = scoreNames[setting], true
            if save() then
                reelActions[reelOption][1] = "BGM: " .. item.scoreName
                switch("reelOptions")
            else
                item.scoreName = previous
            end
        end
    elseif screen == "import" then
        if b then incoming = nil; switch("shelf")
        elseif a and appendReel(incoming) then incoming = nil; tell("Reel imported") end
    elseif screen == "hold" then
        setting = clamp(setting + dx, 4)
        if b then switch("menu")
        elseif a then
            if reel().holds[frame] ~= setting then
                remember()
                reel().holds[frame], dirty = setting, true
            end
            switch("edit")
        end
    elseif screen == "tween" then
        local distance = math.max(math.abs(tweenDx), math.abs(tweenDy))
        setting = clamp(setting + dx, math.min(4, distance - 1, MAX_FRAMES - #reel().frames))
        if b then switch("menu")
        elseif a then
            local rows, generated = reel().frames[frame], {}
            for i = 1, setting do
                local fraction = i / (setting + 1)
                generated[i] = translate(rows, math.floor(tweenDx * fraction + 0.5),
                    math.floor(tweenDy * fraction + 0.5))
            end
            if insertFrames(generated) then switch("edit") end
        end
    elseif screen == "deleteReel" then
        if b then switch("reelOptions")
        elseif a then
            local removed = table.remove(reels, shelf - 1)
            dirty = true
            if save() then
                history[removed] = nil
                shelf = clamp(shelf, #reels + 1)
                switch("shelf")
            else
                table.insert(reels, shelf - 1, removed)
            end
        end
    elseif screen == "edit" then
        x, y = clamp(x + dx, SIZE), clamp(y + dy, SIZE)
        if a then
            local rows = reel().frames[frame]
            pushUndo({selected = frame, row = y, bits = rows[y]})
            rows[y] = rows[y] ~ (1 << (x - 1))
            dirty = true
        elseif b then editMenu() end
    elseif screen == "menu" then
        menuIndex = clamp(menuIndex + dy, #menu)
        if b then switch("edit")
        elseif a then menu[menuIndex][2]() end
    elseif screen == "strip" then
        if dx ~= 0 then moveFrame(dx) end
        if b then
            if moveFrom then frame, moveFrom = moveFrom, nil
            else switch("edit") end
        elseif a then
            if not moveFrom then
                if #reel().frames > 1 then moveFrom = frame end
            else
                if moveFrom ~= frame then
                    remember(moveFrom)
                    local frames = reel().frames
                    local moved = table.remove(frames, moveFrom)
                    table.insert(frames, frame, moved)
                    local holds = reel().holds
                    local hold = table.remove(holds, moveFrom)
                    table.insert(holds, frame, hold)
                    dirty = true
                end
                moveFrom = nil
            end
        elseif up and not moveFrom then undo() end
    elseif screen == "delete" then
        if a then
            remember()
            table.remove(reel().frames, frame)
            table.remove(reel().holds, frame)
            frame, dirty = clamp(frame, #reel().frames), true
            switch("edit")
        elseif b then switch("menu") end
    elseif screen == "generate" then
        if dx ~= 0 then
            ruleIndex = (ruleIndex + dx - 1) % #RULES + 1
            crank = 0
            makePreview()
        end
        if b then switch("edit")
        elseif a then
            -- The seed is already in the timeline. Insert only the seven new frames.
            if insertFrames({table.unpack(preview.frames, 2)}) then switch("edit") end
        end
    elseif screen == "show" then
        if dx ~= 0 then
            moveFrame(dx)
            playbackPosition = playbackStarts[frame] + reel().holds[frame] / 2
        end
        if b then switch(returnTo)
        elseif a then
            reel().loop = not reel().loop
            dirty = true
            save()
        end
    end
end

local function pixels(rows, px, py, scale, previous, grid)
    for row = 1, SIZE do
        for col = 1, SIZE do
            local sx, sy = px + (col - 1) * scale, py + (row - 1) * scale
            if has(rows, col, row) then
                gfx.fillRect(sx, sy, scale, scale)
            elseif previous and has(previous, col, row) then
                for offset = 1, scale - 2, 3 do
                    gfx.drawLine(sx + 1, sy + offset, sx + scale - 2, sy + offset)
                end
            end
            if grid then gfx.drawPixel(sx, sy) end
        end
    end
end

local function header(section)
    gfx.drawText("CRANK REEL  /  " .. section, 12, 8)
    gfx.drawLine(12, 29, 388, 29)
end

local function footer(text)
    gfx.drawLine(12, 211, 388, 211)
    gfx.drawText(notice or text, 12, 217)
end

local function track(index, count, left, top, width)
    for i = 1, count do
        local start = math.floor((i - 1) * width / count)
        local size = math.floor(i * width / count) - start - 1
        if i == index then gfx.fillRect(left + start, top, size, 8)
        else gfx.drawRect(left + start, top + 2, size, 4) end
    end
end

local titleLetters = {
    C = {15, 16, 16, 16, 16, 16, 15},
    R = {30, 17, 17, 30, 20, 18, 17},
    A = {14, 17, 17, 31, 17, 17, 17},
    N = {17, 25, 21, 21, 19, 17, 17},
    K = {17, 18, 20, 24, 20, 18, 17},
    E = {31, 16, 16, 30, 16, 16, 31},
    L = {16, 16, 16, 16, 16, 16, 31},
}

local function titleWord(word, left, top)
    for i = 1, #word do
        for row, bits in ipairs(titleLetters[word:sub(i, i)]) do
            for col = 0, 4 do
                if bits & (16 >> col) ~= 0 then
                    gfx.fillRect(left + (i - 1) * 36 + col * 6, top + (row - 1) * 6, 6, 6)
                end
            end
        end
    end
end

local function spool(cx, cy, radius, angle)
    gfx.setColor(gfx.kColorWhite)
    gfx.fillCircleAtPoint(cx, cy, radius + 2)
    gfx.setColor(gfx.kColorBlack)
    gfx.fillCircleAtPoint(cx, cy, radius)
    gfx.setColor(gfx.kColorWhite)
    gfx.drawCircleAtPoint(cx, cy, radius - 4)
    for hole = 0, 4 do
        local phase = angle + hole * 2 * math.pi / 5
        gfx.fillCircleAtPoint(
            math.floor(cx + math.cos(phase) * radius * 0.52),
            math.floor(cy + math.sin(phase) * radius * 0.52),
            math.floor(radius * 0.19)
        )
    end
    gfx.fillCircleAtPoint(cx, cy, 3)
    gfx.setColor(gfx.kColorBlack)
end

local function drawTitle()
    gfx.drawRect(8, 8, 384, 224)
    gfx.drawLine(16, 35, 383, 35)
    gfx.drawText("HAND-CRANKED PICTURE STUDIO", 22, 15)
    gfx.drawText("01", 355, 15)

    -- Perforations frame the logotype like an exposed film strip.
    gfx.fillRect(20, 46, 14, 139)
    gfx.setColor(gfx.kColorWhite)
    for slot = 0, 8 do gfx.fillRect(23, 50 + slot * 15, 8, 5) end
    gfx.setColor(gfx.kColorBlack)
    titleWord("CRANK", 44, 58)
    titleWord("REEL", 44, 110)
    gfx.drawText("Draw. Wind. Replay.", 44, 165)

    local angle = math.rad(pd.getCrankPosition())
    -- The projection beam and stand sit behind the camera body.
    gfx.drawLine(337, 126, 380, 104)
    gfx.drawLine(337, 143, 380, 164)
    for offset = 0, 15, 5 do gfx.drawLine(365 + offset, 120, 365 + offset, 148) end
    gfx.drawLine(281, 151, 266, 182)
    gfx.drawLine(305, 151, 320, 182)
    gfx.drawLine(254, 182, 337, 182)
    gfx.fillRoundRect(252, 111, 84, 46, 6)
    gfx.fillRect(332, 120, 18, 28)
    gfx.setColor(gfx.kColorWhite)
    gfx.drawRoundRect(257, 116, 73, 35, 3)
    gfx.drawLine(337, 123, 337, 144)
    gfx.drawLine(342, 123, 342, 144)
    gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
    gfx.drawText("16 MM", 269, 130)
    gfx.setImageDrawMode(gfx.kDrawModeCopy)
    spool(316, 94, 25, -angle)
    spool(268, 87, 32, angle)
    local hx = math.floor(268 + 15 * math.cos(angle))
    local hy = math.floor(87 + 15 * math.sin(angle))
    gfx.setColor(gfx.kColorWhite)
    gfx.setLineWidth(3)
    gfx.drawLine(268, 87, hx, hy)
    gfx.setLineWidth(1)
    gfx.fillCircleAtPoint(hx, hy, 4)
    gfx.setColor(gfx.kColorBlack)

    gfx.fillRect(9, 196, 382, 35)
    gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
    gfx.drawText("A   OPEN REEL SHELF", 22, 206)
    gfx.drawText("CRANK  /  TURN", 249, 206)
    gfx.setImageDrawMode(gfx.kDrawModeCopy)
end

local function draw()
    gfx.clear(gfx.kColorWhite)
    gfx.setColor(gfx.kColorBlack)
    if screen == "title" then
        drawTitle()
    elseif screen == "shelf" then
        header("SHELF")
        local first = math.max(1, shelf - 3)
        for i = first, math.min(#reels + 1, first + 3) do
            local top = 37 + (i - first) * 42
            if shelf == i then gfx.drawRoundRect(12, top, 376, 39, 5) end
            local item = reels[i - 1]
            if item then
                pixels(item.frames[1], 21, top + 3, 2)
                gfx.drawTextInRect(item.title, 66, top + 2, 305, 24, 0, "...")
                gfx.drawText(#item.frames .. " frames", 66, top + 19)
            else
                gfx.drawText("+   New reel", 22, top + 10)
            end
        end
        footer(reel() and "A Play   Right Edit   B Manage   Left Title"
            or "A New reel   B Import   Left Title")
    elseif screen == "reelOptions" then
        header("MANAGE REEL")
        gfx.drawTextInRect(reel().title, 24, 43, 350, 24, 0, "...")
        for i, action in ipairs(reelActions) do
            local top = 69 + (i - 1) * 23
            if i == reelOption then gfx.drawRoundRect(12, top, 376, 22, 4) end
            gfx.drawText(action[1], 24, top + 3)
        end
        footer("A Select    B Shelf")
    elseif screen == "reelBgm" then
        header("REEL BGM")
        gfx.drawTextInRect(reel().title, 24, 49, 350, 24, 0, "...")
        gfx.drawText("<  " .. scoreNames[setting] .. "  >", 24, 96)
        footer("Left / Right Choose    A Save    B Cancel")
    elseif screen == "import" then
        header("IMPORT REEL")
        pixels(incoming.frames[1], 22, 48, 8)
        gfx.drawTextInRect(incoming.title, 174, 53, 211, 48, 0, "...")
        gfx.drawText(#incoming.frames .. " frames", 174, 108)
        footer("A Add to shelf    B Cancel")
    elseif screen == "hold" then
        header("FRAME HOLD")
        pixels(reel().frames[frame], 22, 48, 8)
        gfx.drawText(string.format("Frame %02d", frame), 174, 53)
        gfx.drawText("<  " .. setting .. "x  >", 174, 90)
        gfx.drawText("Crank travel for this frame", 174, 126)
        footer("Left / Right Adjust    A Apply    B Cancel")
    elseif screen == "tween" then
        header("IN-BETWEEN FRAMES")
        pixels(reel().frames[frame], 25, 54, 6)
        pixels(reel().frames[frame + 1], 279, 54, 6)
        gfx.drawText("< " .. setting .. " new >", 148, 93)
        footer("Left / Right Adjust    A Insert    B Cancel")
    elseif screen == "rename" then
        gfx.drawText("RENAME REEL", 20, 15)
        gfx.drawLine(20, 35, 204, 35)
        gfx.drawText("Reel title", 20, 53)
        gfx.drawTextInRect(pd.keyboard.text or "", 20, 78, 185, 42, 0, "...")
    elseif screen == "deleteReel" then
        header("DELETE REEL")
        gfx.drawText("Delete this reel and all its frames?", 24, 68)
        gfx.drawTextInRect(reel().title, 24, 107, 350, 36, 0, "...")
        footer("A Delete    B Cancel")
    elseif screen == "edit" then
        header("STUDIO")
        local frames = reel().frames
        gfx.drawRect(15, 38, 162, 162)
        pixels(frames[frame], 16, 39, 10, onion and frames[frame - 1], true)
        local cx, cy = 16 + (x - 1) * 10, 39 + (y - 1) * 10
        gfx.setColor(gfx.kColorWhite)
        gfx.drawRect(cx + 1, cy + 1, 8, 8)
        gfx.setColor(gfx.kColorBlack)
        gfx.drawRect(cx + 2, cy + 2, 6, 6)
        gfx.drawTextInRect(reel().title, 194, 44, 194, 24, 0, "...")
        gfx.drawText(string.format("FRAME  %02d / %02d", frame, #frames), 194, 73)
        track(frame, #frames, 194, 99, 190)
        gfx.drawText("Hold: " .. reel().holds[frame] .. "x", 194, 111)
        gfx.drawText(onion and "Previous frame: ON" or "Previous frame: OFF", 194, 132)
        gfx.drawText("D-pad Move\nA Draw    B Tools", 194, 154)
        footer("Crank to select a frame")
    elseif screen == "strip" then
        header("FILM STRIP")
        local frames = reel().frames
        gfx.drawRect(17, 43, 114, 114)
        pixels(frames[moveFrom or frame], 18, 44, 7)
        gfx.drawText(string.format("FRAME  %02d / %02d", frame, #frames), 151, 49)
        gfx.drawText(moveFrom and string.format("Move %02d to %02d", moveFrom, frame)
            or "Crank or Left / Right", 151, 80)
        local first = math.max(1, math.min(frame - 2, #frames - 4))
        for i = first, math.min(first + 4, #frames) do
            local left = 151 + (i - first) * 47
            if i == frame then gfx.fillRect(left, 114, 43, 54) end
            gfx.setColor(gfx.kColorWhite)
            gfx.fillRect(left + 3, 117, 37, 35)
            gfx.setColor(gfx.kColorBlack)
            gfx.drawRect(left + 3, 117, 37, 35)
            pixels(frames[i], left + 5, 119, 2)
            if i == frame then gfx.setImageDrawMode(gfx.kDrawModeFillWhite) end
            gfx.drawText(string.format("%02d", i), left + 11, 152)
            gfx.setImageDrawMode(gfx.kDrawModeCopy)
        end
        track(frame, #frames, 18, 187, 365)
        footer(moveFrom and "A Place    B Cancel" or "A Pick up    Up Undo    B Studio")
    elseif screen == "menu" then
        header("TOOLS")
        for i, entry in ipairs(menu) do
            local first = math.max(1, menuIndex - 7)
            local top = 36 + (i - first) * 21
            if i >= first and i < first + 8 then
                if i == menuIndex then gfx.drawRoundRect(12, top, 376, 21, 4) end
                gfx.drawText(entry[1], 24, top + 1)
            end
        end
        footer("A Select    B Back")
    elseif screen == "delete" then
        header("DELETE FRAME")
        gfx.drawText("Delete frame " .. frame .. "?", 24, 68)
        pixels(reel().frames[frame], 24, 104, 5)
        footer("A Delete    B Cancel")
    else
        local generating = screen == "generate"
        local frames = generating and preview.frames or reel().frames
        local index = generating and preview.index or frame
        header(generating and "MOTION LAB" or "SCREENING")
        local px = generating and 20 or 128
        gfx.drawRect(px - 1, 37, 146, 146)
        pixels(frames[index], px, 38, 9)
        track(index, #frames, px, 190, 144)
        if generating then
            gfx.drawText("<  " .. RULES[ruleIndex] .. "  >", 190, 48)
            gfx.drawText("Crank to preview\nAdds 7 editable frames", 190, 83)
            gfx.drawText(index .. " / " .. #frames, 190, 131)
        else
            gfx.drawText(index .. " / " .. #frames, 293, 44)
            gfx.drawText(reel().loop and "LOOP" or "ENDS", 293, 64)
        end
        footer(generating and "A Add frames    B Cancel" or "Crank / Left Right    A Loop    B Back")
    end
end

function pd.update()
    if notice and pd.getCurrentTimeMilliseconds() >= noticeUntil then
        notice, redraw = nil, true
    end
    local previousScreen = screen
    buttons()
    local change = pd.getCrankChange()
    if screen == "title" and change ~= 0 then redraw = true end
    if screen == previousScreen and (screen == "show" or screen == "title") then
        turnScore(change, pd.getCurrentTimeMilliseconds())
    end
    if screen == previousScreen and screen == "show" and change ~= 0 then
        local nextPosition = playbackPosition + change * playbackLength / 360
        if reel().loop then
            playbackPosition = nextPosition % playbackLength
        else
            playbackPosition = math.max(0, math.min(playbackLength, nextPosition))
        end
        local selected = #playbackStarts
        while selected > 1 and playbackPosition < playbackStarts[selected] do selected = selected - 1 end
        if selected ~= frame then frame, redraw = selected, true end
    elseif screen == previousScreen and (screen == "edit" or screen == "generate" or screen == "strip") then
        local degrees = 30
        crank = crank + change
        local steps = crank >= 0 and math.floor(crank / degrees) or math.ceil(crank / degrees)
        if steps ~= 0 then
            crank = crank - steps * degrees
            moveFrame(steps)
            redraw = true
        end
    end
    if redraw or screen == "rename" then
        draw()
        redraw = false
    end
end
