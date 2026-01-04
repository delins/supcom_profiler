--- - Function call profiler code for Supreme Commander Forged Alliance. 
--- - Tested with LOUD, may require minor modifications for use with FAF, not tested.
--- - Append the code in this file to LOUD/gamedata/lua/lua/simInit.lua
--- - Toggle the profiler with either the hotkeys (see `SetupSession` below) or schedule it to run at
---   a given time (see `ScheduleProfiler` below).
--- - The report is printed to the standard log file. Use the python package in this repo to prepare
---   the logged output to be imported into https://www.speedscope.app/ for analysis.


--- Initialize state object for either the main thread or coroutines.
local function initializeState()
    return {
        stack = {},
        isFirstTime = true,
        resumed = false,
        currentInfoBuffer = {}
    }
end

--- Table that collects all metrics.
local metrics = {}
local mainState = nil

--- A state just like mainState's is created on demand for each thread we see, and pushed in 
--- coroutineStates by thread id.
local coroutineStates = nil

--- Yielding functions
--- While `WaitSeconds` is used for yielding, it just wraps `WaitTicks` which is the actual yielding
--- function. So we don't include `WaitSeconds` here.
local yielding = {
    [coroutine.yield] = true,
    [WaitTicks] = true,
    [WaitFor] = true,
    [SuspendCurrentThread] = true,
}

--- Functions that we don't want to include in profiling. Any calls to these are skipped.
local blackListed

local getinfo = debug.getinfo
local getSimTime = GetSystemTimeSecondsOnlyForProfileUse
local isProfiling = false

--- The length of what comes before `/gamedata` - not used atm. The main use case would be to 
--- minimize the key length and therefore speed up the profiler, and writing the report.
local pathPrefixLength = 0


local function createFrame(info)
    -- This commented out code would be used in conjuction with pathPrefixLength - not used atm
    --local path = nil
    --if info.source then
    --    path = string.sub(info.source, pathPrefixLength)
    --end
    return {info.source, info.linedefined, info.name, info.currentline, info.func}
end


--- String formats a single frame
local function headKey(frame)
    return (frame[1] or "?")..","..(frame[2] or -1)..","..(frame[3] or "?")..","..(frame[4] or -1)
end


--- String formats an array of stack tuples
local function tailKey(stack)
    local formattedFrames = {}

    for k, stackItem in stack do
        local frame = stackItem.frame
        local fmt = (frame[1] or "?")..","..(frame[2] or -1)..","..(frame[3] or "?")..","..(frame[4] or -1)

        table.insert(formattedFrames, fmt)
    end

    return table.concat(formattedFrames, ";")
end


--- Gets the state for this thread or creates a new one.
local function getCoroutineState(thread)
    local coState = coroutineStates[thread]
    if not coState then
        coState = initializeState()
        coroutineStates[thread] = coState
    end

    return coState
end


local function reverseTable(t)
    local length = table.getn(t)
    local i = 1
    while i < length do
        t[i], t[length] = t[length], t[i]
        i = i + 1
        length = length - 1
    end
end


--- Used with return events.
local function popStack(state, currentTime, currentFrame, fromCoroutine)
    local getn = table.getn

    local topItem = table.remove(state.stack)
    local timestamp = topItem.callTime
    local correction = topItem.durationCorrection

    local duration

    if yielding[currentFrame[5]] then
        -- We discard the yielding function's duration entirely.
        correction = currentTime - timestamp
        duration = 0
    else
        duration = currentTime - timestamp - correction
    end

    local key = headKey(currentFrame)
    if getn(state.stack) > 0 then
        key = tailKey(state.stack)..";"..key
    end

    local accumulated = metrics[key]
    if not accumulated then
        accumulated = {0, 0, 0, false, false}
        metrics[key] = accumulated
    end

    accumulated[1] = accumulated[1] + 1
    accumulated[3] = accumulated[3] + duration
    if fromCoroutine then
        accumulated[5] = true
    else
        accumulated[4] = true
    end

    local depth = getn(state.stack)
    if depth > 0 then
        local parentItem = state.stack[depth]
        parentItem.durationCorrection = parentItem.durationCorrection + correction
        return false
    else
        return true
    end
end


