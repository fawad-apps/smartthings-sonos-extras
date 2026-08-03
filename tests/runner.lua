-- Tiny test runner: no dependencies, exits non-zero on any failure so CI and
-- scripts/deploy.sh can gate on it.

local runner = { cases = {}, failures = 0, passed = 0 }

function runner.test(name, fn)
    table.insert(runner.cases, { name = name, fn = fn })
end

local function fail(msg)
    error({ assertion = msg }, 2)
end

function runner.eq(actual, expected, what)
    if actual ~= expected then
        fail(string.format("%s: expected %s, got %s",
            what or "value", tostring(expected), tostring(actual)))
    end
end

function runner.truthy(value, what)
    if not value then
        fail(string.format("%s: expected truthy, got %s", what or "value", tostring(value)))
    end
end

function runner.falsy(value, what)
    if value then
        fail(string.format("%s: expected falsy, got %s", what or "value", tostring(value)))
    end
end

function runner.matches(text, pattern, what)
    if type(text) ~= "string" or not text:match(pattern) then
        fail(string.format("%s: %s does not match %q", what or "value", tostring(text), pattern))
    end
end

function runner.run()
    for _, case in ipairs(runner.cases) do
        local ok, err = pcall(case.fn)
        if ok then
            runner.passed = runner.passed + 1
            print("  PASS  " .. case.name)
        else
            runner.failures = runner.failures + 1
            local msg = type(err) == "table" and err.assertion or tostring(err)
            print("  FAIL  " .. case.name)
            print("        " .. msg)
        end
    end
    print(string.format("\n%d passed, %d failed", runner.passed, runner.failures))
    if runner.failures > 0 then
        os.exit(1)
    end
end

return runner
