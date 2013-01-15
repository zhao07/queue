-- vim: set ft=lua et :

-- queue in tarantool

-- tarantool config example:

-- space = [
--     {
--         enabled = 1,
--         index = [
--             {
--                 type = "TREE",
--                 unique = 1,
--                 key_field = [
--                     {
--                         fieldno = 0,
--                         type = "STR"
--                     }
--                 ]
--             },
--             {
--                 type = "TREE",
--                 unique = 0,
--                 key_field = [
--                     {
--                         fieldno = 1,    # tube
--                         type = "STR"
--                     },
--                     {
--                         fieldno = 2,    # status
--                         type = "STR"
--                     },
--                     {
--                         fieldno = 4,    # ipri
--                         type = "NUM"
--                     },
--                     {
--                         fieldno = 5    # pri
--                         type = "NUM"
--                     }
--                 ]
--             },
--             {
--                 type    = "TREE",
--                 unique  = 0,
--                 key_field = [
--                     {
--                         fieldno = 3,    # next_event
--                         type = "NUM64"
--                     }
--                 ]
--             }
--         ]
--     }
-- ]

-- Glossary
-- space - number of space contains tubes
-- tube - queue name
-- ttl - time to live
-- ttr - time to release (when task is run)
-- delay - delay period for task



local FIBERS_PER_TUBE  =   1

-- tuple structure
local i_uuid           = 0
local i_tube           = 1
local i_status         = 2
local i_event          = 3
local i_ipri           = 4
local i_pri            = 5
local i_cid            = 6
local i_created        = 7
local i_ttl            = 8
local i_ttr            = 9

local i_cready         = 10
local i_cbury          = 11
local i_ctaken         = 12

local i_task           = 13

-- indexes
local idx_task         = 0
local idx_tube         = 1
local idx_event        = 2

-- task statuses
local ST_READY         = 'r'
local ST_DELAYED       = 'd'
local ST_TAKEN         = 't'
local ST_BURIED        = 'b'
local ST_DONE          = '*'


local human_status = {}
    human_status[ST_READY]      = 'ready'
    human_status[ST_DELAYED]    = 'delayed'
    human_status[ST_TAKEN]      = 'taken'
    human_status[ST_BURIED]     = 'buried'
    human_status[ST_DONE]       = 'done'

local all_statuses = {
    ST_READY,
    ST_DELAYED,
    ST_TAKEN,
    ST_BURIED,
    ST_DONE,
}


local function get_ipri(space, tube, inc)
    local toptask
    if inc < 0 then
        toptask = box.select_limit(space, idx_tube, 0, 1, tube, ST_READY)
        if toptask == nil then
            return queue.default.ipri
        end
    else
        toptask = box.select_reverse_range(space, idx_tube, 1, tube, ST_READY)
        if toptask == nil then
            return queue.default.ipri
        end
        if toptask[i_status] ~= ST_READY then
            return queue.default.ipri
        end
    end

    local ipri = box.unpack('i', toptask[i_ipri])
    if inc < 0 then
        if ipri > -inc then
            ipri = ipri + inc
        else
            ipri = 0
        end
    else
        if ipri < 0xFFFFFFFF - inc then
            ipri = ipri + inc
        else
            ipri = 0xFFFFFFFF
        end
    end

    return ipri
end

local function to_time64(time)
    return time * 1000000
end

local function from_time64(time)
    return tonumber(time) / 1000000
end

local function rettask(task)
    if task == nil then
        return
    end
    -- TODO: use tuple:transform here
    local tuple = {}
    if type(task) == 'table' then
        table.insert(tuple, task[i_uuid + 1])
        for i = i_task + 1, #task do
            table.insert(tuple, task[i])
        end
    else
        table.insert(tuple, task[i_uuid])
        for i = i_task, #task - 1 do
            table.insert(tuple, task[i])
        end
    end
    return tuple
end


