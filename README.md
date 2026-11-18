# Codex Third Party Launcher

一个 macOS 启动器，让官方 Codex Desktop 和使用第三方 Responses API 网关的实例同时运行。启动时填写 Base URL 和 API key，启动器从 `<base-url>/models` 获取模型，然后用模型 ID 填充 Codex 原生模型菜单。

## 安装

发布包支持 Apple Silicon 和 macOS 14 或更新版本。

1. 从 GitHub Releases 下载 `Codex-Third-Party-<版本>-arm64.pkg`，双击并安装到当前用户。 [GitHub Releases](https://github.com/diverpet/codex-third-party-launcher/releases)
2. 在 Finder 打开 `~/Applications/Codex Third Party.app`。首次运行会检查本机安装的官方 ChatGPT.app，校验 OpenAI 签名，再复制到 `~/Applications/.codex-thirdparty/`。
3. 如果 Mac 尚未安装带 Codex 的官方 ChatGPT，启动器会提供下载入口。安装官方 App 后重新打开启动器即可。 [下载 ChatGPT](https://chatgpt.com/download/)

以后从 **Codex Third Party.app** 打开隔离实例，从原来的 **ChatGPT.app** 打开官方账号。安装新版本的启动器前先退出启动器和隔离实例。

## 使用

1. 在 Finder 打开 `~/Applications/Codex Third Party.app`。
2. 填写网关的完整 Base URL 和 API key。两个输入框默认留空。远程网关使用 HTTPS，本机回环网关也可使用 HTTP。
3. 如需阻止 GPT 系列消耗网关额度，勾选 **排除 GPT 系列模型（推荐）**，再点 **Load Models and Launch**。切换网关或过滤设置前，先退出隔离实例，再打开启动器。

网关至少需要支持 `GET /models` 与 `POST /responses`（相对 Base URL），并接受 Bearer token。密钥只在本次启动时传给子进程，不会由启动器写入文件。每个 Base URL 使用独立的 Codex 数据目录和桌面状态，原官方实例可以照常使用。启动器默认将用户主目录标为不加载项目配置，避免官方 `~/.codex/config.toml` 被第三方实例当作项目配置。实际项目目录可按需单独信任。 [网关兼容性](https://learn.chatgpt.com/docs/enterprise/gateway-compatibility)

原生 Computer Use 仍由 Codex Desktop 管理。它需要本机的屏幕录制和辅助功能权限，以及能处理截图和工具调用的模型、兼容的网关。 [Computer Use 设置](https://learn.chatgpt.com/docs/computer-use)

勾选 GPT 排除时，菜单隐藏 GPT 模型，隔离 Codex 改用当前会话的本机 HTTP 代理。代理只监听回环地址。它在转发前检查 Responses 请求的模型 ID，拦截 `gpt-6-luna`、`openai/gpt-6-luna` 等名称，同时保留其他模型的流式响应。适用范围是这次启动配置的网关。隐藏真实模型名称的网关别名仍按请求中的 ID 判断。

## 模型列表与本地覆盖

启动器支持 OpenAI 模型列表的 `data[].id`，也兼容 Codex `models[]` 目录。网关可在模型条目上附带以下可选扩展字段。 [OpenAI Models API](https://developers.openai.com/api/reference/resources/models/methods/list)

- `supported_apis` 为字符串数组时，只有包含 `"responses"` 的模型会显示在菜单。字段缺省或为 `null` 时保留模型。
- `input_modalities` 可声明 `["text"]` 或 `["text","image"]`。普通模型列表缺少该字段时，启动器按模型 ID 查找 Codex 内置目录，找不到时默认使用文本输入。

菜单显示实际请求使用的 model code。

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

从源码构建需要 macOS 14 或更新版本、Xcode Command Line Tools（Swift 5.10 或更新版本）和 Go 1.26 或更新版本。

```sh
swift run GatewayChecks
(cd Proxy && go test ./...)
./scripts/package.sh 1.1.0
```

本地命令默认生成未签名的测试安装包 `dist/Codex-Third-Party-1.1.0-arm64.pkg`。仅需要应用包时执行 `./scripts/build.sh`。也可以用 `./scripts/install.sh [官方 ChatGPT.app 路径]` 从源码安装。

验证本机官方 App 的签名、首次复制和重复运行时，可以执行 `CODEX_TEST_OFFICIAL_APP=/Applications/ChatGPT.app swift run GatewayChecks`。测试使用临时目录。

## 发布

在 GitHub 仓库的 **Settings → Secrets and variables → Actions** 配置以下条目。

| 类型 | 名称 | 内容 |
| --- | --- | --- |
| Variable | `APPLE_DEVELOPER_ID_APPLICATION` | Developer ID Application 签名身份的全名 |
| Variable | `APPLE_DEVELOPER_ID_INSTALLER` | Developer ID Installer 签名身份的全名 |
| Secret | `APPLE_DEVELOPER_ID_P12_BASE64` | 同时包含两个签名证书和私钥的 PKCS#12 文件，Base64 编码 |
| Secret | `APPLE_DEVELOPER_ID_P12_PASSWORD` | PKCS#12 导出密码 |
| Secret | `APPLE_NOTARY_API_KEY_P8_BASE64` | App Store Connect 团队 API 私钥，Base64 编码 |
| Secret | `APPLE_NOTARY_KEY_ID` | App Store Connect API Key ID |
| Secret | `APPLE_NOTARY_ISSUER_ID` | App Store Connect Issuer ID |

推送形如 `v1.1.0` 的 tag 后，`macOS Release` 会编译和测试、签名、公证、附加票据，并把验证通过的安装包和 SHA-256 校验和发布到 GitHub Releases。
