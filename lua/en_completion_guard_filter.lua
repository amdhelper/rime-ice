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
    if not is_pinyin_seq(clean) then
        -- 非拼音序列 = 用户在查英文词：原样放行（前缀补全保持可见）
        for cand in input:iter() do
            yield(cand)
        end
        return
    end
    -- 拼音序列 = 用户在打中文：英文前缀补全沉底（完整键入的英文词不动）
    local pending_en = {}
    local n = 0
    for cand in input:iter() do
        n = n + 1
        if n > 500 then
            yield(cand)
        elseif cand.text:match("^[%a'%-]+$") and cand.text:lower() ~= code:lower() then
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
