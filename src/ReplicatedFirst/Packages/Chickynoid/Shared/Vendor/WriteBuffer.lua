local module = {}
module.__index = module

export type Class = typeof(setmetatable({} :: {
	offset: number,
	currentSize: number,
	startSize: number,
	stepSize: number,
	buf: buffer,
}, module))

function module.new(startSize: number?)
	local buf = buffer.create(math.max(startSize or 0, 0))
	
	local self = setmetatable({
		offset = 0,
		currentSize = buffer.len(buf),
		startSize = math.max(startSize or 0, 0),
		stepSize = 128,
		buf = buf,
	}, module)

	return self
end

function module.GetBuffer(self: Class)
	if (buffer.len(self.buf) == self.offset) then
		return self.buf
	end
	
	local finalBuffer = buffer.create(self.offset)
	self.currentSize = self.offset
	
	buffer.copy(finalBuffer, 0, self.buf, 0, self.offset)
	self.buf = finalBuffer

	return finalBuffer
end

function module.CheckSize(self: Class, add: number)
	local checkSize = self.offset + add

	if checkSize > self.currentSize then
		self.currentSize += math.max(self.stepSize, add)

		local newBuf = buffer.create(self.currentSize)
		buffer.copy(newBuf, 0, self.buf,0, self.offset)

		self.buf = newBuf
	end
end

function module.WriteU8(self: Class, byte: number)
	self:CheckSize(1)
	buffer.writeu8(self.buf, self.offset, byte)
	self.offset += 1
end

function module.WriteI16(self: Class, u16: number)
	self:CheckSize(2)
	buffer.writeu16(self.buf, self.offset, u16)
	self.offset += 2
end

function module.WriteVector3(self: Class, vec: Vector3)
	self:CheckSize(12)
	buffer.writef32(self.buf, self.offset, vec.X)
	self.offset += 4
	buffer.writef32(self.buf, self.offset, vec.Y)
	self.offset += 4
	buffer.writef32(self.buf, self.offset, vec.Z)
	self.offset += 4
end

function module.WriteFloat16(self: Class, value: number)  
	self:CheckSize(2)
	local sign = value < 0
	value = math.abs(value)

	local mantissa, exponent = math.frexp(value)

	if value == math.huge then
		if sign then
			buffer.writeu8(self.buf, self.offset, 252)-- 11111100
			self.offset += 1
		else
			buffer.writeu8(self.buf, self.offset, 124) -- 01111100
			self.offset += 1
		end

		buffer.writeu8(self.buf, self.offset, 0) -- 00000000
		self.offset += 1

		return
	elseif value ~= value or value == 0 then
		buffer.writeu8(self.buf, self.offset, 0)
		self.offset += 1
		
		buffer.writeu8(self.buf, self.offset, 0)
		self.offset += 1

		return
	elseif exponent + 15 <= 1 then -- Bias for halfs is 15
		mantissa = math.floor(mantissa * 1024 + 0.5)

		if sign then
			buffer.writeu8(self.buf, self.offset, (128 + bit32.rshift(mantissa, 8))) -- Sign bit, 5 empty bits, 2 from mantissa
			self.offset += 1
		else
			buffer.writeu8(self.buf, self.offset, (bit32.rshift(mantissa, 8)))
			self.offset += 1
		end

		buffer.writeu8(self.buf, self.offset, bit32.band(mantissa, 255)) -- Get last 8 bits from mantissa
		self.offset += 1
		
		return
	end

	mantissa = math.floor((mantissa - 0.5) * 2048 + 0.5)

	-- The bias for halfs is 15, 15-1 is 14
	if sign then
		buffer.writeu8(self.buf, self.offset, (128 + bit32.lshift(exponent + 14, 2) + bit32.rshift(mantissa, 8)))
		self.offset += 1
	else
		buffer.writeu8(self.buf, self.offset, (bit32.lshift(exponent + 14, 2) + bit32.rshift(mantissa, 8)))
		self.offset += 1
	end

	buffer.writeu8(self.buf, self.offset, bit32.band(mantissa, 255))
	self.offset += 1
end
 
return module