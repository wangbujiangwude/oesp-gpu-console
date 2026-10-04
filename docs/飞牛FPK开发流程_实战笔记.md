# 飞牛 fnOS FPK 原生应用开发流程（实战笔记）

> 以《GPU 控制台》为例，从零到装进应用中心的全过程
> 设备：ARM64（Amlogic S922X）· fnOS · 2026-10-01 实测

---

## 一、FPK 到底是什么

**`.fpk` 就是一个 gzip 压缩的 tar 包，改名而来。** 没有专有格式、没有编译步骤。

```bash
file gpuconsole_1.0.2.fpk
# → gzip compressed data

tar tzf gpuconsole_1.0.2.fpk     # 直接当 tar.gz 看
```

### 包内结构（顶层）

```
manifest            ← 元信息（key = value 文本）
ICON.PNG            ← 256×256 图标
ICON_256.PNG        ← 同上
LICENSE
cmd/                ← 生命周期钩子（安装/启动/停止/卸载/升级）
config/
  privilege         ← 运行身份（run-as / groupname）
  resource          ← 资源需求（要跑 docker 项目才写，否则 {}）
wizard/
  install           ← 安装向导（JSON，弹窗里的步骤与表单）
app.tgz             ← 应用主体（再一层 tar.gz）
```

### app.tgz 内部（应用主体，会被解到应用目录）

```
server/gateway.py   ← 后端服务
ui/config           ← 桌面入口配置
ui/images/icon_*.png
scripts/*.sh        ← 自己的脚本
```

---

## 二、manifest 字段详解

```
appname                    = gpuconsole           # 唯一标识，决定路径 /var/apps/<appname>
version                    = 1.0.2                # 版本，升级判断靠它
display_name               = GPU 控制台            # 应用中心显示名
desc                       = ...                  # 长描述（支持纯文本）
platform                   = all                  # all / x86 / arm
source                     = thirdparty
os_min_version             = 1.1.8                # 最低系统版本
maintainer                 = Kou
distributor                = Kou
distributor_url            = https://...
desktop_uidir              = ui                   # 桌面入口目录
desktop_applaunchname      = gpuconsole.Application   # 必须与 ui/config 里的 key 一致
checkport                  = false                # 是否检查端口占用（我们不占端口）
disable_authorization_path = true                 # 隐藏"文件授权"设置，最小化权限面
checksum                   = <32位hex>            # 实测为 app.tgz 的 md5，装包时会校验
```

> `desktop_applaunchname` 与 `ui/config` 的 `.url` key **必须完全一致**，否则应用中心图标点了打不开。

---

## 三、★ 核心机制：统一网关 + Unix Socket

**fnOS 原生应用不监听 TCP 端口。** 这是最容易走弯路的地方。

```
应用进程 ──→ 监听 $TRIM_APPDEST/app.sock（Unix Socket）
                    ↑
飞牛 nginx 网关 ────┘  把 /app/<appname>/* 转发进来
```

所以后端只要在这个 socket 上说标准 HTTP/1.1 即可：

```python
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(SOCK_PATH)          # $TRIM_APPDEST/app.sock
srv.listen(64)
os.chmod(SOCK_PATH, 0o666)
while True:
    conn, _ = srv.accept()
    threading.Thread(target=handle_request, args=(conn,)).start()
```

### 请求路径带前缀，必须剥离

飞牛网关转发过来的路径是 `/app/gpuconsole/api/status`，要自己剥掉前缀：

```python
PREFIX = "/app/gpuconsole"
if path.startswith(PREFIX):
    path = path[len(PREFIX):] or "/"
```

### ui/config —— 桌面入口

```json
{
  ".url": {
    "gpuconsole.Application": {
      "title": "GPU 控制台",
      "icon": "images/icon_{0}.png",
      "type": "iframe",
      "gatewayPrefix": "/app/gpuconsole",
      "gatewaySocket": "app.sock",
      "url": "/app/gpuconsole/",
      "allUsers": true
    }
  }
}
```

`type: iframe` = 点图标后用内嵌 iframe 打开 `url`，请求经 `gatewaySocket` 转发。

### 环境变量

应用运行时 fnOS 会注入：

| 变量 | 含义 |
|---|---|
| `TRIM_APPDEST` | 应用目录（实测指向 `/vol1/@appcenter/<appname>`，软链 `/var/apps/<appname>/target`） |
| `TRIM_PKGVAR` | 数据目录（存 pid/log/配置） |

---

## 四、生命周期钩子（cmd/）

fnOS 在对应时机调用这些脚本：

| 文件 | 时机 |
|---|---|
| `install_init` | 安装前 |
| `install_callback` | 安装后（**在这里启动服务**） |
| `uninstall_init` | 卸载前（停服务） |
| `uninstall_callback` | 卸载后（清 socket/pid） |
| `upgrade_init` | 升级前（停旧版，防抢 socket） |
| `upgrade_callback` | 升级后（起新版） |
| `config_init` / `config_callback` | 配置变更前后 |
| `main` | 手动入口：`cmd/main {start\|stop\|restart\|status}` |

**全部必须 `chmod +x`**，且**首行 `#!/bin/bash` 不能少**。

---

## 五、打包

```bash
# 1) 应用主体
tar czf app.tgz server ui scripts LICENSE

# 2) 算 checksum
CK=$(md5sum app.tgz | cut -d' ' -f1)
sed -i "s/^checksum.*/checksum                   = $CK/" manifest

# 3) 顶层打包（这就是 .fpk）
tar czf gpuconsole_1.0.2.fpk manifest ICON.PNG ICON_256.PNG LICENSE cmd config wizard app.tgz
```

