-- CR1: versioned Base32 text wrapping a checksummed, compact binary reel.
ReelCode = {scoreNames = {"Popcorn", "Moon Drift", "Dark Alley", "Flash Bang"}}

local alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
local digit = {}
for i = 1, #alphabet do digit[alphabet:sub(i, i)] = i - 1 end

local function checksum(data)
    local crc = 0xffff
    for i = 1, #data do
        crc = crc ~ (data:byte(i) << 8)
        for _ = 1, 8 do
            local polynomial = crc & 0x8000 ~= 0 and 0x1021 or 0
            crc = ((crc << 1) ~ polynomial) & 0xffff
        end
    end
    return crc
end

local function toText(data)
    local output, bits, pending = {}, 0, 0
    for i = 1, #data do
        pending = (pending << 8) | data:byte(i)
        bits = bits + 8
        while bits >= 5 do
            bits = bits - 5
            local index = ((pending >> bits) & 31) + 1
            output[#output + 1] = alphabet:sub(index, index)
        end
        pending = pending & ((1 << bits) - 1)
    end
    if bits > 0 then
        local index = (pending << (5 - bits)) + 1
        output[#output + 1] = alphabet:sub(index, index)
    end
    return table.concat(output)
end

local function fromText(code)
    local output, bits, pending = {}, 0, 0
    for i = 1, #code do
        local value = digit[code:sub(i, i)]
        if not value then return nil end
        pending = (pending << 5) | value
        bits = bits + 5
        if bits >= 8 then
            bits = bits - 8
            output[#output + 1] = string.char(pending >> bits)
            pending = pending & ((1 << bits) - 1)
        end
    end
    if pending ~= 0 or bits >= 5 then return nil end
    return table.concat(output)
end

local function encodeRuns(data)
    local output, i = {}, 1
    while i <= #data do
        if data:byte(i) == 0 then
            local last = i
            while last < #data and last - i < 254 and data:byte(last + 1) == 0 do
                last = last + 1
            end
            output[#output + 1] = string.char(0, last - i + 1)
            i = last + 1
        else
            output[#output + 1] = data:sub(i, i)
            i = i + 1
        end
    end
    return table.concat(output)
end

local function decodeRuns(data, expected)
    local output, size, i = {}, 0, 1
    while i <= #data do
        if data:byte(i) == 0 then
            local count = data:byte(i + 1)
            if not count or count == 0 then return nil end
            output[#output + 1] = string.rep("\0", count)
            size, i = size + count, i + 2
        else
            output[#output + 1] = data:sub(i, i)
            size, i = size + 1, i + 1
        end
        if size > expected then return nil end
    end
    if size == expected then return table.concat(output) end
end

function ReelCode.encode(reel)
    local raw, delta, holds = {}, {}, {}
    for i, frame in ipairs(reel.frames) do
        holds[i] = string.char(reel.holds[i])
        for y, row in ipairs(frame) do
            local diff = row ~ (i == 1 and 0 or reel.frames[i - 1][y])
            raw[#raw + 1] = string.char(row & 255, row >> 8)
            delta[#delta + 1] = string.char(diff & 255, diff >> 8)
        end
    end
    local bitmap, compressed = table.concat(raw), encodeRuns(table.concat(delta))
    local flags = reel.loop and 1 or 0
    if #compressed < #bitmap then
        bitmap, flags = compressed, flags | 2
    end
    local scoreByte = ""
    for i, name in ipairs(ReelCode.scoreNames) do
        if i > 1 and name == reel.scoreName then
            flags, scoreByte = flags | 4, string.char(i)
            break
        end
    end
    local data = string.char(flags, #reel.frames, #reel.title) .. reel.title
        .. table.concat(holds) .. scoreByte .. bitmap
    local crc = checksum(data)
    return "CR1-" .. toText(data .. string.char(crc >> 8, crc & 255))
end

function ReelCode.decode(code)
    if type(code) ~= "string" or #code > 4096 then return nil end
    code = code:gsub("^\239\187\191", ""):upper():gsub("%s", "")
    if code:sub(1, 4) ~= "CR1-" then return nil end
    local bytes = fromText(code:sub(5):gsub("O", "0"):gsub("[IL]", "1"))
    if not bytes or #bytes < 7 then return nil end
    local data = bytes:sub(1, -3)
    local hi, lo = bytes:byte(-2, -1)
    if checksum(data) ~= ((hi << 8) | lo) then return nil end
    local flags, count, titleSize = data:byte(1, 3)
    if flags > 7 or count < 1 or count > 32 or titleSize < 1 or titleSize > 24 then return nil end
    if #data < 3 + titleSize + count then return nil end
    local title = data:sub(4, 3 + titleSize)
    if title:find("%c") or not title:find("%S") or not utf8.len(title) then return nil end
    local reel = {title = title, loop = flags & 1 ~= 0, frames = {}, holds = {}}
    local bitmapStart = 4 + titleSize + count
    reel.scoreName = ReelCode.scoreNames[1]
    if flags & 4 ~= 0 then
        reel.scoreName = ReelCode.scoreNames[data:byte(bitmapStart)]
        if not reel.scoreName then return nil end
        bitmapStart = bitmapStart + 1
    end
    local bitmap = data:sub(bitmapStart)
    local compressed = flags & 2 ~= 0
    if compressed then bitmap = decodeRuns(bitmap, count * 32) end
    if not bitmap or #bitmap ~= count * 32 then return nil end
    local offset = 1
    for i = 1, count do
        local hold = data:byte(3 + titleSize + i)
        if hold < 1 or hold > 4 then return nil end
        reel.holds[i], reel.frames[i] = hold, {}
        for y = 1, 16 do
            local low, high = bitmap:byte(offset, offset + 1)
            local row = low | (high << 8)
            if compressed and i > 1 then row = row ~ reel.frames[i - 1][y] end
            reel.frames[i][y] = row
            offset = offset + 2
        end
    end
    return reel
end
