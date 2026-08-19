-- 按键误触自动修正过滤器 (typo_correction_filter.lua)
-- ============================================================
-- 用途：打字时不小心按错一个键（按成邻键/两键按反/多按一下），
--       程序自动识别用户真正想打的词，照常放进候选列表前列。
-- 示例：想打 zhrmghg（中华人民共和国），误输 zhrnghg（m 按成邻键 n）
--       → 候选首位仍然是「中华人民共和国」，comment 提示 ← zhrmghg
--
-- 为什么不用 librime 原生 enable_correction（2026-08-19 实测否决）：
--   内置 NearSearchCorrector 的容差 threshold=5 硬编码在 syllabifier.cc，
--   过宽的编辑距离把正常输入也扰动（nihao 首位「你好」被挤到第 4），
--   且只认 kNormalSpelling（简拼 kAbbreviation 完全不在容错范围）。
--   本滤镜全权接管：全拼+简拼误触，正常输入零干扰。
--
-- 零干扰门控（按序判定）：
--   1. 等长真词门控：候选流里存在「字数 == 码长」的非造句词 → 输入正确，直通
--      （简拼正确码必有等长真词：zhrmghg→中华人民共和国 7==7）
--   2. 元音门控：等长门控没命中且元音数 > 码长/4 → 全拼输入途中（zhongg），直通
--      （zhrnghg 0 元音✓继续反查；zhonghuarenmin 5>3✗直通，
--        保护长全拼打字不跑变体反查——打字卡顿防护）
--   🔥 不要按候选权重判"输入途中"：用户词库残留词 quality≈0.7 会混进
--      误触码候选流造成误判直通（2026-08-19 实测根因）
--
-- 修正策略（QWERTY 键盘物理邻接，三类，覆盖三种误触）：
--   1. 单键替换 —— 按成隔壁的键（zhrnghg → zhrmghg）
--   2. 邻键换位 —— 相邻两键按反（zhrmhgg → zhrmghg）
--   3. 单键删除 —— 多按了一个键（zhrmghgg → zhrmghg）
-- 每个变体用 Component.ScriptTranslator 做真实音节切分反查（词组级，
-- 非音节级——棱镜只存音节 key，Memory:dict_lookup 查不了词组，实证），
-- 收集 type=phrase/user_phrase（排除造句垃圾）且 quality≥0.2 的真词，
-- 按词频排序注入候选前列。
--
-- 性能：每键一次等长扫描 O(scan_cap)；变体反查只在误触码上发生且按码缓存；
--       长全拼被元音门控挡掉。打字无感。
--
-- 依赖：Component.ScriptTranslator（librime-lua ≥ git2024-02，
--       Ubuntu 24.04 librime-plugin-lua 1.10.0+dfsg1~git20230917 已含；
--       rimi-setup 已把 librime-plugin-lua 列为硬依赖）
-- 仅全拼方案挂载（rime_ice / rimi）：双拼键位是音素码，邻接关系不成立。
-- 轻量模式（无 lua）由 rimi-setup/deploy_linux.sh sed 剔除本滤镜行。
-- 滤镜注入候选不走 script_translator 学习链路，
-- 选中修正词不会把错误编码写进用户词库（不污染自学习）。
--
-- 🔥 挂载位置必须在 corrector.lua 之后：corrector 会把不匹配「［拼音］」
--    格式的 comment 清空，我们的「← 正确编码」注释放在它后面才保得住。
-- 🔥 Translation iter 是消耗式的：扫描吃过的候选必须回放，否则首候选丢失。

-- QWERTY 键盘物理邻接表（librime corrector.cc keyboard_map 同款）
local NEIGHBORS = {
    q = "w",       w = "qe",     e = "wr",     r = "et",
    t = "ry",      y = "tu",     u = "yi",     i = "uo",
    o = "ip",      p = "o",
    a = "s",       s = "ad",     d = "sf",     f = "dg",
    g = "fh",      h = "gj",     j = "hk",     k = "jl",
    l = "k",
    z = "x",       x = "zc",     c = "xv",     v = "cb",
    b = "vn",      n = "bm",     m = "n",
}

-- 生成全部修正变体：替换（最多）→ 换位 → 删除
local function variants_of(code)
    local n = #code
    local out = {}
    for i = 1, n do
        local nb = NEIGHBORS[code:sub(i, i)]
        if nb then
            for j = 1, #nb do
                table.insert(out, code:sub(1, i - 1) .. nb:sub(j, j) .. code:sub(i + 1))
            end
        end
    end
    for i = 1, n - 1 do
        local a = code:sub(i, i)
        local b = code:sub(i + 1, i + 1)
        if a ~= b then
            table.insert(out, code:sub(1, i - 1) .. b .. a .. code:sub(i + 2))
        end
    end
    for i = 1, n do
        table.insert(out, code:sub(1, i - 1) .. code:sub(i + 1))
    end
    return out
end

-- 元音门控：全拼码元音密集，简拼/误触码几乎全是声母
local function vowel_count(code)
    local _, n = code:gsub('[aeiou]', '')
    return n
end

local M = {}

function M.init(env)
    local config = env.engine.schema.config
    local ns = env.name_space:gsub('^%*', '')
    local function conf(key, default)
        return config:get_int(ns .. '/' .. key)
            or config:get_int('typo_correction/' .. key) or default
    end
    env.max_candidates = conf('max_candidates', 5)
    env.min_code_length = conf('min_code_length', 4)
    env.max_code_length = conf('max_code_length', 26)
    env.scan_cap = conf('scan_cap', 100)
    env.per_variant_cap = conf('per_variant_cap', 8)
    env.quality_floor = 0.2     -- 低于此词频的变体命中不收（生僻噪音）
    env.cache = {}              -- code → 修正结果表/false，同码不重复计算
    -- 词组级反查器：Component.ScriptTranslator
    -- 4 参形式: (engine, schema, name_space, klass)
    local ok, st = pcall(function()
        return Component.ScriptTranslator(env.engine, env.engine.schema,
                                          'translator', 'script_translator')
    end)
    if ok and st then
        env.st = st
    else
        env.st = nil
        log.error('[typo_correction] Component.ScriptTranslator 不可用，滤镜停用: '
                  .. tostring(st))
    end
