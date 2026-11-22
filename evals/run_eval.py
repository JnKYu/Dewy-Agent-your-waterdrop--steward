#!/usr/bin/env python3
"""Safely evaluate Dewy's Gemini function-calling behavior against LangSmith."""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from typing import Any

from langsmith import Client


DATASET_DEFAULT = "dewy-baseline"
MODEL_DEFAULT = "gemini-3.8-flash"
API_BASE = "https://generativelanguage.googleapis.com/v1beta/models"

# This is an evaluation copy of Dewy's function inventory. It describes tools to
# Gemini, but this script never imports or executes Dewy's local Swift handlers.
TOOL_SPECS: list[tuple[str, str, dict[str, Any], list[str]]] = [
    ("record_water", "记录明确报告的饮水量，单位毫升；未说明时可省略 amount_ml。", {"amount_ml": {"type": "INTEGER"}}, []),
    ("add_task", "新增用户明确要求记录的待办。", {"title": {"type": "STRING"}}, ["title"]),
    ("complete_task", "完成用户明确指出且唯一匹配的待办。", {"title": {"type": "STRING"}}, ["title"]),
    ("add_activity", "记录用户明确安排的娱乐、运动、休息或社交活动。", {"title": {"type": "STRING"}, "category": {"type": "STRING", "enum": ["娱乐", "运动", "休息", "社交"]}}, ["title", "category"]),
    ("start_focus", "开始专注；可选关联已有待办的准确标题。", {"task_title": {"type": "STRING"}}, []),
    ("link_focus_task", "把当前或最近结束的专注关联到待办。", {"task_title": {"type": "STRING"}, "session_scope": {"type": "STRING", "enum": ["current", "latest_ended"]}}, ["task_title"]),
    ("stop_focus", "结束当前专注。", {}, []),
    ("record_work", "归档用户当天明确完成的工作、推进或知识讨论，不记录未来计划。", {"details": {"type": "STRING"}}, ["details"]),
    ("remember_profile_fact", "按用户明确要求保存稳定画像事实。", {"category": {"type": "STRING"}, "content": {"type": "STRING"}}, ["category", "content"]),
    ("propose_profile_fact", "为用户明确说出的稳定偏好或目标创建待确认画像候选。", {"category": {"type": "STRING"}, "content": {"type": "STRING"}}, ["category", "content"]),
    ("get_user_profile", "读取用户长期画像和候选。", {}, []),
    ("update_profile_fact", "按唯一匹配修改长期画像。", {"selector": {"type": "STRING"}, "new_content": {"type": "STRING"}, "new_category": {"type": "STRING"}}, ["selector", "new_content"]),
    ("delete_profile_fact", "按唯一匹配删除长期画像。", {"selector": {"type": "STRING"}}, ["selector"]),
    ("record_meal", "记录用户明确报告的饮食。", {"details": {"type": "STRING"}}, ["details"]),
    ("record_sleep", "记录用户提供的睡觉和起床时间。", {"bedtime": {"type": "STRING"}, "wake_time": {"type": "STRING"}, "note": {"type": "STRING"}}, ["bedtime", "wake_time"]),
    ("add_goal", "记录用户明确提出的目标。", {"title": {"type": "STRING"}}, ["title"]),
    ("update_goal_progress", "更新用户明确指定目标的进展。", {"goal_title": {"type": "STRING"}, "progress": {"type": "STRING"}}, ["goal_title", "progress"]),
    ("get_summary", "读取本地日、周、上周或月总结。", {"period": {"type": "STRING", "enum": ["day", "week", "previous_week", "month"]}}, ["period"]),
    ("list_calendar_events", "读取 Mac 系统日历事件。", {"start_at": {"type": "STRING"}, "end_at": {"type": "STRING"}}, ["start_at", "end_at"]),
    ("create_calendar_event", "创建用户明确要求的日历事件。", {"title": {"type": "STRING"}, "start_at": {"type": "STRING"}, "end_at": {"type": "STRING"}}, ["title", "start_at", "end_at"]),
    ("update_calendar_event", "按准确标题和日期修改日历事件。", {"title": {"type": "STRING"}, "date": {"type": "STRING"}, "new_title": {"type": "STRING"}, "start_at": {"type": "STRING"}, "end_at": {"type": "STRING"}}, ["title", "date"]),
    ("delete_calendar_event", "按准确标题和日期删除日历事件。", {"title": {"type": "STRING"}, "date": {"type": "STRING"}}, ["title", "date"]),
    ("list_habits", "查询习惯、计划日、打卡状态和统计。", {}, []),
    ("create_habit", "创建用户明确要求的新习惯。", {"title": {"type": "STRING"}, "weekdays": {"type": "ARRAY", "items": {"type": "INTEGER"}}, "rest_days": {"type": "ARRAY", "items": {"type": "INTEGER"}}, "reminder_time": {"type": "STRING"}}, ["title"]),
    ("update_habit", "按准确标题修改习惯。", {"title": {"type": "STRING"}, "new_title": {"type": "STRING"}, "weekdays": {"type": "ARRAY", "items": {"type": "INTEGER"}}, "rest_days": {"type": "ARRAY", "items": {"type": "INTEGER"}}}, ["title"]),
    ("set_habit_reminder", "设置或关闭习惯提醒。", {"title": {"type": "STRING"}, "time": {"type": "STRING"}}, ["title", "time"]),
    ("delete_habit", "删除用户明确指定的习惯。", {"title": {"type": "STRING"}}, ["title"]),
    ("check_in_habit", "为用户明确指定的习惯打卡。", {"title": {"type": "STRING"}, "date": {"type": "STRING"}}, ["title"]),
]

