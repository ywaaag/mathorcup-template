# mathorcup-template 实例化与功能冒烟测试报告

测试日期：2026-04-24

## 结论

本轮在模板仓库之外创建了两个临时实例目录，分别验证了低风险工作流层和容器/论文编译层。结论是：当前 `mathorcup-template` 可以在其他目录正常实例化；渲染、协议校验、主脑任务面板、任务派发、反馈门禁、状态一致性检查、reset、容器启动、论文编译和容器工具基线均通过。

未发现阻断性问题。需要注意的是，本轮没有执行真实 `codex exec` worker，也没有运行完整 `install_deps.sh` 依赖安装，因为 reference image 已经具备本轮所需工具基线。

## 测试环境

- 模板源目录：`/home/ywag/mathorcup-template`
- 低风险实例目录：`/tmp/mathorcup-template-smoke-20260424_211949.KGAy6s`
- 容器实例目录：`/tmp/mathorcup-template-container-20260424_212027.ycSyvi`
- 镜像：`mathorcup-runtime:latest`
- 镜像实际标签：`mathorcup-runtime:20260419`
- 容器测试名：`smokecontest-container-20260424_212027`
- 测试容器状态：已在测试结束后执行 `docker rm -f` 清理

## 低风险实例化测试

执行范围：

```bash
bash scripts/validate_agent_docs.sh --template-source-only
bash scripts/setup.sh smokecontest --render-only --target /tmp/mathorcup-template-smoke-20260424_211949.KGAy6s
bash scripts/validate_agent_docs.sh --root /tmp/mathorcup-template-smoke-20260424_211949.KGAy6s
bash scripts/doctor.sh --root /tmp/mathorcup-template-smoke-20260424_211949.KGAy6s
bash scripts/main_brain_summary.sh --target /tmp/mathorcup-template-smoke-20260424_211949.KGAy6s
bash scripts/list_open_tasks.sh --open-only --target /tmp/mathorcup-template-smoke-20260424_211949.KGAy6s
bash scripts/recommend_tasks.sh --target /tmp/mathorcup-template-smoke-20260424_211949.KGAy6s
bash scripts/make_task_packet.sh --task TASK_REVIEW_CONSISTENCY --target /tmp/mathorcup-template-smoke-20260424_211949.KGAy6s
bash scripts/dispatch_task.sh --task TASK_REVIEW_CONSISTENCY --owner smoke_review --target /tmp/mathorcup-template-smoke-20260424_211949.KGAy6s
bash scripts/check_worker_feedback.sh --task TASK_REVIEW_CONSISTENCY --target /tmp/mathorcup-template-smoke-20260424_211949.KGAy6s
bash scripts/close_task.sh --task TASK_REVIEW_CONSISTENCY --to review --target /tmp/mathorcup-template-smoke-20260424_211949.KGAy6s
bash scripts/check_state_consistency.sh --target /tmp/mathorcup-template-smoke-20260424_211949.KGAy6s
bash scripts/paper.sh --target /tmp/mathorcup-template-smoke-20260424_211949.KGAy6s print-config
bash scripts/reset_state.sh --target /tmp/mathorcup-template-smoke-20260424_211949.KGAy6s
python3 -m py_compile scripts/lib/workflow_state.py scripts/lib/workflow_events.py scripts/lib/workflow_audit.py
```

结果：

- `template_source_validate`：通过
- `render_only`：通过
- `rendered_validate_all`：通过
- `roles/tasks/queue/state-consistency` 分项校验：通过
- `doctor`：通过，正确识别 rendered instance
- `main_brain_summary`：通过，初始队列显示 `ready: 7`
- `list_open_tasks` / `recommend_tasks`：通过
- `make_task_packet`：通过
- `dispatch_task`：通过，`TASK_REVIEW_CONSISTENCY` 被认领为 `in_progress`
- `check_worker_feedback`：通过，dispatch callback 创建的 feedback skeleton 可通过 gate
- `close_task --to review`：通过
- `check_state_consistency`：通过，event log 解析到 5 条事件，无 WARN/ERROR
- `paper.sh print-config`：通过
- `reset_state` 后再次 validate：通过
- Python 编译检查：通过

关键观察：

- 渲染后的 `.env` 正确写入 `COMPETITION_NAME=smokecontest`、`CONTAINER_NAME=smokecontest-dev` 和临时 `HOST_DIR`。
- `project/paper/runtime/paper.env` 正确保留 `PAPER_ACTIVE_ENTRYPOINT=main.tex` 与 acceptance artifact 路径。
- 主脑摘要能正确输出 runtime facts、queue overview、recent events 和推荐下一步命令。
- 派发路径会生成任务包，并通过 callback 补齐 feedback skeleton。

## 容器与论文编译测试

执行范围：

```bash
bash scripts/setup.sh smokecontest --render-only --target /tmp/mathorcup-template-container-20260424_212027.ycSyvi
bash scripts/bootstrap_container.sh --target /tmp/mathorcup-template-container-20260424_212027.ycSyvi
bash scripts/doctor.sh --root /tmp/mathorcup-template-container-20260424_212027.ycSyvi
bash scripts/paper.sh --target /tmp/mathorcup-template-container-20260424_212027.ycSyvi build
bash scripts/validate_agent_docs.sh --root /tmp/mathorcup-template-container-20260424_212027.ycSyvi
docker exec smokecontest-container-20260424_212027 bash -lc 'python3 --version && pip --version && latexmk -v | head -n 1 && xelatex --version | head -n 1 && command -v biber && command -v fd && command -v tree && command -v yq'
docker rm -f smokecontest-container-20260424_212027
```

结果：

- `render_only_container_profile`：通过
- `bootstrap_container`：通过
- `doctor_container_running`：通过
- `paper_build`：通过
- `validate_after_paper_build`：通过
- `container_tool_probe`：通过
- `cleanup_container`：通过

论文编译结果：

- `paper.sh build` 成功生成 host-visible PDF
- 产物路径：`/tmp/mathorcup-template-container-20260424_212027.ycSyvi/project/paper/main.pdf`
- LaTeX 日志显示：`Output written on main.pdf (1 page).`

容器工具基线：

- `Python 3.12.12`
- `pip 24.1.2`
- `latexmk 4.83`
- `XeTeX 3.141592653-2.6-0.999995 (TeX Live 2023/Debian)`
- `biber`：`/usr/bin/biber`
- `fd`：`/usr/local/bin/fd`
- `tree`：`/usr/bin/tree`
- `yq`：`/usr/local/bin/yq`

## 未覆盖范围

- 未执行 `scripts/install_deps.sh`，因为当前 reference image 已满足 paper build 和工具基线。
- 未执行 `scripts/exec_healthcheck.sh` 和 `scripts/run_exec_worker.sh`，本轮重点是模板实例化、repo harness、Docker 与 paper build。
- 未测试并行 `run_exec_batch.sh`，只测试了单任务 dispatch/gate/close 流程。
- 未测试 `bootstrap_container.sh --recreate`，避免对非本轮创建资源产生破坏性影响。

## 风险判断

当前模板的基础实例化链路是可用的：`render -> validate -> doctor -> dispatch -> feedback gate -> close/recheck -> reset` 没有发现状态漂移。容器链路也可用：`render -> bootstrap -> paper build -> validate -> cleanup` 成功闭环。

后续如果要继续增强，优先建议补一组自动化 smoke 脚本，把本报告中的命令固化为 `scripts/smoke_instance.sh` 或 CI 入口。这样每次改 `scaffold/`、workflow kernel 或 shell facade 后，都能一键验证模板源与渲染实例是否仍然一致。