local function process_tube(space, tube)

    while true do
        local now = box.time64()
        local next_event = 3600
        while true do
            local task = box.select_range(space, idx_event, 1)

            if task == nil then
                break
            end

            local event = box.unpack('l', task[i_event])
            if event > now then
                next_event = from_time64(event - now)
                break
            end

            local created   = box.unpack('l', task[i_created])
            local ttl       = box.unpack('l', task[i_ttl])
            local ttr       = box.unpack('l', task[i_ttr])


            if now >= created + ttl then
                queue.stat[space][tube]:inc('ttl.total')
                queue.stat[space][tube]:inc(
                    'ttl.' .. human_status[task[i_status]])
                box.delete(space, task[i_uuid])

            -- delayed -> ready
            elseif task[i_status] == ST_DELAYED then
                box.update(space, task[i_uuid],
                    '=p=p+p',

                    i_status,
                    ST_READY,

                    i_event,
                    created + ttl,

                    i_cready,
                    1
                )
                queue.consumers[space][tube]:put(true, 0.1)
            -- taken -> ready
            elseif task[i_status] == ST_TAKEN then
                box.update(space, task[i_uuid],
                    '=p=p=p+p',

                    i_status,
                    ST_READY,

                    i_cid,
                    0,

                    i_event,
                    created + ttl,

                    i_cready,
                    1
                )
                queue.consumers[space][tube]:put(true, 0.1)
            else
                print("Internal error: unexpected task status: ",
                    task[i_status],
                    " (", human_status[ task[i_status] ], ")")
                box.update(space, task[i_uuid],
                    '=p',
                    i_event,
                    now + to_time64(5)
                )
            end
            now = box.time64()
        end

        queue.workers[space][tube].ch:get(next_event)
    end
end

local function consumer_dead_tube(space, tube, cid)
    local index = box.space[tonumber(space)].index[idx_tube]

    for task in index:iterator(box.index.EQ, tube, ST_TAKEN) do
        local created = box.unpack('l', task[i_created])
        local ttl = box.unpack('l', task[i_ttl])
        if box.unpack('i', task[i_cid]) == cid then
            queue.stat[space][tube]:inc('ready_by_disconnect')
            box.update(
                space,
                task[i_uuid],
                '=p=p=p+p',

                i_status,
                ST_READY,

                i_event,
                created + ttl,

                i_cid,
                0,

                i_cready,
                1
            )


            if not queue.consumers[space][tube]:is_full() then
                queue.consumers[space][tube]:put(true)
            end
            if not queue.workers[space][tube].ch:is_full() then
                queue.workers[space][tube].ch:put(true)
            end
        end
    end
end


local function consumer_dead(cid)
    for space, tbt in pairs(queue.consumers) do
        for tube, ch in pairs(tbt) do
            consumer_dead_tube(space, tube, cid)
        end
    end
end

if queue == nil then
    queue = {}
    queue.consumers = {}
    queue.workers = {}
    queue.stat = {}

    setmetatable(queue.consumers, {
            __index = function(tbs, space)
                local spt = {}
                setmetatable(spt, {
                    __index = function(tbt, tube)
                        local channel = box.ipc.channel(1)
                        rawset(tbt, tube, channel)
                        return channel
                    end
                })
                rawset(tbs, space, spt)
                return spt
            end,
            __gc = function(tbs)
                for space, tubes in pairs(tbs) do
                    for tube, tbt in pairs(tubes) do
                        rawset(tubes, tube, nil)
                    end
                    rawset(tbs, space, nil)
                end
            end
        }
    )
    
    setmetatable(queue.stat, {
            __index = function(tbs, space)
                local spt = {}
                setmetatable(spt, {
                    __index = function(tbt, tube)
                        local stat = {
                            inc = function(t, cnt)
                                t[cnt] = t[cnt] + 1
                                return t[cnt]
                            end
                        }
                        setmetatable(stat, {
                            __index = function(t, cnt)
                                rawset(t, cnt, 0)
                                return 0
                            end

                        })

                        rawset(tbt, tube, stat)
                        return stat
                    end
                })
                rawset(tbs, space, spt)
                return spt
            end,
            __gc = function(tbs)
                for space, tubes in pairs(tbs) do
                    for tube, tbt in pairs(tubes) do
                        rawset(tubes, tube, nil)
                    end
                    rawset(tbs, space, nil)
                end
            end
        }
    )

    setmetatable(queue.workers, {
            __index = function(tbs, space)
                
                local spt = rawget(tbs, space)
                spt = {}
                setmetatable(spt, {
                    __index = function(tbt, tube)
                        
                        local v = rawget(tbt, tube)

                        v = { fibers = {}, ch = box.ipc.channel(1) }

                        -- rawset have to be before start fiber
                        rawset(tbt, tube, v)

                        for i = 1, FIBERS_PER_TUBE do
                            local fiber = box.fiber.create(
                                function()
                                    box.fiber.detach()
                                    process_tube(space, tube)
                                end
                            )
                            box.fiber.resume(fiber)
                            table.insert(v.fibers, fiber)
                        end
                        
                        return v
                    end
                })
                rawset(tbs, space, spt)
                return spt
            end,

            __gc = function(tbs)
                for space, tubes in pairs(tbs) do
                    for tube, tbt in pairs(tubes) do
                        for i, fiber in pairs(tbt.fibers) do
                            box.fiber.cancel(fiber)
                        end
                        tbt.fibers = nil
                        tbt.ch = nil
                        rawset(tubes, tube, nil)
                    end
                    rawset(tbs, space, nil)
                end
            end
        }
    )
