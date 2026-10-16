# 共鸣类型

`area_clear.tres` 是当前正式共鸣：负责清理杂兵，对 Boss 不造成伤害、击退、减速或余震灼烧；Boss 仍会收到“共鸣来袭”事件并开启自身防御反应。

`single_target_template.tres` 只定义未来单体共鸣所需的目标策略，不进入当前掉落、选择或 UI。后续扩展时复制为正式方案，再通过 `Resonance.set_resonance_type()` 接入；不要修改范围清场型来兼任打 Boss。
