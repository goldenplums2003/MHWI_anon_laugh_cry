-- 太刀 登龙 / 大居  命中·落空 语音
--   命中 -> tangxiao.wav      落空 -> tangku.wav
-- 依赖 LuaEngine (HalcyonAlcedo)
--
-- 判定：招式开始时记下任务累计伤害和怪物血量总和，招式进行期间只要伤害涨了
-- 或怪掉血了就立刻锁定为命中。在过程中判而不是等结束再比对，结束时机
-- 有偏差也不会误判。

local CONFIG = {
    volume  = 51,      -- 音量
    onlyRed = false,   -- true = 只在红刃(练气3)时触发
    silent  = false,   -- true = 只判定不放音
    hud     = false,   -- 屏幕提示命中/落空。Ctrl+D 开关
    verbose = false,   -- true = 每次动作切换、每笔伤害都写进 logs/LuaEngine.log
    collect = false,   -- true = 记录从居合姿态出来的、未登记的动作（找新招式 ID 时用）
}

local WEAPON_LS = 3    -- 武器种类：太刀

local AUDIO = {
    hit  = { name = 'tangxiao', file = 'nativePC/Music/3/tangxiao.wav' },
    miss = { name = 'tangku',   file = 'nativePC/Music/3/tangku.wav'   },
}

-- 招式动作 ID。同一招在不同刃色下是不同的动作（游戏 FSM 里本来就有
-- cWp03AuraLevelWhiteOver / cWp03AuraLevelRedOver 这类按刃色分叉的条件），
-- 所以 mains 是一个集合，把各刃色的 ID 都放进去。
--   49326 登龙(气刃兜割)      三个刃色共用这一个 ID（已实测）
--   大居(居合抜刀气刃斩) 每个刃色一个 ID：49461 白 / 49462 黄 / 49463 红，进入自 49458
-- 无刃(练气=0)的大居不做判定：它似乎有多个 ID 变体（只确认过 49153，还有别的没抓到），
-- 收益不值得那个复杂度。要加的话把 collect 打开、无刃下只放大居，把冒出来的 ID 全加进来。
-- 别混进来的：49459 是居合构え(蓄力姿态)，49157 是大居的退出动作。
-- follow 留空：伤害在招式进行中就已入账，尽早结束判定反而让音效更跟手。
-- judge 决定怎么算"成功"：
--   'damage' 招式进行中打出了伤害（或怪掉血）
--   'aura'   招式结束时练气没掉 —— 对应大居"判定帧和怪物攻击帧重合"
--   'both'   两者都要满足：既没掉刃、又打出了伤害
-- 登龙只能用 'damage'：它中空都掉一级练气，练气没有区分度。
-- 练气读不到时（返回 -1）一律回落到 'damage'，不会因为地址失效变成永远判失败。
local MOVES = {
    { label = '登龙', mains = { [49326] = true }, follow = {}, judge = 'damage' },
    { label = '大居', mains = { [49461] = true, [49462] = true, [49463] = true },
      follow = {}, judge = 'both' },
}

-- 自动采集用：从这些动作里出来的、尚未登记的动作会记一条 [太刀待认] 日志。
--   49458 特殊纳刀
--   49459 居合构え（蓄力姿态，跟刃色无关，各刃色都会经过）
-- 各种居合都从这两个状态出来。注意别把 49460 加进来 —— 它是通用待机，
-- 从它出来的动作五花八门，只会刷屏。
local WATCH_FROM = { [49458] = true, [49459] = true }

local QUEST_BASE  = 0x14500ED30
local DMG_OFFSET  = 0x17088
local WEAPON_BASE = 0x1450139A0

local loaded   = false
local lastLmt  = -1
local lastLmt2 = -1
local lastDmg  = -1
local tracking = {}

local function num(v, fallback)
    if type(v) == 'number' then return v end
    return fallback
end

-- 任务累计伤害。GetAddressData 只能读 4 字节，指针必须用 GetAddress 走完整 64 位。
local function totalDamage()
    local p = num(GetAddress(QUEST_BASE, {}), 0)
    if p <= 0x10000 then return -1 end
    return num(GetAddressData(p + DMG_OFFSET, 'int'), -1)
end

-- 练气等级（1白 / 2黄 / 3红）。只用来记日志和 onlyRed 开关，不参与命中判定：
-- 登龙无论中空都掉一级；大居掉不掉取决于判定帧有没有和怪物的攻击帧重合，
-- 跟"有没有打出伤害"是两回事（可能没伤害却不掉，也可能有伤害却掉）。
local function auraLevel()
    local base = GetAddress(WEAPON_BASE, { 0x50, 0x76B0 })
    if type(base) ~= 'number' or base <= 0x10000 then return -1 end
    return num(GetAddressData(base + 0x2370, 'int'), -1)
end

-- 怪物血量总和。on_monster_create / on_monster_destroy 是无参回调，拿不到指针，
-- 必须主动调 GetAllMonster()——它返回以怪物地址为键、值为 {Id, SubId} 的表。
local function monsterHp()
    local ok, list = pcall(GetAllMonster)
    if not ok or type(list) ~= 'table' then return -1 end
    local sum = 0
    for ptr, _ in pairs(list) do
        if type(ptr) == 'number' and ptr > 0x10000 then
            local a = GetAddress(ptr, { 0x7670 })
            if type(a) == 'number' and a > 0x10000 then
                sum = sum + num(GetAddressData(a + 0x64, 'float'), 0)
            end
        end
    end
    return math.floor(sum + 0.5)
end

