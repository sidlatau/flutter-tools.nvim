local jobstart = vim.fn.jobstart
local jobstop = vim.fn.jobstop
local chansend = vim.fn.chansend

---@class Job
---@field id integer
---@field cmd string
---@field cwd string
---@field env table
---@field result string[]
---@field detach boolean
---@field on_stdout fun(self: Job, data: string):nil
---@field on_stderr fun(self: Job, data: string):nil
---@field on_exit fun(result: string[]):nil
---@field private __process_result fun(id: integer, data: string[], name: string): table
---@field private __make_args fun(overrides: table): table
---@field private __is_alive fun(): boolean
---@field private __set_status fun(status: integer): nil
local Job = {}

local status = {
  ALIVE = 0,
  DEAD = 1
}

function Job:__make_args(overrides)
  return {
    cwd = overrides.cwd or self.cwd,
    env = overrides.env or self.env,
    detach = overrides.detach or self.detach,
    stdout_buffered = overrides.stdout_buffered,
    stderr_buffered = overrides.stderr_buffered,
    on_stdout = function(id, data, name)
      self:__process_result(id, data, name)
    end,
    on_stderr = function(id, data, name)
      self:__process_result(id, data, name)
    end,
    on_exit = function(_, code, _)
      if self.on_exit then
        self.on_exit(code ~= 0, self.result)
        self:__set_status(status.DEAD)
      end
    end
  }
end

---Create a new Job
---@param o table
---@return Job
function Job:new(o)
  o = o or {}
  setmetatable(o, self)
  self.result = {""}
  self:__set_status(status.ALIVE)
  self.__index = self
  return o
end

function Job:__is_alive()
  return self.status ~= status.DEAD
end

---Set the state of a Job
function Job:__set_status(s)
  self.status = s
end

function Job:close()
  if self.id and self:__is_alive() then
    jobstop(self.id)
    self:__set_status(status.DEAD)
  end
end

---Check if this is the end of the output
---@param data string[]
---@return boolean
local function is_EOF(data)
  return #data == 1 and data[1] == ""
end

--[[
Stream event handlers receive data as it becomes available from the OS,
thus the first and last items in the {data} list may be partial lines.
Empty string completes the previous partial line. Examples (not including
  the final `['']` emitted at EOF):
    - `foobar` may arrive as `['fo'], ['obar']`
    - `foo\nbar` may arrive as
      `['foo','bar']`
      or `['foo',''], ['bar']`
      or `['foo'], ['','bar']`
      or `['fo'], ['o','bar']`

There are two ways to deal with this:
1. To wait for the entire output, use |channel-buffered| mode.
2. To read line-by-line, use the following code: >

    let s:lines = ['']
    func! s:on_event(job_id, data, event) dict
      let eof = (a:data == [''])
      " Complete the previous line.
      let s:lines[-1] .= a:data[0]
      " Append (last item may be a partial line, until EOF).
      call extend(s:lines, a:data[1:])
    endf
--]]
---Convert the table of results into a series of calls to on
---stderr or stdout with only a single line
function Job:__process_result(_, data, name)
  if data and type(data) == "table" then
    if is_EOF(data) then
      return
    end
    if data[#data] == "" then
      data[#data] = nil
    end
    if data[1] then
      self.result[#self.result] = self.result[#self.result] .. data[1]
    end
    vim.list_extend(self.result, data, 2)
    local last_line = self.result[#self.result]
    if last_line then
      if name == "stdout" and self.on_stdout then
        self:on_stdout(last_line)
      elseif name == "stderr" and self.on_stderr then
        self:on_stderr(last_line)
      end
    end
  end
end

function Job:send(cmd)
  if self.id then
    chansend(self.id, cmd)
  end
end

function Job:sync()
  self.id = jobstart(self.cmd, self:__make_args({stdout_buffered = true, stderr_buffered = true}))
  return self
end

function Job:start()
  self.id = jobstart(self.cmd, self:__make_args(self))
  return self
end

return Job
