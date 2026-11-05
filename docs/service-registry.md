# PeachyPet 服务注册格式

PeachyPet 的「服务」页读取注册目录 `~/.peachypet/services/`，目录里一个服务对应一个 JSON 文件，文件名就是服务 id。新增、修改、删除文件后，页面在 1 秒内更新。字段约束由同目录的 `service-registry.schema.json` 定义，以它为准。

## 文件名

`<id>.json`，id 只能由小写字母、数字和连字符组成，例如 `comfyui.json`、`git-pull-all.json`。

## 字段

| 字段 | 必填 | 说明 |
|---|---|---|
| `schema` | 是 | 固定写 `1` |
| `name` | 是 | 显示名 |
| `kind` | 是 | `service`：常驻服务，有启动、停止、重启；`task`：跑完就退出，只有「执行」 |
| `command` | 是 | 一行 shell 命令，用登录 shell（`zsh -lc`）执行，conda、fnm、brew 的 PATH 都能用 |
| `cwd` | 否 | 工作目录，支持 `~` |
| `url` | 否 | 「打开」按钮跳转的地址 |
| `port` | 否 | 服务监听的端口，用来判断是否在运行；从终端启动的服务也能据此识别 |
| `env` | 否 | 额外的环境变量，值必须是字符串 |
| `note` | 否 | 显示在名字下面的一句说明 |

不认识的字段会被忽略。

## 示例

```json
{"schema":1,"name":"ComfyUI","kind":"service","command":"conda run -n comfy python main.py --port 8188","cwd":"~/Documents/AI/Tools/ComfyUI","url":"http://127.0.0.1:8188","port":8188}
```

```json
{"schema":1,"name":"Ollama","kind":"service","command":"ollama serve","url":"http://127.0.0.1:11434","port":11434}
```

```json
{"schema":1,"name":"拉取全部仓库","kind":"task","command":"~/Documents/git-pull-all.sh ~/Documents/AI"}
```

## 规则

- **注册不等于启动。** 新命令或被改过的命令，第一次运行前，PeachyPet 会把完整的命令、目录和环境变量拿给用户确认。确认后，只改 `name`、`url`、`note` 不需要再确认。
- 格式错误的文件只影响它自己：页面上会显示「格式错误」和原因，其他条目照常显示。
- 注册服务不会开机自启。PeachyPet 不会往 `~/Library/LaunchAgents` 写任何文件。
- 删除注册：删掉文件即可，或者在页面上点删除，文件会进废纸篓。
