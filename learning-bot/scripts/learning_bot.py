#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
learning_bot.py - entry / router driver for the Learning Bot launcher skill.

It does three things, all emitting a machine-parsable [SKILL_RESULT] block:

  --menu                Print the recommended preset questions (map to the 17 local aipc-skills).
  --route "<text>"      Classify a user utterance -> a preset skill, a dev skill (ENV/FETCH/PIPE),
                        or "clarify". This is a SUGGESTION for the agent, not a hard decision.
  --resolve <key>       Resolve a preset key to its published skill name (the host invokes it by
                        that name). Offline.
  --install <key>       BACKUP path: when the host does not ship that skill, download the package
                        from the AI PC Skills release and unzip it locally. Only command here
                        that hits the network.

The 17 preset skills and the 3 dev skills live in scripts/skills_registry.json.

这些本地能力 skill **已经上架**，宿主按 skill_name 直接调用即可 —— 本文件不再托管下载地址、
也不负责下载解压。key 是仓库内部的稳定标识（路由/关键词/组合配方都用它），skill_name 才是
对外调用名，两者不要混用。整个文件除 --capacity 外都不联网（stdlib only）。
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
REGISTRY = HERE / "skills_registry.json"

# Windows 控制台默认使用系统 ANSI 代码页（cp1252 / cp936），而本脚本的 reason= 字段是中文。
# 不强制 UTF-8 的话，print() 会抛 UnicodeEncodeError 并让进程以退出码 1 结束 —— 调用方看到的
# 是「路由器崩溃」而不是路由结果。只有开了「Beta: 使用 UTF-8 提供全球语言支持」的机器才碰巧
# 正常，绝不能依赖那个开关。errors="replace" 保证极端情况下也只是替换字符，不会中断输出。
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass


def load_registry():
    with open(REGISTRY, "r", encoding="utf-8") as f:
        return json.load(f)


def emit(fields):
    """Print a [SKILL_RESULT] block from an ordered list of (key, value) pairs."""
    print("[SKILL_RESULT]")
    for k, v in fields:
        if isinstance(v, (dict, list)):
            v = json.dumps(v, ensure_ascii=False)
        print(f"{k}={v}")
    print("[/SKILL_RESULT]")


def cmd_menu(reg):
    presets = reg["preset_skills"]
    data = [
        {"key": s["key"], "name": s["name_cn"], "question": s["question"],
         "model_download": bool(s.get("has_model_download"))}
        for s in presets
    ]
    print("Learning Bot 已启动。你可以直接问我下面这些本地能力（每一条都会调用一个本地 skill，")
    print("全部在你的 Intel AIPC 上离线运行）：\n")
    for i, s in enumerate(presets, 1):
        tag = " [首次使用需下载模型]" if s.get("has_model_download") else ""
        print(f"  {i:>2}. [{s['key']}] {s['name_cn']}{tag} —— 例如：{s['question']}")
    print()
    print("标有「首次使用需下载模型」的能力，首次调用会从 ModelScope 拉取模型；届时会把下载进度条")
    print("（百分比 / 已下载·总大小 / 速度 / 剩余时间）实时展示给你，不会让你干等。\n")
    print("如果你的需求超出上面这些，我会根据实际情况改用开发类 skill：")
    for d in reg["dev_skills"]:
        print(f"     - {d['alias']} ({d['key']})：{d['when']}")
    print()
    emit([
        ("status", "ok"),
        ("action", "menu"),
        ("count", len(presets)),
        ("data", data),
    ])


def _score(text, keywords):
    return sum(1 for kw in keywords if kw.strip() and kw.strip().lower() in text)


def _has_download_intent(t):
    """强下载模型意图：'下载/拉/取' + '模型/权重/参数/IR'，中间允许插入 ≤4 个字符。
    解决 '下载一个 ASR 模型' 这类连字串匹配会漏掉的情况。"""
    triggers = ("下载", "拉取", "拉一个", "取一个", "get ", "fetch ", "download", "pull ")
    targets  = ("模型", "权重", "参数", " ir ", "(ir)", "openVINO ir")
    if not any(trig in t for trig in triggers):
        return False
    return any(tgt in t for tgt in targets)


