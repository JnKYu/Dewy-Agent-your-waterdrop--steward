import Foundation
import EventKit

extension DewyStore {
    func send(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let turnID = UUID()
        appendMessage(ChatLine(id: turnID, role: .user, text: text))
        if let answer = handleProfileCandidateReply(text) {
            appendMessage(ChatLine(role: .assistant, text: answer)); return
        }
        if let answer = localAction(for: text) {
            appendMessage(ChatLine(role: .assistant, text: answer)); return
        }
        if !apiKey.isEmpty, !data.settings.modelName.isEmpty {
            Task { await askModel(text, turnID: turnID) }
        } else {
            appendMessage(ChatLine(role: .assistant, text: localReply(text)))
        }
    }

    private func localAction(for text: String) -> String? {
        let lower = text.lowercased()
        let intentGroups = [
            ["喝水", "喝了", "饮水"], ["待办", "任务"], ["专注"],
            ["工作记录", "记录工作"], ["早餐", "午餐", "晚餐", "加餐", "吃了"],
            ["睡眠"], ["目标", "进度", "进展"], ["总结", "日报", "周报", "月报"],
            ["娱乐", "运动", "休息", "社交"]
        ]
        if intentGroups.filter({ group in group.contains(where: { lower.contains($0) }) }).count > 1 {
            return nil // 复合请求交由 Gemini 通过 function calling 拆解
        }
        if lower.contains("帮助") || lower == "help" { return "你可以试试：\n· 喝水 / 喝了 350ml\n· 新增待办：整理资料\n· 完成：整理资料\n· 开始专注 / 结束专注\n· 工作记录：今天完成了…\n· 早餐：燕麦和牛奶\n· 睡眠 23:00-07:00\n· 目标：完成作品集\n· 今日总结 / 周总结 / 月总结" }
        if lower.contains("今日总结") || lower.contains("日报") { return dailySummary() }
        if lower.contains("上周总结") || lower.contains("上周复盘") {
            if ["建议", "分析", "评价"].contains(where: { lower.contains($0) }) { return nil }
            return previousWeekReviewText()
        }
        if lower.contains("周总结") || lower.contains("周报") { return dailySummary(period: "week") }
        if lower.contains("月总结") || lower.contains("月报") { return dailySummary(period: "month") }
        if lower.contains("结束专注") || lower.contains("停止专注") || lower.contains("完成专注") { return stopFocus() }
        if lower.contains("取消专注") || lower.contains("中断专注") { return stopFocus(cancel: true) }
        if lower.contains("开始专注") || lower == "专注" || lower.hasPrefix("专注：") || lower.hasPrefix("专注:") {
            let task = text.components(separatedBy: CharacterSet(charactersIn: ":：")).dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
            let linkedTask = data.tasks.first(where: { !$0.title.isEmpty && $0.title.localizedCaseInsensitiveCompare(task) == .orderedSame })
            return startFocus(task: task.isEmpty ? "未关联任务" : task, taskID: linkedTask?.id)
        }
        if lower.contains("喝水") || lower.contains("喝了一杯") || lower.contains("饮水") {
            let amount = Self.firstNumber(in: text)
            let ml = amount.map { value in (lower.contains("杯") && !lower.contains("ml") && !lower.contains("毫升")) ? value * data.settings.cupMilliliters : value } ?? data.settings.cupMilliliters
            return addWater(ml)
        }
        if lower.hasPrefix("新增待办") || lower.hasPrefix("待办") || lower.hasPrefix("添加任务") {
            return addTask(Self.afterColonOrPrefix(text, prefixes: ["新增待办", "待办", "添加任务"]))
        }
        if lower.hasPrefix("完成：") || lower.hasPrefix("完成:") || lower.hasPrefix("完成 ") {
            let query = Self.afterColonOrPrefix(text, prefixes: ["完成"])
            if let index = data.tasks.firstIndex(where: { $0.status != "已完成" && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)) }) {
                markTaskCompleted(data.tasks[index].id); return "完成啦，真棒。\(data.tasks[index].title) 已标记完成，给自己一点小奖励吧。"
            }
            return "我暂时没找到这条待办。你可以告诉我完整的待办名称。"
        }
        if lower.hasPrefix("工作记录") || lower.hasPrefix("记录工作") || lower.hasPrefix("工作：") || lower.hasPrefix("工作:") {
            return addWork(Self.afterColonOrPrefix(text, prefixes: ["工作记录", "记录工作", "工作"]))
        }
        if ["娱乐", "运动", "休息", "社交"].contains(where: { lower.hasPrefix($0) }) {
            let category = ["娱乐", "运动", "休息", "社交"].first(where: { lower.hasPrefix($0) }) ?? "休息"
            return addActivity(Self.afterColonOrPrefix(text, prefixes: [category]), category: category)
        }
        if lower.hasPrefix("目标") || lower.hasPrefix("设定目标") {
            return addGoal(Self.afterColonOrPrefix(text, prefixes: ["设定目标", "目标"]))
        }
        if lower.hasPrefix("睡眠") {
            let matches = text.range(of: #"\d{1,2}:\d{2}\s*[-至~—]\s*\d{1,2}:\d{2}"#, options: .regularExpression).map { String(text[$0]) }
            if let span = matches {
                let times = span.components(separatedBy: CharacterSet(charactersIn: "-至~—")).map { $0.trimmingCharacters(in: .whitespaces) }
                if times.count == 2 { return addSleep(bedtimeText: times[0], wakeText: times[1]) }
            }
            return "可以这样记录睡眠：睡眠 23:00-07:00。"
        }
        if ["早餐", "午餐", "晚餐", "加餐", "吃了"].contains(where: { lower.hasPrefix($0) }) {
            let meal = Self.afterColonOrPrefix(text, prefixes: ["早餐", "午餐", "晚餐", "加餐", "吃了"])
            return addMeal(meal.isEmpty ? text : meal)
        }
        if (lower.contains("进度：") || lower.contains("进度:") || lower.contains("进展：") || lower.contains("进展:")), !data.goals.isEmpty {
            let update = Self.afterColonOrPrefix(text, prefixes: ["进度", "进展"])
            let parts = update.components(separatedBy: CharacterSet(charactersIn: "-—，,"))
            let query = parts.first?.trimmingCharacters(in: .whitespaces) ?? ""
            let progress = parts.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if let index = data.goals.firstIndex(where: { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }) {
                let value = progress.isEmpty ? update : progress
                setGoalProgress(id: data.goals[index].id, progress: value)
                return "目标进展记下啦：\(data.goals[index].title) · \(value)。"
            }
            return "我还没找到这个目标。可以告诉我目标名称和这次进展。"
        }
        if lower.contains("进度") && !data.goals.isEmpty {
            return "你可以这样更新目标：进展：\(data.goals[0].title) - 已完成第一步。"
        }
        return nil
    }

    private func localReply(_ text: String) -> String {
        let lower = text.lowercased()
        if ["自伤", "自残", "不想活", "想死"].contains(where: { lower.contains($0) }) {
            return "听到你现在这么难受，我很在意你的安全。请现在联系一位信任的人陪着你；如果你正处于立即伤害自己的危险，请联系当地紧急服务或前往最近的急诊。你现在身边有可以联系的人吗？"
        }
        if ["累", "疲惫", "焦虑", "沮丧", "难过", "烦", "压力", "撑不住"].contains(where: { lower.contains($0) }) {
            return "听起来今天真的消耗了你很多能量。你愿意多和我说一点吗？如果现在觉得很堵，也可以先离开任务几分钟，去窗边站一会儿、喝口水，等呼吸平复了我们再决定下一步。"
        }
        if lower.contains("你好") || lower.contains("早安") { return "早安。你想先看看今天的安排，还是先慢慢开始？" }
        if lower.contains("喝水") { return "我可以帮你记录饮水。直接说“喝水”或“喝了 350ml”就好。" }
        return "我在这里。你可以告诉我想记录或安排什么；输入“帮助”可以查看我现在支持的指令。\n\n如果在设置里接入兼容的语言模型，我也可以进行更开放的对话。"
    }

    private func askModel(_ text: String, turnID: UUID) async {
        let apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            appendMessage(ChatLine(role: .assistant, text: "还没有设置 Google API Key。请先在设置里填入 API Key 后再试。"))
            return
        }

        let configuredModel = data.settings.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelName = configuredModel.isEmpty ? "gemini-3.8-flash" : configuredModel
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(modelName):generateContent") else {
            appendMessage(ChatLine(role: .assistant, text: "模型服务地址看起来不太对，可以在设置里检查一下。"))
            return
        }

        var request = URLRequest(url: url); request.httpMethod = "POST"; request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

        let system = """
        你是 Dewy，一位温柔而坚定的私人管家。

        ## 语言与语气
        - 使用简体中文。
        - 语气柔和、明确、简短，不说教。
        - 不编造用户记录。
        - 用户疲惫或焦虑时，先共情倾听，暂停催促。

        ## 回复排版
        - 每个要点单独一行，用 "- " 开头的 Markdown 列表。
        - 不同主题之间用一个空行分隔。
        - 单个段落不超过三句话。
        - 分阶段计划按下面的格式输出，标题独占一行，前后各空一行：

        ### 第一阶段：阶段名称

        - 要点一
        - 要点二

        ### 第二阶段：阶段名称

        - 要点一
        - 要点二

        ## 画像回复方式
        - 用户问“你记得我什么”“你了解我哪些偏好”时，用一到两句自然、温暖的口语概括；除非用户明确要求清单，否则不要用项目符号或复述类别标签。
        - 可用“我记得你……”自然带出已确认事实，避免“你目前确认保存了”“画像如下”等生硬措辞。
        - 待确认候选要与已确认画像分开表达。可以说“你之前提到……，我还没有把它记下来；你希望我也记住吗？”并等待明确答复。
        - 没有待确认候选时，不要额外提起候选流程；不得补充画像中没有的性格、经历或偏好。
        - 例如： “我记得你喜欢简洁直接的回答，也在朝着 Agent 工程实习的目标努力。你之前还提到想每天早上 7 点起床，我还没有把这件事记下来；你希望我也记住吗？”

        ## 已确认的长期用户画像
        \(profileFactsContext(for: messages.last(where: { $0.role == .user })?.text ?? ""))
        用户询问画像、明确要求修改或删除画像时，提供完整画像供本轮准确匹配；普通问题只带入相关画像。

        ## 待确认画像候选
        \(data.profileCandidates.first.map { "[\($0.category)] \($0.content)" } ?? "无待确认候选")
        候选确认只在聊天中处理。无冲突候选：询问用户是否保存；用户明确同意后本地确认，明确拒绝后丢弃。若候选标记了相似旧画像，必须让用户选择“更新”“另存”或“忽略”，不能将普通“好”解释成更新旧项。

        ## 当地本地记录摘要
        - 当前本地日期时间：\(Date.now.formatted(date: .complete, time: .shortened))（\(TimeZone.current.identifier)）
        - 今日饮水：\(waterToday) ml
        - 杯子容量：\(data.settings.cupMilliliters) ml
        - 未完成待办：\(openTasksToday.map(\.title).joined(separator: "、"))
        - 专注计时：\(focusIsRunning ? "进行中" : "未进行")

        ## 本地函数调用
        - 用户明确说“记住我……”时调用 remember_profile_fact；这是明确授权，可直接保存。
        - 用户没有明确要求保存，但明确说出稳定偏好、长期目标、固定作息或职业/学习背景时，可调用 propose_profile_fact 建立候选；不得推测、概括人格、保存短期状态或敏感信息。每轮最多一条，事实不明确就不提议。
        - 候选在聊天中确认。相似候选必须让用户选择更新、另存或忽略；只有工具/本地操作成功后才能确认已保存。
        - 用户询问“你记得我什么”等画像问题时调用 get_user_profile。用户明确要求修改或删除画像时调用 update_profile_fact 或 delete_profile_fact；按原画像内容或唯一类别精确匹配。未匹配或匹配多条时列出可选项并先询问，禁止猜测覆盖。
        - 用户明确要求记录或管理事项时，调用对应的本地函数。
        - 用户询问日历安排、明确要求创建/修改/删除日程时，调用相应日历函数。使用上面的本地日期时间解释“今天/明天/下周”；日期或事件匹配不明确时先询问。
        - 删除或修改日历事件必须由用户明确提出；按事件标题和日期唯一匹配，本地返回多条时不要猜选。
        - 用户明确要求查看、创建、改名、调整计划日/休息日、设置或关闭习惯提醒、删除习惯或打卡时，调用相应习惯函数。weekday 编号为周一=1至周日=7；省略创建习惯的计划日时默认为每天；提醒时间使用本地 24 小时制 HH:mm。
        - 习惯计划日的修改从明天起生效，历史统计使用每段时间当时的计划。
        - 用户要求把当前或刚结束的专注关联到待办时，调用 link_focus_task；除非用户明确指定目标记录，否则由本地优先匹配当前专注。
        - 复合请求可以调用多个函数。
        - 信息不足、任务无法唯一匹配或意图不明确时，先询问。
        - 函数执行由本地应用负责。
        - 只有收到函数执行结果后，才可以确认操作已完成。
        - 不要仅凭推测写入信息。

        ## 工作与学习事实自动归档
        - 当用户分享当天实际完成的工作、任务推进、目标进展，或与工作/学习相关的知识技能讨论时，主动使用 record_work 保存简短事实，不需要用户再次要求“记录”。
        - 只记录用户明确说过或已由本地操作确认的内容；把知识讨论写成“讨论/梳理了……”，不要夸大为“掌握/完成”。
        - 不要把未来计划、假设场景、你自己提出的建议或普通闲聊写成已完成事实。
        - 待办完成、目标进展、关联待办的专注结束会由本地代码自动归档；不要为同一事实重复调用 record_work。
        - 饮水、饮食、睡眠和专注时长由专门模块记录，不写入工作内容。
        """
        let recent = messages.suffix(12).map { message -> [String: String] in
            ["role": message.role == .assistant ? "model" : "user", "content": message.text]
        }
        let contentPayload: [[String: Any]] = recent.map { item in
            ["role": item["role"] ?? "user", "parts": [["text": item["content"] ?? ""]]]
        }
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": contentPayload,
            "tools": [["functionDeclarations": Self.geminiFunctionDeclarations]],
            "toolConfig": ["functionCallingConfig": ["mode": "AUTO"]]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        // Failed attempts can still consume project request quota; avoid automatic retries.
        let maxAttempts = 1
        for _ in 0..<maxAttempts {
            do {
                let (bytes, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    appendMessage(ChatLine(role: .assistant, text: "Gemini 没有返回有效的网络响应，请稍后重试。"))
                    return
                }
                if (200..<300).contains(http.statusCode) {
                    guard let payload = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
                          let candidate = (payload["candidates"] as? [[String: Any]])?.first,
                          let modelContent = candidate["content"] as? [String: Any],
                          let parts = modelContent["parts"] as? [[String: Any]] else {
                        appendMessage(ChatLine(role: .assistant, text: "我暂时没有收到有效回复，可以稍后再试。"))
                        return
                    }

                    let functionCalls = parts.compactMap { $0["functionCall"] as? [String: Any] }
                    if functionCalls.isEmpty {
                        let answer = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
                        appendMessage(ChatLine(role: .assistant, text: answer.isEmpty ? "我暂时没有收到有效回复，可以稍后再试。" : answer))
                        return
                    }

                    // Execute supported local functions, then ask Gemini once
                    // to turn the verified local results into a natural reply.
                    var localResults: [(name: String, result: String)] = []
                    for call in functionCalls {
                        let name = call["name"] as? String ?? ""
                        let arguments = call["args"] as? [String: Any] ?? [:]
                        let result = await executeLocalFunction(name: name, arguments: arguments, sourceTurnID: turnID)
                        localResults.append((name, result))
                    }

                    var followupContents = contentPayload.map { item -> [String: Any] in
                        ["role": item["role"] ?? "user", "parts": [["text": item["content"] ?? ""]]]
                    }
                    followupContents.append(["role": "model", "parts": parts])
                    followupContents.append([
                        "role": "function",
                        "parts": localResults.map { item in
                            ["functionResponse": ["name": item.name, "response": ["result": item.result]]] as [String: Any]
                        }
                    ])
                    var followupBody = body
                    followupBody["contents"] = followupContents
                    var followupRequest = URLRequest(url: url)
                    followupRequest.httpMethod = "POST"
                    followupRequest.timeoutInterval = 45
                    followupRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    followupRequest.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
                    followupRequest.httpBody = try? JSONSerialization.data(withJSONObject: followupBody)

                    do {
                        let (followupBytes, followupResponse) = try await URLSession.shared.data(for: followupRequest)
                        if let followupHTTP = followupResponse as? HTTPURLResponse,
                           (200..<300).contains(followupHTTP.statusCode),
                           let followupPayload = (try? JSONSerialization.jsonObject(with: followupBytes)) as? [String: Any],
                           let followupCandidate = (followupPayload["candidates"] as? [[String: Any]])?.first,
                           let followupModelContent = followupCandidate["content"] as? [String: Any],
                           let followupParts = followupModelContent["parts"] as? [[String: Any]] {
                            let polished = followupParts.compactMap { $0["text"] as? String }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                            appendMessage(ChatLine(role: .assistant, text: polished.isEmpty ? localResults.map(\.result).joined(separator: "\n") : polished))
                        } else {
                            appendMessage(ChatLine(role: .assistant, text: localResults.map(\.result).joined(separator: "\n")))
                        }
                    } catch {
                        // The local action already succeeded; always show its verified result.
                        appendMessage(ChatLine(role: .assistant, text: localResults.map(\.result).joined(separator: "\n")))
                    }
                    return
                }

                let payload = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
                let errorObject = payload?["error"] as? [String: Any]
                let detail = errorObject?["message"] as? String
                if http.statusCode == 503 {
                    appendMessage(ChatLine(role: .assistant, text: "Gemini 当前请求量较高，服务暂时繁忙（503）。这通常不是配额耗尽；为避免自动消耗额外请求，请稍后手动重试，或在设置中更换当前可用的模型。"))
                } else if http.statusCode == 429 {
                    appendMessage(ChatLine(role: .assistant, text: "Gemini 暂时拒绝了请求（429）。这通常是请求频率或每日配额限制；请在 Google AI Studio 查看此项目的用量与限额，再稍后重试。"))
                } else {
                    appendMessage(ChatLine(role: .assistant, text: "Gemini 请求失败（\(http.statusCode)）。\(detail ?? "请检查 API Key、模型名称和 Google AI Studio 项目设置。")"))
                }
                return
            } catch is CancellationError {
                return
            } catch {
                appendMessage(ChatLine(role: .assistant, text: "暂时连不上 Google Gemini 服务。你的本地记录仍然安全保存；请检查网络后再试。"))
                return
            }
        }
    }

    private static var geminiFunctionDeclarations: [[String: Any]] {
        [
            ["name": "record_water", "description": "记录用户明确报告的饮水量，单位毫升。未说明容量时省略 amount_ml，由本地使用杯子设置值。", "parameters": ["type": "OBJECT", "properties": ["amount_ml": ["type": "INTEGER", "description": "饮水量，毫升；未说明时省略"]]]],
            ["name": "add_task", "description": "新增用户明确要求记录的待办。", "parameters": ["type": "OBJECT", "properties": ["title": ["type": "STRING", "description": "待办标题"]], "required": ["title"]]],
            ["name": "complete_task", "description": "将用户明确指出且唯一匹配的已有待办标记为完成。", "parameters": ["type": "OBJECT", "properties": ["title": ["type": "STRING", "description": "待办标题或唯一匹配关键词"]], "required": ["title"]]],
            ["name": "add_activity", "description": "记录用户明确安排的娱乐、运动、休息或社交活动。", "parameters": ["type": "OBJECT", "properties": ["title": ["type": "STRING", "description": "活动内容"] , "category": ["type": "STRING", "enum": ["娱乐", "运动", "休息", "社交"], "description": "活动类别"]], "required": ["title", "category"]]],
            ["name": "start_focus", "description": "开始专注计时；关联已有待办时必须提供它的准确标题，不关联时省略 task_title。", "parameters": ["type": "OBJECT", "properties": ["task_title": ["type": "STRING", "description": "已有待办的准确标题，可省略"]]]],
            ["name": "link_focus_task", "description": "将当前进行中的专注，或最近结束的一段专注，关联到已有待办。必须提供待办准确标题；用户明确指定当前或结束记录时，传 session_scope=current 或 latest_ended，否则省略并由本地优先匹配当前专注。", "parameters": ["type": "OBJECT", "properties": ["task_title": ["type": "STRING", "description": "已有待办的准确标题"], "session_scope": ["type": "STRING", "enum": ["current", "latest_ended"], "description": "可选，当前进行中的专注或最近结束的专注"]], "required": ["task_title"]]],
            ["name": "stop_focus", "description": "结束当前正在进行的专注计时。", "parameters": ["type": "OBJECT", "properties": [String: Any]()]],
            ["name": "record_work", "description": "自动归档用户当天明确分享的实际工作、任务推进、目标进展或工作学习相关知识讨论；不可记录未来计划或助手建议。", "parameters": ["type": "OBJECT", "properties": ["details": ["type": "STRING", "description": "工作记录正文"]], "required": ["details"]]],
            ["name": "remember_profile_fact", "description": "仅当用户明确说“记住/以后记得”等并给出稳定的个人偏好、称呼、长期目标或作息事实时直接保存到长期画像；绝不可保存模型推测内容。", "parameters": ["type": "OBJECT", "properties": ["category": ["type": "STRING", "description": "画像分类，如称呼、偏好、长期目标、作息"], "content": ["type": "STRING", "description": "用户明确要求记住的内容"]], "required": ["category", "content"]]],
            ["name": "propose_profile_fact", "description": "当用户明确说出稳定且未来有用的偏好、长期目标、固定作息或职业/学习背景，但没有直接要求保存时，创建待用户确认的画像候选。只基于用户原话，不要推测；每轮最多一条。", "parameters": ["type": "OBJECT", "properties": ["category": ["type": "STRING", "description": "画像分类，如称呼、偏好、长期目标、作息、职业学习"], "content": ["type": "STRING", "description": "忠实概括用户明确陈述的单条事实"]], "required": ["category", "content"]]],
            ["name": "get_user_profile", "description": "用户询问当前长期画像、已保存偏好、待确认画像候选时读取本地画像。", "parameters": ["type": "OBJECT", "properties": [String: Any]()]],
            ["name": "update_profile_fact", "description": "用户明确要求修改一条已有画像时调用。selector 应使用上下文中的原画像内容或唯一类别；本地只精确匹配唯一条目，不确定时会要求澄清。", "parameters": ["type": "OBJECT", "properties": ["selector": ["type": "STRING", "description": "现有画像的准确内容或唯一类别"], "new_content": ["type": "STRING", "description": "更新后的画像内容"], "new_category": ["type": "STRING", "description": "可选的新类别"]], "required": ["selector", "new_content"]]],
            ["name": "delete_profile_fact", "description": "用户明确要求忘记或删除已有画像时调用。selector 应使用画像准确内容或唯一类别；本地只在唯一匹配时删除。", "parameters": ["type": "OBJECT", "properties": ["selector": ["type": "STRING", "description": "画像准确内容或唯一类别"]], "required": ["selector"]]],
            ["name": "record_meal", "description": "记录用户明确报告的饮食内容。", "parameters": ["type": "OBJECT", "properties": ["details": ["type": "STRING", "description": "饮食内容"]], "required": ["details"]]],
            ["name": "record_sleep", "description": "记录用户明确提供的睡觉和起床时间，格式 HH:mm。", "parameters": ["type": "OBJECT", "properties": ["bedtime": ["type": "STRING", "description": "入睡时间，如 23:00"], "wake_time": ["type": "STRING", "description": "起床时间，如 07:00"], "note": ["type": "STRING", "description": "可选备注"]], "required": ["bedtime", "wake_time"]]],
            ["name": "add_goal", "description": "记录用户明确提出的目标；若期限或完成标准不足，本地逻辑会继续询问。", "parameters": ["type": "OBJECT", "properties": ["title": ["type": "STRING", "description": "目标描述"]], "required": ["title"]]],
            ["name": "update_goal_progress", "description": "更新用户明确指定且唯一匹配的目标进展。", "parameters": ["type": "OBJECT", "properties": ["goal_title": ["type": "STRING", "description": "目标标题或唯一匹配关键词"], "progress": ["type": "STRING", "description": "本次进展"]], "required": ["goal_title", "progress"]]],
            ["name": "get_summary", "description": "读取本地记录并生成日、当前周、上周或月总结。", "parameters": ["type": "OBJECT", "properties": ["period": ["type": "STRING", "enum": ["day", "week", "previous_week", "month"], "description": "总结周期；上周使用 previous_week"]], "required": ["period"]]],
            ["name": "list_calendar_events", "description": "读取 Mac 系统日历中的事件。start_at 与 end_at 必须使用包含时区的 ISO 8601 日期时间。仅在用户询问日程时调用。", "parameters": ["type": "OBJECT", "properties": ["start_at": ["type": "STRING", "description": "查询开始时间，如 2026-11-21T00:00:00+08:00"], "end_at": ["type": "STRING", "description": "查询结束时间，如 2026-11-22T00:00:00+08:00"]], "required": ["start_at", "end_at"]]],
            ["name": "create_calendar_event", "description": "在 Mac 默认系统日历创建用户明确要求的事件。标题、开始和结束时间必须明确；时间使用包含本地时区偏移的 ISO 8601。", "parameters": ["type": "OBJECT", "properties": ["title": ["type": "STRING", "description": "日程标题"], "start_at": ["type": "STRING", "description": "开始时间 ISO 8601，含时区偏移"], "end_at": ["type": "STRING", "description": "结束时间 ISO 8601，含时区偏移"]], "required": ["title", "start_at", "end_at"]]],
            ["name": "update_calendar_event", "description": "修改 Mac 系统日历事件。必须提供原事件准确标题和日期；只传需要修改的新字段。匹配不唯一时本地会拒绝修改。", "parameters": ["type": "OBJECT", "properties": ["title": ["type": "STRING", "description": "现有日程准确标题"], "date": ["type": "STRING", "description": "现有日程日期，格式 YYYY-MM-DD"], "new_title": ["type": "STRING", "description": "可选的新标题"], "start_at": ["type": "STRING", "description": "可选的新开始时间，ISO 8601 含时区偏移"], "end_at": ["type": "STRING", "description": "可选的新结束时间，ISO 8601 含时区偏移"]], "required": ["title", "date"]]],
            ["name": "delete_calendar_event", "description": "删除用户明确指定的 Mac 系统日历事件。必须提供准确标题和日期；匹配不唯一时本地会拒绝删除。", "parameters": ["type": "OBJECT", "properties": ["title": ["type": "STRING", "description": "日程准确标题"], "date": ["type": "STRING", "description": "日程日期，格式 YYYY-MM-DD"]], "required": ["title", "date"]]],
            ["name": "list_habits", "description": "查询本地习惯列表、每周计划日、今日打卡状态、近30天完成率和历史最高连续打卡。", "parameters": ["type": "OBJECT", "properties": [String: Any]()]],
            ["name": "create_habit", "description": "创建用户明确要求的新习惯。省略 weekdays 时默认每天；weekday 编号为周一=1至周日=7；可选 reminder_time 使用本地 HH:mm。", "parameters": ["type": "OBJECT", "properties": ["title": ["type": "STRING", "description": "习惯名称"], "weekdays": ["type": "ARRAY", "items": ["type": "INTEGER"], "description": "可选计划日，周一=1至周日=7；省略代表每天"], "rest_days": ["type": "ARRAY", "items": ["type": "INTEGER"], "description": "可选固定休息日，周一=1至周日=7"], "reminder_time": ["type": "STRING", "description": "可选本地提醒时间 HH:mm，例如 20:30"]], "required": ["title"]]],
            ["name": "update_habit", "description": "修改唯一匹配的习惯名称、每周计划日或固定休息日。提供准确的现有标题；计划变更从明天起生效并保留历史统计。", "parameters": ["type": "OBJECT", "properties": ["title": ["type": "STRING", "description": "现有习惯准确名称"], "new_title": ["type": "STRING", "description": "可选的新名称"], "weekdays": ["type": "ARRAY", "items": ["type": "INTEGER"], "description": "可选计划日，周一=1至周日=7"], "rest_days": ["type": "ARRAY", "items": ["type": "INTEGER"], "description": "可选固定休息日，周一=1至周日=7"]], "required": ["title"]]],
            ["name": "set_habit_reminder", "description": "设置或关闭唯一匹配习惯的本地提醒。time 使用 HH:mm；传“关闭”可停用提醒。", "parameters": ["type": "OBJECT", "properties": ["title": ["type": "STRING", "description": "习惯准确名称"], "time": ["type": "STRING", "description": "本地时间 HH:mm，或“关闭”"]], "required": ["title", "time"]]],
            ["name": "delete_habit", "description": "删除用户明确指定的习惯及其打卡记录。必须提供准确习惯名称。", "parameters": ["type": "OBJECT", "properties": ["title": ["type": "STRING", "description": "习惯准确名称"]], "required": ["title"]]],
            ["name": "check_in_habit", "description": "为用户明确指定的习惯记录打卡；日期可省略为今天，过去日期作为补记并标注记录时间，不可对未来日期打卡。重复打卡不会重复添加。", "parameters": ["type": "OBJECT", "properties": ["title": ["type": "STRING", "description": "习惯准确名称"], "date": ["type": "STRING", "description": "可选日期 YYYY-MM-DD，省略为今天"]], "required": ["title"]]]
        ]
    }

    private func executeLocalFunction(name: String, arguments: [String: Any], sourceTurnID: UUID) async -> String {
        func string(_ key: String, maxLength: Int = 500) -> String? {
            guard let value = arguments[key] as? String else { return nil }
            let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return !clean.isEmpty && clean.count <= maxLength ? clean : nil
        }

        func timeParts(_ raw: String) -> (hour: Int, minute: Int)? {
            let parts = raw.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2, (0...23).contains(parts[0]), (0...59).contains(parts[1]) else { return nil }
            return (parts[0], parts[1])
        }

        func dateValue(_ raw: String) -> Date? {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = iso.date(from: raw) { return date }
            iso.formatOptions = [.withInternetDateTime]
            if let date = iso.date(from: raw) { return date }
            let local = DateFormatter()
            local.locale = Locale(identifier: "en_US_POSIX")
            local.timeZone = .current
            local.dateFormat = raw.contains("T") ? "yyyy-MM-dd'T'HH:mm:ss" : "yyyy-MM-dd"
            return local.date(from: raw)
        }

        switch name {
        case "propose_profile_fact":
            guard let category = string("category", maxLength: 40), let content = string("content", maxLength: 500) else {
                return "画像候选格式无效，没有保存。"
            }
            return proposeProfileFact(category: category, content: content)
        case "get_user_profile":
            return userProfileText()
        case "update_profile_fact":
            guard let selector = string("selector", maxLength: 500), let content = string("new_content", maxLength: 500) else {
                return "修改画像需要提供要匹配的原内容和新内容。"
            }
            return updateProfileFact(matching: selector, newCategory: string("new_category", maxLength: 40), newContent: content)
        case "delete_profile_fact":
            guard let selector = string("selector", maxLength: 500) else { return "删除画像需要指定要删除的内容或类别。" }
            return deleteProfileFact(matching: selector)
        case "remember_profile_fact":
            guard let category = string("category", maxLength: 40), let content = string("content", maxLength: 500) else {
                return "长期画像需要有效的分类和内容；没有保存任何信息。"
            }
            if data.profileFacts.contains(where: { $0.content.localizedCaseInsensitiveCompare(content) == .orderedSame }) {
                return "这条内容已在长期画像中，不需要重复添加。"
            }
            guard addProfileFact(category: category, content: content) else {
                return "长期画像没有保存成功，请检查本地存储空间或权限。"
            }
            return "已按你的明确要求，将「\(content)」保存到长期画像（\(category)）。你随时可以在聊天中让我查看、修改或忘掉。"
        case "record_water":
            let amount = arguments["amount_ml"] as? Int ?? data.settings.cupMilliliters
            guard (1...10_000).contains(amount) else { return "饮水量无效；请使用 1 到 10000 毫升之间的整数。" }
            return addWater(amount)
        case "add_task":
            guard let title = string("title", maxLength: 200) else { return "待办标题为空或太长，请重新确认。" }
            return addTask(title)
        case "complete_task":
            guard let query = string("title", maxLength: 200) else { return "请提供待办标题。" }
            let matches = data.tasks.indices.filter { data.tasks[$0].status != "已完成" && data.tasks[$0].title.localizedCaseInsensitiveContains(query) }
            guard matches.count == 1, let index = matches.first else { return matches.isEmpty ? "没有找到对应的未完成待办。" : "找到多条相似待办，请用户说明具体标题。" }
            markTaskCompleted(data.tasks[index].id)
            return "已标记完成：\(data.tasks[index].title)。"
        case "add_activity":
            guard let title = string("title", maxLength: 200), let category = string("category", maxLength: 10), ["娱乐", "运动", "休息", "社交"].contains(category) else { return "活动内容或类别无效，请重新确认。" }
            return addActivity(title, category: category)
        case "start_focus":
            if let title = string("task_title", maxLength: 200) {
                guard let task = data.tasks.first(where: { $0.title.localizedCaseInsensitiveCompare(title) == .orderedSame }) else { return "没有找到标题为“\(title)”的待办；请确认标题，或不关联任务开始专注。" }
                return startFocus(task: task.title, taskID: task.id)
            }
            return startFocus()
        case "stop_focus": return stopFocus()
        case "link_focus_task":
            guard let title = string("task_title", maxLength: 200) else { return "请提供要关联的待办准确名称。" }
            let scope = string("session_scope", maxLength: 20)
            return linkFocusTask(taskTitle: title, sessionScope: scope)
        case "record_work":
            guard let details = string("details") else { return "工作记录为空或太长，请重新确认。" }
            return addWork(details, source: "conversation", sourceID: "chat-turn:\(sourceTurnID.uuidString)")
        case "record_meal":
            guard let details = string("details") else { return "饮食记录为空或太长，请重新确认。" }
            return addMeal(details)
        case "record_sleep":
            guard let bedtime = string("bedtime", maxLength: 5), let wakeTime = string("wake_time", maxLength: 5) else { return "请提供睡觉和起床时间，例如 23:00 和 07:00。" }
            return addSleep(bedtimeText: bedtime, wakeText: wakeTime, note: string("note") ?? "")
        case "add_goal":
            guard let title = string("title", maxLength: 300) else { return "目标内容为空或太长，请重新确认。" }
            return addGoal(title)
        case "update_goal_progress":
            guard let title = string("goal_title", maxLength: 200), let progress = string("progress") else { return "请提供目标名称和本次进展。" }
            let matches = data.goals.indices.filter { data.goals[$0].title.localizedCaseInsensitiveContains(title) }
            guard matches.count == 1, let index = matches.first else { return matches.isEmpty ? "没有找到对应目标。" : "找到多个相似目标，请用户说明具体目标名称。" }
            setGoalProgress(id: data.goals[index].id, progress: progress)
            return "目标进展已记录：\(data.goals[index].title) · \(progress)"
        case "list_calendar_events":
            guard let startText = string("start_at", maxLength: 40), let endText = string("end_at", maxLength: 40),
                  let start = dateValue(startText), let end = dateValue(endText), end > start,
                  end.timeIntervalSince(start) <= 93 * 24 * 60 * 60 else {
                return "查询时间范围无效；请提供不超过 93 天的明确起止时间。"
            }
            guard let events = await DewyCalendarStore.shared.listEvents(from: start, to: end) else {
                return "无法读取系统日历；请检查 Dewy 的日历访问权限和查询时间。"
            }
            guard !events.isEmpty else { return "该时间范围内没有日历事件。" }
            return events.prefix(80).map { event in
                "- \(event.startDate.formatted(date: .abbreviated, time: .shortened))–\(event.endDate.formatted(date: .omitted, time: .shortened))：\(event.title ?? "无标题")（\(event.calendar.title)）"
            }.joined(separator: "\n")
        case "create_calendar_event":
            guard let title = string("title", maxLength: 200), let startText = string("start_at", maxLength: 40), let endText = string("end_at", maxLength: 40),
                  let start = dateValue(startText), let end = dateValue(endText), end > start,
                  end.timeIntervalSince(start) <= 7 * 24 * 60 * 60 else {
                return "创建日程需要有效标题、起止时间，且时长不能超过 7 天。"
            }
            return await DewyCalendarStore.shared.createEvent(title: title, start: start, end: end)
        case "update_calendar_event":
            guard let title = string("title", maxLength: 200), let dateText = string("date", maxLength: 10),
                  let date = dateValue(dateText) else { return "修改日程需要原事件准确标题和日期。" }
            let newTitle = string("new_title", maxLength: 200)
            let start = string("start_at", maxLength: 40).flatMap(dateValue)
            let end = string("end_at", maxLength: 40).flatMap(dateValue)
            if arguments["start_at"] != nil && start == nil || arguments["end_at"] != nil && end == nil { return "新时间格式无效；请使用含时区的 ISO 8601 日期时间。" }
            return await DewyCalendarStore.shared.updateEvent(title: title, on: date, newTitle: newTitle, newStart: start, newEnd: end)
        case "delete_calendar_event":
            guard let title = string("title", maxLength: 200), let dateText = string("date", maxLength: 10),
                  let date = dateValue(dateText) else { return "删除日程需要准确标题和日期。" }
            return await DewyCalendarStore.shared.deleteEvent(title: title, on: date)
        case "list_habits":
            return habitListText()
        case "create_habit":
            guard let title = string("title", maxLength: 160) else { return "请提供有效的习惯名称。" }
            let weekdays = arguments["weekdays"] as? [Int]
            if let weekdays, weekdays.isEmpty || !weekdays.allSatisfy({ (1...7).contains($0) }) { return "计划日无效，请使用 1 到 7（周一到周日）。" }
            let restDays = arguments["rest_days"] as? [Int] ?? []
            if arguments["rest_days"] != nil && arguments["rest_days"] as? [Int] == nil || !restDays.allSatisfy({ (1...7).contains($0) }) { return "休息日格式无效，请使用 1 到 7（周一到周日）。" }
            guard !data.habits.contains(where: { $0.title.localizedCaseInsensitiveCompare(title) == .orderedSame }) else { return "已经存在名为「\(title)」的习惯；如需调整请调用 update_habit。" }
            let plannedDays = Set(weekdays ?? Array(1...7))
            let reminderText = string("reminder_time", maxLength: 5)
            if arguments["reminder_time"] != nil && reminderText == nil { return "提醒时间无效，请使用 HH:mm。" }
            let reminder = reminderText.flatMap(timeParts)
            if reminderText != nil && reminder == nil { return "提醒时间无效，请使用 24 小时制 HH:mm，例如 20:30。" }
            addHabit(title, weekdays: plannedDays, restDays: Set(restDays), reminderHour: reminder?.hour, reminderMinute: reminder?.minute)
            let reminderDescription = reminder.map { String(format: "，提醒时间 %02d:%02d", $0.hour, $0.minute) } ?? ""
            return "习惯「\(title)」已创建，计划日：\(weekdayText(plannedDays.subtracting(Set(restDays))))\(reminderDescription)。"
        case "update_habit":
            guard let title = string("title", maxLength: 160) else { return "请提供要修改的习惯准确名称。" }
            let weekdays = arguments["weekdays"] as? [Int]
            if arguments["weekdays"] != nil && weekdays == nil { return "计划日格式无效。" }
            let restDays = arguments["rest_days"] as? [Int]
            if arguments["rest_days"] != nil && restDays == nil { return "休息日格式无效。" }
            return updateHabit(named: title, newTitle: string("new_title", maxLength: 160), weekdays: weekdays.map(Set.init), restDays: restDays.map(Set.init))
        case "set_habit_reminder":
            guard let title = string("title", maxLength: 160), let time = string("time", maxLength: 10) else { return "请提供习惯准确名称和提醒时间；关闭提醒时传“关闭”。" }
            if ["关闭", "off", "none"].contains(time.lowercased()) { return setHabitReminder(named: title, hour: nil, minute: nil) }
            guard let parts = timeParts(time) else { return "提醒时间无效，请使用 24 小时制 HH:mm，例如 20:30。" }
            return setHabitReminder(named: title, hour: parts.hour, minute: parts.minute)
        case "delete_habit":
            guard let title = string("title", maxLength: 160) else { return "请提供要删除的习惯准确名称。" }
            return deleteHabit(named: title)
        case "check_in_habit":
            guard let title = string("title", maxLength: 160) else { return "请提供要打卡的习惯准确名称。" }
            let date: Date
            if let dateText = string("date", maxLength: 10) {
                guard let parsed = dateValue(dateText) else { return "补记日期格式无效，请使用 YYYY-MM-DD。" }
                date = parsed
            } else {
                date = Date()
            }
            return recordHabitCheckIn(named: title, on: date)
        case "get_summary":
            guard let period = string("period", maxLength: 20) else { return "请指定总结周期：day、week、previous_week 或 month。" }
            switch period {
            case "day": return dailySummary()
            case "week": return dailySummary(period: "week")
            case "previous_week": return previousWeekReviewText()
            case "month": return dailySummary(period: "month")
            default: return "总结周期无效，请使用 day、week、previous_week 或 month。"
            }
        default: return "Dewy 不支持此本地操作。"
        }
    }

    static func firstNumber(in text: String) -> Int? {
        guard let range = text.range(of: #"\d+"#, options: .regularExpression) else { return nil }
        return Int(text[range])
    }
    static func afterColonOrPrefix(_ text: String, prefixes: [String]) -> String {
        if let range = text.range(of: #"[:：]"#, options: .regularExpression) { return String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines) }
        for prefix in prefixes where text.lowercased().hasPrefix(prefix.lowercased()) {
            return String(text.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: " ：:，,\t"))
        }
        return text
    }
    static func timeToday(_ text: String) -> Date? {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return Calendar.current.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: Date())
    }
    func formatDuration(_ seconds: Int) -> String {
        let mins = seconds / 60
        return mins < 60 ? "\(mins) 分钟" : "\(mins / 60) 小时 \(mins % 60) 分钟"
    }
}

struct GoogleModelResponse: Decodable {
    struct Candidate: Decodable {
        let content: Content?
    }
    struct Content: Decodable {
        let parts: [Part]?
    }
    struct Part: Decodable {
        let text: String?
    }
    let candidates: [Candidate]?
}