end

queue.default = {}
    queue.default.pri   = 0x7FFFFFFF
    queue.default.ipri  = 0x7FFFFFFF
    queue.default.ttl   = 3600 * 24 * 1
    queue.default.ttr   = 60
    queue.default.delay = 0






queue.statistic = function()

    local stat = {}

    for space, spt in pairs(queue.stat) do
        for tube, st in pairs(spt) do
            for name, value in pairs(st) do
                if type(value) ~= 'function' then

                    table.insert(stat,
                        'space' .. tostring(space) .. '.' .. tostring(tube)
                            .. '.' .. tostring(name)
                    )
                    table.insert(stat, tostring(value))
                end

            end
            table.insert(stat,
                        'space' .. tostring(space) .. '.' .. tostring(tube)
                            .. '.tasks.total'
            )
            table.insert(stat,
                tostring(box.space[tonumber(space)].index[idx_tube]:count(tube))
            )

            for i, s in pairs(all_statuses) do
                table.insert(stat,
                            'space' .. tostring(space) .. '.' .. tostring(tube)
                                .. '.tasks.' .. human_status[s]
                )
                table.insert(stat,
                    tostring(
                        box.space[tonumber(space)]
                            .index[idx_tube]:count(tube, s)
                    )
                )
            end
        end
    end
    return stat

end


local function put_push(space, tube, ipri, delay, ttl, ttr, pri, ...)

    local utask = { ... }

    ttl = tonumber(ttl)
    if ttl <= 0 then
        ttl = queue.default.ttl
    end
    ttl     = to_time64(ttl)

    delay = tonumber(delay)
    if delay <= 0 then
        delay = queue.default.delay
    end
    delay = to_time64(delay)
    ttl = ttl + delay


    ttr = tonumber(ttr)
    if ttr <= 0 then
        ttr = queue.default.ttr
    end
    ttr = to_time64(ttr)

    pri = tonumber(pri)
    pri = pri + queue.default.pri
    if pri > 0xFFFFFFFF then
        pri = 0xFFFFFFFF
    elseif pri < 0 then
        pri = 0
    end


    local task
    local now = box.time64()

    if delay > 0 then
        task = {
            box.uuid_hex(),
            tube,
            ST_DELAYED,
            box.pack('l', now + delay),
            box.pack('i', ipri),
            box.pack('i', pri),
            box.pack('i', 0),
            box.pack('l', now),
            box.pack('l', ttl),
            box.pack('l', ttr),
            box.pack('l', 0),
            box.pack('l', 0),
            box.pack('l', 0)
        }
    else
        task = {
            box.uuid_hex(),
            tube,
            ST_READY,
            box.pack('l', now + ttl),
            box.pack('i', ipri),
            box.pack('i', pri),
            box.pack('i', 0),
            box.pack('l', now),
            box.pack('l', ttl),
            box.pack('l', ttr),
            box.pack('l', 1),
            box.pack('l', 0),
            box.pack('l', 0)
        }
    end

    for i = 1, #utask do
        table.insert(task, utask[i])
    end

    task = box.insert(space, unpack(task))

    if delay == 0 and not queue.consumers[space][tube]:is_full() then
        queue.consumers[space][tube]:put(true)
    end
    if not queue.workers[space][tube].ch:is_full() then
        queue.workers[space][tube].ch:put(true)
    end

    return rettask(task)

end


queue.put = function(space, tube, ...)
    queue.stat[space][tube]:inc('put')
    return put_push(space, tube, queue.default.ipri, ...)
end


queue.urgent = function(space, tube, delayed, ...)
    delayed = tonumber(delayed)
    queue.stat[space][tube]:inc('urgent')

    -- TODO: may decrease ipri before put_push
    if delayed > 0 then
        return put_push(space, tube, queue.default.ipri, delayed, ...)
    end

    local ipri = get_ipri(space, tube, -1)
    return put_push(space, tube, ipri, delayed, ...)
end


