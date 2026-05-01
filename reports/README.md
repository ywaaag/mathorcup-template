# Reports Directory

这个目录只保留需要长期引用的报告。

默认规则：

- `smoke_instance_*.md` 和 `smoke_realflow_*.md` 是本地验证产物，默认不入库。
- `codex_context_handoff_*.md` 是本地会话交接产物，默认不入库。
- 如果某份报告需要成为长期证据，先改成有语义的文件名，再明确加入 Git。
- 新的 smoke 结论优先写入 README、handoff 或专门的稳定报告，不要堆积重复时间戳文件。

清理原则：

- 可以删除未跟踪的 generated reports。
- 不要批量删除已经 tracked 的历史报告，除非这是一次单独的证据整理任务。