def _has_out_of_scope_signal(t):
    """强越界信号：云端/不要本地/批量安装/造假 —— 这些都需要先让 agent 解释边界，
    路由层把它们引到 dev skill（由 agent 在 dev 阶段决定如何拒绝 / 收窄）。"""
    return any(w in t for w in (
        "云端", "云上", "调云", "api 做", "api进行", "用api", "用 api",
        "在线推理", "远程推理", "调用openai", "调 openai", "调chatgpt",
        "不用真跑", "直接告诉", "直接给", "伪造", "造假",
        "一次性全", "一次全", "批量安装", "全部安装", "全装", "把 17", "把17",
    ))


def _has_dev_phrase(t):
    """纯开发意图短语：**产出物是开发资产**（环境 / notebook / 模型文件 / 量化 IR /
    性能报告）时才算。这类需求没法拿 17 个预设原子能力当基础，只能直接走 dev skill。

    注意：'部署 / 流水线 / pipeline / serve' 曾经在这个列表里，现在**故意移走**了 ——
    「把 asr→llm→tts 组成流水线并部署成服务」是可以拿预设原子能力搭出来的，应当走
    compose 并把 PIPE 当辅助（见 _assist_for），而不是整个交给 dev skill 从零开发。
    """
    return any(w in t for w in ("下载模型", "找模型", "download model",
                                "搭环境", "配置环境", "安装环境", "配好环境",
                                "基准测试", "benchmark", "找瓶颈", "量化",
                                "notebook", "教程"))


def _match_synthesis(reg, t):
    """内容合成类需求（PRD / 培训材料 / 学习路径）：产出物是散文文档，没有可安装的 skill，
    也没有 [SKILL_RESULT] 可产出 —— 真正干活的是 agent 自己的写作能力，skill 只能用
    content-fetch 抓真实 notebook/示例当素材。

    返回命中的 deliverable id；未命中返回 None。

    注意：'学习路径' 曾经在 _has_dev_phrase() 里，现已移到这里统一管，避免两处打架。
    """
    best, best_sc = None, 0
    for s in reg.get("synthesis_signals", []):
        sc = _score(t, s.get("keywords", []))
        if sc > best_sc:
            best, best_sc = s, sc
    return best["id"] if best else None


def _assist_for(t):
    """辅助（不是接管）：预设原子能力仍是主体，这些 dev skill 只负责补缺口。"""
    assist = []
    if any(w in t for w in ("部署", "服务", "常驻", "流水线", "pipeline", "serve",
                            "优化", "加速", "端到端")):
        assist.append("openvino-pipeline-optimization")
    if any(w in t for w in ("没装", "装不上", "环境", "第一次用", "还没配")):
        assist.append("openvino-environment-management")
    if any(w in t for w in ("缺模型", "没有模型", "换个模型", "换模型", "找个模型")):
        assist.append("openvino-content-fetch")
    return assist


def _match_combo(reg, t):
    """配方表命中：覆盖「会议纪要」「字幕助手」这类没有直白关键词、单靠多命中兜不住的说法。
    返回 (combo, 命中关键词数)；未命中返回 (None, 0)。"""
    best, best_sc = None, 0
    for c in reg.get("combos", []):
        sc = _score(t, c.get("keywords", []))
        if sc > best_sc:
            best, best_sc = c, sc
    return best, best_sc


def _match_gaps(reg, t):
    """缺口识别：这些能力 17 个预设原子覆盖不到，需要参考 dev skill 单独开发。
    命中缺口**不等于**放弃预设能力 —— 能被预设覆盖的阶段照常用预设原子，
    只有缺口阶段才单独开发。"""
    return [g["id"] for g in reg.get("gap_signals", [])
            if _score(t, g.get("keywords", [])) > 0]


