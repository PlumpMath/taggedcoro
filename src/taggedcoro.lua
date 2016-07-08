--
-- Pure Lua implementation
--

local coroutine = require "coroutine"
local create = coroutine.create
local resume = coroutine.resume
local yield = coroutine.yield
local status = coroutine.status
local running = coroutine.running
local isyieldable = coroutine.isyieldable or function ()
  -- approximates the behavior of Lua 5.3 isyieldable
  local _, ismain = running()
  return not ismain
end

local coros = setmetatable({}, { __mode = "k" })

coros[running()] = {} -- add main thread

local MARK = {}

local M = {}

local DEFAULT_TAG = "coroutine"

function M.create(tag, f)
  tag = tag or DEFAULT_TAG
  local co = create(f)
  local meta = { tag = tag }
  coros[co] = meta
  return co
end

local function yieldk(...)
  local mark, err = ...
  if mark == MARK then
    error(err, 2)
  else
    return ...
  end
end

function M.yield(tag, ...)
  tag = tag or DEFAULT_TAG
  return yieldk(yield(MARK, running(), tag, ...))
end

local callk

local function callkk(co, meta, ok, ...)
  meta.stacked = nil
  if ok then
    return callk(co, meta, resume(co, ...))
  else -- not yieldable
    return callk(co, meta, resume(co, MARK, ...))
  end
end

function callk(co, meta, ok, ...)
  if not ok then
    local err = ...
    if not meta.source then
      meta.source = co
    end
    local mrun = coros[running()]
    if mrun then mrun.source = meta.source end
    error(err, 0)
  end
  if status(co) == "dead" then
    return ...
  end
  local mark, source, tag = ...
  if mark ~= MARK then -- untagged yield
    if not isyieldable() then
      return callk(co, meta, resume(co, nil, "untagged coroutine not found"))
    elseif coros[running()] then -- parent is tagged, pass it along with "untagged" tag
      meta.stacked = true
      return callkk(co, meta, pcall(yield, MARK, running(), MARK, ...))
    else -- parent is untagged, pass it along as is
      meta.stacked = true
      return callkk(co, meta, pcall(yield, ...))
    end
  elseif tag == MARK then
    if not isyieldable() then
      return callk(co, meta, resume(co, nil, "untagged coroutine not found"))
    elseif coros[running()] then -- parent is tagged, pass it along
      meta.stacked = true
      return callkk(co, meta, pcall(yield, ...))
    else -- parent is untagged
      return callk(co, meta, pcall(yield, select(4, ...)))
    end
  elseif meta.tag ~= tag then
    if not isyieldable() then
      return callk(co, meta, resume(co, MARK, "coroutine for tag " .. tostring(tag) .. " not found"))
    elseif coros[running()] then -- parent is tagged, pass it along
      meta.stacked = true
      return callkk(co, meta, pcall(yield, ...))
    else -- parent is untagged
      return callk(co, meta, resume(co, MARK, "attempt to yield across untagged coroutine"))
    end
  end -- yield was for me, set source and return
  meta.source = source
  return select(4, ...)
end

function M.call(co, ...)
  if M.status(co) ~= "suspended" then
    error("attempt to resume " .. M.status(co) .. " coroutine")
  end
  local meta = coros[co]
  if meta then
    meta.source = nil
    meta.parent = running()
    meta.parent_isyieldable = isyieldable()
    return callk(co, meta, resume(co, ...))
  else
    error("cannot resume untagged coroutine")
  end
end

function M.resume(co, ...)
  return pcall(M.call, co, ...)
end

function M.status(co)
  if coros[co] and coros[co].stacked then
    return "stacked"
  else
    return status(co)
  end
end

function M.parent(co)
  return coros[co] and coros[co].parent
end

function M.tag(co)
  return coros[co] and coros[co].tag
end

function M.source(co)
  return coros[co] and coros[co].source
end

M.running = running

function M.isyieldable(tag)
  tag = tag or DEFAULT_TAG
  if not isyieldable() then
    return false
  end
  local co = running()
  while true do
    local meta = coros[co]
    if not meta then
      return false
    end
    if meta.tag == tag then
      return true
    end
    if not meta.parent_isyieldable then
      return false
    end
    co = meta.parent
    if not co then
      return false
    end
  end
end

function M.wrap(tag, f)
  local co
  if type(tag) == "thread" then
    co = tag
  else
    co = M.create(tag, f)
  end
  return function(...) return M.call(co, ...) end, co
end

local function auxtraceback(start, msg, level)
  local res = { msg }
  res[#res+1] = "stack traceback:"
  while start do
    res[#res+1] = debug.traceback(start, nil, level+1):match("^[^\n]*\n(.*)$")
    level = 1
    local mstart = coros[start]
    if not mstart then
      res[#res+1] = "\treached untagged coroutine, aborting traceback"
      break
    end
    start = mstart.parent
  end
  return table.concat(res, "\n")
end

function M.traceback(co, msg, level)
  if type(co) ~= "thread" then
    co, msg, level = running(), co, msg
  end
  msg = msg and tostring(msg)
  level = level or 1
  local start = M.source(co) or co
  return auxtraceback(start, msg, level)
end

function M.fortag(tag)
  return {
    running = running,
    create = function (f) return M.create(tag, f) end,
    yield = function (...)
      return M.yield(tag, ...)
    end,
    wrap = function (f)
      if type(f) == "thread" then
        return M.wrap(f)
      else
        return M.wrap(tag, f)
      end
    end,
    isyieldable = function () return M.isyieldable(tag) end,
    status = M.status,
    resume = M.resume,
    call = M.call,
    tag = M.tag,
    source = M.source,
    parent = M.parent,
    traceback = M.traceback
  }
end

function M.make(tag)
  tag = tag or {}
  return M.fortag(tag)
end

function M.install()
  debug.setmetatable(running(), {
    __index = {
      call = M.call,
      resume = M.resume,
      parent = M.parent,
      source = M.source,
      tag = M.tag,
      status = M.status
    },
    __call = M.call
  })
  return M
end

return M
