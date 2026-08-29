--[[
	英文直出（2026-08-29 新增，rimi v0.2.12）
	需求：中文输入法开着时，输入框里已经打了一串字母（如 wumi）——
	若第一屏候选里没有想要的英文命中（或者这串字母是词库里根本不存在的
	罕见英文，如 "wumi"），按【左侧 Shift】直接把这串字母作为英文上屏。

	标准 RIME lua API：
	- key:repr()  → 键名字符串（X11 keysym 名），左 Shift 返回 "Shift_L"
	- key:release() → bool，是否按键释放事件（只处理按下，防双击）
	- context:is_composing() → bool，是否正在组成
	- context.input  → 当前输入（拼音串可能含空格分隔，如 "wu mi"）
	- context:get_selected_candidate() → 当前选中候选
	- engine:commit_text(s) → 直接上屏文本
	- context:clear() → 清空 composition

	挂载（两个方案 engine/processors，放在 ascii_composer 之后、recognizer 之前）：
		- lua_processor@*direct_eng

	防误触：仅「左 Shift 按下 + 正在组成 + input 去掉空格后纯英文」时上屏；
	ascii_mode 或未在打字时全放行给 RIME 默认（Shift 中英切换不受影响）。
--]]
local function direct_eng(key, env)
  -- 只处理「左 Shift」按下（屏蔽释放，防按压抖动）
  if key:release() then
    return 2
  end
  if key:repr() ~= "Shift_L" then
    return 2  -- 非左 Shift，交下游
  end

  local ctx = env.engine.context
  -- 仅在正在组成时才有意义；ascii_mode（西文态）放行给 RIME 中英切换
  if env.engine.context:is_ascii_mode() ~= false and env.engine.context:is_ascii_mode() then
    return 2
  end
  if not ctx:is_composing() then
    return 2
  end

  local input = ctx.input or ""
  -- 拼音串可能带空格分隔（"wu mi"），去空格后只留字母
  local letters = input:gsub("%s", "")
  if letters == "" or not letters:match("^[a-zA-Z]+$") then
    return 2  -- 非纯英文（含数字/符号）放行
  end

  if env.engine.context.input ~= "" then
    log.info("[direct_eng] Shift 直出英文: " .. letters)
  end
  -- 上屏为英文原文
  env.engine:commit_text(letters)
  ctx:clear()
  return 1  -- kAccept
end

return direct_eng