def route(reg, text):
    t = (text or "").lower()

    # Hardware boundary: only Intel AIPC (Windows) is supported locally. If the user
    # explicitly names an unsupported host (Apple Silicon / macOS / discrete NVIDIA /
    # Linux desktop), return clarify BEFORE any preset/dev routing so the agent is
    # forced to confirm hardware rather than silently mapping it to a preset skill.
    non_intel_markers = (
        "m3 macbook", "m3 mac", "m2 macbook", "m2 mac", "m1 macbook", "m1 mac",
        "m4 macbook", "m4 mac", "macbook", "macos", "mac os", "apple silicon",
        "apple m1", "apple m2", "apple m3", "apple m4",
    )
    if any(m in t for m in non_intel_markers):
        return {"scope": "clarify", "target": "", "matched": "false",
                "reason": "仅支持 Intel AIPC (Windows)；当前输入提到非 Intel 硬件，请确认硬件平台"}

    # 内容合成类（PRD / 培训材料 / 学习路径）必须在 combo / preset / dev 之前判定。
    # 否则「给一个端侧会议纪要总结功能写个 PRD」里的"会议纪要"会先被 combo 抢走，
    # 路由成 preset/asr —— 用户要的是一份文档，弱 agent 却跑去装 ASR skill 做推理。
    deliverable = _match_synthesis(reg, t)
    if deliverable:
        return {
            "scope": "synthesize", "target": "openvino-content-fetch", "targets": [],
            "assist": [], "gaps": [], "deliverable": deliverable, "matched": "true",
            "reason": ("内容合成类需求：用 content-fetch 抓真实 notebook/示例做素材，"
                       "正文由 agent 自己写并标注来源；不要安装任何 preset skill，"
                       "也不要搭环境 / 下载模型 / 部署服务"),
        }

    # Score every preset skill by keyword hits.
    preset_hits = []
    for s in reg["preset_skills"]:
        sc = _score(t, s["keywords"])
        if sc > 0:
            preset_hits.append((sc, s["key"]))
    preset_hits.sort(reverse=True)

    # 上架清单里 OCR 只有 NPU 版（Local OCR on NPU），没有单独的 GPU 版本，
    # 所以用户即使点名 GPU 也只能给 ocr-npu —— 不要凭空造一个不存在的 skill。
    def normalize_ocr(key):
        if key.startswith("ocr-"):
            return "ocr-npu"
        return key

    # Score dev skills.
    dev_hits = []
    for d in reg["dev_skills"]:
        sc = _score(t, d["keywords"])
        if sc > 0:
            dev_hits.append((sc, d["key"]))
    dev_hits.sort(reverse=True)

    # Strong development-intent words steer to dev skills even if a modality word appears
    # (e.g. "下载 ASR 模型" is a FETCH job, not the ASR skill). Layered check:
    #   1) 连字串开发短语（高置信度）
    #   2) '下载/拉' + '模型/IR' 模式（修复 "下载一个 ASR 模型" 漏召回）
    #   3) 越界信号（云端/批量安装/造假等）—— 也优先 dev，让 agent 在 dev 阶段解释边界
    dev_override = (
        _has_dev_phrase(t)
        or _has_download_intent(t)
        or _has_out_of_scope_signal(t)
    )

    # ------------------------------------------------------------------
    # 核心原则：17 个预设 skill 是**原子能力**，优先拿它们当基础拼装；三个开发类 skill
    # 只在预设能力搭不出来、或链条上有缺口时作为**辅助**出现。判断顺序：
    #   1) 产出物是开发资产（环境/notebook/模型文件/量化IR/性能报告）→ dev
    #   2) 命中配方表 → compose
    #   3) 命中 ≥2 个不同预设原子 → compose（按 flow_order 排序）
    #   4) 命中 1 个预设原子 → preset
    #   5) 都没有 → dev / clarify
    # 缺口（gap_signals）不会否决前面的结论：能被预设覆盖的阶段照常用预设原子，
    # 缺口阶段单独走 dev 开发，由 gaps= 字段告诉 agent 哪几段要自己做。
    # ------------------------------------------------------------------
    assist = _assist_for(t)
    gaps = _match_gaps(reg, t)
    order = {s["key"]: s.get("flow_order", 5) for s in reg["preset_skills"]}

    def _finish(res):
        """统一补上 targets / assist / gaps / deliverable 四个字段。"""
        res.setdefault("targets", [])
        res.setdefault("deliverable", "")   # 只有 scope=synthesize 才非空
        merged = list(assist)
        # 有缺口就必须把 FETCH/PIPE 带上：缺口阶段要找模型 + 自己接进流水线。
        if gaps:
            for k in ("openvino-content-fetch", "openvino-pipeline-optimization"):
                if k not in merged:
                    merged.append(k)
        res["assist"] = merged
        res["gaps"] = gaps
        return res

    if preset_hits and not dev_override:
        # 2) 配方表优先 —— 它把 stages 顺序写死，比 flow_order 自动排序更可靠。
        combo, combo_sc = _match_combo(reg, t)
        if combo and combo_sc > 0:
            stages = list(combo["stages"])
            return _finish({
                "scope": "compose" if len(stages) > 1 else "preset",
                "target": stages[0], "targets": stages, "matched": "true",
                "reason": f"命中组合配方「{combo['name_cn']}」，以预设原子能力为基础拼装",
            })

        # 3) 多原子命中 → 组合。先按 key 去重（OCR 的设备变体归一成一个）。
        seen, keys = set(), []
        for _sc, k in preset_hits:
            nk = normalize_ocr(k)
            if nk not in seen:
                seen.add(nk)
                keys.append(nk)

        # 同一个流水线阶段上的能力互为替代品，不能串成一条链 —— 「发票解析成结构化数据」
        # 会同时命中 paddleocr-vl 和 mineru（都是 flow_order=1 的文档解析），串成
        # paddleocr-vl→mineru 是没有意义的。同阶段只保留得分最高的那个。
        stage_of = {p["key"]: (p.get("flow_order"), (p.get("io") or {}).get("out"))
                    for p in reg["preset_skills"]}
        score_of = {}
        for sc, k in preset_hits:
            nk = normalize_ocr(k)
            score_of[nk] = max(score_of.get(nk, 0), sc)
        best_at_stage, deduped = {}, []
        for k in keys:
            st = stage_of.get(k)
            prev = best_at_stage.get(st)
            if prev is None:
                best_at_stage[st] = k
                deduped.append(k)
            elif score_of.get(k, 0) > score_of.get(prev, 0):
                deduped[deduped.index(prev)] = k
                best_at_stage[st] = k
        keys = deduped

        if len(keys) > 1:
            stages = sorted(keys, key=lambda k: (order.get(k, 5), keys.index(k)))
            return _finish({
                "scope": "compose", "target": stages[0], "targets": stages,
                "matched": "true",
                "reason": f"命中 {len(stages)} 个预设原子能力，按数据流顺序组合",
            })

        # 4) 单原子
        return _finish({
            "scope": "preset", "target": keys[0], "targets": [keys[0]],
            "matched": "true",
            "reason": f"命中预设本地能力关键词（{preset_hits[0][0]} 个）",
        })

    # 配方表也能救回「一个预设关键词都没命中」的说法（如「帮我做个会议助手」）。
    if not dev_override:
        combo, combo_sc = _match_combo(reg, t)
        if combo and combo_sc > 0:
            stages = list(combo["stages"])
            return _finish({
                "scope": "compose" if len(stages) > 1 else "preset",
                "target": stages[0], "targets": stages, "matched": "true",
                "reason": f"命中组合配方「{combo['name_cn']}」，以预设原子能力为基础拼装",
            })

    if dev_hits:
        return _finish({"scope": "dev", "target": dev_hits[0][1], "matched": "true",
                        "reason": "产出物是开发资产，预设原子能力无法作为基础"})

    # dev_override 命中但 dev 关键词未命中：路由到最贴近的 dev skill（由 agent 解释边界）
    if dev_override:
        # 默认目标 = ENV（搭环境/装东西/解释硬件边界最常用），但下载模型类信号优先 FETCH
        if _has_download_intent(t):
            target = "openvino-content-fetch"
            reason = "检测到「下载/拉取 模型」强开发意图 → 路由到 FETCH"
        else:
            target = "openvino-environment-management"
            reason = "检测到越界/批处理/造假等强信号 → 路由到 ENV 由 agent 解释边界"
        return _finish({"scope": "dev", "target": target, "matched": "true",
                        "reason": reason})

    if preset_hits:
        best = normalize_ocr(preset_hits[0][1])
        return _finish({"scope": "preset", "target": best, "targets": [best],
                        "matched": "true", "reason": "命中预设本地能力关键词"})

    return _finish({"scope": "clarify", "target": "", "matched": "false",
                    "reason": "无法可靠归类，建议先向用户追问具体任务 / 模态 / 目标"})


