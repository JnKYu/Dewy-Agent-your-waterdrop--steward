# Dewy Baseline Evaluation Set

## 用途

这是一份全虚构的基准测评集，用来比较 Dewy 当前 Gemini + 本地函数调用流程与之后的 LangGraph 版本。JSONL 每行是一个 LangSmith dataset example：`inputs` 为固定时钟、用户输入和模拟本地状态；`outputs` 为预期工具调用及行为断言；`metadata` 为分类标签。

## 覆盖范围

共 **66** 条用例，包含饮水、待办、活动、专注、工作自动归档、饮食、睡眠、目标、日历、习惯、聊天式画像查看/确认/修改/删除、摘要、日期、排版、工具失败与复合请求。

## 数据安全与使用边界

- 所有姓名、习惯、任务、日程与时间均为虚构；不可把真实聊天、真实 `records.json` 或 API Key 合并进来。
- 当前 `outputs` 是行为参考，不是要求助手逐字复述的标准答案。工具参数可以做字段级比对，回复质量断言需人工或评分器判断。
- `must_not_write=true` 的用例必须验证没有触发写入工具；歧义案例要检查是否先追问。
- 本数据集不应连接真实日历或真实本地记录。用模拟函数/临时数据运行。
- 画像候选确认/忽略现在通过聊天文本触发；精确更新和删除由本地函数验证。仍应使用模拟数据，不连接真实画像。

## 推荐评估顺序

1. 先检查 JSONL 每行都能解析，并确认例子数与分类。
2. 建 LangSmith Dataset `dewy-baseline`，将每行的 `inputs`、`outputs` 和 `metadata` 导入。
3. 用独立 runner 调用 Gemini，捕获 function calls；不要执行真实副作用，改用 fake tool executor。
4. 先用规则评分：工具名、关键参数、是否应澄清、禁止写入是否满足。
5. 对语气、清晰度、事实忠实度等开放指标再人工抽查或用 evaluator。
6. JSONL 中已标记 `development` 与约 20% 的 `holdout`；不要用 holdout 持续调整 prompt。LangGraph 版本使用同一份数据进行对照实验。

## 字段说明

- `inputs.now`: 固定本地时间，日期计算不可依赖运行机器的真实时钟。
- `inputs.local_context`: runner 注入的虚构本地数据；可按每条用例裁剪。
- `inputs.user`: 单轮主输入；需要多轮上下文时另有 `inputs.conversation`。
- `outputs.expected_tool_calls`: 预期工具和关键参数；空数组表示不应调用工具。
- `outputs.must_ask`: 是否必须先向用户澄清。
- `outputs.must_not_write`: 是否禁止任何写入操作。
- `outputs.response_checks`: 回复的语义检查项，不做全文字符串相等比较。
- `metadata`: case id、功能分类、难度和 synthetic 标记。
