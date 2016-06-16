local coroutine = require "taggedcoro"

local ex = { TAG = "exception" }

local function trycatchk(cblk, co, dead, ...)
  if dead then
    return ...
  else
    local resume = function (v)
      return trycatchk(cblk, co, co(v))
    end
    local co, e = ...
    local traceback = function (msg)
      return ex.traceback(co, msg)
    end
    return cblk(e, traceback, resume)
  end
end

function ex.trycatch(tblk, cblk)
  local co = coroutine.wrap(function ()
    return true, tblk()
  end, ex.TAG)
  return trycatchk(cblk, co, co())
end

function ex.throw(e)
  return coroutine.yield(ex.TAG, false, coroutine.running(), e)
end

function ex.traceback(co, msg)
  local tb = { msg, "stack traceback:" }
  while co do
    tb[#tb+1] = debug.traceback(co):gsub("^stack traceback:\n", "")
    co = coroutine.caller(co)
  end
  return table.concat(tb, "\n")
end

return ex
