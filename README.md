# MathorCup Template — Agent-First Scaffold

这个仓库不是某一场比赛的实例项目，而是一个面向未来实例仓库的 Agent-first / workflow-first / scaffold-first 模板源。

## 1. 现在的结构规则

- `scaffold/`
  - 唯一模板 source of truth
  - 所有未来实例要渲染出的协议文档、runtime contract、prompt templates、paper config、README 骨架都在这里
- repo root 下的 `project/`
  - 仅作为 render target placeholder
  - 不再混放实例级 live `MEMORY.md`
- `scripts/`
  - 保留稳定入口名
  - 但内部职责已经拆分为 render / bootstrap / deps / reset / doctor / validate

## 2. 从模板实例化一个新比赛项目

推荐流程：

```bash
git clone <this-template> mathorcup-<比赛名>
cd mathorcup-<比赛名>
bash scripts/setup.sh <比赛名>
```

`setup.sh` 现在默认做的是：

1. 渲染缺失的实例文件
2. 生成运行配置
3. 创建/启动容器
4. 安装依赖
5. 运行校验/诊断

它默认不再做：

- 强制重置 `MEMORY.md`
- 删除历史 handoff
- 覆盖已有 runtime config

## 3. 关键入口

- `scripts/setup.sh`
  - 编排入口
- `scripts/render_templates.sh`
  - 从 `scaffold/` 渲染实例文件
- `scripts/bootstrap_container.sh`
  - 仅处理容器创建/启动
- `scripts/install_deps.sh`
  - 仅处理容器内依赖安装
- `scripts/reset_state.sh`
  - 仅处理 runtime state 重置
- `scripts/doctor.sh`
  - 轻量诊断
- `scripts/validate_agent_docs.sh`
  - 协议/合同/active entrypoint 校验

## 4. 新增的 Agent-first 合同层

- `scaffold/project/spec/runtime_contract.md.template`
  - 当前运行事实总入口
- `scaffold/project/spec/multi_agent_workflow_contract.md.template`
  - 主脑 / 代码脑 / 论文脑 / 杂务 Agent 协作协议
- `scaffold/project/workflow/prompt_template_library.md.template`
  - prompt-template library
- `scaffold/project/output/review/WORKER_FEEDBACK_TEMPLATE.md`
  - 结构化 worker 回传
- `scaffold/project/output/retrospectives/RETROSPECTIVE_TEMPLATE.md`
  - 经验复盘模板
- `scaffold/project/paper/runtime/paper.env.template`
  - paper active entrypoint 单一事实源

## 5. 轻量验证路径

推荐至少跑：

```bash
tmpdir="$(mktemp -d)"
bash scripts/setup.sh --render-only --target "$tmpdir"
bash scripts/validate_agent_docs.sh --root "$tmpdir"
bash scripts/doctor.sh --root "$tmpdir"
```

## 6. 没有 sub-agent 也怎么用

模板的硬依赖不是 vendor-specific delegation，而是：

- 共享的 `MEMORY.md`
- runtime contract
- workflow contract
- prompt-template library
- review / retrospective templates

即使只有多个独立会话，也能靠统一任务包 + 统一回传格式来协作。

## 7. 迁移说明

详见：

- `MIGRATION_TO_AGENT_FIRST_WORKFLOW.md`
