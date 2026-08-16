# ArgoX 部署教程：打包到 GitHub + VPS 快速安装

本教程分两部分：

- **A. 把项目整理成一个可长期维护的 GitHub 仓库**
- **B. 在全新 VPS 上一条命令完成 VLESS + XHTTP + PQC + ECH + Argo + CDN 部署**

---

## A. 打包到 GitHub

### A0. 仓库必须满足的两个硬性条件（对应你的一键命令）

你要用的一键命令是：

```bash
bash <(wget -qO- https://raw.githubusercontent.com/hkzping999/XHTTP-CDN/main/argox.sh)
```

这条命令能不能跑通，只取决于两件事：

1. 仓库 **默认分支必须叫 `main`**（GitHub 新建仓库默认就是 `main`，不用改；
   如果你的仓库还是 `master`，要么在 GitHub 设置里改名，要么把上面命令里
   的 `main` 换成 `master`）。
2. `argox.sh` 必须在 **仓库根目录**（不能放进子文件夹），这样
   `raw.githubusercontent.com/hkzping999/Argo-reality-pqc/main/argox.sh`
   这个路径才存在。

这次给你的补丁包里，`argox.sh` 内部新增了一个常量：

```bash
ARGOX_RAW_URL='https://raw.githubusercontent.com/hkzping999/Argo-reality-pqc/main/argox.sh'
```

这个地址已经**按你的仓库名写死**了，后面 B 部分会解释它的用途
（自安装防损坏机制）。如果你以后仓库改名、换分支，记得同步改这一行。

### A1. 仓库结构建议

```
argox/
├── argox.sh                                  # 主脚本
├── README.md                                 # 项目说明（已有）
├── CHANGELOG.md                               # 版本记录（已有）
├── SHA256SUMS.txt                             # 发布文件校验和（已有）
├── config-vless-xhttp-pqc-ech-argo-cdn.conf   # 非交互安装模板
├── config-pqc-strong.conf                     # 备用模板
├── tests/
│   └── test_release.sh                        # 发布前自检脚本
├── DEPLOY_GUIDE.md                             # 本教程
├── LICENSE                                     # 建议加开源许可证，例如 MIT
└── .gitignore
```

### A2. 创建 `.gitignore`

**这一步很重要**：绝不能把你自己的 Tunnel Token、UUID、ECHConfig 或任何
含真实域名/密钥的配置文件提交到仓库。仓库里只应该保留"模板"
（`config-vless-xhttp-pqc-ech-argo-cdn.conf` 里的 `ARGO_AUTH` 应始终是占位符）。

```gitignore
# 本地调试产物
*.local.conf
my-*.conf
*.token
*.pem
*.key
.DS_Store

# 若你在仓库目录里跑过安装测试
tests/argox-release-test.*
```

> 如果你打算把自己实际使用的固定域名配置也存一份，建议放进**私有仓库**，
> 或者用 `git-crypt` / GitHub Secrets 加密，而不是明文放进公开仓库。

### A3. 首次推送到 GitHub

```bash
# 1. 在本地解压这次给你的压缩包
unzip Argo-reality-pqc-main-v2_3_6-xhttp-split.zip -d argox
cd argox

# 2. 初始化 git 仓库
git init
git add -A
git commit -m "ArgoX v2.3.7: Shadowrocket + PassWall XHTTP split support"

# 3. 在 GitHub 网页端创建一个空仓库（不要勾选自动生成 README），
#    你的仓库地址：https://github.com/hkzping999/Argo-reality-pqc
git branch -M main
git remote add origin https://github.com/hkzping999/Argo-reality-pqc.git
git push -u origin main
```

### A4. 打 Release（推荐，方便 VPS 直接下载固定版本）

```bash
git tag -a v2.3.7 -m "Shadowrocket + PassWall XHTTP split support"
git push origin v2.3.7
```