FUNCTION_DECLARATIONS = [
    {
        "name": name,
        "description": description,
        "parameters": {
            "type": "OBJECT",
            "properties": properties,
            **({"required": required} if required else {}),
        },
    }
    for name, description, properties, required in TOOL_SPECS
]

WRITE_TOOLS = {
    "record_water", "add_task", "complete_task", "add_activity", "start_focus",
    "link_focus_task", "stop_focus", "record_work", "remember_profile_fact",
    "propose_profile_fact", "update_profile_fact", "delete_profile_fact",
    "record_meal", "record_sleep", "add_goal", "update_goal_progress",
    "create_calendar_event", "update_calendar_event", "delete_calendar_event",
    "create_habit", "update_habit", "set_habit_reminder", "delete_habit",
    "check_in_habit",
}

SYSTEM_PROMPT = """你是 Dewy，一位温柔而坚定的私人管家。

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

## 已确认的长期用户画像
{{PROFILE_FACTS}}
用户询问画像、明确要求修改或删除画像时，提供完整画像供本轮准确匹配；普通问题只带入相关画像。

## 待确认画像候选
{{PROFILE_CANDIDATE}}
候选确认只在聊天中处理。无冲突候选：询问用户是否保存；用户明确同意后本地确认，明确拒绝后丢弃。若候选标记了相似旧画像，必须让用户选择“更新”“另存”或“忽略”，不能将普通“好”解释成更新旧项。

## 当地本地记录摘要
- 当前本地日期时间：{{NOW}}
- 今日饮水：{{WATER}} ml
- 杯子容量：{{CUP}} ml
- 未完成待办：{{TASKS}}
- 专注计时：{{FOCUS}}

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
- 饮水、饮食、睡眠和专注时长由专门模块记录，不写入工作内容。"""


def gemini_call(api_key: str, model: str, body: dict[str, Any]) -> dict[str, Any]:
    url = f"{API_BASE}/{model}:generateContent"
    request = urllib.request.Request(
        url,
        data=json.dumps(body, ensure_ascii=False).encode("utf-8"),
        headers={"Content-Type": "application/json", "x-goog-api-key": api_key},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"Gemini HTTP {exc.code}: {detail[:1200]}") from exc


def make_system(inputs: dict[str, Any]) -> str:
    context = inputs.get("local_context") or {}
    now = inputs.get("now", "未提供")
    facts = context.get("profile_facts") or []
    candidates = context.get("profile_candidates") or []
    open_tasks = [task.get("title", "") for task in context.get("tasks", []) if task.get("status") not in {"已完成", "完成", "done"}]
    focus = context.get("focus_is_running", False)
    if isinstance(context.get("focus"), dict):
        focus = context["focus"].get("is_running", focus)
    water = context.get("water_today_ml", context.get("water_today", "未提供"))
    cup = context.get("cup_milliliters", "未提供")
    fact_text = "\n".join(f"- [{item.get('category', '其他')}] {item.get('content', '')}" for item in facts if isinstance(item, dict)) or "暂无已确认画像"
    candidate = candidates[0] if candidates and isinstance(candidates[0], dict) else None
    candidate_text = f"[{candidate.get('category', '其他')}] {candidate.get('content', '')}" if candidate else "无待确认候选"
    return (SYSTEM_PROMPT.replace("{{PROFILE_FACTS}}", fact_text)
            .replace("{{PROFILE_CANDIDATE}}", candidate_text)
            .replace("{{NOW}}", str(now) + "（测试数据中的固定时间，不读取机器当前时间）")
            .replace("{{WATER}}", str(water))
            .replace("{{CUP}}", str(cup))
            .replace("{{TASKS}}", "、".join(open_tasks) if open_tasks else "无")
            .replace("{{FOCUS}}", "进行中" if focus else "未进行"))