queue.take = function(space, tube, timeout)

    if timeout == nil then
        timeout = 0
    else
        timeout = tonumber(timeout)
        if timeout < 0 then
            timeout = 0
        end
    end

    local created = box.time()

    while true do

        local task = box.select_limit(space, idx_tube, 0, 1, tube, ST_READY)
        if task ~= nil  then

            local now = box.time64()
            local created = box.unpack('l', task[i_created])
            local ttr = box.unpack('l', task[i_ttr])
            local ttl = box.unpack('l', task[i_ttl])
            local event = now + ttr
            if event > created + ttl then
                event = created + ttl
            end


            task = box.update(space,
                task[i_uuid],
                    '=p=p=p+p',
                    i_status,
                    ST_TAKEN,

                    i_event,
                    event,

                    i_cid,
                    box.session.id(),

                    i_ctaken,
                    1
            )

            if not queue.workers[space][tube].ch:is_full() then
                queue.workers[space][tube].ch:put(true)
            end
            queue.stat[space][tube]:inc('take')
            return rettask(task)
        end

        if timeout > 0 then
            now = box.time()
            if now < created + timeout then
                queue.consumers[space][tube]:get(created + timeout - now)
            else
                queue.stat[space][tube]:inc('take_timeout')
                return
            end
        end
    end
end

queue.delete = function(space, id)
    local task = box.select(space, idx_task, id)
    if task == nil then
        error("Task not found")
    end

    queue.stat[space][ task[i_tube] ]:inc('delete')
    return rettask(box.delete(space, id))
end

queue.ack = function(space, id)
    local task = box.select(space, idx_task, id)
    if task == nil then
        error('Task not found')
    end

    if task[i_status] ~= ST_TAKEN then
        error('Task is not taken')
    end

    if box.unpack('i', task[i_cid]) ~= box.session.id() then
        error('Only consumer that took the task can it ack')
    end
    local task = box.select(space, idx_task, id)
    if task == nil then
        error("Task not found")
    end

    queue.stat[space][ task[i_tube] ]:inc('ack')
    return rettask(box.delete(space, id))
end

queue.touch = function(space, id)
    local task = box.select(space, idx_task, id)
    if task == nil then
        error('Task not found')
    end

    if task[i_status] ~= ST_TAKEN then
        error('Task is not taken')
    end

    if box.unpack('i', task[i_cid]) ~= box.session.id() then
        error('Only consumer that took the task can it touch')
    end
    local task = box.select(space, idx_task, id)
    if task == nil then
        error("Task not found")
    end
    

    local ttr = box.unpack('l', task[i_ttr])
    local ttl = box.unpack('l', task[i_ttl])
    local created = box.unpack('l', task[i_created])
    local now = box.time64()
    
    local event

    if created + ttl > now + ttr then
        event = now + ttr
    else
        event = created + ttl
    end

    task = box.update(space, id, '=p', i_event, event)

    queue.stat[space][ task[i_tube] ]:inc('touch')
    return rettask(task)
end