然后在 GitHub 网页的 **Releases** 页面，基于这个 tag 创建 Release，
把 `SHA256SUMS.txt` 里的内容贴进 Release 说明，方便别人（或者未来的你）
校验下载文件没有被篡改。

### A5.（可选）加一个 CI 自检

在 `.github/workflows/test.yml` 里加一个最小化的 CI，每次 push 自动跑
仓库自带的 `tests/test_release.sh`，防止以后改坏脚本自己不知道：

```yaml
name: release-check
on:
  push:
  pull_request:
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: install jq
        run: sudo apt-get update -qq && sudo apt-get install -y jq
      - name: run release self-test
        run: bash tests/test_release.sh
```

---

## B. VPS 上的部署教程

### B1. 前置条件检查表

| 项目 | 要求 |
|---|---|
| VPS 系统 | Debian / Ubuntu / CentOS / Alpine / Armbian / Arch，任意一种 |
| 权限 | 需要 root（`sudo` 亦可） |
| 架构 | AMD64 / ARM64 / s390x |
| 域名 | 已托管在 **Cloudflare** 的域名一个 |
| Cloudflare Tunnel | 提前建好，并绑定 Public Hostname（见 B2） |
| Cloudflare ECH | 该 Zone 已启用（Free 套餐一般默认开） |
| 出站网络 | VPS 能正常访问 Cloudflare（大多数 VPS 默认可以） |

> **无需在 VPS 防火墙上放行任何入站端口。** Argo Tunnel 是 VPS 主动向
> Cloudflare 发起的出站连接，客户端从来不会直接连 VPS 的 IP。只要 SSH
> 端口能连上，其余端口建议保持默认拒绝（见 B7 的安全建议）。

### B2. 先在 Cloudflare 后台把 Tunnel 建好

1. 打开 Cloudflare **Zero Trust** 后台 → **Networks → Tunnels**。
2. 新建一个 Tunnel，记下它的 **Token**（一段很长的字符串），
   或者下载它的 **credentials JSON**。
3. 给这个 Tunnel 添加一条 **Public Hostname**，Hostname 必须和你等会
   要在脚本里填的固定域名**完全一致**（例如 `xhttp.example.com`）。如果后面使用的是 **Tunnel Token**，Service 默认请填 `http://localhost:8080`；这个端口必须和脚本 `NGINX_PORT` 完全相同。脚本不会再为了躲避端口占用而静默改成 8081/8082，否则 Cloudflare 远程 ingress 仍指向旧端口会直接造成 502。
4. 确认该域名所在 Zone 的 **SSL/TLS → Edge Certificates → Encrypted
   ClientHello (ECH)** 已启用。

> ⚠️ 用**临时** `trycloudflare.com` 隧道不支持 XHTTP + PQC + ECH 组合，
> 一定要用固定 Tunnel。

### B3. 登录 VPS，一条命令完成安装

这就是你想要的用法。登录任意一台满足前置条件的 VPS 后，直接运行：

```bash
bash <(wget -qO- https://raw.githubusercontent.com/hkzping999/Argo-reality-pqc/main/argox.sh)
```

会进入交互菜单，跟着提示选协议、填固定域名和 Token 即可。如果想跳过菜单，
直接走"傻瓜式固定域名安装"（见 B4），在同一条命令后面加参数：

```bash
bash <(wget -qO- https://raw.githubusercontent.com/hkzping999/Argo-reality-pqc/main/argox.sh) -c -g
```

`bash <(...)` 后面跟的参数会正常传给脚本，这点已经验证过，不受这种
"进程替换"写法影响。