def cmd_route(reg, text):
    r = route(reg, text)
    # target= 保留为「单个 key / 链首」，老的只读 target 的解析方不会炸；
    # targets= 是有序的完整链条，assist= 是辅助的 dev skill，gaps= 是预设覆盖不到、
    # 需要参考 dev skill 单独开发的阶段。
    emit([
        ("status", "ok"),
        ("action", "route"),
        ("matched", r["matched"]),
        ("scope", r["scope"]),
        ("target", r["target"]),
        ("targets", ",".join(r.get("targets") or [])),
        ("deliverable", r.get("deliverable") or ""),
        ("assist", ",".join(r.get("assist") or [])),
        ("gaps", ",".join(r.get("gaps") or [])),
        ("reason", r["reason"]),
    ])


QUESTIONS_FILE = HERE / "questions.json"


def _emit_questions(skill, qtype, blocks):
    """Emit a [SKILL_QUESTIONS] block (same contract as the shared questions.ps1)."""
    print("[SKILL_QUESTIONS]")
    print(f"skill={skill}")
    print(f"type={qtype}")
    print(f"count={len(blocks)}")
    print("data=" + json.dumps(blocks, ensure_ascii=False))
    print("[/SKILL_QUESTIONS]")


def _preset_block(reg):
    """Build the preset (recommend) block from the registry — single source of truth."""
    opts = [
        {"key": s["key"], "label": s["name_cn"], "example": s["question"],
         "model_download": bool(s.get("has_model_download"))}
        for s in reg["preset_skills"]
    ]
    return {
        "type": "preset",
        "id": "menu",
        "prompt": "你可以直接问我这些本地能力（每条对应一个在 Intel AIPC 上离线运行的 skill）：",
        "multiselect": False,
        "options": opts,
    }


