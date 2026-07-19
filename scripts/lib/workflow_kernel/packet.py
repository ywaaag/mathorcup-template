from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Dict, List, Optional

from workflow_kernel.schema import parse_kv_env, path_matches, resolve_config_ref, role_map, task_from_id


def collect_acceptance_artifacts(root: Path, role_config: Dict[str, Any], task: Optional[Dict[str, Any]]) -> List[str]:
    refs = list(role_config["default_acceptance_artifacts"])
    if task is not None:
        refs.extend(task.get("output_refs", []))
    resolved: List[str] = []
    for ref in refs:
        if isinstance(ref, str) and "#" in ref:
            resolved_value = resolve_config_ref(root, ref)
            if resolved_value:
                resolved.append(resolved_value)
        elif ref:
            resolved.append(ref)
    unique: List[str] = []
    for item in resolved:
        if item not in unique:
            unique.append(item)
    return unique


def choose_cwd(root: Path, role_name: str, task: Optional[Dict[str, Any]]) -> Path:
    if role_name in {"paper_brain", "layout_worker", "citation_worker"}:
        return root / "project/paper"
    if task and any(path_matches("project/paper", path) for path in task.get("allowed_paths", [])):
        return root / "project/paper"
    return root


def make_task_packet(root: Path, state: Dict[str, Any], role_name: str, task_id: Optional[str]) -> str:
    roles = role_map(state)
    if role_name not in roles:
        raise SystemExit(f"unknown role: {role_name}")
    task: Optional[Dict[str, Any]] = None
    if task_id:
        task = task_from_id(state, task_id)
        if task["role"] != role_name:
            raise SystemExit(f"task {task_id} is registered for role {task['role']}, not {role_name}")

    role = roles[role_name]
    env = parse_kv_env(root / ".env")
    paper_env = parse_kv_env(root / "project/paper/runtime/paper.env")
    cwd = choose_cwd(root, role_name, task)
    must_read = list(role["must_read_docs"])
    if task:
        for item in task["input_refs"]:
            if item not in must_read:
                must_read.append(item)
    acceptance = collect_acceptance_artifacts(root, role, task)
    contract = task.get("task_contract", {}) if task else {}

    lines = [
        f"你现在在 `{cwd}` 工作。",
        "",
        "任务包用途：",
        "- 这个 packet 可以直接贴给另一个会话，也可以作为 `codex exec` 的 stdin 输入。",
        "- 主脑负责 claim / gate / close；worker 负责执行与结构化回传，不负责改状态机。",
        "",
        "角色：",
        f"- {role_name}",
    ]
    if task:
        lines.extend(
            [
                "",
                "任务：",
                f"- `{task['task_id']}`: {task['title']}",
                f"- status: `{task['status']}`",
                f"- active_owner: `{task['owner'] or '-'}`",
                f"- feedback_path: `{task['feedback_path']}`",
                f"- retrospective_path: `{task['retrospective_path']}`",
                f"- retrospective_policy: `{task.get('retrospective_policy', 'required')}`",
                f"- dependency_mode: `{contract.get('dependency_mode', 'final')}`",
            ]
        )
        lines.extend(["", "任务合同："])
        contract_sections = [
            ("objective", "目标"),
            ("dependencies", "依赖任务"),
            ("canonical_inputs", "canonical inputs"),
            ("problem_inputs", "题目/数据输入"),
            ("fixed_parameters", "固定参数"),
            ("algorithm_boundaries", "算法与最优性边界"),
            ("required_artifacts", "精确产物合同"),
            ("validation_commands", "验证命令"),
            ("numeric_acceptance", "数值验收"),
        ]
        lines.append(f"- prepared: `{str(bool(contract.get('prepared', False))).lower()}`")
        for key, label in contract_sections:
            value = contract.get(key, "")
            lines.append(f"- {label}:")
            values = value if isinstance(value, list) else [value]
            if values:
                for item in values:
                    rendered = json.dumps(item, ensure_ascii=False) if isinstance(item, dict) else str(item)
                    lines.append(f"  - {rendered}")
            else:
                lines.append("  - <none>")
        lines.append(f"- manifest gate: `{contract.get('manifest_gate', 'none')}`")
        if contract.get("dependency_mode") == "provisional":
            lines.extend(
                [
                    "- PROVISIONAL: upstream canonical evidence is not final.",
                    "- 产物、feedback、handoff 和 manifest 必须显式标注 PROVISIONAL。",
                    "- 本任务不得 close 为 done，也不得作为论文 canonical input。",
                ]
            )
    lines.extend(
        [
            "",
            "本轮唯一目标：",
            f"- {task['title']}" if task else "- [在这里填写唯一任务]",
            "",
            "本轮不是：",
            "- 不要越出 task registry 和 role matrix 规定的 scope",
            "- 不要覆盖其他角色正在占用的文件",
            "- 不要把静态规则写回 `MEMORY.md`",
            "- 不要自行拆新的顶层 task_id，除非主脑在任务包里明确授权",
            "- 不要绕开 `task_registry.json` / `work_queue.json` 的既有约束",
            "",
            "允许修改的文件范围：",
        ]
    )
    for path in (task["allowed_paths"] if task else role["write_roots"]):
        lines.append(f"- `{path}`")
    lines.extend(["", "禁止修改的路径："])
    for path in (task["forbidden_paths"] if task else role["forbidden_roots"]):
        lines.append(f"- `{path}`")
    lines.extend(["", "必须按顺序读取："])
    for idx, doc in enumerate(must_read, start=1):
        lines.append(f"{idx}. `{doc}`")
    lines.extend(["", "当前容器：", f"- `{env.get('CONTAINER_NAME', '')}`"])
    lines.extend(
        [
            "- 当前镜像：`{}`".format(env.get("IMAGE_NAME", "")),
            "- 当前 runtime：`{}`".format(env.get("CONTAINER_RUNTIME", "")),
            "- 当前 GPU 请求：`{}`".format(env.get("CONTAINER_GPUS", "")),
            "- privileged：`{}`".format(env.get("CONTAINER_PRIVILEGED", "")),
            "- 容器用户：`{}`".format(env.get("CONTAINER_USER", "")),
            "- GRANT_SUDO：`{}`".format(env.get("CONTAINER_GRANT_SUDO", "")),
            "- machine truth：根目录 `.env` + `project/paper/runtime/paper.env`",
            f"- host project root：`{env.get('HOST_PROJECT_DIR', str(root / 'project'))}`",
            "- container project root：`/workspace/mathorcup`（host 的 `project/` 直接挂载到这里）",
            "- 容器内 artifact 示例：host `project/output/result.csv` 对应 `/workspace/mathorcup/output/result.csv`",
            "- 不要使用错误路径 `/workspace/mathorcup/project/...`",
            "- rendered mirror：`project/spec/runtime_contract.md` / `project/paper/spec/paper_runtime_contract.md`",
            "- 容器环境镜像说明入口：`project/spec/runtime_contract.md -> ## Current Host / Container Facts`",
            "- reference image baseline 入口：`project/spec/runtime_contract.md -> ## Reference Image Environment Snapshot`",
            "- 预期基础工具：`python3`, `pip`, `latexmk`, `xelatex`, `R`, `biber`, `fd`, `tree`, `yq`",
        ]
    )
    if role_name == "code_brain":
        lines.extend(
            [
                "",
                "代码侧输出约束：",
                "- 输出图表到 `project/figures/`",
                "- 输出 CSV / 中间结果到 `project/output/`",
                "- 若使用 matplotlib 生成含中文标签的图，必须先调用 `project/src/common/plot_style.py` 中的 `use_chinese_fonts()`",
                "- 不要临时下载字体；如字体异常，先运行 `bash scripts/doctor.sh --target <dir>` 检查 container matplotlib CJK baseline",
                "- 若产出建模结论或 canonical numbers，更新 `project/output/model_manifest.json`；可从 `project/output/MODEL_MANIFEST_TEMPLATE.json` 初始化",
                "- handoff 必须写明算法边界、最优性声明、枚举上限、验证命令和 paper-facing outputs",
                "- handoff 使用 `project/output/handoff/HANDOFF_TEMPLATE.md`",
                "- 只允许后续角色消费已被 `MEMORY.md -> ## Handoff Index` 索引的 handoff",
            ]
        )
    if role_name in {"paper_brain", "layout_worker", "citation_worker", "review_worker"} or (task and any(path_matches("project/paper", path) for path in task["allowed_paths"])):
        lines.extend(
            [
                "",
                "paper 运行事实：",
                "- active paper entrypoint 的 machine truth 以 `project/paper/runtime/paper.env` 为准",
                f"- 当前 entrypoint: `{paper_env.get('PAPER_ACTIVE_ENTRYPOINT', '')}`",
                f"- 当前 acceptance PDF: `{paper_env.get('PAPER_ACCEPT_PDF', '')}`",
                f"- 当前 acceptance LOG: `{paper_env.get('PAPER_ACCEPT_LOG', '')}`",
                "- 论文 worker 必须遵守 `project/paper/AGENTS.md -> 数模竞赛论文写作与工程约束`",
                "- 默认执行顺序：改写 -> 重新编译 -> 人工抽查关键数值 -> 九项写作自查",
                "- 不为论文修改新增 acceptance checker、manifest、hash、CLI、测试或其他工程设施",
                "- 既有 `paper_acceptance_check.sh` 仅供主脑内部 gate 按需使用，不得成为 PDF 内容或 paper worker 的默认施工内容",
                "- 最终回传不得自称消除 AI 痕迹；必须请用户本人通读摘要和引言判断文风",
            ]
        )
    lines.extend(["", "验收产物："])
    for item in acceptance:
        lines.append(f"- `{item}`")
    lines.extend(
        [
            "",
            "开始前：",
            "- `bash scripts/validate_agent_docs.sh`",
        ]
    )
    if task:
        lines.extend(
            [
                "",
                "流程 gate：",
                f"- 完成后补 `feedback`: `{task['feedback_path']}`",
                f"- retrospective policy `{task.get('retrospective_policy', 'required')}`；需要时补 `{task['retrospective_path']}`",
                "- feedback / retrospective 属于 workflow artifact scope，不会扩大业务文件 write scope。",
                "- canonical feedback skeleton 路径：`dispatch_task.sh` 触发 `task.dispatched` callback 自动补建",
                "- `submit_feedback.sh` 仅用于 repair missing feedback、初始化 retrospective、或手工补录",
                "- 不允许绕开 `check_*` / `close_task.sh` 流程；worker 只提交结果，不自行验收结案",
                f"- 结案前 handoff intake：`bash scripts/check_handoff_intake.sh --target {root}`",
                f"- 反馈检查：`bash scripts/check_worker_feedback.sh --task {task['task_id']} --target {root}`",
                f"- 复盘检查：`bash scripts/check_retrospective.sh --task {task['task_id']} --target {root}`",
                f"- 主脑转 review：`bash scripts/close_task.sh --task {task['task_id']} --to review --target {root}`",
                f"- 主脑转 done：`bash scripts/close_task.sh --task {task['task_id']} --to done --accepted-by main_brain --target {root}`",
                f"- 如需打回或撤销，由主脑执行：`bash scripts/reopen_task.sh --task {task['task_id']} ... --target {root}` / `bash scripts/cancel_task.sh --task {task['task_id']} ... --target {root}`",
                "",
                "完成后必须做的事：",
                f"- 把结构化结论写回 `{task['feedback_path']}`",
                f"- 按 retrospective policy 或 incident 要求补 `{task['retrospective_path']}`",
                "- 若消费 handoff，先通过 indexed intake 读取结果；不要直接扫描 `project/output/handoff/`。",
                "- 最终回复必须和 feedback 中的已验证事实 / 风险结论一致",
            ]
        )
    lines.extend(
        [
            "",
            "最终回复格式：",
            "1. 改了哪些文件",
            "2. 做了什么",
            "3. 哪些结论是已验证的",
            "4. 验证 / 编译 / 验收结果",
            "5. 剩余风险",
            "6. 本轮踩坑点",
            "7. 下次主脑最该提前告诉你的信息",
        ]
    )
    return "\n".join(lines) + "\n"
