# Codex Third Party Launcher

一个 macOS 启动器，让官方 Codex Desktop 和使用第三方 Responses API 网关的实例同时运行。启动时填写 Base URL 和 API key，启动器从 `<base-url>/models` 获取模型，然后用模型 ID 填充 Codex 原生模型菜单。

## 安装

需要 macOS 14 或更新版本、Xcode Command Line Tools（Swift 5.10 或更新版本）及已安装的官方 ChatGPT 桌面应用。

```sh
git clone https://github.com/diverpet/codex-third-party-launcher.git
cd codex-third-party-launcher
./scripts/install.sh
```

默认读取 `/Applications/ChatGPT.app`。如果官方应用在别的位置，把应用路径作为安装脚本的第一个参数。安装器把官方签名的应用复制到 `~/Applications/.codex-thirdparty/`，并在 `~/Applications` 放置 **Codex Third Party.app**。更新启动器前，请先退出旧启动器，再将旧启动器 `.app` 移到其他位置。

## 使用

1. 在 Finder 打开 `~/Applications/Codex Third Party.app`。
2. 填写网关的完整 Base URL 和 API key。两个输入框默认留空。远程网关使用 HTTPS，本机回环网关也可使用 HTTP。
3. 点 **Load Models and Launch**，在第二个 Codex 实例里选择模型。切换网关前先退出这个实例，再打开启动器。

网关至少需要支持 `GET /models` 与 `POST /responses`（相对 Base URL），并接受 Bearer token。密钥只在本次启动时传给子进程，不会由启动器写入文件。每个 Base URL 使用独立的 Codex 数据目录和桌面状态，原官方实例可以照常使用。启动器默认将用户主目录标为不加载项目配置，避免官方 `~/.codex/config.toml` 被第三方实例当作项目配置。实际项目目录可按需单独信任。 [网关兼容性](https://learn.chatgpt.com/docs/enterprise/gateway-compatibility)

原生 Computer Use 仍由 Codex Desktop 管理。它需要本机的屏幕录制和辅助功能权限，以及能处理截图和工具调用的模型、兼容的网关。 [Computer Use 设置](https://learn.chatgpt.com/docs/computer-use)

## 模型列表与本地覆盖

启动器支持普通的 `data[].id` 模型列表，以及附带详细模态信息的 Codex `models[]` 目录。没有模态信息的模型会尝试匹配 Codex 内置目录，否则默认只声明文本输入。菜单始终显示实际请求使用的 model code。

如需隐藏某些前缀或为网关缺少元数据的模型声明图片输入，第一次启动后，在对应的 `~/.codex-thirdparty/gateways/<profile-id>/` 目录创建 `model-overrides.json`，然后重启第三方实例。可以通过该目录 `config.toml` 中的 `base_url` 找到对应的网关。

```json
{
  "excludePrefixes": ["openai/", "anthropic/"],
  "inputModalities": {
    "example-vision-model": ["text", "image"],
    "example-text-model": ["text"]
  }
}
```

不要把真实网关配置、模型目录或密钥提交进仓库。

## 构建与验证

```sh
swift run GatewayChecks
./scripts/build.sh
```

如果本机 Swift 的默认构建引擎报错，可执行 `swift run --build-system native GatewayChecks` 和 `SWIFT_BUILD_SYSTEM=native ./scripts/build.sh`。

构建产物是 `dist/Codex Third Party.app`。仓库只包含启动器源代码，官方 ChatGPT Desktop 由用户在本机安装。