--[[ Some code used for debugging.
local allThreadState = {}


local trackState = function(action, identifier)
    if not allThreadState[identifier] and table.getn(allThreadState) >= 10 then return end
    local myinsert = table.insert

    local newState = {}
    local level = 3
    while true do
        local info = getinfo(level, "Sfnl")
        if not info then
            break
        end

        table.insert(newState, info)
        level = level + 1
    end

    local statePerIdentifier = allThreadState[identifier]
    if not statePerIdentifier then
        statePerIdentifier = {}
        allThreadState[identifier] = statePerIdentifier
    end
    myinsert(statePerIdentifier, {action, newState})
end


local printTracked = function()
    for identifier, statePerIdentifier in allThreadState do
        LOG(identifier)
        for k,item in statePerIdentifier do
            local action = item[1]
            local stack = item[2]
            LOG("    "..action)
            for _,info in stack do
                LOG("        "..headKey(createFrame(info)))
            end
            LOG(" ")
        end
    end
end


local messagecounter = {}


local function printCallStack(action, identifier)
    local currentCount = messagecounter[identifier] or 0

    local level = 3
    while true do
        local info = getinfo(level, "Sfnl")
        if not info then
            break
        end

        LOG(identifier.." "..currentCount.." "..action.." "..headKey(createFrame(info)))
        level = level + 1
    end

    messagecounter[identifier] = currentCount + 1
end
]]


-- Shared hook handler between the main thread and coroutines.
local hook = function(action)
    local getinfo = debug.getinfo
    local getn = table.getn
    local insert = table.insert
    local CurrentThread = CurrentThread

    local success, currentThread = pcall(CurrentThread)

    local formattedThread
    if success then
        formattedThread = tostring(currentThread)
    else
        formattedThread = "main"
    end

    -- Used for debugging in conjuction with the commented out functions above.
    --trackState(action, formattedThread)
    --printCallStack(action, formattedThread)

    -- Get the head.
    local currentInfo = getinfo(2, "Sfnl")
    if blackListed[currentInfo.func] or not currentInfo then
        return
    end

    local currentFrame = createFrame(currentInfo)

    -- Get state related info.
    local state = nil
    if success then
        if currentThread then
            state = getCoroutineState(currentThread)
        else
            LOG("CurrentThread didn't throw an error yet it returned nil")
            return
        end
    else
        state = mainState
    end

    local currentTime = getSimTime()

    -- The first time we see the main thread or coroutine we may be barging in while it's already
    -- some layers deep in its callstack, and we have to catch up. We do the cath up here. We also
    -- end up in this code if a coroutine was spawned after we started profiling, but that doesn't
    -- matter for correctness.
    if state.isFirstTime then
        local level = 3
        local depth = 1
        while true do
            local parentInfo = getinfo(level, "Sfnl")
            if not parentInfo then
                break
            end

            local parentFrame = createFrame(parentInfo)
            local item = {
                frame = parentFrame,
                callTime = currentTime,
                durationCorrection = 0,
                isTailReturn = false
            }
            insert(state.stack, item)
            level = level + 1
            depth = depth + 1
        end

        reverseTable(state.stack)

        -- If we're processing a call event the `if call` block below will increment our depth.
        -- Otherwise we have to compensate for the fact that we missed the call event.
        if action != "call" then
            local item = {
                frame = currentFrame,
                callTime = currentTime,
                durationCorrection = 0,
                isTailReturn = false
            }
            insert(state.stack, item)
        end

        state.isFirstTime = false
    end

    local depth = getn(state.stack)

    if action == "call" then
        if state.resumed then
            state.resumed = false
        else
            depth = depth + 1
            item = {
                frame = currentFrame,
                callTime = currentTime,
                durationCorrection = 0,
                isTailReturn = false
            }
            insert(state.stack, item)

            if depth > 1 then
                local stackParentItem = state.stack[depth - 1]
                local parentInfo = getinfo(3, "Sfnl")

                -- We usually have a parent, in the obvious case. Sometimes though, probably
                -- because of a tail call where our parent was also the root, the parent frame just
                -- vanishes. There will be a tail return for it in the future though. We used to 
                -- keep track of the "real" stack depth, but it doesn't seem to be necessary so I 
                -- removed it for now.
                if parentInfo then
                    if parentInfo.source == "=(tail call)" then
                        -- Our little hack to communicate that the the available returnline of our
                        -- parent isn't where we were called, but its at least close usually.
                        stackParentItem.frame[4] = -stackParentItem.frame[4]
                        stackParentItem.isTailReturn = true
                    else
                        stackParentItem.frame = createFrame(parentInfo)
                    end
                else
                    stackParentItem.isTailReturn = true
                end
            end
        end
    else -- "return" and "tail return"
        local topItem = state.stack[getn(state.stack)]
        local frameToUse
        if topItem.isTailReturn then
            frameToUse = topItem.frame
        else
            frameToUse = currentFrame
        end

        local isNowEmpty = popStack(state, currentTime, frameToUse, success)

        if yielding[currentInfo.func] then
            state.resumed = true
        end

        -- I don't think state.resumed will ever happen at this point, since it would mean that a
        -- yielding function was the top level function called. But who knows.
        if getn(state.stack) == 0 and success then
            coroutineStates[currentThread] = nil
        end
    end

