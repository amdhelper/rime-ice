-- 🔥 2026-08-29 英文前缀补全守卫（en_full 40万词库配套）
-- 背景：逐键打中文（如 nihao）的中间态（nihaoa），英文词库的前缀补全候选
-- （Nihau 尼豪岛等专名）抢首位，把中文候选压下去（金标准第15项）。
-- 但爸爸的英文查词需求（打 centri 找到 centriole）也是核心功能，不能一刀切沉底。
--
-- 判定规则（两全）：
--   ① 输入串可完整切分为合法拼音音节（DP，如 ni-hao-a）→ 用户在打中文
--      → 英文前缀补全词沉底（完整键入的英文词 text==input 不动）。
--   ② 输入串不是合法拼音序列（如 centri / mitocho）→ 用户在查英文词
--      → 候选流原样放行，英文补全正常可见。
--
-- 判定不依赖 cand.type（librime 候选 type 是翻译器自传字符串，不可靠）：
-- 「纯字母候选 且 text ~= 完整输入码」= 前缀补全词；500 条安全阀防内存膨胀。
--
-- 🔥 2026-09-12 三症根治之二（wsm/sm 英文缩写抢首位）：
--   旧判定只认全拼音节序列——is_pinyin_seq("wsm")=false 直接放行英文，
--   en_full 词库的垃圾缩写 wsm/S-M/SM 精确匹配抢在「为什么/什么」前面。
--   新增辅音简拼判定（pinyin_util.is_consonant_abbrev：纯字母、无元音、
--   合法声母序列，zh/ch/sh 视为整体）——wsm/sm/bcd 是中文简拼，英文沉底。
--   判定模块与 typo_correction_filter 共享（pinyin_util.lua），防音节表漂移。
--   词典侧配套：en_full.dict.yaml 已清洗 5420 条无词频全辅音缩写
--   （scripts/clean_en_full.py），双保险。
--
-- 🔥 2026-09-14 高频英文词回归（爸爸实测：bot/max 从候选里消失了）：
--   9-12 的中间态加严过头——「音节+声母」形态的常用英文词全被误杀：
--   bot(bo+t)、max(ma+x)、six(si+x)、pen(pe+n)、but(bu+t) 都是合法
--   拼音中间态，旧逻辑 partial=true 时无条件连 text==code 的精确英文词
--   也沉底，en_full 40万冷僻词补全霸屏，bot 首屏只剩「波特/拨通」。
--   而当初要杀的鬼词 wom/nih/lis/sh 全都不在 en/en_ext 2.5万常用词表里。
--   修法：中间态豁免 = 输入码命中常用英文词表（lua/common_en_words.lua，
--   由 scripts/gen_common_en_words.py 从 en_dicts 生成）。真英文词回原位，
--   鬼词继续沉底，辅音简拼分支不动，三症回归（19项）不炸。

local M = {}

-- 🔥 共享拼音判定模块。pcall 容错：缺失时退回本地内联音节表（旧行为），
-- 不崩溃（金标准 18 项会抓住降级）。
local ok_pu, pinyin_util = pcall(require, 'pinyin_util')
if not ok_pu then
    pinyin_util = nil
end

-- 常用英文词表（en/en_ext 2.5万词，含缩写/技术词）。pcall 容错：
-- 缺失时豁免集为空 → 退回 9-12 行为（bot/max 沉底），不崩溃。
local ok_cw, common_en = pcall(require, 'common_en_words')
if not ok_cw then
    common_en = nil
end

