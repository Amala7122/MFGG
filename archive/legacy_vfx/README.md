# Legacy VFX archive

这里保存一组早期 Fireball / one-shot VFX 试验资产。

它们已不属于当前正式运行路径，且原始场景仍引用早期工程中的路径，例如：

`res://aObjs/aBuilding/Tower/aMageTower/mage_/projectile/...`

这些引用在当前 MFGG 工程中不存在，因此这组资产被视为历史样本，而不是可直接运行的正式资源。

处理原则：

- 保留原始文件内容，不为了“让它能打开”而改写历史资产。
- `archive/.gdignore` 让 Godot 不扫描这个归档目录。
- 正式导出配置排除 `archive/*`。
- 如果未来决定复活某个效果，应复制所需部分到正式资源目录，并重新建立依赖，而不是直接从 archive 引用。