end

function M.tags_match(seg, env)
    env.seg = seg
    return seg:has_tag('abc')
end

function M.func(input, env)
    local ctx = env.engine.context
    local seg = env.seg
    local code = ctx.input
    local found = nil
    local consumed = {}

    if env.st and seg and seg.start == 0
        and ctx:get_option('typo_correction') ~= false
        and #code >= env.min_code_length
        and #code <= env.max_code_length
        and not code:find("[' ]") then
        local cached = env.cache[code]
        if cached == nil then
            -- 第一遍扫描：等长真词门控
            -- 纯简拼码（元音门控已滤掉全拼）正确时必有等长真词候选
            -- （zhrmghg→中华人民共和国 7==7），误触码只有短句凑词。
            -- 🔥 不要按候选权重判"输入途中"：用户词库残留词 quality≈0.7
            --   会混进误触码候选流造成误判直通（2026-08-19 实测根因）
            -- 🔥 iter 消耗式：扫过的候选记入 consumed，输出时回放
            local has_exact, n = false, 0
            for cand in input:iter() do
                n = n + 1
                table.insert(consumed, cand)
                if utf8.len(cand.text) == #code and cand.type ~= 'sentence' then
                    has_exact = true
                    break
                end
                if n >= env.scan_cap then break end
            end
            if has_exact then
                cached = false   -- 输入正确：零干扰直通
            elseif vowel_count(code) > math.floor(#code / 4) then
                -- 元音密集的全拼码扫不到等长真词 = 半截输入途中（zhongg），
                -- 跳过昂贵的变体反查（每键最多扫 100 个候选，打字无感）
                cached = false
            else
                -- 第二遍：变体反查
                cached = {}
                local seen = {}
                for _, v in ipairs(variants_of(code)) do
                    local okq, tr = pcall(function() return env.st:query(v, seg) end)
                    if okq and tr then
                        local k = 0
                        -- regime 按【原始码】判定，不能按变体（删除变体会丢元音，
                        -- 如 womrn→wmrn，若按变体判会把全拼误触当简拼处理，
                        -- 收进「我没惹你」这类字数巧合的垃圾——2026-08-19 实测）：
                        --   原始码纯简拼 → 一字一键，字数必须等于变体码长；
                        --   原始码含元音 → comment 音节拆分完整解析校验
                        local v_is_initials = vowel_count(code) == 0
                        for cand in tr:iter() do
                            k = k + 1
                            local clen = utf8.len(cand.text)
                            local ok_match = false
                            if cand.type ~= 'sentence'
                                and (cand.quality or 0) >= env.quality_floor
                                and clen >= 2 then
                                if v_is_initials then
                                    ok_match = (clen == #v)
                                elseif cand.comment and #cand.comment > 0 then
                                    -- comment 形如「［wo men］」（rime_ice 有全角括号包裹，
                                    -- rimi 降级方案无括号）——两种都兼容
                                    local parsed = cand.comment:match('^［(.+)］$') or cand.comment
                                    parsed = parsed:gsub('%s+', '')
                                    ok_match = (parsed == v)
                                end
                            end
                            if ok_match and not seen[cand.text] then
                                seen[cand.text] = true
                                table.insert(cached, {
                                    text = cand.text,
                                    corrected = v,
                                    quality = cand.quality or 0,
                                })
                            end
                            if k >= env.per_variant_cap then break end
                        end
                    end
                    if #cached >= env.max_candidates * 4 then break end
                end
                table.sort(cached, function(a, b) return a.quality > b.quality end)
                if #cached > env.max_candidates then
                    local cut = {}
                    for i = 1, env.max_candidates do cut[i] = cached[i] end
                    cached = cut
                end
                if #cached == 0 then cached = false end
            end
            env.cache[code] = cached
            local cn = 0
            for _ in pairs(env.cache) do cn = cn + 1 end
            if cn > 4000 then env.cache = { [code] = cached } end
        end
        if cached then found = cached end
    end

    if not found then
        -- 直通：先回放扫描消耗的候选，再续原流（消耗式 iter 防丢）
        for _, cand in ipairs(consumed) do yield(cand) end
        for cand in input:iter() do yield(cand) end
        return
    end

    -- 误触修正候选置顶，comment 标注正确编码
    local seen = {}
    for _, c in ipairs(found) do
        if not seen[c.text] then
            seen[c.text] = true
            local cand = Candidate('typo', seg.start, seg._end, c.text, '← ' .. c.corrected)
            cand.quality = 10   -- 压过翻译器候选（initial_quality 1.2）
            yield(cand)
        end
    end
    -- 回放扫描已消耗的候选
    for _, cand in ipairs(consumed) do
        if not seen[cand.text] then
            seen[cand.text] = true
            yield(cand)
        end
    end
    -- 原有候选流剩余部分（去重后保留，仍可翻页选择）
    for cand in input:iter() do
        if not seen[cand.text] then
            yield(cand)
        end
    end
end

function M.fini(env)
    if env.st and env.st.finish_session then
        pcall(function() env.st:finish_session() end)
    end
    env.st = nil
    env.cache = nil
end

return M