end


local function flushBuffer(state, currentTime, fromCoroutine)
    local length = table.getn(state.stack)

    for i = length, 1, -1 do
        popStack(state, currentTime, state.stack[i].frame, fromCoroutine)
    end

end


local function flushBuffers()
    local currentTime = getSimTime()

    flushBuffer(mainState, currentTime, false)

    for _, state in pairs(coroutineStates) do
        flushBuffer(state, currentTime, true)
    end
end


local function printProfileResults()
    LOG("Printing profiler data")
    
    -- Sort by duration in ascending order.
    local keys = table.keys(metrics, function(a, b)
        return metrics[a][3] < metrics[b][3]
    end)

    for _, key in keys do
        local acc = metrics[key]
        -- acc[2] used to be ticks, but we're not recording it atm.
        LOG("prof: "..key..";"..acc[1]..","..acc[3]..","..(acc[4] and "t" or "f")..","..(acc[5] and "t" or "f"))
    end
end


function TurnOnProfiler()
    if not isProfiling then
        LOG("Starting profiler")

        metrics = {}
        mainState = initializeState()
        coroutineStates = {}

        local outPath = debug.getinfo(1, "S").source
        pathPrefixLength = string.len(outPath) - 29 + 1

        -- In contrast to what some online sourecs say, this also hooks functions in coroutines,
        -- both started and new ones it seems.
        debug.sethook(hook, 'cr')
        isProfiling = true
    end
end


function TurnOffProfiler()
    if isProfiling then
        LOG("Stopping profiler")

        debug.sethook()
        isProfiling = false

        flushBuffers()
        printProfileResults()
    end
end


local baseSetupSession = SetupSession
function SetupSession()
    baseSetupSession()

    WARN('Profiler: To activate UI Profiler press CTRL-O')
    WARN('          To deactivate:          press CTRL-P')
    WARN('Note that to enable the profiler ingame using the hotkeys, cheats have to be enabled.')
    SimConExecute('IN_BindKey CTRL-O SimLua TurnOnProfiler()')
    SimConExecute('IN_BindKey CTRL-P SimLua TurnOffProfiler()')
end


blackListed = {
    [debug.sethook] = true,
    [TurnOnProfiler] = true,
    [TurnOffProfiler] = true,
}


--- Schedules the profiler to run at some designated time and for some duration. 
--- No cheats need to be enabled.
function ScheduleProfiler(from, duration)
    LOG("Scheduled to profiler to run at "..from.."s")
    WaitSeconds(from)
    TurnOnProfiler()
    WaitSeconds(duration)
    TurnOffProfiler()
end


--- Records wallclock time starting at `from` ingame seconds till `duration` ingame seconds later.
--- Good to get a rough idea of how some block of ingame time performed.
function ScheduleBenchmark(from, duration)
    WaitSeconds(from)
    startTime = getSimTime()
    WaitSeconds(duration)
    endTime = getSimTime()
    difference = endTime - startTime
    LOG("benchmark started at: "..from.."s, duration: "..duration.."s, measured wallclock time: "..difference.."s")
end


ForkThread(ScheduleProfiler, 1 * 60, 60)


-- Note: a benchmark started at 0 gives bad results.
ForkThread(ScheduleBenchmark, 10 * 60, 10 * 60)
ForkThread(ScheduleBenchmark, 20 * 60, 10 * 60)
ForkThread(ScheduleBenchmark, 30 * 60, 10 * 60)
ForkThread(ScheduleBenchmark, 40 * 60, 10 * 60)
ForkThread(ScheduleBenchmark, 50 * 60, 10 * 60)
ForkThread(ScheduleBenchmark, 60 * 60, 10 * 60)