local function loadAll()
    for _, a in pairs(AUDIO) do
        loadAudio(a.name, a.file)
        setVolume(a.name, CONFIG.volume)
    end
end

-- 出结果：记日志 + 屏幕提示 + 放音。why 说明是提前判出来的还是等到动作结束才判的。
local function announce(mv, ok, why, st, dmg, aura, nextLmt)
    Console_Info('[太刀] ' .. mv.label .. (ok and ' 成功' or ' 失败')
        .. '   [' .. (mv.judge or 'damage') .. '/' .. why .. ']'
        .. '   伤害 ' .. st.dmg .. '->' .. dmg
        .. '   练气 ' .. st.aura .. '->' .. aura
        .. (nextLmt and ('   下一动作=' .. nextLmt) or ''))
    if CONFIG.hud then Message(mv.label .. (ok and ' 成功' or ' 失败')) end
    if not CONFIG.silent then
        playAudio(ok and AUDIO.hit.name or AUDIO.miss.name)
    end
end

-- 带冷却的热键。冷却给足 3 秒，否则按住不放会反复切换。
local function hotkey(keys, tag)
    if engine.keypad(keys)
        and (CheckChronoscope(tag) or not CheckPresenceChronoscope(tag))
    then
        AddChronoscope(3, tag)
        return true
    end
    return false
end

function on_time()
    local P = engine.Player:new()
    if P.Weapon.type ~= WEAPON_LS then return end

    if not loaded then
        loadAll()
        loaded = true
    end

    local lmt  = P.Action.lmtID
    local dmg  = totalDamage()
    local hp   = monsterHp()
    local aura = auraLevel()

    for i, mv in ipairs(MOVES) do
        local st = tracking[i]
        if st == nil then
            st = { active = false, dmg = 0, hp = 0, aura = 0, hit = false }
            tracking[i] = st
        end

        if mv.mains[lmt] and not st.active then
            if not CONFIG.onlyRed or aura == 3 then
                st.active = true
                st.hit = false
                st.played = false
                st.dmg, st.hp, st.aura = dmg, hp, aura
            end
        end

        if st.active then
            -- 伤害涨了、或怪掉血了，锁定"打中了"
            if dmg > st.dmg then st.hit = true end
            if hp >= 0 and st.hp >= 0 and hp < st.hp then st.hit = true end

            -- 结果一旦确定就立刻出声，不等动作放完 —— 延迟主要就来自这段等待。
            -- 'damage' 判定：伤害到手即成功已定。
            -- 'aura'/'both' 判定：掉刃即失败已定（练气不会在招式中途回升）。
            if not st.played then
                local mode = mv.judge or 'damage'
                local auraDropped = (aura >= 0 and st.aura >= 0 and aura < st.aura)
                if mode == 'damage' and st.hit then
                    st.played = true
                    announce(mv, true, '提前', st, dmg, aura, nil)
                elseif (mode == 'aura' or mode == 'both') and auraDropped then
                    st.played = true
                    announce(mv, false, '提前', st, dmg, aura, nil)
                end
            end
        end

        -- 动作结束。提前出过声的就只补一条日志，不重复放音。
        if st.active and not mv.mains[lmt] and not mv.follow[lmt] then
            st.active = false

            if st.played then
                Console_Info('[太刀] ' .. mv.label .. ' 动作结束（已提前出声）'
                    .. '   伤害 ' .. st.dmg .. '->' .. dmg
                    .. '   练气 ' .. st.aura .. '->' .. aura
                    .. '   下一动作=' .. lmt)
            else
                local auraReadable = (aura >= 0 and st.aura >= 0)
                local auraKept     = auraReadable and (aura >= st.aura)

                local ok
                if mv.judge == 'aura' and auraReadable then
                    ok = auraKept
                elseif mv.judge == 'both' and auraReadable then
                    ok = st.hit and auraKept      -- 不掉刃 且 打出伤害
                else
                    ok = st.hit                   -- 练气读不到时也走这条
                end
                announce(mv, ok, '结束', st, dmg, aura, lmt)
            end
        end
    end

    if hotkey({ 'd', 'Ctrl' }, 'ls_hud') then
        CONFIG.hud = not CONFIG.hud
        Message('太刀屏幕提示: ' .. (CONFIG.hud and '开' or '关'))
    end

    -- 自动采集：同一招在不同刃色下是不同动作 ID，靠这条把没见过的连同练气等级记下来，
    -- 不用专门跑诊断。已登记的 ID 会跳过，不刷屏。
    if CONFIG.collect and lmt ~= lastLmt and WATCH_FROM[lastLmt] and not WATCH_FROM[lmt] then
        local known = false
        for _, mv in ipairs(MOVES) do
            if mv.mains[lmt] then known = true end
        end
        if not known then
            Console_Info('[太刀待认] 路径 ' .. lastLmt2 .. ' -> ' .. lastLmt .. ' -> ' .. lmt
                .. '   练气=' .. aura)
        end
    end

    -- 找新招式 ID 时把 verbose 打开：每笔伤害和每次动作切换都会记进日志
    if CONFIG.verbose then
        if lastDmg >= 0 and dmg > lastDmg then
            Console_Info('[太刀伤害] +' .. (dmg - lastDmg) .. '  当前动作=' .. lmt)
        end
        if lmt ~= lastLmt then
            Console_Info('[太刀ID] 动作 ' .. lastLmt .. ' -> ' .. lmt
                .. '   练气=' .. aura .. '   怪血=' .. hp .. '   伤害=' .. dmg)
        end
    end
    lastDmg = dmg
    if lmt ~= lastLmt then
        lastLmt2 = lastLmt
        lastLmt = lmt
    end
end
