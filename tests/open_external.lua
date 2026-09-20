-- Run from the repository root:
-- nvim --headless -u NONE -l tests/open_external.lua
vim.opt.runtimepath:prepend(vim.fn.getcwd())

local util = require("neowiki.util")
local original_open, original_notify, original_cmd = vim.ui.open, vim.notify, vim.cmd
local calls, notifications
local passed = 0

local function equal(expected, actual)
  assert(vim.deep_equal(expected, actual), vim.inspect({ expected = expected, actual = actual }))
end

local function test(name, run)
  calls, notifications = {}, {}
  vim.ui.open = function(url)
    calls[#calls + 1] = url
    return {}
  end
  vim.notify = function(message, level, opts)
    notifications[#notifications + 1] = { message = message, level = level, opts = opts }
  end
  vim.cmd = function()
    error("open_external must not execute an Ex command")
  end
  local ok, err = pcall(run)
  assert(ok, name .. ": " .. tostring(err))
  passed = passed + 1
end

local ok, err = pcall(function()
  local unchanged = {
    "https://example.com/releases/hello!world",
    "https://example.com/search?q=hello!world&lang=en",
    "https://example.com/#!/notes/intro",
    "https://example.com/a%20dir/test.txt#section-2",
    "https://example.com/search?q=don't&value=$HOME;still-data",
    "/tmp/a dir/notes!100%.pdf",
    "C:\\Users\\Example\\My Documents\\notes!100%.pdf",
  }
  for _, url in ipairs(unchanged) do
    test("preserves " .. url, function()
      util.open_external(url)
      equal({ url }, calls)
      equal({ {
        message = "Opening in external app: " .. url,
        level = vim.log.levels.INFO,
        opts = { title = "neowiki" },
      } }, notifications)
    end)
  end

  test("encodes only literal web URL spaces", function()
    util.open_external("https://example.com/a dir/already%20encoded?q=hello world#part!")
    equal({ "https://example.com/a%20dir/already%20encoded?q=hello%20world#part!" }, calls)
  end)

  test("ignores nil and empty input", function()
    util.open_external(nil)
    util.open_external("")
    equal({}, calls)
    equal({}, notifications)
  end)

  test("reports a missing handler without a success notification", function()
    vim.ui.open = function()
      return nil, "no handler found"
    end
    util.open_external("https://example.com/")
    equal({ {
      message = "Failed to open external link: no handler found",
      level = vim.log.levels.ERROR,
      opts = { title = "neowiki" },
    } }, notifications)
  end)

  test("reports a process creation exception", function()
    vim.ui.open = function()
      error("spawn failed", 0)
    end
    util.open_external("https://example.com/")
    equal({ {
      message = "Failed to open external link: spawn failed",
      level = vim.log.levels.ERROR,
      opts = { title = "neowiki" },
    } }, notifications)
  end)
end)

vim.ui.open, vim.notify, vim.cmd = original_open, original_notify, original_cmd
if not ok then
  io.stderr:write(tostring(err) .. "\n")
  vim.cmd("cquit 1")
end
print(string.format("PASS: %d open_external tests", passed))