> **关于这种一键命令的一个真实存在过的坑，这次已经修复：**
> 脚本安装到最后一步会执行 `create_shortcut()`，把自己安装成
> `/etc/argox/argox.sh`，并生成全局命令 `argox`。旧版本这一步是用
> `cp "${BASH_SOURCE[0]}" ...` 实现的——但当脚本是通过
> `bash <(wget -qO- ...)` 这种"进程替换"方式运行时，
> `${BASH_SOURCE[0]}` 指向的其实是一个**一次性的匿名管道**（类似
> `/dev/fd/63`），而不是一个可以重复读取的普通文件。bash 解释器自己也在
> 从这同一个管道里往后读取还没执行到的脚本内容；这时候再用 `cp` 去读一
> 遍同一个管道，会跟 bash 自身的读取进度互相抢字节。我实测复现过这个
> 问题：拷贝出来的文件被截断、损坏，脚本本身也会在这一步之后**莫名提前
> 结束**（后面没执行到的代码被 `cp` 提前"吃掉"了）。
> 这次补丁把判断逻辑从"能不能读"改成了"是不是一个真正的普通文件"：
> 如果是（比如你在 VPS 上先 `git clone` 再本地执行），照旧直接拷贝；
> 如果不是（也就是你现在用的这种管道一键安装），改为向脚本里新增的
> `ARGOX_RAW_URL` 常量重新单独发起一次 `wget` 下载，并加上"非空 +
> `bash -n` 语法校验"双重检查，通过了才正式覆盖安装，避免网络抖动或者
> GitHub 反代返回错误页面时把坏文件当正式版装上。这个修复已经在真实的
> 进程替换环境下验证过：装完的 `/etc/argox/argox.sh` 和源文件逐行一致，
> 脚本也不会再提前退出。**这就是这次修复的核心原因**——如果你直接用旧包
> 里的 `argox.sh` 跑这条一键命令，`argox -n`、`argox -r`
> 这些后续管理命令大概率会因为装出来的脚本被截断而报错或行为异常；用这
> 次修复后的版本就不会有这个问题。

如果你更信任先落盘再执行、或者想在执行前自己看一眼脚本内容，也可以用
等价的两步写法（效果完全一样，只是分成了两条命令）：

```bash
wget -qO argox.sh https://raw.githubusercontent.com/hkzping999/Argo-reality-pqc/main/argox.sh
sha256sum argox.sh    # 对照 GitHub Release 里的 SHA256SUMS.txt 核对一下
sudo bash argox.sh -c -g
```

这种两步写法里 `${BASH_SOURCE[0]}` 就是一个真实文件，走的是原来的
`cp` 路径，不会触发上面说的问题；效果和一条命令的管道写法完全等价，
纯粹是个人习惯选择。

**方式二：先 `git clone` 整个仓库（想同时保留模板文件、DEPLOY_GUIDE 等时更方便）**

```bash
ssh root@your-vps-ip
git clone https://github.com/hkzping999/Argo-reality-pqc.git
cd Argo-reality-pqc
chmod +x argox.sh
sha256sum -c SHA256SUMS.txt   # 校验完整性
sudo bash argox.sh -c -g
```

### B4. `-c -g` 到底做了什么（傻瓜式固定域名安装，逐项确认版）

不管你用的是 B3 里的一键管道命令、两步落盘命令、还是 `git clone` 后本地跑，
只要命令末尾带上 `-c -g`：

```bash
# 一键管道
bash <(wget -qO- https://raw.githubusercontent.com/hkzping999/Argo-reality-pqc/main/argox.sh) -c -g
# 或者 git clone 后本地执行
sudo bash argox.sh -c -g
```

脚本会作为"VLESS + XHTTP + PQC + Argo + CDN + ECH"这一个协议整体，
**逐项**问你以下内容，每一项都会把当前默认值显示在 `[ ]` 里——
直接回车就采用默认值进入下一步，或者手动输入新值后回车确认，跟脚本里
其它协议的交互习惯是一致的：