完整脚本见 `gpu-console/build_fpk.sh`。

---

## 六、安装与调试

### 安装

```bash
# 手动安装开关（默认可能关闭）
appcenter-cli manual-install enable

# 安装
appcenter-cli install-fpk /tmp/gpuconsole.fpk -v 1

# 查看 / 启动 / 停止 / 卸载
appcenter-cli list
appcenter-cli status gpuconsole
appcenter-cli start gpuconsole
appcenter-cli uninstall gpuconsole
```

> `appcenter-cli` 在 `/usr/local/bin/appcenter-cli`（**不在** `/usr/trim/bin`，别找错）。

### 调试

```bash
# 应用运行日志（应用中心的日志在这里，不是 /var/apps/...）
tail -f /var/log/apps/gpuconsole.log

# 自己的日志
tail -f /var/apps/gpuconsole/var/cmd.log
tail -f /var/log/oesp-gpu/fix-*.log

# 直接验证后端（绕过 nginx，最高效）
curl -s --unix-socket /vol1/@appcenter/gpuconsole/app.sock http://localhost/api/status

# 验证带前缀路径（模拟网关真实调用）
curl -s --unix-socket /vol1/@appcenter/gpuconsole/app.sock \
     "http://localhost/app/gpuconsole/api/version"
```

---

## 七、⛔ 本次踩的坑（都是真金白银）

### 1. `sys.executable` 在 fnOS 应用环境里是空字符串

```
PermissionError: [Errno 13] Permission denied: ''
```

`subprocess.Popen([sys.executable, ...])` 直接炸，**应用显示 running 但 socket 永远不出现**。

**必须逐个回退探测解释器**：

```python
def pyexe():
    for c in (sys.executable, shutil.which("python3"), shutil.which("python"),
              "/usr/bin/python3", "/usr/bin/python"):
        if c and os.path.isfile(c) and os.access(c, os.X_OK):
            return c
    return "python3"
```

shell 钩子里同理，不能只写 `command -v python3`（PATH 不全）。

### 2. 同 appname 的 `install-fpk` 不会升级

```
[Info]Application [gpuconsole] is installed.       ← 直接跳过，版本没变
```

**改版本号后必须 `uninstall` 再 `install`**。（`upgrade_init/callback` 是给应用中心内部升级流用的。）

### 3. socket 的真实路径是 `/vol1/@appcenter/<appname>/app.sock`

`/var/apps/<appname>/target` 是软链，但应用实际在真实路径跑。**排查时两个都试**。

### 4. 应用以普通用户跑 → 读不到 docker socket

`privileged` 里加 `"groupname": "docker"` 即可（实测属组变成 `gpuconsole docker`，容器列表正常出）。

```json
{
  "defaults": { "run-as": "package" },
  "groupname": "docker"
}
```

### 5. Windows 打包会丢可执行位

从 Windows 传过去后 `chmod +x cmd/* scripts/*.sh`（build_fpk.sh 里已内置这一步）。

### 6. Git Bash 的 MSYS 路径转换

在 Windows 上用 Git Bash 调 Python 脚本传 `/tmp/xxx` 参数时，**会被改写成 `C:/Users/.../Temp/xxx`**，导致远端报
`No such file`（多种远程传输工具都会中招，且报错路径是 Windows 的，极具迷惑性）。

解决：命令前加 `MSYS_NO_PATHCONV=1`。

---

## 八、完整开发流程 checklist

```
① 建目录
   gpu-console/{manifest,cmd,config,wizard,server,ui,scripts}

② 写 manifest（注意 desktop_applaunchname 要和 ui/config 对齐）

③ 写 server/gateway.py
   · AF_UNIX socket，bind $TRIM_APPDEST/app.sock，chmod 666
   · 剥离 /app/<appname> 前缀
   · pyexe() 探测解释器（别信 sys.executable）
   · start/stop/status/supervise 四个子命令

④ 写 ui/config（type=iframe + gatewayPrefix + gatewaySocket）

⑤ 写 cmd/ 钩子，全部 chmod +x

⑥ 写 config/privilege（run-as package；需要 docker 就加 groupname）

⑦ 生成图标（256×256 PNG → ICON.PNG / ICON_256.PNG / ui/images/icon_{64,256}.png）

⑧ bash build_fpk.sh  → 产出 <appname>_<version>.fpk

⑨ appcenter-cli install-fpk xxx.fpk -v 1

⑩ 等 2 秒看 socket 是否出现：
   ls -l /vol1/@appcenter/<appname>/app.sock
   curl -s --unix-socket .../app.sock http://localhost/api/status

⑪ 有错看 /var/log/apps/<appname>.log

⑫ 改完再装：先 uninstall，再 install（版本号要+1）
```

---

## 九、本应用最终实测结果

| 项目 | 结果 |
|---|---|
| 包名 | `gpuconsole_1.0.2.fpk`（20,946 bytes） |
| 安装 | ✅ `Installation complete`，列表显示 `GPU 控制台 1.0.2` |
| 启动 | ✅ **2 秒内 socket 就绪** |
| 进程 | ✅ `gateway.py supervise` + `gateway.py serve`（用户 `gpuconsole:docker`） |
| API `/api/version` | ✅ `{"version": "1.0.2", "app": "gpuconsole"}` |
| API `/api/status` | ✅ GPU 频率 / 中断 / CMA / 温度 / 模块 / 容器 全部真实 |
| 带前缀路径 | ✅ `/app/gpuconsole/api/version` 正常 |
| 首页 | ✅ 9,288 bytes |
| 容器识别 | ✅ `androidemu-android` 正确标为"用 GPU" |
