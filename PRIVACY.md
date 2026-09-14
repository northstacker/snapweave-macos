# SnapWeave 隐私说明

SnapWeave 不运行内容服务器，也不会自动上传截图、GIF、OCR、翻译或历史数据。

- 屏幕录制权限只用于读取用户主动框选的区域。
- 辅助功能权限只在用户主动启用自动滚动时使用。
- 截图历史首次确认后才启用，保存在 `~/Library/Application Support/SnapWeave/ScreenshotHistory/`；可关闭记录、保留既有项目或全部清空。
- 剪贴板历史使用独立开关，保存在 `~/Library/Application Support/SnapWeave/ClipboardHistory/`。第三方应用若未正确标记敏感内容，SnapWeave 无法自动判断其是否为密码。
- OCR 使用 macOS Vision；翻译使用 macOS Translation。首次下载苹果语言包可能需要联网，但 SnapWeave 不会接收翻译正文。
- 用户主动导出的诊断包不包含截图、截图草稿、GIF、钉图、OCR/翻译正文、剪贴板载荷或快捷键配置。
- 0.10.0 增加的本地性能 signpost 只包含功能阶段和耗时，不包含任何截图像素或用户文字，也不会上传。
- 0.11.0 使用 SQLite 保存剪贴板和最近截图的索引元数据，原图、缩略图和标注工程仍保存在同目录的独立文件中；旧版 JSON 会在迁移成功后保留带日期的备份。
- 0.11.0 的捕获会话检查点只保存方向、帧数、尺寸和匹配状态等元数据，不保存屏幕像素，也不会写入诊断包。
- 0.11.1 首次启动会将旧 `~/Library/Application Support/横截/` 目录整体迁移到 `~/Library/Application Support/SnapWeave/`。若新旧目录同时存在，则只使用新目录，并保留旧目录供用户自行核对。
- 0.12.0 的会话调度、拼接批量落盘和 ScreenCaptureKit 内容缓存只记录状态与耗时；请求取消会释放缓存，不会把屏幕像素、OCR/翻译文字或剪贴板正文写入日志。