| 步骤 | 变量 | 默认值 | 说明 |
|---|---|---|---|
| 1 | `ARGO_DOMAIN` | 无（必填） | B2 里绑定的固定 Tunnel 域名，格式不对会重试，最多 5 次 |
| 2 | `ARGO_AUTH` | 无（必填） | Tunnel Token 或单行 credentials JSON，隐藏输入，格式不对会重试 |
| 3 | `SERVER` | `www.cloudflare.com` | 客户端连接用的 CDN 优选入口 |
| 4 | `ENABLE_VLESS_PQC` | `y` | 是否开启 ML-KEM-768/X25519 后量子 VLESS Encryption |
| 5 | `VLESS_PQC_STRICT` | `y` | PQC 校验失败时直接中止安装，而不是悄悄降级 |
| 6 | `VLESS_PQC_DISABLE_0RTT` | `y` | 是否禁用 0-RTT，只走 1-RTT |
| 7 | `XHTTP_CDN_MODE` | `packet-up` | 只能是 `auto`/`stream-one`/`stream-up`/`packet-up` 之一，兼容性最好的是 `packet-up` |
| 8 | `ENABLE_XHTTP_SPLIT` | `n` | 是否开启 XHTTP 上下行分离 |
| 9 | `XHTTP_DOWNLOAD_SERVER[:PORT]` | 继承 `SERVER:443` | 仅第 8 项开启时询问；可填另一 Cloudflare 优选域名/IP/IPv6 |
| 10 | `ENABLE_ECH` | `y` | 是否开启 ECH（Encrypted Client Hello） |
| 11 | `ECH_STRICT` | `y` | ECH 校验失败时直接中止安装，而不是悄悄关闭 ECH |
| 12 | `ECH_QUERY_DOMAIN` | `cloudflare-ech.com` | 用来查询 HTTPS/ECH 记录的域名 |
| 13 | `ECH_DNS` | `https://1.1.1.1/dns-query` | 获取 ECH 配置用的 DoH/DoU 解析地址 |

开关类字段（第 4/5/6/8/10/11 项）如果输入了既不是空、也不能识别成 y/n
的内容，会提示"输入无效"并自动回退为默认值，不会把打错的字当成"n"
悄悄接受；第 7 项如果输入的不是那四个合法模式之一，会提示重新输入，
最多重试 3 次，用尽后回退默认值；第 9 项会解析域名/IP/IPv6及可选端口；
第 12/13 项分别做域名格式 / DoH-DoU URL 格式校验，格式不对同样会重试后
回退默认值。开启上下行分离且第 7 项为 `stream-one` 时，脚本会提示并自动把
上行改为 `stream-up`。

全部项目问完后，脚本会打印一份配置汇总，再问一次"确认并开始安装？[Y/n]"，
回车或输入 `y` 才会真正开始装；这个模式依然会**拒绝**临时域名、无效凭据、
以及覆盖已存在的 ArgoX 安装，避免误装成弱配置。这是首次部署最推荐的方式。

安装过程大约几分钟，结束后会直接打印出：

- 标准 VLESS 分享链接（`vless://...`，可以直接导入 v2rayN / Shadowrocket 等）
- Mihomo/Clash 订阅片段
- 原生 Xray 客户端完整配置文件路径

### B5. 想自定义参数？用高级模板安装

如果你不想走一问一答的向导、想一次性把所有参数写进一个文件里免交互安装，
用模板文件而不是 `-g`（这一步需要本地有
`config-vless-xhttp-pqc-ech-argo-cdn.conf`，所以要先 `git clone` 整个
仓库，或者单独下载这个模板文件）：

```bash
cp config-vless-xhttp-pqc-ech-argo-cdn.conf my-xhttp.conf
chmod 600 my-xhttp.conf
nano my-xhttp.conf        # 至少要改 ARGO_DOMAIN 和 ARGO_AUTH 两项
sudo bash argox.sh -f my-xhttp.conf
```

`my-xhttp.conf` 里的关键项：