queue.done = function(space, id, ...)
    local task = box.select(space, 0, id)
    if task == nil then
        error("Task not found")
    end
    if task[i_status] ~= ST_TAKEN then
        error('Task is not taken')
    end

    if box.unpack('i', task[i_cid]) ~= box.session.id() then
        error('Only consumer that took the task can it done')
    end

    local event = box.unpack('l', task[i_created]) +
        box.unpack('l', task[i_ttl])
    local tube = task[i_tube]

    task = task
                :transform(i_task, #task, ...)
                :transform(i_status, 1, ST_DONE)
                :transform(i_event, 1, event)

    task = box.replace(space, task:unpack())
    if not queue.workers[space][tube].ch:is_full() then
        queue.workers[space][tube].ch:put(true)
    end
    queue.stat[space][ tube ]:inc('done')
    return rettask(task)
end

queue.bury = function(space, id)
    local task = box.select(space, 0, id)
    if task == nil then
        error("Task not found")
    end
    if task[i_status] ~= ST_TAKEN then
        error('Task is not taken')
    end

    if box.unpack('i', task[i_cid]) ~= box.session.id() then
        error('Only consumer that took the task can it done')
    end

    local event = box.unpack('l', task[i_created]) +
        box.unpack('l', task[i_ttl])
    local tube = task[i_tube]

    task = box.update(space, task[i_uuid],
        '=p=p+p',

        i_status,
        ST_BURIED,

        i_event,
        event,

        i_cbury,
        1
    )

    if not queue.workers[space][tube].ch:is_full() then
        queue.workers[space][tube].ch:put(true)
    end
    queue.stat[space][ tube ]:inc('bury')
    return rettask(task)
end


queue.dig = function(space, id)
    local task = box.select(space, 0, id)
    if task == nil then
        error("Task not found")
    end
    if task[i_status] ~= ST_BURIED then
        error('Task is not buried')
    end

    local tube = task[i_tube]

    task = box.update(space, task[i_uuid],
        '=p+p',

        i_status,
        ST_READY,
        
        i_cbury,
        1
    )

    if not queue.workers[space][tube].ch:is_full() then
        queue.workers[space][tube].ch:put(true)
    end
    queue.stat[space][ tube ]:inc('dig')
    return rettask(task)
end


queue.kick = function(space, tube, count)
    local index = box.space[tonumber(space)].index[idx_tube]

    if count == nil then
        error("wrong count")
    end
    count = tonumber(count)

    if count <= 0 then
        return 0
    end

    local kicked = 0
    
    for task in index:iterator(box.index.EQ, tube, ST_BURIED) do
        box.update(space, task[i_uuid],
            '=p+p',

            i_status,
            ST_READY,
            
            i_cbury,
            1
        )
        kicked = kicked + 1
        queue.stat[space][ tube ]:inc('dig')
    end

    return kicked
end

queue.release = function(space, id, delay, ttl)
    local task = box.select(space, idx_task, id)
    if task == nil then
        error('Task not found')
    end
    if task[i_status] ~= ST_TAKEN then
        error('Task is not taken')
    end
    if box.unpack('i', task[i_cid]) ~= box.session.id() then
        error('Only consumer that took the task can it release')
    end

    local tube = task[i_tube]

    local now = box.time64()

    if ttl == nil then
        ttl = box.unpack('l', task[i_ttl])
    else
        ttl = to_time64(tonumber(ttl))
    end

    if delay == nil then
        delay = 0
    else
        delay = to_time64(tonumber(delay))
        if delay <= 0 then
            delay = 0
        end
        ttl = ttl + delay
    end

    local created = box.unpack('l', task[i_created])


    if delay > 0 then
        task = box.update(space,
            id,
            '=p=p=p=p',

            i_status,
            ST_DELAYED,

            i_event,
            now + delay,

            i_ttl,
            ttl,

            i_cid,
            0
        )
    else
        task = box.update(space,
            id,
            '=p=p=p=p+p',

            i_status,
            ST_READY,

            i_event,
            created + ttl,

            i_ttl,
            ttl,

            i_cid,
            0,
            
            i_cready,
            1
        )
        if not queue.consumers[space][tube]:is_full() then
            queue.consumers[space][tube]:put(true)
        end
    end
    if not queue.workers[space][tube].ch:is_full() then
        queue.workers[space][tube].ch:put(true)
    end
    
    queue.stat[space][ task[i_tube] ]:inc('release')

    return rettask(task)
end


queue.requeue = function(space, id)
    local task = box.select(space, idx_task, id)
    if task == nil then
        error('Task not found')
    end
    if task[i_status] ~= ST_TAKEN then
        error('Task is not taken')
    end
    if box.unpack('i', task[i_cid]) ~= box.session.id() then
        error('Only consumer that took the task can it release')
    end

    local tube = task[i_tube]

    local now = box.time64()


    local ipri = get_ipri(space, tube, 1)

    local created = box.unpack('l', task[i_created])
    local ttl = box.unpack('l', task[i_ttl])


    task = box.update(space,
        id,
        '=p=p=p+p=p',

        i_status,
        ST_READY,

        i_event,
        created + ttl,

        i_cid,
        0,
        
        i_cready,
        1,

        i_ipri,
        ipri
    )
    if not queue.consumers[space][tube]:is_full() then
        queue.consumers[space][tube]:put(true)
    end
    if not queue.workers[space][tube].ch:is_full() then
        queue.workers[space][tube].ch:put(true)
    end
    
    queue.stat[space][ task[i_tube] ]:inc('requeue')

    return rettask(task)
end

queue.meta = function(space, id)
    local task = box.select(space, 0, id)
    if task == nil then
        error('Task not found');
    end

    queue.stat[space][ task[i_tube] ]:inc('meta')

    task = task
        :transform(i_task, #task - i_task, tostring(box.time64()))
        :transform(i_status, 1, human_status[ task[i_status] ])
    return task
end


queue.peek = function(space, id)
    local task = box.select(space, 0, id)
    if task == nil then
        error("Task not found")
    end

    queue.stat[space][ task[i_tube] ]:inc('peek')
    return rettask(task)
end



box.session.on_disconnect(
    function()
        local cid = box.session.id()
        box.fiber.resume(
            box.fiber.create(
                function()
                    box.fiber.detach()
                    consumer_dead(cid)
                end
            )
        )
    end
)