-- 标准汉语拼音音节表（无声调，含 v 代 ü 形态；略宽——宁可多判拼音保中文首位）
local SYLLABLES = {}
for _, w in ipairs({
  "a","ai","an","ang","ao",
  "ba","bai","ban","bang","bao","bei","ben","beng","bi","bian","biao","bie","bin","bing","bo","bu",
  "ca","cai","can","cang","cao","ce","cei","cen","ceng","cha","chai","chan","chang","chao","che",
  "chen","cheng","chi","chong","chou","chu","chua","chuai","chuan","chuang","chui","chun","chuo",
  "ci","cong","cou","cu","cuan","cui","cun","cuo",
  "da","dai","dan","dang","dao","de","dei","den","deng","di","dia","dian","diao","die","ding","diu",
  "dong","dou","du","duan","dui","dun","duo",
  "e","ei","en","eng","er",
  "fa","fan","fang","fei","fen","feng","fo","fou","fu",
  "ga","gai","gan","gang","gao","ge","gei","gen","geng","gong","gou","gu","gua","guai","guan",
  "guang","gui","gun","guo",
  "ha","hai","han","hang","hao","he","hei","hen","heng","hong","hou","hu","hua","huai","huan",
  "huang","hui","hun","huo",
  "ji","jia","jian","jiang","jiao","jie","jin","jing","jiong","jiu","ju","juan","jue","jun",
  "ka","kai","kan","kang","kao","ke","kei","ken","keng","kong","kou","ku","kua","kuai","kuan",
  "kuang","kui","kun","kuo",
  "la","lai","lan","lang","lao","le","lei","leng","li","lia","lian","liang","liao","lie","lin",
  "ling","liu","lo","long","lou","lu","luan","lue","lun","luo","lv",
  "ma","mai","man","mang","mao","me","mei","men","meng","mi","mian","miao","mie","min","ming",
  "miu","mo","mou","mu",
  "na","nai","nan","nang","nao","ne","nei","nen","neng","ni","nian","niang","niao","nie","nin",
  "ning","niu","nong","nou","nu","nuan","nue","nun","nuo","nv",
  "o","ou",
  "pa","pai","pan","pang","pao","pei","pen","peng","pi","pian","piao","pie","pin","ping","po","pou","pu",
  "qi","qia","qian","qiang","qiao","qie","qin","qing","qiong","qiu","qu","quan","que","qun",
  "ran","rang","rao","re","ren","reng","ri","rong","rou","ru","rua","ruan","rui","run","ruo",
  "sa","sai","san","sang","sao","se","sen","seng","sha","shai","shan","shang","shao","she","shei",
  "shen","sheng","shi","shou","shu","shua","shuai","shuan","shuang","shui","shun","shuo","si",
  "song","sou","su","suan","sui","sun","suo",
  "ta","tai","tan","tang","tao","te","tei","teng","ti","tian","tiao","tie","ting","tong","tou",
  "tu","tuan","tui","tun","tuo",
  "wa","wai","wan","wang","wei","wen","weng","wo","wu",
  "xi","xia","xian","xiang","xiao","xie","xin","xing","xiong","xiu","xu","xuan","xue","xun",
  "ya","yan","yang","yao","ye","yi","yin","ying","yo","yong","you","yu","yuan","yue","yun",
  "za","zai","zan","zang","zao","ze","zei","zen","zeng","zha","zhai","zhan","zhang","zhao","zhe",
  "zhei","zhen","zheng","zhi","zhong","zhou","zhu","zhua","zhuai","zhuan","zhuang","zhui","zhun",
  "zhuo","zi","zong","zou","zu","zuan","zui","zun","zuo",
  -- v 代 ü 的常见输入形态
  "nve","lve","nv","lv",
}) do
    SYLLABLES[w] = true
end

-- 完整切分判定（DP）：s 能否切成若干合法拼音音节
local function is_pinyin_seq(s)
    local n = #s
    if n == 0 or n > 32 then
        return false
    end
    local dp = { [0] = true }
    for i = 1, n do
        local maxL = math.min(6, i)
        for L = 1, maxL do
            if dp[i - L] and SYLLABLES[s:sub(i - L + 1, i)] then
                dp[i] = true
                break
            end
        end
    end
    return dp[n] == true
end

function M.func(input, env)
    local code = env.engine.context.input
    -- 去分隔符（模糊拼音 ' 与空格）转小写后判定
    local clean = code:lower():gsub("[' ]", "")
    -- 🔥 2026-09-12 中文模式判定扩展：全拼音节序列 或 辅音简拼（sm/wsm/bcd）
    -- 都视为"用户在打中文"。旧版只认全拼序列，wsm/sm 被当成英文查询直接放行，
    -- en_full 的缩写词条抢在「为什么/什么」前面（爸爸实测三症之二）。
    -- 🔥 中间态加严（三症同族根治）：en_full 混着 sh/wom/nih/lis 这类 ECDICT
    -- 冷僻词条，恰好等于打中文的半途编码（wom=wo+m）——中间态时连 text==code
    -- 的英文精确词也沉底（完整键入的真英文词 list/cpu 不是中间态，豁免保留）。
    local partial = false
    local seq = false
    local chinese_mode
    if pinyin_util then
        seq = pinyin_util.is_pinyin_seq(clean)
        partial = pinyin_util.is_partial_pinyin(clean)
        chinese_mode = partial
            or seq
            or pinyin_util.is_consonant_abbrev(clean)
    else
        seq = is_pinyin_seq(clean)
        chinese_mode = seq   -- 模块缺失退回旧行为
    end
    -- 🔥 2026-09-14 中间态豁免（bot/max 回归修复）：输入码是「音节+声母」
    -- 纯中间态（partial 且非完整拼音序列）且命中 en/en_ext 常用英文词表
    -- （bot=bo+t / max=ma+x / six=si+x / but=bu+t）→ 视为用户键入英文，
    -- 原样放行不沉底。鬼词（wom/nih/lis/sh 不在常用表）仍沉底。
    -- ⚠️ 必须排除 seq：常用表里 he/me/pen/man/women 等 1176 词同时是合法
    -- 全拼，若一并豁免会把中文高频输入让给英文（9-12 三症原地复发）。
    -- seq 词的精确英文词（text==code）本就有豁免，前缀补全词继续沉底。
    if partial and not seq and common_en and common_en[clean] == true then
        chinese_mode = false
    end
    if not chinese_mode then
        -- 非拼音序列也非辅音简拼 = 用户在查英文词：原样放行（前缀补全保持可见）
        for cand in input:iter() do
            yield(cand)
        end
        return
    end
    -- 拼音序列 = 用户在打中文：英文前缀补全沉底
    -- （完整键入的英文词 text==code 豁免——但中间态不豁免，见上）
    local pending_en = {}
    local n = 0
    for cand in input:iter() do
        n = n + 1
        if n > 500 then
            yield(cand)
        elseif cand.text:match("^[%a'%-]+$")
                and (partial or cand.text:lower() ~= code:lower()) then
            table.insert(pending_en, cand)
        else
            yield(cand)
        end
    end
    for _, cand in ipairs(pending_en) do
        yield(cand)
    end
end

return M