```bash
INSTALL_PROTOCOLS='i'                 # i = VLESS + XHTTP CDN
ENABLE_VLESS_PQC='y'                  # 开启 VLESS Encryption 后量子加密
VLESS_PQC_STRICT='y'                  # 校验失败直接中止，不悄悄降级
VLESS_PQC_DISABLE_0RTT='y'            # 禁用 0-RTT，只走 1-RTT
XHTTP_CDN_MODE='packet-up'            # 兼容性最好的 CDN 模式
ENABLE_XHTTP_SPLIT='n'                # y=启用上下行分离
XHTTP_DOWNLOAD_SERVER=''              # 下行 CDN 入口；空=继承 SERVER
XHTTP_DOWNLOAD_PORT=''                # 空=继承 SERVER_PORT/443
ENABLE_ECH='y'
ECH_STRICT='y'
ECH_QUERY_DOMAIN='cloudflare-ech.com'
ECH_DNS='https://1.1.1.1/dns-query'

ARGO_DOMAIN='xhttp.example.com'                       # 必填：你的固定域名
ARGO_AUTH='粘贴 Cloudflare Tunnel Token 或 JSON'        # 必填
SERVER='www.cloudflare.com'                           # CDN 优选入口
```

上下行分离只改变客户端连接方式：服务端仍复用同一个 XHTTP inbound、Nginx 路径和固定 Tunnel。即使下行选择另一 Cloudflare 优选 IP/域名，`Host/SNI` 也继续使用 `ARGO_DOMAIN`。v2.3.7 会把完整 XHTTP `extra` JSON URL 编码后写入标准 VLESS URI，因此除了原生 Xray JSON / Mihomo provider，也可直接生成 Shadowrocket 和 PassWall/PassWall2 专用导入输出。

> `my-xhttp.conf` 里填了真实 Token 之后，**千万不要**把它 commit 进
> GitHub 仓库，参考 A2 的 `.gitignore`。

### B6. 装完之后常用的命令

安装完会自动生成一个全局命令 `argox`，以后不需要再进脚本所在目录：

```bash
sudo argox -n     # 重新打印所有客户端链接/订阅（装完随时可以再看一遍）
sudo argox -r     # 增删协议（比如后面想再加一个 trojan-direct 备用节点）
sudo argox -d     # 修改现有配置（域名、端口等）
sudo argox -t     # 更换/重新绑定 Argo Tunnel
sudo argox -a     # 切换 Argo 服务开机自启
sudo argox -x     # 切换 Xray 服务开机自启
sudo argox -v     # 查看版本
sudo argox -u     # 彻底卸载
```

### B7. 安装后建议做的安全检查

**1）确认防火墙只放行 SSH**

Argo Tunnel 全程出站连接，不需要对外开放 443/8080 等端口。用 `ufw`
举例（其他发行版同理，换成 `firewall-cmd` 或云厂商安全组）：

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow OpenSSH
sudo ufw enable
sudo ufw status
```

如果你的云厂商本身有"安全组"面板，直接在面板上只放行 SSH 端口更省心，
效果和 ufw 一样。

**2）跑一遍脚本自带的配置校验**

```bash
sudo /etc/argox/xray run -test \
  -c /etc/argox/inbound.json \
  -c /etc/argox/outbound.json
```

**3）确认 XHTTP、PQC 都已经正确写入**

```bash
sudo /etc/argox/jq -r '
  .inbounds[]
  | select(.tag | endswith("xhttp-h1.1-cdn"))
  | [.streamSettings.network,
     .streamSettings.xhttpSettings.mode,
     .settings.decryption]
  | @tsv
' /etc/argox/inbound.json
```

预期输出前三列分别以 `xhttp`、`packet-up`、`mlkem768x25519plus.native.600s.`
开头；客户端 `encryption` 应以 `mlkem768x25519plus.native.1rtt.` 开头，
且 `tlsSettings` 中存在 `echConfigList`。

**4）确认服务在跑**

```bash
sudo systemctl status argo
sudo systemctl status xray
```

### B8. 客户端怎么用

- 装完直接复制脚本打印出的 `vless://...` 链接，导入 v2rayN / Shadowrocket /
  NekoBox / Mihomo 等支持 XHTTP + VLESS Encryption + ECH 的较新客户端。
