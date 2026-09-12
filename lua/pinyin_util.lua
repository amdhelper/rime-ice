-- pinyin_util.lua — 拼音音节/简拼判定共享模块
-- ============================================================
-- 为什么需要：en_completion_guard_filter（英文守卫）与 typo_correction_filter
-- （误触修正）都需要判断"输入串是不是合法拼音"。2026-09-12 实锤三症：
--   ① gongneng 元音数=2 恰好不满足旧元音门控（>码长/4=2），被误触修正
--      当成"简拼误触码"反查邻键变体 gongmeng，把权重仅 1 的「公孟」以
--      quality=10 强行置顶，永远压过权重 50 万的「功能」——用户感觉"不学习"。
--   ② wsm/sm 是合法简拼（每字母都是声母），但旧守卫只认全拼音节序列
--      （is_pinyin_seq("wsm")=false 直接放行），en_full 词库里的垃圾缩写
--      wsm/S-M/SM 精确匹配抢在「为什么/什么」前面。
-- 判定逻辑集中到本模块，两个滤镜共用，避免两套音节表漂移。
--
-- 对外接口：
--   M.is_pinyin_seq(s)        全拼序列判定（s 能否切成若干合法音节，DP）
--   M.is_abbrev_seq(s)        简拼序列判定（每单元都是声母；zh/ch/sh 视为整体，
--                             与 speller/algebra 的 abbrev 规则一致；a/e/o 零声母算合法单元）
--   M.abbrev_syllable_count(s) 简拼音节数（is_abbrev_seq 为真时才有意义）
-- 入参一律：小写、无分隔符（调用方先 code:lower():gsub("[' ]","")）。

local M = {}

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
M.SYLLABLES = SYLLABLES

-- 声母表（简拼单元）。a/e/o 是零声母音节的首字母，abbrev 规则下同样合法。
-- zh/ch/sh 双字母视为一个单元（与 rime_ice speller/algebra 的
-- abbrev/^([zcs]h).+$/$1/ 一致：zhs → 中山市 是 2 个音节不是 3 个）。
local INITIALS = {}
for _, w in ipairs({
  "b","p","m","f","d","t","n","l","g","k","h",
  "j","q","x","zh","ch","sh","r","z","c","s","y","w",
  "a","e","o",
}) do
    INITIALS[w] = true
end
M.INITIALS = INITIALS

-- 全拼序列判定（DP）：s 能否切成若干合法拼音音节
function M.is_pinyin_seq(s)
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

-- 简拼解析：贪心从左到右，zh/ch/sh 双字母优先。
-- 返回 音节数；解析失败返回 nil。
local function parse_abbrev(s)
    local n = #s
    if n == 0 or n > 32 then
        return nil
    end
    local i, count = 1, 0
    while i <= n do
        local two = s:sub(i, i + 1)
        if INITIALS[two] then
            i = i + 2
        elseif INITIALS[s:sub(i, i)] then
            i = i + 1
        else
            return nil
        end
        count = count + 1
    end
    return count
end

function M.is_abbrev_seq(s)
    return parse_abbrev(s) ~= nil
end

function M.abbrev_syllable_count(s)
    return parse_abbrev(s) or 0
end

-- 辅音简拼判定：纯字母、不含元音(aeiou)、长度 2-8、且可解析为合法声母序列。
-- 用于区分「中文简拼」（sm/wsm/bcd —— 声母全是辅音 b p m f d t n l g k h
-- j q x zh ch sh r z c s y w，无一含 aeiou）与「真英文词」（app/cpu/ios ——
-- 含元音字母）。
-- 🔥 不要用 is_abbrev_seq 做英文守卫：它把零声母 a/e/o 也当合法单元，
-- app=a-p-p 会被误判成简拼，导致打 app 时英文被错误沉底。
-- 辅音简拼排除 aeiou，天然把 app/cpu/ios 挡在外面。
function M.is_consonant_abbrev(s)
    local n = #s
    if n < 2 or n > 8 then
        return false
    end
    if s:find("[aeiou]") then
        return false
    end
    if not s:match("^%a+$") then
        return false
    end
    return parse_abbrev(s) ~= nil
end

-- 音节前缀集合（is_partial_pinyin 用）：所有音节的真前缀
local PREFIXES = {}
for w in pairs(SYLLABLES) do
    for L = 1, #w - 1 do
        PREFIXES[w:sub(1, L)] = true
    end
end
-- 声母也是合法中间态片段（打 wo 后再按 m → wom，m 是声母）
for w in pairs(INITIALS) do
    PREFIXES[w] = true
end

-- 拼音中间态判定：code = 若干完整音节 + 一个合法片段（音节真前缀或声母）。
-- 用户逐键打中文的每一个半途状态都命中：wom(=wo+m) / nih(=ni+h) / lis(=li+s)
-- / sh(=声母) / zho(=zhong前缀)。真英文词不命中：centri(cen+tri,tri非前缀)
-- / list(li+st,st非前缀) / hello(he+llo,llo非前缀)。
-- 🔥 用途（2026-09-12 三症同族根治）：en_full 40万词库混着 sh/wom/nih/lis 这类
-- ECDICT 冷僻词条，恰好等于拼音中间态编码——打 women 途中（wom）英文鬼词抢首位。
-- 中间态时英文精确词（text==code）也必须沉底。
function M.is_partial_pinyin(s)
    local n = #s
    if n == 0 or n > 32 then
        return false
    end
    for cut = 0, n - 1 do
        local frag = s:sub(cut + 1)
        if PREFIXES[frag] and (cut == 0 or M.is_pinyin_seq(s:sub(1, cut))) then
            return true
        end
    end
    return false
end

-- 含 CJK 汉字判定（Lua pattern 是字节级的，多字节字符必须走 utf8.codes）
function M.has_cjk(s)
    for _, c in utf8.codes(s) do
        if c >= 0x4E00 and c <= 0x9FFF then
            return true
        end
    end
    return false
end

return M
