# 参与贡献

欢迎通过 Issue 描述复现步骤，或通过 Pull Request 改进代码与文档。当前主程序位于 `native/`，早期 Python CLI 位于 `apple_store_assistant/`。

请先阅读 [README](README.md)、[用户教程](USER_GUIDE.md) 和 [架构说明](ARCHITECTURE.md)。针对自动化变更，在本地隔离页面验证，避免用真实账号、真实订单或付款来运行测试；现有入口为 `bash native/test-automation.sh` 和 `python3 -m unittest discover -v`。

提交前请移除密码、Cookie、浏览器资料、联系人、发票、订单和付款信息，使用明确的虚构样例。屏幕录像与截图也需要逐帧检查后再分享。

贡献须由你原创或拥有合法提交权，并按项目的 GPL-3.0-only 许可提供。第三方代码和资源应保留原有许可及出处；提交 PR 不表示你转让版权，也不表示你同意将贡献改为闭源商业许可。若涉及额外授权，维护者会另行书面沟通。