def cmd_questions(reg, qtype):
    """Emit prepared questions. preset comes from the registry; preflight/clarify from
    scripts/questions.json. Offline / network-free."""
    extra = {}
    if QUESTIONS_FILE.exists():
        with open(QUESTIONS_FILE, "r", encoding="utf-8") as f:
            extra = json.load(f)
    preset = [_preset_block(reg)]
    preflight = extra.get("preflight", [])
    clarify = extra.get("clarify", [])
    if qtype == "preset":
        blocks = preset
    elif qtype == "preflight":
        blocks = preflight
    elif qtype == "clarify":
        blocks = clarify
    else:  # all
        blocks = preset + preflight + clarify
    _emit_questions("learning-bot", qtype, blocks)
    return 0


def cmd_resolve(reg, key, out_dir=None):
    """把内部 key 解析成上架后的官方 skill 名。

    这些 skill 已经上架，宿主直接按 skill_name 调用即可，learning-bot 不再下载解压任何东西。
    out_dir 参数保留只为兼容旧调用方（--install -OutDir），现在没有实际作用。
    """
    presets = {s["key"]: s for s in reg["preset_skills"]}
    if key not in presets:
        emit([
            ("status", "error"),
            ("action", "resolve"),
            ("skill", key),
            ("reason", f"未知的 preset skill key：{key}；可选：{', '.join(presets)}"),
        ])
        return 1

    s = presets[key]
    needs_dl = bool(s.get("has_model_download"))
    fields = [
        ("status", "ok"),
        ("action", "resolve"),
        ("skill", key),
        ("skill_name", s["skill_name"]),
        ("name_cn", s["name_cn"]),
        ("model_download", "true" if needs_dl else "false"),
        ("progress_required", "true" if needs_dl else "false"),
        ("fallback_url", _fallback_url(reg, s)),
        ("note", "already published; invoke it by skill_name (no skill-package download needed)"),
        ("fallback_note",
         "宿主上找不到该 skill 时，用 `-Install {} [-OutDir <目录>]` 从 release 下载并解压，"
         "再按解压出来的 scripts\\run.ps1 调用".format(key)),
    ]
    if needs_dl:
        fields.append((
            "progress_note",
            "首次调用会下载模型：必须把 stdout 上以「模型下载中」开头的进度行实时展示给用户"
            "（百分比 / 已下载·总大小 / 速度 / ETA），退出码 3 时用 `scripts\\run.ps1 --continue` "
            "续跑并继续刷新进度，直到下载完成；不允许长时间静默等待。",
        ))
    if out_dir:
        fields.append(("ignored_out_dir", out_dir))
    emit(fields)
    return 0


# --------------------------------------------------------------------------
# 备用方案：宿主没预置某个 AIPC skill 时，从 release 下载技能包
#
# 正常路径是 --resolve：skill 已上架，宿主按 skill_name 直接调用即可。但宿主未预置时
# 那条路会直接断掉，所以这里提供 --install 作为 backup：从 registry 的 release.base_url
# 拼出 zip 地址，下载 → 校验 → 解压到本地，让 agent 还能按解压出来的 run.ps1 继续干活。
#
# 这是本文件里**唯一**会联网的 preset 相关命令（--capacity 会 shell out 探测硬件）。
# --menu / --route / --resolve / --questions 仍然全程离线。
# --------------------------------------------------------------------------

DEFAULT_INSTALL_ROOT = Path(os.path.expanduser("~")) / ".openvino" / "aipc-skills"


def _fallback_url(reg, skill):
    base = (reg.get("release") or {}).get("base_url", "")
    zip_name = skill.get("zip", "")
    return base + zip_name if base and zip_name else ""


