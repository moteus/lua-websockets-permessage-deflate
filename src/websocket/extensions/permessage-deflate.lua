------------------------------------------------------------------
--
--  Author: Alexey Melnichuk <alexeymelnichuck@gmail.com>
--
--  Copyright (C) 2015-2016 Alexey Melnichuk <alexeymelnichuck@gmail.com>
--
--  Licensed according to the included 'LICENSE' document
--
--  This file is part of lua-websockets-permessage-deflate library.
--
------------------------------------------------------------------

local zlib = require 'zlib'

------------------------------------------------------------------
-- export from lluv.utils
local function class(base)
  local t = base and setmetatable({}, base) or {}
  t.__index = t
  t.__class = t
  t.__base  = base

  function t.new(...)
    local o = setmetatable({}, t)
    if o.__init then
      if t == ... then -- we call as Class:new()
        return o:__init(select(2, ...))
      else             -- we call as Class.new()
        return o:__init(...)
      end
    end
    return o
  end

  return t
end
------------------------------------------------------------------

-------------------------------------------------------------------
-- export from lluv.utils
local List = class() do

function List:reset()
  self._first = 0
  self._last  = -1
  self._t     = {}
  return self
end

List.__init = List.reset

function List:push_front(v)
  assert(v ~= nil)
  local first = self._first - 1
  self._first, self._t[first] = first, v
  return self
end

function List:push_back(v)
  assert(v ~= nil)
  local last = self._last + 1
  self._last, self._t[last] = last, v
  return self
end

function List:peek_front()
  return self._t[self._first]
end

function List:peek_back()
  return self._t[self._last]
end

function List:pop_front()
  local first = self._first
  if first > self._last then return end

  local value = self._t[first]
  self._first, self._t[first] = first + 1

  return value
end

function List:pop_back()
  local last = self._last
  if self._first > last then return end

  local value = self._t[last]
  self._last, self._t[last] = last - 1

  return value
end

function List:size()
  return self._last - self._first + 1
end

function List:empty()
  return self._first > self._last
end

function List:find(fn, pos)
  pos = pos or 1
  if type(fn) == "function" then
    for i = self._first + pos - 1, self._last do
      local n = i - self._first + 1
      if fn(self._t[i]) then
        return n, self._t[i]
      end
    end
  else
    for i = self._first + pos - 1, self._last do
      local n = i - self._first + 1
      if fn == self._t[i] then
        return n, self._t[i]
      end
    end
  end
end

end
-------------------------------------------------------------------

-------------------------------------------------------------------
-- export from lluv.utils
local Buffer = class() do

-- eol should ends with specific char.

function Buffer:__init(eol, eol_is_rex)
  self._eol       = eol or "\n"
  self._eol_plain = not eol_is_rex
  self._lst = List.new()
  return self
end

function Buffer:reset()
  self._lst:reset()
  return self
end

function Buffer:eol()
  return self._eol, self._eol_plain
end

function Buffer:set_eol(eol, eol_is_rex)
  self._eol       = assert(eol)
  self._eol_plain = not eol_is_rex
  return self
end

function Buffer:append(data)
  if #data > 0 then
    self._lst:push_back(data)
  end
  return self
end

function Buffer:prepend(data)
  if #data > 0 then
    self._lst:push_front(data)
  end
  return self
end