- 如果客户端 GUI 还没完整支持解析链接里的 PQC/ECH 参数，直接用原生 Xray
  配置文件：`/etc/argox/subscribe/xray-xhttp-pqc-ech.json`，本地跑
  `xray run -c xray-xhttp-pqc-ech.json` 即可，默认 SOCKS 端口
  `127.0.0.1:10808`，HTTP 端口 `127.0.0.1:10809`。
- 想要订阅链接方式导入，脚本会在 `/etc/argox/subscribe/` 下生成多种格式，
  按 README 里"客户端输出"一节的方式访问。

### B9. 常见问题排查

| 现象 | 排查方向 |
|---|---|
| 安装时报"拒绝临时域名" | 你的 Tunnel 是 Quick Tunnel（`trycloudflare.com`），需要在 Cloudflare 后台建**固定** Tunnel |
| 安装时报凭据无效 | Token 复制时带了多余空格/换行；或者用了过期的 Token，去 Cloudflare 后台重新生成 |
| 连上但一直握手失败 | 先确认该 Zone 的 ECH 是否真的开启；再确认客户端 Xray-core 版本够新（要支持 XHTTP + VLESS Encryption + ECH） |
| 想换新域名 | `sudo argox -t` 重新绑定 Tunnel，或 `sudo argox -d` 改配置 |
| 想彻底重装 | 先 `sudo argox -u` 卸载干净，再回到 B4/B5 重新安装 |

---

如果你后面还想让我：
- 补一份 GitHub Actions 自动打 Release + 校验和的完整 workflow；
- 或者写一份"多节点批量部署"的脚本（用 SSH 循环跑多台 VPS）；

告诉我你打算用几台 VPS、用不用 Ansible/Terraform 这类工具，我再针对性地写。


## Shadowrocket 与 OpenWrt PassWall / PassWall2

### Shadowrocket

建议版本：**2.2.88+**（优先最新版）。脚本输出：

- `https://<ARGO_DOMAIN>/<UUID>/shadowrocket`：Shadowrocket base64 订阅。
- `https://<ARGO_DOMAIN>/<UUID>/shadowrocket-xhttp-uri.txt`：高级 XHTTP 单节点标准 VLESS URI。

高级 URI 包含 `encryption=<PQC>`、`ech=<ECH>`、`type=xhttp`、`mode`、`host`、`path` 与 `extra=<URL-encoded JSON>`。开启上下行分离时，`extra.downloadSettings` 内含独立下行 `address/port`、TLS SNI/ALPN 和 ECH；不显式设置 `stream-down`。

### PassWall / PassWall2

脚本输出：

- `https://<ARGO_DOMAIN>/<UUID>/passwall`：专用 base64 订阅。
- `https://<ARGO_DOMAIN>/<UUID>/passwall-xhttp-uri.txt`：单节点分享 URI。
- `https://<ARGO_DOMAIN>/<UUID>/passwall-xhttp-extra.json`：LuCI 手工兜底用 XHTTP Extra。

推荐在 PassWall 中使用 **Xray / VLESS / XHTTP** 节点。若“通过链接添加节点”导入后发现 `XHTTP Extra` 为空或没有下行设置，不要重新改服务端：先建立/编辑该节点，再把 `passwall-xhttp-extra.json` 的完整 JSON 粘贴进 **XHTTP Extra**。这是为了绕开部分版本 LuCI 对复杂 `extra=` 分享链接的解析差异。

2026-08-15 验证基线：PassWall 最新 release 为 26.8.12-1；PassWall2 最新 release 为 26.8.14-1，后者发布包包含 Xray-core 26.7.28。实际部署建议使用同代或更新版本。
