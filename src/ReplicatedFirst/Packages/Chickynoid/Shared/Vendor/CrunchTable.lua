--CrunchTable lets you define compression schemes for simple tables to be sent by roblox
--If a field in a table is not defined in the layout, it will be ignored and stay in the table
--If a field in a table is not present, but is defined in the layout, it'll default to 0 (or equiv)

--!strict
local module = {}
type Self = typeof(module)
type anyTable = { [any]: any }

module.Enum = table.freeze({
	FLOAT = 1,
	VECTOR3 = 2,
	INT32 = 3,
	UBYTE = 4,
})

module.Sizes = table.freeze({
	4,
	12,
	4,
	1
})

local function Deep(tbl: anyTable): anyTable
	local tCopy = table.create(#tbl)

	for k, v in pairs(tbl) do
		if type(v) == "table" then
			tCopy[k] = Deep(v)
		else
			tCopy[k] = v
		end
	end

	return tCopy
end

local Layout = {}
Layout.__index = Layout

export type Layout = typeof(setmetatable({} :: {
	pairTable: {
		[number]: {
			field: string,
			enum: number,
			size: number,
		}
	},

	totalBytes: number,
}, Layout))


function Layout.Add(self: Layout, field: string, enum: number)
	table.insert(self.pairTable, {
		size = module.Sizes[enum],
		field = field,
		enum = enum,
	})

	self:CalcSize()
end

function Layout.CalcSize(self: Layout)
	local totalBytes = 0

	for index, rec in self.pairTable do	
		rec.size = module.Sizes[rec.enum]
		totalBytes += rec.size
	end

	local numBytesForIndex = 2
	self.totalBytes = totalBytes + numBytesForIndex
end

function module.CreateLayout(self: Self): Layout
	return setmetatable({
		pairTable = {},
		totalBytes = 0,
	}, Layout)
end

function module.DeepCopy(self: Self, sourceTable: anyTable)
	return Deep(sourceTable)
end

function module.BinaryEncodeTable(self: Self, srcData: anyTable, layout: Layout)
	local newPacket = Deep(srcData)
	
	local buf = buffer.create(layout.totalBytes)
	local numBytesForIndex = 2
	local offset = numBytesForIndex 
	local contentBits = 0
	local bitIndex = 0
	
	for index, rec in layout.pairTable do
		local key = rec.field
		local encodeChar = rec.enum
		local srcValue: unknown = newPacket[key]
		
		if (encodeChar == module.Enum.INT32) then
			if (type(srcValue) == "number" and srcValue ~= 0) then
				buffer.writei32(buf, offset, srcValue)
				offset += rec.size
				contentBits = bit32.bor(contentBits, bit32.lshift(1, bitIndex))
			end
		elseif (encodeChar == module.Enum.FLOAT) then
			if (type(srcValue) == "number" and srcValue ~= 0) then
				buffer.writef32(buf, offset, srcValue)
				offset += rec.size
				contentBits = bit32.bor(contentBits, bit32.lshift(1, bitIndex))
			end
		elseif (encodeChar == module.Enum.UBYTE) then
			if (type(srcValue) == "number" and srcValue ~= 0) then
				buffer.writeu8(buf, offset, srcValue)
				offset += rec.size
				contentBits = bit32.bor(contentBits, bit32.lshift(1, bitIndex))
			end
		elseif (encodeChar == module.Enum.VECTOR3) then
			if (typeof(srcValue) == "Vector3" and srcValue.Magnitude > 0) then
				buffer.writef32(buf, offset, srcValue.X)
				offset += 4
				buffer.writef32(buf, offset, srcValue.Y)
				offset += 4
				buffer.writef32(buf, offset, srcValue.Z)
				offset += 4
				contentBits = bit32.bor(contentBits, bit32.lshift(1, bitIndex))
			end
		end
		
		newPacket[key] = nil

		bitIndex += 1
	end

	--Write the contents
	buffer.writeu16(buf, 0, contentBits)

	--Copy it to a new buffer
	local finalBuffer = buffer.create(offset)
	buffer.copy(finalBuffer, 0, buf, 0, offset)

	newPacket._b = finalBuffer
 
	--leave the other fields untouched
	return newPacket	
end
	

function module.BinaryDecodeTable(self: Self, srcData: anyTable, layout: Layout)
	local command = Deep(srcData)
	assert(command._b, "missing _b field")
	
	local buf: buffer? = command._b
	command._b = nil

	local offset = 0
	assert(type(buf) == "buffer", "_b should be a buffer!")

	local contentBits = buffer.readu16(buf, 0)
	offset+=2

	local bitIndex = 0
	
	for index, rec in layout.pairTable do
		local key = rec.field
		local encodeChar = rec.enum
		local hasBit = bit32.band(contentBits, bit32.lshift(1, bitIndex)) > 0
		
		if (hasBit == false) then
			if (encodeChar == module.Enum.INT32) then
				command[key] = 0
			elseif (encodeChar == module.Enum.FLOAT) then
				command[key] = 0
			elseif (encodeChar == module.Enum.UBYTE) then
				command[key] = 0
			elseif (encodeChar == module.Enum.VECTOR3) then
				command[key] = Vector3.zero
			end
		else
			if (encodeChar == module.Enum.INT32) then
				command[key] = buffer.readi32(buf,offset)
				offset+=rec.size
			elseif (encodeChar == module.Enum.FLOAT) then
				command[key] = buffer.readf32(buf,offset)
				offset+=rec.size
			elseif (encodeChar == module.Enum.UBYTE) then
				command[key] = buffer.readu8(buf,offset)
				offset+=rec.size
			elseif (encodeChar == module.Enum.VECTOR3) then
				local x = buffer.readf32(buf,offset)
				offset+=4
				local y = buffer.readf32(buf,offset)
				offset+=4
				local z = buffer.readf32(buf,offset)
				offset+=4
				command[key] = Vector3.new(x,y,z)
			end
		end
		bitIndex+=1
	end
	return command
end

return module