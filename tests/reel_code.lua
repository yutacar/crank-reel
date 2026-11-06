dofile("Source/reelCode.lua")

local function roundTrip(reel)
    local code = ReelCode.encode(reel)
    local decoded = assert(ReelCode.decode(code))
    assert(decoded.title == reel.title and decoded.loop == reel.loop)
    assert(decoded.scoreName == reel.scoreName)
    assert(#decoded.frames == #reel.frames)
    for i, rows in ipairs(reel.frames) do
        assert(decoded.holds[i] == reel.holds[i])
        for y, row in ipairs(rows) do assert(decoded.frames[i][y] == row) end
    end
    return code
end

local empty = {}
for y = 1, 16 do empty[y] = 0 end
local sparse = {title = "月", loop = true, scoreName = "Moon Drift",
    frames = {empty, empty}, holds = {1, 4}}
local code = roundTrip(sparse)
assert(ReelCode.decode("\239\187\191" .. code:lower() .. "\r\n"))
local aliases = code:sub(5):gsub("0", "O"):gsub("1", "L")
assert(aliases ~= code:sub(5))
assert(ReelCode.decode("CR1-" .. aliases))
assert(ReelCode.decode("CR1-" .. aliases:gsub("L", "I")))
assert(not ReelCode.decode(code:sub(1, -3)))
local replacement = code:sub(7, 7) == "A" and "B" or "A"
assert(not ReelCode.decode(code:sub(1, 6) .. replacement .. code:sub(8)))

math.randomseed(12)
local dense = {title = "Full reel", loop = false, scoreName = "Popcorn", frames = {}, holds = {}}
for i = 1, 32 do
    local rows = {}
    for y = 1, 16 do rows[y] = math.random(0, 65535) end
    dense.frames[i], dense.holds[i] = rows, i % 4 + 1
end
roundTrip(dense)
print("CR1 tests passed")