def _download(url, dest, label):
    """Stream a zip to dest, printing 「技能包下载中」progress lines the agent must relay."""
    import urllib.request

    tmp = dest.with_suffix(dest.suffix + ".partial")
    tmp.parent.mkdir(parents=True, exist_ok=True)
    req = urllib.request.Request(url, headers={"User-Agent": "learning-bot/1.0"})
    start = time.time()
    with urllib.request.urlopen(req, timeout=60) as resp, open(tmp, "wb") as f:
        total = int(resp.headers.get("Content-Length") or 0)
        done = 0
        last = 0.0
        while True:
            chunk = resp.read(256 * 1024)
            if not chunk:
                break
            f.write(chunk)
            done += len(chunk)
            now = time.time()
            if now - last >= 0.5 or (total and done >= total):
                last = now
                _print_progress(done, total, now - start, label)
    tmp.replace(dest)
    _print_progress(dest.stat().st_size, dest.stat().st_size, time.time() - start, label)
    return dest


def _human(n):
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return "{:.1f} {}".format(n, unit)
        n /= 1024.0


def _print_progress(done, total, elapsed, label):
    speed = done / elapsed if elapsed > 0 else 0
    if total:
        pct = done * 100.0 / total
        filled = int(pct / 5)
        bar = "█" * filled + "░" * (20 - filled)
        eta = (total - done) / speed if speed > 0 else 0
        line = "技能包下载中 [{}] {:5.1f}% | {}/{} | {}/s | 剩余约 {} | {}".format(
            bar, pct, _human(done), _human(total), _human(speed), _fmt_eta(eta), label)
    else:
        line = "技能包下载中 [{}] {} | {}/s | {}".format(
            "░" * 20, _human(done), _human(speed), label)
    print(line, flush=True)


