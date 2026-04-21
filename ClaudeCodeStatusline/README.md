# Claude Code Statusline

为 [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI 提供丰富的状态栏显示，在终端底部实时展示会话使用情况。

## 效果展示

```
GLM 5.1 ████████░░ 80% ↑12.5K ↓3.2K $0.42 5m32s
5H ██████░░ 62% ↻2h15m | MON ████████░░ 78% | 5h:45% ↻3h20m | 7d:23% ↻5d12h | cache:67% | +128 -42
```

**第一行**：模型名称 | 上下文进度条 | Token 统计（↑输入 ↓输出）| 费用 | 持续时间

**第二行**：5H 配额 | 月度配额 | 速率限制 | 缓存命中 | 代码变更

## 功能

- 上下文窗口使用率进度条（颜色随百分比变化：绿 → 黄 → 红）
- Token 消耗统计（自动缩写 K/M）
- 会话费用（USD）和持续时间
- 速率限制倒计时（5h / 7d）
- 缓存命中率统计
- 代码行变更统计（+添加 / -删除）
- 智谱 AI 外部配额监控（可选，带本地缓存）

## 安装

### 前置依赖

- [jq](https://stedolan.github.io/jq/)（JSON 解析）
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI

macOS 安装 jq：

```bash
brew install jq
```

### 配置步骤

1. 下载脚本并赋予执行权限：

```bash
# 将脚本放到你喜欢的位置
mkdir -p ~/.claude
curl -o ~/.claude/statusline.sh https://raw.githubusercontent.com/用户名/claude-code-statusline/main/statusline.sh
chmod +x ~/.claude/statusline.sh
```

2. 在 Claude Code 配置文件 `~/.claude/settings.json` 中添加 `statusLine` 配置：

```json
{
  "statusLine": {
    "type": "command",
    "command": "/Users/你的用户名/.claude/statusline.sh",
    "padding": 2
  }
}
```

> `command` 请填写脚本的绝对路径。`padding` 控制状态栏的内边距。

3. 重启 Claude Code 即可生效。

## 环境变量配置

### 外部配额监控（智谱 AI）

脚本支持通过智谱 AI 的监控 API 查看外部配额使用情况。该功能默认启用，通过以下环境变量配置：

| 环境变量 | 默认值 | 说明 |
|---------|--------|------|
| `GLM_MONITOR_URL` | `https://open.bigmodel.cn/api/monitor/usage/quota/limit` | 配额监控 API 地址 |
| `GLM_QUOTA_CACHE_TTL` | `300` | 缓存有效期（秒） |
| `GLM_QUOTA_STALE_MAX_AGE` | `1800` | 过期缓存最大保留时间（秒） |
| `GLM_MONITOR_TIMEOUT_MS` | `1500` | API 请求超时（毫秒） |
| `GLM_QUOTA_DISABLE` | `0` | 设为 `1` 禁用外部配额监控 |

设置方式（在 `~/.zshrc` 或 `~/.bashrc` 中添加）：

```bash
export GLM_QUOTA_DISABLE=1  # 禁用外部配额监控
```

## 许可证

MIT License