def make_contents(inputs: dict[str, Any]) -> list[dict[str, Any]]:
    turns = inputs.get("conversation")
    if not isinstance(turns, list) or not turns:
        turns = [{"role": "user", "content": str(inputs.get("user", ""))}]
    contents: list[dict[str, Any]] = []
    for turn in turns:
        if not isinstance(turn, dict):
            continue
        role = str(turn.get("role", "user"))
        role = "model" if role in {"assistant", "model", "dewy"} else "user"
        text = str(turn.get("content", turn.get("text", "")))
        if text:
            contents.append({"role": role, "parts": [{"text": text}]})
    if not contents:
        contents = [{"role": "user", "parts": [{"text": str(inputs.get("user", ""))}]}]
    return contents


def response_parts(payload: dict[str, Any]) -> list[dict[str, Any]]:
    candidates = payload.get("candidates") or []
    if not candidates:
        return []
    content = candidates[0].get("content") or {}
    return content.get("parts") or []


def mock_result(name: str, args: dict[str, Any], inputs: dict[str, Any]) -> str:
    """Return synthetic tool results only; never call Dewy's real local code."""
    context = inputs.get("local_context") or {}
    read_tools = {"get_user_profile", "get_summary", "list_calendar_events", "list_habits"}
    if name in read_tools:
        if name == "get_user_profile":
            data = {"profile_facts": context.get("profile_facts", []), "profile_candidates": context.get("profile_candidates", [])}
        elif name == "list_calendar_events":
            data = {"events": context.get("events", []), "requested_range": {"start_at": args.get("start_at"), "end_at": args.get("end_at")}}
        elif name == "list_habits":
            data = {"habits": context.get("habits", [])}
        else:
            data = {"summary_fixture": context}
        return "模拟读取结果（非真实数据）:" + json.dumps(data, ensure_ascii=False)
    return "模拟函数结果：操作在测试沙盒中成功；没有写入真实 records.json、系统日历或任何应用数据。请求=" + json.dumps({"name": name, "arguments": args}, ensure_ascii=False)


def target_factory(api_key: str, model: str):
    def target(inputs: dict[str, Any]) -> dict[str, Any]:
        contents = make_contents(inputs)
        body: dict[str, Any] = {
            "systemInstruction": {"parts": [{"text": make_system(inputs)}]},
            "contents": contents,
            "tools": [{"functionDeclarations": FUNCTION_DECLARATIONS}],
            "toolConfig": {"functionCallingConfig": {"mode": "AUTO"}},
        }
        first = gemini_call(api_key, model, body)
        parts = response_parts(first)
        calls: list[dict[str, Any]] = []
        for part in parts:
            call = part.get("functionCall")
            if isinstance(call, dict) and call.get("name"):
                calls.append({"name": call["name"], "arguments": call.get("args") or {}})
        answer = "\n".join(str(part["text"]) for part in parts if isinstance(part.get("text"), str)).strip()

        if calls:
            # Match Dewy's current one-tool-round flow, but replace every local
            # operation with a deterministic fake response.
            followup = list(contents)
            followup.append({"role": "model", "parts": parts})
            followup.append({
                "role": "function",
                "parts": [
                    {"functionResponse": {"name": call["name"], "response": {"result": mock_result(call["name"], call["arguments"], inputs)}}}
                    for call in calls
                ],
            })
            second_body = dict(body)
            second_body["contents"] = followup
            second_parts = response_parts(gemini_call(api_key, model, second_body))
            second_text = "\n".join(str(part["text"]) for part in second_parts if isinstance(part.get("text"), str)).strip()
            if second_text:
                answer = second_text

        return {"tool_calls": calls, "answer": answer}
    return target


def same_expected_calls(outputs: dict[str, Any], actual: dict[str, Any]) -> tuple[bool, str]:
    expected = outputs.get("expected_tool_calls") or []
    calls = actual.get("tool_calls") or []
    expected_names = [item.get("name") for item in expected]
    actual_names = [item.get("name") for item in calls]
    if expected_names != actual_names:
        return False, f"预期工具={expected_names}；实际工具={actual_names}"
    for exp, got in zip(expected, calls):
        want = exp.get("arguments") or {}
        have = got.get("arguments") or {}
        for key, value in want.items():
            if have.get(key) != value:
                return False, f"{exp.get('name')} 参数 {key}：预期 {value!r}，实际 {have.get(key)!r}"
    return True, "工具名和预期参数匹配"