function Buffer:read_line(eol, eol_is_rex)
  local plain

  if eol then plain = not eol_is_rex
  else eol, plain = self._eol, self._eol_plain end

  local lst = self._lst

  local ch = eol:sub(-1)
  local check = function(s) return not not string.find(s, ch, nil, true) end

  local t = {}
  while true do
    local i = self._lst:find(check)

    if not i then
      if #t > 0 then lst:push_front(table.concat(t)) end
      return
    end

    assert(i > 0)

    for i = i, 1, -1 do t[#t + 1] = lst:pop_front() end

    local line, tail

    -- try find EOL in last chunk
    if plain or (eol == ch) then line, tail = split_first(t[#t], eol, true) end

    if eol == ch then assert(tail) end

    if tail then -- we found EOL
      -- we can split just last chunk and concat
      t[#t] = line

      if #tail > 0 then lst:push_front(tail) end

      return table.concat(t)
    end

    -- we need concat whole string and then split
    -- for eol like `\r\n` this may not work well but for most cases it should work well
    -- e.g. for LuaSockets pattern `\r*\n` it work with one iteration but still we need
    -- concat->split because of case such {"aaa\r", "\n"}

    line, tail = split_first(table.concat(t), eol, plain)

    if tail then -- we found EOL
      if #tail > 0 then lst:push_front(tail) end
      return line
    end
  end
end

function Buffer:read_all()
  local t = {}
  local lst = self._lst
  while not lst:empty() do
    t[#t + 1] = self._lst:pop_front()
  end
  return table.concat(t)
end

function Buffer:read_some()
  if self._lst:empty() then return end
  return self._lst:pop_front()
end

function Buffer:read_n(n)
  n = math.floor(n)

  if n == 0 then
    if self._lst:empty() then return end
    return ""
  end

  local lst = self._lst
  local size, t = 0, {}

  while true do
    local chunk = lst:pop_front()

    if not chunk then -- buffer too small
      if #t > 0 then lst:push_front(table.concat(t)) end
      return
    end

    if (size + #chunk) >= n then
      assert(n > size)
      local pos = n - size
      local data = string.sub(chunk, 1, pos)
      if pos < #chunk then
        lst:push_front(string.sub(chunk, pos + 1))
      end

      t[#t + 1] = data
      return table.concat(t)
    end

    t[#t + 1] = chunk
    size = size + #chunk
  end
end

function Buffer:read(pat, ...)
  if not pat then return self:read_some() end

  if pat == "*l" then return self:read_line(...) end

  if pat == "*a" then return self:read_all() end

  return self:read_n(pat)
end

function Buffer:empty()
  return self._lst:empty()
end

function Buffer:next_line(data, eol)
  eol = eol or self._eol or "\n"
  if data then self:append(data) end
  return self:read_line(eol, true)
end

function Buffer:next_n(data, n)
  if data then self:append(data) end
  return self:read_n(n)
end

end
-------------------------------------------------------------------

------------------------------------------------------------------
local ZError = class() do

local ERRORS = {
  [ 1] = "STREAM_END";
  [ 2] = "NEED_DICT";
  [-1] = "ERRNO";
  [-2] = "STREAM_ERROR";
  [-3] = "DATA_ERROR";
  [-4] = "MEM_ERROR";
  [-5] = "BUF_ERROR";
  [-6] = "VERSION_ERROR";
}

for k, v in pairs(ERRORS) do ZError[v] = k end

function ZError:__init(no, name, msg, ext, code, reason)
  self._no     = assert(no)
  self._name   = assert(name or ERRORS[no])
  self._msg    = msg    or ''
  self._ext    = ext    or ''
  return self
end

function ZError:cat()    return 'ZLIB'       end

function ZError:no()     return self._no     end

function ZError:name()   return self._name   end

function ZError:msg()    return self._msg    end

function ZError:ext()    return self._ext    end

function ZError:__tostring()
  local fmt 
  if self._ext and #self._ext > 0 then
    fmt = "[%s][%s] %s (%d) - %s"
  else
    fmt = "[%s][%s] %s (%d)"
  end
  return string.format(fmt, self:cat(), self:name(), self:msg(), self:no(), self:ext())
end

function ZError:__eq(rhs)
  return self._no == rhs._no
end

end
------------------------------------------------------------------

------------------------------------------------------------------
-- zilb
local z do

local function zlib_name(zlib)
  if zlib._VERSION and string.find(zlib._VERSION, 'lua-zlib', nil, true) then
    return 'lua-zlib'
  end

  if zlib._VERSION and string.find(zlib._VERSION, 'lzlib', nil, true) then
    return 'lzlib'
  end
end

z = {
  _LIBNAME            = assert(zlib_name(zlib), 'Unsupported zlib Lua binding');

  DEFLATED            = zlib.DEFLATED            or  8;

  BEST_SPEED          = zlib.BEST_SPEED          or  1;
  BEST_COMPRESSION    = zlib.BEST_COMPRESSION    or  9;
  NO_COMPRESSION      = zlib.NO_COMPRESSION      or  0;
  DEFAULT_COMPRESSION = zlib.DEFAULT_COMPRESSION or -1;

  MAXIMUM_MEMLEVEL    = zlib.MAXIMUM_MEMLEVEL    or  9;
  MINIMUM_MEMLEVEL    = zlib.MINIMUM_MEMLEVEL    or  1;
  DEFAULT_MEMLEVEL    = zlib.DEFAULT_MEMLEVEL    or  8;

  MINIMUM_WINDOWBITS  = zlib.MINIMUM_WINDOWBITS  or  8;
  MAXIMUM_WINDOWBITS  = zlib.MAXIMUM_WINDOWBITS  or  15;
  DEFAULT_WINDOWBITS  = zlib.DEFAULT_WINDOWBITS  or  15;
  GZIP_WINDOWBITS     = zlib.GZIP_WINDOWBITS     or  16;
  RAW_WINDOWBITS      = zlib.RAW_WINDOWBITS      or  -1;

  DEFAULT_STRATEGY    = zlib.DEFAULT_STRATEGY    or  0;
  FILTERED            = zlib.FILTERED            or  1;
  HUFFMAN_ONLY        = zlib.HUFFMAN_ONLY        or  2;
  RLE                 = zlib.RLE                 or  3;
  FIXED               = zlib.FIXED               or  4;
}

if z._LIBNAME == 'lzlib' then

local InflateStream = class() do

local Buffer = class(Buffer) do

local base = Buffer.__base

function Buffer:read_some(n)
  local chunk = base.read_some(self)
  if n and chunk and #chunk > n then
    local tail
    chunk, tail = chunk:sub(1, n), chunk:sub(n+1)
    self:prepend(tail)
  end
  return chunk
end

end

function InflateStream:__init(windowBits)
  local buffer  = Buffer.new()
  local read    = function (size) return buffer:read_some(size) end
  self._buffer  = buffer
  self._inflate = zlib.inflate(read, windowBits)
  return self
end

function InflateStream:write(msg)
  self._buffer:append(msg)
  return self
end

function InflateStream:read(...)
  local ok, data = pcall(self._inflate.read, self._inflate, ...)
  if not ok then
    local no = string.match(data, "failed to decompress %[(%-?%d+)%]")
    if no then return nil, ZError.new(tonumber(no), nil, "failed to decompress") end
    return error(data)
  end
  return data
end

function InflateStream:close(...)
  return self._inflate:close(...)
end

end

local DeflateStream = class() do

function DeflateStream:__init(level, windowBits,  memLevel, strategy, dictionary)
  local buffer  = Buffer.new()
  local write   = function(msg) return buffer:append(msg) end
  self._buffer  = buffer
  self._deflate = zlib.deflate(write, level, z.DEFLATED, windowBits,  memLevel, strategy, dictionary)
  return self
end

function DeflateStream:write(msg)
  local data, err = self._deflate:write(msg)
  if not data then
    local no = string.match(err, "failed to compress %[(%-?%d+)%]")
    if no then return nil, ZError.new(tonumber(no), nil, "failed to compress") end
    return error(err)
  end
  return self
end

function DeflateStream:read(...)
  return self._buffer:read(...)
end

function DeflateStream:flush()
  return self._deflate:flush()
end

function DeflateStream:close(...)
  return self._deflate:close(...)
end

end

z.InflateStream = InflateStream

z.DeflateStream = DeflateStream

end

if z._LIBNAME == 'lua-zlib' then

local function decode_error(str)
  if string.find(str, "RequiresDictionary:",  nil, true) then
    return ZError.NEED_DICT
  end
  if string.find(str, "InternalError: no",    nil, true) then
    return ZError.BUF_ERROR
  end
  if string.find(str, "InternalError:",       nil, true) then
    return ZError.STREAM_ERROR
  end
  if string.find(str, "InvalidInput:",        nil, true) then
    return ZError.DATA_ERROR
  end
  if string.find(str, "OutOfMemory:",         nil, true) then
    return ZError.MEM_ERROR
  end
  if string.find(str, "IncompatibleLibrary:", nil, true) then
    return ZError.VERSION_ERROR
  end
  return ZError.ERRNO
end

local function zerror(str)
  return ZError.new(decode_error(str), nil, str)
end

local InflateStream = class() do

function InflateStream:__init(windowBits)
  self._buffer  = Buffer.new()
  self._inflate = zlib.inflate(windowBits)
  return self
end

function InflateStream:write(msg)
  local ok, chunk = pcall(self._inflate, msg)
  if not ok then return nil, zerror(chunk) end
  self._buffer:append(chunk)
  return self
end

function InflateStream:read(...)
  return self._buffer:read(...)
end

function InflateStream:close(...)
  return true
end

end

local DeflateStream = class() do

function DeflateStream:__init(level, windowBits)
  self._buffer  = Buffer.new()
  self._deflate = zlib.deflate(level, windowBits)
  return self
end

function DeflateStream:write(msg)
  local ok, chunk = pcall(self._deflate, msg)
  if not ok then return nil, zerror(chunk) end
  self._buffer:append(chunk)
  return self
end

function DeflateStream:read(...)
  return self._buffer:read(...)
end

function DeflateStream:flush()
  local ok, chunk = pcall(self._deflate, '', 'sync')
  if not ok then return nil, zerror(chunk) end
  self._buffer:append(chunk)
  return self
end

function DeflateStream:close(...)
  return true
end

end

z.InflateStream = InflateStream

z.DeflateStream = DeflateStream

end

local RawInflateStream = class(z.InflateStream) do

local inherit = RawInflateStream.__base

function RawInflateStream:__init(windowBits)
  windowBits = windowBits or z.DEFAULT_WINDOWBITS
  windowBits = windowBits * z.RAW_WINDOWBITS
  return inherit.__init(self, windowBits)
end

end

local RawDeflateStream = class(z.DeflateStream) do

local inherit = RawDeflateStream.__base

function RawDeflateStream:__init(level, windowBits, ...)
  windowBits = windowBits or z.DEFAULT_WINDOWBITS
  windowBits = windowBits * z.RAW_WINDOWBITS
  return inherit.__init(self, level, windowBits, ...)
end

end

z.RawInflateStream = RawInflateStream

z.RawDeflateStream = RawDeflateStream

end
------------------------------------------------------------------

------------------------------------------------------------------
local DError = class() do

local ERRORS = {
  [-2] = "EPARAM";
  [-3] = "DATA_ERROR";
  [-4] = "MEM_ERROR";
  [-5] = "BUF_ERROR";
  [-6] = "VERSION_ERROR";
}

for k, v in pairs(ERRORS) do DError[v] = k end

function DError:__init(no, name, msg, ext, code, reason)
  self._no     = assert(no)
  self._name   = assert(name or ERRORS[no])
  self._msg    = msg    or ''
  self._ext    = ext    or ''
  return self
end

function DError:cat()    return 'PMCE-DEFLATE' end

function DError:no()     return self._no       end

function DError:name()   return self._name     end

function DError:msg()    return self._msg      end

function DError:ext()    return self._ext      end

function DError:__tostring()
  local fmt 
  if self._ext and #self._ext > 0 then
    fmt = "[%s][%s] %s (%d) - %s"
  else
    fmt = "[%s][%s] %s (%d)"
  end
  return string.format(fmt, self:cat(), self:name(), self:msg(), self:no(), self:ext())
end

function DError:__eq(rhs)
  return self._no == rhs._no
end

end
------------------------------------------------------------------

------------------------------------------------------------------
local Deflate = class() do

Deflate.name = 'permessage-deflate';
Deflate.rsv1 = true;
Deflate.rsv2 = false;
Deflate.rsv3 = false;

local known_params = {
  server_no_context_takeover = true;
  client_no_context_takeover = true;
  client_max_window_bits     = true;
  server_max_window_bits     = true;
}

local function valid_window(bits)
  return bits and bits >= z.MINIMUM_WINDOWBITS and bits <= z.MAXIMUM_WINDOWBITS
end

local function valid_params(params, server)
  for k, v in pairs(params) do
    if not known_params[k] then
      local msg = "illegal extension parameter '" .. tostring(k) .. "' for extension 'permessage-deflate'"
      return nil, DError.new(DError.EPARAM, nil, msg, tostring(k))
    end

    -- does not support multiple values for any parameter
    if type(v) == 'table' then
      local msg = "multiple occurrence of extension parameter '" .. k .. "' for extension 'permessage-deflate'"
      return nil, DError.new(DError.EPARAM, nil, msg, k)
    end
  end

  local fmt = "illegal extension parameter value '%s' for parameter '%s' of extension 'permessage-deflate'"
  
  if params.server_no_context_takeover and params.server_no_context_takeover ~= true then
    local msg = string.format(fmt, tostring(params.server_no_context_takeover), 'server_no_context_takeover')
    return nil, DError.new(DError.EPARAM, nil, msg, 'server_no_context_takeover')
  end

  if params.client_no_context_takeover and params.client_no_context_takeover ~= true then
    local msg = string.format(fmt, tostring(params.client_no_context_takeover), 'client_no_context_takeover')
    return nil, DError.new(DError.EPARAM, nil, msg, 'client_no_context_takeover')
  end

  if server or params.server_max_window_bits ~= true then
    if params.server_max_window_bits and not valid_window(tonumber(params.server_max_window_bits)) then
      local msg = string.format(fmt, tostring(params.server_max_window_bits), 'server_max_window_bits')
      return nil, DError.new(DError.EPARAM, nil, msg, 'server_max_window_bits')
    end
  end

  if server or params.client_max_window_bits ~= true then
    if params.client_max_window_bits and not valid_window(tonumber(params.client_max_window_bits)) then
      local msg = string.format(fmt, tostring(params.client_max_window_bits), 'client_max_window_bits')
      return nil, DError.new(DError.EPARAM, nil, msg, 'client_max_window_bits')
    end
  end

  return true
end

function Deflate:__init(options)
  if options then
    local ok, err = valid_params(options, false)
    if not ok then return nil, err end
  end

  self._options = {
    level           = options and options.level        or z.DEFAULT_COMPRESSION;
    memLevel        = options and options.memLevel     or z.DEFAULT_MEMLEVEL;
    strategy        = options and options.strategy     or z.DEFAULT_STRATEGY;
    clientWindow    = options and options.client_max_window_bits;
    serverWindow    = options and options.server_max_window_bits;
    noClientContext = options and options.client_no_context_takeover;
    noServerContext = options and options.server_no_context_takeover; 
  }

  return self
end

function Deflate:offer()
  local offer = {}

  if self._options.noClientContext then
    offer.client_no_context_takeover = true
  end

  if self._options.clientWindow then
    offer.client_max_window_bits = self._options.clientWindow
  else
    offer.client_max_window_bits = true
  end

  if self._options.noServerContext then
    offer.server_no_context_takeover = true
  end

  if self._options.serverWindow then
    offer.server_max_window_bits = self._options.serverWindow
  end

  return offer
end

function Deflate:accept(params)
  local ok, param = valid_params(params, true)
  if not ok then return nil, param end

  params.client_max_window_bits = tonumber(params.client_max_window_bits)
  params.server_max_window_bits = tonumber(params.server_max_window_bits)

  -- server accept invalid client_max_window_bits 
  if self._options.clientWindow and params.client_max_window_bits then
    if self._options.clientWindow ~= true then
      if params.client_max_window_bits > self._options.clientWindow then
        local msg = string.format('offer client_max_window_bits: %d but server respnse: %d', 
          self._options.clientWindow, params.client_max_window_bits)
        return nil, DError.new(DError.EPARAM, nil, msg, 'client_max_window_bits')
      end
    end
  end

  -- we ask without context but server ignore this
  if self._options.noServerContext and not params.server_no_context_takeover then
    local msg = 'offer server_no_context_takeover but server does not accept it'
    return nil, DError.new(DError.EPARAM, nil, msg, 'server_no_context_takeover')
  end

  if self._options.serverWindow and self._options.serverWindow ~= true then
    if self._options.serverWindow ~= z.DEFAULT_WINDOWBITS and not params.server_max_window_bits then
      local msg = string.format('offer server_max_window_bits: %d but server does not accept it',
        self._options.serverWindow, params.server_max_window_bits)
      return nil, DError.new(DError.EPARAM, nil, msg, 'server_max_window_bits')
    end

    if self._options.serverWindow ~= z.DEFAULT_WINDOWBITS or params.server_max_window_bits then
      if params.server_max_window_bits > self._options.serverWindow then
        local msg = string.format('offer server_max_window_bits: %d but server respnse: %d',
          self._options.serverWindow, params.server_max_window_bits)
        return nil, DError.new(DError.EPARAM, nil, msg, 'server_max_window_bits')
      end
    end
  end

  self._options.deflateNoContext = self._options.noClientContext or params.client_no_context_takeover
  self._options.deflateWindow    = self._options.clientWindow or z.DEFAULT_WINDOWBITS
  if params.client_max_window_bits and params.client_max_window_bits < self._options.deflateWindow then
    self._options.deflateWindow = params.client_max_window_bits
  end

  self._options.inflateNoContext = params.server_no_context_takeover
  self._options.inflateWindow    = params.server_max_window_bits or z.DEFAULT_WINDOWBITS

  return true
end

function Deflate:response(params)
  params = params[1] and params or {params}
  for i = 1, #params do repeat
    local param = params[i]

    local ok, err = valid_params(param, false)
    if not ok then return nil, err end

    local client_max_window_bits = tonumber(param.client_max_window_bits)
    local server_max_window_bits = tonumber(param.server_max_window_bits)

    if param.server_no_context_takeover then
      if self._options.noServerContext == false then
        break
      end
    end
    local deflateNoContext = param.server_no_context_takeover or self._options.noServerContext

    if server_max_window_bits  then
      if self._options.serverWindow and server_max_window_bits > self._options.serverWindow then
        break
      end
    end
    local deflateWindow = server_max_window_bits or self._options.serverWindow or z.DEFAULT_WINDOWBITS

    if param.client_no_context_takeover then
      if self._options.noClientContext == false then
        break
      end
    end
    local inflateNoContext = param.client_no_context_takeover or self._options.noClientContext

    if client_max_window_bits then
      if self._options.clientWindow and client_max_window_bits > self._options.clientWindow then
        break
      end
    end
    local inflateWindow = client_max_window_bits or self._options.clientWindow or z.DEFAULT_WINDOWBITS

    -- Configure deflate object

    self._options.deflateNoContext = deflateNoContext
    self._options.deflateWindow    = deflateWindow
    self._options.inflateNoContext = inflateNoContext
    self._options.inflateWindow    = inflateWindow

    -- Build response

    local resp = {}
    if self._options.deflateNoContext then resp.server_no_context_takeover = true end

    if self._options.inflateNoContext then resp.client_no_context_takeover = true end

    if (self._options.deflateWindow ~= z.DEFAULT_WINDOWBITS) or param.server_max_window_bits then
      resp.server_max_window_bits = self._options.deflateWindow
    end

    if self._options.inflateWindow ~= z.DEFAULT_WINDOWBITS or param.client_max_window_bits then
      resp.client_max_window_bits = self._options.inflateWindow 
    end

    return resp
  until true end
end

function Deflate:encode(opcode, msg, fin)
  if not self._deflate then
    self._deflate = z.RawDeflateStream.new(
      self._options.level,
      self._options.deflateWindow,
      self._options.memLevel, self._options.strategy
    )
  end

  -- io.write("SEND: ", frame_name(opcode), ' ', tostring(fin), ' ', tostring(#msg), '/')

  local ok, err = self._deflate:write(msg)
  if not ok then return nil, err end
  if fin then
    ok, err = self._deflate:flush()
    if not ok then return nil, err end
  end

  local out, err = self._deflate:read('*a')
  if not out then return nil, err end

  if fin then out = out:sub(1, -5) end

  -- io.write(tostring(#out), '\n')

  if fin and self._options.deflateNoContext then
    -- print("CLOSE DEFLATE")
    self._deflate:close()
    self._deflate = nil
  end

  return out
end

function Deflate:decode(opcode, msg, fin)
  if not self._inflate then
    self._inflate = z.RawInflateStream.new(
      self._options.inflateWindow
    )
  end

  -- io.write("RECV: ", frame_name(opcode), ' ', tostring(fin), ' ', tostring(#msg), '/')

  local ok, err = self._inflate:write(msg)
  if not ok then return nil, err end

  if fin then
    ok, err = self._inflate:write('\000\000\255\255')
    if not ok then return nil, err end
  end

  local out, err = self._inflate:read('*a')
  if not out then return nil, err end

  -- io.write(tostring(#out), '\n')

  if fin and self._options.inflateNoContext then
    -- print("CLOSE INFLATE")
    self._inflate:close()
    self._inflate = nil
  end

  return out
end

end
------------------------------------------------------------------

local PermessageDeflate = {
  name   = Deflate.name;
  rsv1   = Deflate.rsv1;
  rsv2   = Deflate.rsv2;
  rsv3   = Deflate.rsv3;
  client = Deflate.new;
  server = Deflate.new;
}

return PermessageDeflate