def _fmt_eta(sec):
    sec = int(sec)
    if sec < 60:
        return "{}秒".format(sec)
    return "{}分{}秒".format(sec // 60, sec % 60)


def cmd_install(reg, key, out_dir=None, force=False):
    """备用方案：把某个已上架的 AIPC skill 从 release 下载并解压到本地。"""
    presets = {s["key"]: s for s in reg["preset_skills"]}
    if key not in presets:
        emit([
            ("status", "error"),
            ("action", "install"),
            ("skill", key),
            ("reason", f"未知的 preset skill key：{key}；可选：{', '.join(presets)}"),
        ])
        return 1

    s = presets[key]
    url = _fallback_url(reg, s)
    if not url:
        emit([
            ("status", "error"),
            ("action", "install"),
            ("skill", key),
            ("reason", "registry 里没有该 skill 的 release zip，无法走备用下载方案"),
        ])
        return 1

    root = Path(out_dir) if out_dir else DEFAULT_INSTALL_ROOT
    target = root / Path(s["zip"]).stem
    entry = target / "scripts" / "run.ps1"

    if entry.exists() and not force:
        emit([
            ("status", "ok"),
            ("action", "install"),
            ("skill", key),
            ("skill_name", s["skill_name"]),
            ("installed", "already"),
            ("install_dir", str(target)),
            ("entry", str(entry)),
            ("url", url),
            ("note", "已存在，跳过下载；加 -Force 可强制重新下载"),
        ])
        return 0

    zip_path = root / s["zip"]
    try:
        print(f"从 release 备用地址下载技能包：{url}", flush=True)
        _download(url, zip_path, s["skill_name"])
        if target.exists() and force:
            shutil.rmtree(target)
        target.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(zip_path) as zf:
            _safe_extract(zf, target)
        zip_path.unlink(missing_ok=True)
    except Exception as exc:                      # noqa: BLE001 - 原因要如实回报给 agent
        emit([
            ("status", "error"),
            ("action", "install"),
            ("skill", key),
            ("url", url),
            ("install_dir", str(target)),
            ("reason", "{}: {}".format(type(exc).__name__, exc)),
            ("note", "下载/解压失败；可让用户手动下载上面的 url 并解压到 install_dir —— 绝不伪造成功"),
        ])
        return 1

    entry = _find_entry(target)
    emit([
        ("status", "ok"),
        ("action", "install"),
        ("skill", key),
        ("skill_name", s["skill_name"]),
        ("installed", "downloaded"),
        ("install_dir", str(target)),
        ("entry", str(entry) if entry else ""),
        ("url", url),
        ("model_download", "true" if s.get("has_model_download") else "false"),
        ("progress_required", "true" if s.get("has_model_download") else "false"),
        ("note", "备用方案安装完成；按 entry 指向的 run.ps1 调用该 skill"),
    ])
    return 0


def _safe_extract(zf, target):
    """Reject absolute paths and .. traversal before extracting (zip-slip guard)."""
    root = target.resolve()
    for member in zf.namelist():
        dest = (root / member).resolve()
        if not str(dest).startswith(str(root)):
            raise ValueError(f"zip entry escapes the target directory: {member}")
    zf.extractall(root)


def _find_entry(target):
    direct = target / "scripts" / "run.ps1"
    if direct.exists():
        return direct
    hits = sorted(target.glob("*/scripts/run.ps1"))
    return hits[0] if hits else None


# --------------------------------------------------------------------------
# 本机资源与模型可行性
#
# 目的：别推荐一个本机根本装不下的模型（8GB 预算跑不了 15B）。
# 真正的硬件探测在 detect_resources.ps1 里（要问 OpenVINO 拿显存），这里只做两件事：
# 读它写下的缓存，以及按 model_sizing.json 的系数算账。
#
# 注意这里刻意**不**自动触发探测：--menu / --route 必须保持纯 stdlib、离线、零 IO 依赖。
# 只有显式调用 --capacity 才会去探测。
# --------------------------------------------------------------------------

SIZING_FILE = HERE / "model_sizing.json"
CAPACITY_CACHE = Path(os.path.expanduser("~")) / ".openvino" / "capacity.json"
DETECT_SCRIPT = HERE / "detect_resources.ps1"


def load_sizing():
    with open(SIZING_FILE, "r", encoding="utf-8") as f:
        return json.load(f)


def load_capacity():
    """读探测缓存；没有就返回 None —— 调用方必须能在没有缓存时正常工作。"""
    try:
        with open(CAPACITY_CACHE, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return None


def parse_model_spec(model_id):
    """从 model id 里解析参数量和精度，例如 Qwen2.5-7B-Instruct-INT4-OV -> (7.0, INT4)。

    解析不出来就返回 None，由调用方去用默认值 —— 不要瞎猜一个数字当成事实。
    注意 '2.5' 这种版本号不能被当成参数量，所以要求 B 前面是数字且紧跟边界。
    """
    params = None
    m = re.search(r"(\d+(?:\.\d+)?)\s*[Bb](?![a-zA-Z])", model_id or "")
    if m:
        try:
            params = float(m.group(1))
        except ValueError:
            params = None

    precision = None
    upper = (model_id or "").upper()
    for p in ("INT4", "INT8", "FP16", "FP32"):
        if p in upper:
            precision = p
            break
    return params, precision


def estimate_need_gb(params_b, precision, sizing):
    """估算加载该模型需要多少 GB。"""
    per = sizing["bytes_per_param"].get(precision)
    if per is None or params_b is None:
        return None
    return round(params_b * per + sizing["runtime_overhead_gb"], 1)


def suggest_alternatives(params_b, precision, budget_gb, sizing):
    """跑不动时给真的能跑的替代方案；算不出来就返回空列表，不编。"""
    if params_b is None or budget_gb is None:
        return []
    out = []

    # 1) 先降精度
    order = ["FP32", "FP16", "INT8", "INT4"]
    if precision in order:
        for lower in order[order.index(precision) + 1:]:
            need = estimate_need_gb(params_b, lower, sizing)
            if need is not None and need <= budget_gb:
                out.append(f"{lower}:{need}GB")
                break

    # 2) 再降参数量档位（只考虑比当前小的）
    for tier in sorted((t for t in sizing.get("known_param_tiers", []) if t < params_b),
                       reverse=True):
        need = estimate_need_gb(tier, precision, sizing)
        if need is not None and need <= budget_gb:
            out.append(f"{tier}B@{precision}:{need}GB")
            break

    return out


def cmd_capacity():
    """触发一次真实探测（会调 PowerShell），把结果原样透传出去。"""
    if not DETECT_SCRIPT.exists():
        emit([("status", "error"), ("skill", "learning-bot"), ("action", "capacity"),
              ("reason", "detect-script-missing"),
              ("note", f"expected {DETECT_SCRIPT}")])
        return 1
    try:
        proc = subprocess.run(
            ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
             "-File", str(DETECT_SCRIPT)],
            capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=300)
    except Exception as e:
        emit([("status", "error"), ("skill", "learning-bot"), ("action", "capacity"),
              ("reason", "detect-failed"), ("note", f"{type(e).__name__}: {e}")])
        return 1
    sys.stdout.write(proc.stdout or "")
    return proc.returncode


def cmd_can_run(model, params_b, precision):
    """判定某个模型在本机跑不跑得动。"""
    sizing = load_sizing()
    parsed_params, parsed_prec = parse_model_spec(model)

    # 优先级：显式参数 > 从 model id 解析 > 默认（INT4，AIPC 部署的常态）
    params_b = params_b if params_b is not None else parsed_params
    precision = precision or parsed_prec or sizing["default_precision"]

    cap = load_capacity()
    fields = [("status", "ok"), ("skill", "learning-bot"), ("action", "can-run"),
              ("model", model or ""), ("precision", precision)]

    if params_b is None:
        # 解析不出参数量就如实说不知道，不要拿一个编的数字去做判断。
        fields += [("params_b", ""), ("fits", "unknown"),
                   ("reason", "无法从 model id 解析参数量，请用 --params 显式指定")]
        emit(fields)
        return 0

    need = estimate_need_gb(params_b, precision, sizing)
    fields.append(("params_b", params_b))
    fields.append(("need_gb", need if need is not None else ""))

    if cap is None:
        fields += [("budget_gb", ""), ("fits", "unknown"),
                   ("next", "learning-bot --capacity"),
                   ("reason", "尚未探测本机资源，先运行 --capacity 再判定")]
        emit(fields)
        return 0

    budget = cap.get("usable_budget_gb")
    fits = (need is not None and budget is not None and need <= budget)
    fields += [("budget_gb", budget if budget is not None else ""),
               ("capacity_source", cap.get("source", "")),
               ("fits", "true" if fits else "false")]
    if not fits:
        alts = suggest_alternatives(params_b, precision, budget, sizing)
        fields.append(("alternatives", ",".join(alts)))
        fields.append(("reason",
                       f"需要约 {need}GB，本机可用预算约 {budget}GB"
                       + ("；可考虑 alternatives 里的方案" if alts
                          else "；未找到能装下的替代方案，建议改用 CPU 或换更小的模型")))
    else:
        fields.append(("reason", f"需要约 {need}GB，本机可用预算约 {budget}GB，可以运行"))
    if cap.get("source") == "estimate":
        fields.append(("note", "capacity is an estimate (openvino unavailable); treat as advisory"))
    emit(fields)
    return 0


def main():
    ap = argparse.ArgumentParser(description="Learning Bot launcher / router")
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--menu", action="store_true", help="打印推荐给用户的预设问题")
    g.add_argument("--route", metavar="TEXT", help="对一句用户输入做路由建议")
    g.add_argument("--resolve", metavar="KEY",
                   help="把 preset key 解析成上架后的官方 skill 名（宿主按该名字调用）")
    g.add_argument("--install", metavar="KEY",
                   help="[备用方案] 宿主未预置该 skill 时，从 AI PC Skills release 下载并解压技能包")
    g.add_argument("--questions", metavar="TYPE",
                   choices=["preset", "preflight", "clarify", "all"],
                   help="输出准备好的问题（preset/preflight/clarify/all），[SKILL_QUESTIONS] 契约")
    g.add_argument("--capacity", action="store_true",
                   help="探测本机内存/显存预算（会调用 OpenVINO，首次较慢）")
    g.add_argument("--can-run", metavar="MODEL", dest="can_run",
                   help="判定某模型在本机跑不跑得动（默认按 INT4 估算）")
    ap.add_argument("--out-dir", default=None,
                    help="--install 的解压目录；默认 ~/.openvino/aipc-skills")
    ap.add_argument("--force", action="store_true",
                    help="--install 时即使已存在也重新下载")
    ap.add_argument("--params", type=float, default=None,
                    help="--can-run 的参数量（单位 B）；不给则从 model id 解析")
    ap.add_argument("--precision", default=None, choices=["INT4", "INT8", "FP16", "FP32"],
                    help="--can-run 的精度；不给则从 model id 解析，再不行用 INT4")
    args = ap.parse_args()

    if args.capacity:
        return cmd_capacity()
    if args.can_run is not None:
        return cmd_can_run(args.can_run, args.params, args.precision)

    reg = load_registry()
    if args.menu:
        cmd_menu(reg)
        return 0
    if args.route is not None:
        cmd_route(reg, args.route)
        return 0
    if args.questions is not None:
        return cmd_questions(reg, args.questions)
    if args.resolve is not None:
        return cmd_resolve(reg, args.resolve, args.out_dir)
    if args.install is not None:
        return cmd_install(reg, args.install, args.out_dir, args.force)
    return 0


if __name__ == "__main__":
    sys.exit(main())
