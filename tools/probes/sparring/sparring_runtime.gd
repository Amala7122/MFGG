extends RefCounted
## 固定帧无渲染会快于音频混音线程；每局结束后排空播放，避免批跑积压。
## 仅诊断生命周期使用，不参与战斗中的音频或判定。
static func settle_audio(tree: SceneTree) -> void:
	for type_name in ["AudioStreamPlayer", "AudioStreamPlayer2D", "AudioStreamPlayer3D"]:
		for node: Node in tree.root.find_children("*", type_name, true, false):
			node.call("stop")
			node.set("stream", null)
	var until := Time.get_ticks_msec() + 100
	while Time.get_ticks_msec() < until:
		await tree.process_frame