def answer_asks_clarification(text: str) -> bool:
    markers = ("？", "?", "请确认", "请告诉我", "能否告诉", "你希望", "需要你提供", "具体是", "哪一个", "哪一条")
    return any(marker in text for marker in markers)


def make_evaluators():
    def tool_calls_evaluator(inputs, outputs, reference_outputs):
        ok, detail = same_expected_calls(reference_outputs or {}, outputs or {})
        return {"key": "tool_calls_match", "score": ok, "comment": detail}

    def clarification_evaluator(inputs, outputs, reference_outputs):
        refs = reference_outputs or {}
        if not refs.get("must_ask"):
            return {"key": "clarification_when_needed", "score": True, "comment": "此用例未要求必须追问"}
        asked = answer_asks_clarification((outputs or {}).get("answer", ""))
        return {"key": "clarification_when_needed", "score": asked, "comment": "发现追问语句" if asked else "回复中未识别到明确追问"}

    def no_write_evaluator(inputs, outputs, reference_outputs):
        refs = reference_outputs or {}
        if not refs.get("must_not_write"):
            return {"key": "no_unauthorized_write", "score": True, "comment": "此用例未禁止写入"}
        writes = [call.get("name") for call in (outputs or {}).get("tool_calls", []) if call.get("name") in WRITE_TOOLS]
        return {"key": "no_unauthorized_write", "score": not writes, "comment": f"检测到写入工具：{writes}" if writes else "未调用写入工具"}

    return [tool_calls_evaluator, clarification_evaluator, no_write_evaluator]


def metadata_split(example: Any) -> str | None:
    """Read both normal metadata and the extra-nested shape from an import."""
    metadata = getattr(example, "metadata", None) or {}
    if not isinstance(metadata, dict):
        return None
    value = metadata.get("split")
    if isinstance(value, str):
        return value
    nested = metadata.get("metadata")
    if isinstance(nested, str):
        try:
            nested = json.loads(nested)
        except json.JSONDecodeError:
            nested = None
    if isinstance(nested, dict) and isinstance(nested.get("split"), str):
        return nested["split"]
    return None


def main() -> int:
    parser = argparse.ArgumentParser(description="安全评估 Dewy Gemini function calling；所有工具执行均为模拟。")
    parser.add_argument("--dataset", default=os.getenv("LANGSMITH_DATASET", DATASET_DEFAULT), help="LangSmith 数据集名称")
    parser.add_argument("--split", default="development", help="LangSmith 正式 split 名称，例如 development 或 holdout")
    parser.add_argument("--limit", type=int, default=5, help="最多评估条数；首次建议 5")
    parser.add_argument("--model", default=os.getenv("GEMINI_MODEL", MODEL_DEFAULT), help="Gemini 模型名")
    parser.add_argument("--experiment", default=None, help="LangSmith 实验名前缀")
    args = parser.parse_args()

    gemini_key = os.getenv("GEMINI_API_KEY")
    if not gemini_key:
        print("缺少 GEMINI_API_KEY 环境变量。", file=sys.stderr)
        return 2
    if not os.getenv("LANGSMITH_API_KEY"):
        print("缺少 LANGSMITH_API_KEY 环境变量。", file=sys.stderr)
        return 2

    try:
        client = Client()
        # Prefer a formal LangSmith split. If the current import only has
        # metadata.split (possibly nested under metadata.metadata), filter it
        # locally so the evaluation can still run while the dataset is fixed.
        examples = list(client.list_examples(dataset_name=args.dataset, splits=[args.split] if args.split else None))
        if not examples:
            all_examples = list(client.list_examples(dataset_name=args.dataset))
            examples = [item for item in all_examples if metadata_split(item) == args.split] if args.split else all_examples
        if args.limit > 0:
            examples = examples[:args.limit]
        if not examples:
            print(f"数据集 {args.dataset!r} 的 split {args.split!r} 下没有例子。请先在 LangSmith 建立正式 split，或检查数据集名称。", file=sys.stderr)
            return 2
        exp_name = args.experiment or f"dewy-gemini-{args.split}-smoke"
        print(f"开始评估 {len(examples)} 条；模型={args.model}；split={args.split}。工具只返回模拟结果。")
        results = client.evaluate(
            target_factory(gemini_key, args.model),
            data=examples,
            evaluators=make_evaluators(),
            experiment_prefix=exp_name,
            max_concurrency=1,
        )
        print(results)
        return 0
    except Exception as exc:
        print(f"评估失败：{exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
