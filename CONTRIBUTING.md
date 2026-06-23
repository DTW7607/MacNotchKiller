# 贡献指南

感谢你改进 FullScreenTools。这个项目依赖 macOS 私有显示接口，提交问题或代码时，请尽量提供可复现、可验证的信息。

## 开发环境

- macOS 13 或更高版本
- Apple Silicon Mac
- Swift 5.10 或更高版本工具链

```bash
git clone https://github.com/DTW7607/FullScreenTools.git
cd FullScreenTools
swift build
```

## 提交问题

请使用仓库的 Bug Report 模板，并至少提供：

- Mac 型号和芯片
- macOS 完整版本号
- 目标应用及其版本
- 是否已授予辅助功能权限
- 可稳定复现的操作步骤
- 完整错误文本或终端日志

显示器排列和输入问题请同时说明外接显示器数量及排列方式。

## 提交代码

1. 从 `main` 创建短期功能分支。
2. 保持改动范围集中，不混入构建缓存或本机配置。
3. 对生命周期、坐标系、Event Tap 和异步回调的改动补充必要注释。
4. 执行 `swift build` 和 `swift build -c release`。
5. 在 Pull Request 中说明验证环境、预期行为和已知风险。

建议使用 Conventional Commits：

```text
feat(selection): add interactive window highlighting
fix(display): wait for virtual display registration before positioning
docs: document permissions and recovery shortcut
```

## 工程约束

- 不提交 `.build/` 或其他生成物。
- 不直接链接私有类符号；私有 API 必须继续通过窄桥接层和运行时检测访问。
- 不削弱 `Control + Option + Command + Q` 故障退出路径。
- 不把真实设备上的成功结果等同于其他 macOS 版本兼容。
- 不添加遥测、网络请求或画面上传行为，除非经过单独讨论并默认关闭。
