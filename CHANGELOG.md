## 2.3.7-shadowrocket-passwall-xhttp-split - 2026-08-15

- **Shadowrocket 专用 XHTTP 导出**：XHTTP 节点不再使用仅带 `Host` 的旧式 Shadowrocket URI；改为符合 Xray 分享链接提案的标准 VLESS URI，并携带 URL 编码后的完整 `extra` JSON。开启上下行分离时，`extra.downloadSettings` 包含独立下行地址/端口、`stream-down`、Host/SNI、ALPN 与 ECH；顶层同时保留 PQC `encryption` 和 `ech` 参数。新增 `shadowrocket-xhttp-uri.txt` 单节点直导文件。建议 Shadowrocket 2.2.88+。
- **PassWall / PassWall2 专用支持**：新增 `/passwall` base64 订阅、`passwall-xhttp-uri.txt` 单节点 URI，以及 `passwall-xhttp-extra.json` 手工兜底文件。PassWall 的 Xray XHTTP Extra 可承载 `downloadSettings`；考虑到部分 LuCI 分享链接入口对复杂 `extra=` 曾有解析差异，提供 JSON 兜底，避免导入成功却悄悄丢失上下行分离。
- Nginx `/auto` 增加 `PassWall` User-Agent 映射，可自动返回 PassWall 专用订阅。
- 回归测试新增 Shadowrocket / PassWall URI 二次解码验证：逐字段确认 PQC encryption、ECH、XHTTP `mode/path/host`、`extra.downloadSettings.address/port`、`stream-down` 和下行 ECH 均未在 URL/base64 编码过程中丢失。

# Changelog

## 2.3.6-xhttp-uplink-downlink-split - 2026-08-15

- **为固定域名 `VLESS + XHTTP + Argo + CDN + PQC + ECH` 组合新增 XHTTP 上下行分离开关。** 默认关闭，开启后上行继续使用现有 `SERVER` / `XHTTP_CDN_MODE`，下行通过 Xray `xhttpSettings.extra.downloadSettings` 建立独立 XHTTP 连接；可以给下行指定另一 Cloudflare 优选域名/IP 与端口，但 `Host` / TLS `serverName` 仍固定使用 `ARGO_DOMAIN`，因此上下行仍落到同一个 Tunnel Public Hostname，不需要第二套服务端 inbound、Nginx 路径或 Cloudflare Public Hostname。
- `argox -g` 引导安装新增 `ENABLE_XHTTP_SPLIT` 与条件式 `XHTTP_DOWNLOAD_SERVER[:PORT]` 输入；高级模板新增 `ENABLE_XHTTP_SPLIT`、`XHTTP_DOWNLOAD_SERVER`、`XHTTP_DOWNLOAD_PORT`。已安装系统的“修改配置”菜单也可直接开启/关闭并更换下行入口，切换只重新生成客户端/订阅，不新增服务端监听端口。
- 原生 Xray 输出 `/etc/argox/subscribe/xray-xhttp-pqc-ech.json` 在分离模式下生成 `extra.downloadSettings`，下行模式固定为 `stream-down`，并继承同一套 TLS 1.3、PQC curve 与 ECH 设置；Mihomo provider 同步输出 `xhttp-opts.download-settings`。标准 `vless://` URI 继续保留单链路兼容输出，因为通用 URI 参数无法完整表达这套非对称 downloadSettings 结构。
- 增加模式保护：Xray 不允许 `stream-one + downloadSettings`，因此用户开启上下行分离时若当前为 `stream-one`，脚本会明确提示并自动把上行切换为 `stream-up`；`packet-up` 可直接与独立 `stream-down` 搭配。
- 增加下行入口校验与 IPv6 规范化；Mihomo 的下行 `host/server/servername` 使用显式字符串引用，避免 IPv6/特殊值破坏 YAML。
- **补齐固定 Tunnel Token 的回源端口一致性保护。** Token 模式属于 Cloudflare 远程管理的 ingress，向导不再在 `8080` 被占用时悄悄改用 `8081/8082`；而是保持用户/默认的本地 Nginx origin 端口并在占用时直接报错，要求它与 Zero Trust Public Hostname 的 Service（默认 `http://localhost:8080`）严格一致，避免“cloudflared 正常但边缘 502”。JSON/local-config Tunnel 仍可安全选择空闲端口，因为 `tunnel.yml` 会同步写入实际端口。
- **启动校验改为 fail-fast。** systemd/OpenRC 启动 Xray 前必须先通过 Xray `run -test` 和 Nginx `-t`，不再用 `|| true` 吞掉 Nginx 配置/启动错误；生成原生 `xray-xhttp-pqc-ech.json` 后，如果目标 VPS 上存在已安装 Xray，也会再用同一 core 执行 `run -test`，PQC/ECH/XHTTP/downloadSettings 字段不兼容会当场停止而不是输出坏配置。
- `tests/test_release.sh` 新增 Xray JSON 与 Mihomo YAML 的上下行分离回归检查，包括 `stream-one` 自动保护、下行地址继承、ECH 继承、`download-settings` 结构、IPv6 规范化、Token 回源端口保护和启动前校验防回退验证。

## 2.3.5-menu-consistency-and-dead-compat-bridge-removed - 2026-08-14

- **修复 `guided_xhttp_install()`（`argox -g` / 主菜单选项 3）与主菜单判断
  "是否已安装"标准不一致的问题。** 主菜单（`menu_setting()`）是否显示
  安装前菜单还是管理菜单，看的是 `STATUS[]`——也就是 Argo/Xray/Nginx
  是否真的存在、注册过、在运行；而向导之前判断"已安装"只是简单测试
  `[ -d "$WORK_DIR" ]` 目录存不存在。如果上一次安装中途失败或被中断，
  `/etc/argox` 目录可能已经创建但服务从未真正装上——这时主菜单会正确显示
  "尚未安装"的安装前菜单，但选择向导时却会看到"检测到已有 ArgoX
  安装"而拒绝执行，两边说法自相矛盾，用户会被卡住。
  现在向导改成先看 `STATUS[]`：真的检测到已注册/运行中的服务才拒绝
  （行为不变）；如果只是遗留的空壳目录、什么服务都没有，会提示一句
  "检测到残留目录，自动清理后继续"，直接清掉再往下走，而不是硬拒绝。
- **删除了一段已经损坏、且会在全新安装上误触发的"旧版本兼容桥接"逻辑**
  （原脚本入口处、`check_root` 之前）。这段代码本身就有 bug：两条
  `warning` 提示打印完之后紧跟着一行裸的 `exit 2`，导致后面写好的
  "10 秒倒计时 / 按任意键跳过"逻辑和最终的报错提示全是永远执行不到的
  死代码。更麻烦的是它的触发条件是"`$WORK_DIR` 目录存在但 `custom`
  文件不存在"——而这次新增的向导安装流程在正常情况下就是不会主动写
  `custom` 文件的，所以哪怕是一次全新的、成功的部署，也会被这段逻辑
  误判成"检测到旧版本安装"，进而打印出`[Compatibility Mode] ...`
  这条提示后突然退出。这段桥接逻辑本来是为迁移某个更早期版本准备的
  过渡措施，已经不再需要，直接整段删除，脚本入口现在会正常走到
  `check_root → select_language → ... → menu_setting/guided_xhttp_install`。
- `tests/test_release.sh` 新增用例，模拟"目录存在但没有任何服务被检测到"
  的残留场景，验证向导会自动清理并正常走完整个安装流程，而不是报错拒绝。

## 2.3.4-guided-wizard-interactive-fields - 2026-08-14

- **`argox -g` / 主菜单选项 3（`固定域名 VLESS + XHTTP + PQC + ECH + Argo +
  CDN 傻瓜式安装`）现在真正逐项交互式确认关键参数**，而不是只问域名和
  Token、其余全部静默写死。新增的向导按顺序询问：
  `SERVER`（CDN 优选入口）、`ENABLE_VLESS_PQC`、`VLESS_PQC_STRICT`、
  `VLESS_PQC_DISABLE_0RTT`、`XHTTP_CDN_MODE`
  （`auto`/`stream-one`/`stream-up`/`packet-up`）、`ENABLE_ECH`、
  `ECH_STRICT`、`ECH_QUERY_DOMAIN`、`ECH_DNS`。每一项都会把当前默认值显示
  在 `[ ]` 里：直接回车采用默认值进入下一步，或手动输入新值后回车确认，
  和脚本里其它协议既有的交互习惯保持一致。全部问完后会打印一份配置汇总，
  再问一次"确认并开始安装？[Y/n]"，回车或输入 y 才真正执行安装。
- 开关类字段（`ENABLE_VLESS_PQC` 等）输入了无法识别的内容时会提示"输入
  无效"并回退为默认值，不会把打错的字当成"n"悄悄接受；`XHTTP_CDN_MODE`
  限定只能是四个合法模式之一，`ECH_QUERY_DOMAIN`/`ECH_DNS`
  分别复用脚本已有的域名格式校验和 DoH/DoU URL 格式校验，格式不对会重试
  最多 3 次，用尽后回退默认值，逻辑与脚本里已有的域名/Token 重试风格一致。
- 原来的 `apply_guided_xhttp_defaults()` 拆成了
  `apply_guided_xhttp_infra_defaults()`（UUID、路径、端口等用户不需要
  逐项确认的内部实现细节，继续保持固定默认值）+ 向导内联的逐项询问
  （面向用户关心的那组关键参数）。
- `tests/test_release.sh` 同步更新并新增用例：分别验证"全程回车走默认
  值"、"手动输入覆盖单个字段"、"非法输入回退默认值并给出提示"这三类路径，
  以及端到端跑一遍完整向导后各字段的最终取值。

## 2.3.3-oneliner-safe-self-install - 2026-08-13

- **修复 `create_shortcut()` 在 `bash <(wget -qO- .../argox.sh)` /
  `bash <(curl -Ls .../argox.sh)` 一键管道执行方式下的自安装损坏问题。**
  旧逻辑用 `cp "${BASH_SOURCE[0]}" ...` 把"自己"拷贝到
  `/etc/argox/argox.sh`；但通过进程替换（`bash <(...)`）运行时，
  `${BASH_SOURCE[0]}` 指向的是一次性匿名管道（如 `/dev/fd/63`），bash
  解释器本身也在从同一个管道往后读未执行的脚本内容。这种情况下再用 `cp`
  读一次同一个管道，会和 bash 自身的读取进度互相抢占字节：实测会拷贝出
  一份被截断/损坏的文件，且脚本本身会在该步骤后提前终止（后续尚未执行
  的行被 `cp` 提前"吃掉"）。
  现在改为：先用 `[ -f ... ]`（而不是原来的 `[ -r ... ]`）判断来源是不是
  一个真正的普通文件——本地 `git clone` 后直接执行、或已安装在
  `/etc/argox/argox.sh` 时是普通文件，走原来的 `cp` 逻辑；如果不是普通
  文件（管道/进程替换），改为向新增的 `ARGOX_RAW_URL` 常量重新发起一次
  独立的 `wget` 下载，并加上非空校验 + `bash -n` 语法校验，校验通过才
  覆盖安装，避免网络抖动或代理返回错误页面时把坏文件当正式版本装上。
  已用真实的进程替换环境验证：安装后的 `/etc/argox/argox.sh` 与源文件
  逐行一致，且脚本在该步骤后能继续正常往下执行，不再提前退出。
- 新增 `ARGOX_REPO_URL` / `ARGOX_RAW_URL` 两个常量，指向
  `https://github.com/hkzping999/Argo-reality-pqc` 与其 `main` 分支下的
  `argox.sh`，供 `create_shortcut()` 与今后的自更新逻辑复用。
- 语言字符串里遗留的旧仓库地址（`fscarmen/argox`、旧的
  `hkzping999/argox`）统一更新为 `hkzping999/Argo-reality-pqc`。

## 2.3.2-xhttp-tls13-curve-hardening - 2026-08-13

- CDN-facing XHTTP inbound/outbound (`xhttp-h1.1-cdn`, tag `i`, both the
  first-install heredoc and the post-install hot-add path) now sets a
  complete `xhttpSettings.extra` block: `xPaddingBytes` (ClientHello/request
  header length padding against traffic-size fingerprinting),
  `noSSEHeader`, `scMaxEachPostBytes`, `scMinPostsIntervalMs`, and
  `scMaxBufferedPosts`. Previously only `mode` and `path` were set.
- Native Xray client (`subscribe/xray-xhttp-pqc-ech.json`) mirrors the same
  `xhttpSettings.extra` block and now also declares `tlsSettings.minVersion`
  / `maxVersion` = `"1.3"` and `curvePreferences: ["X25519MLKEM768",
  "X25519"]` as an explicit, auditable statement of intent. Note: since
  `fingerprint: "chrome"` (uTLS) stays enabled by default, uTLS — not these
  fields — controls the actual ClientHello and already mimics modern
  Chrome's own hybrid PQC key share; the explicit fields take effect if a
  user later disables uTLS fingerprinting.
- Direct-TLS backup inbounds not behind Cloudflare (`xhttp-h3-direct` tag
  `j`, `trojan-direct` tag `k`) — where Xray terminates TLS itself — now
  pin `minVersion`/`maxVersion` to `1.3` and set
  `curvePreferences: ["X25519MLKEM768", "X25519"]`, enabling a real
  ML-KEM-768/X25519 hybrid post-quantum key exchange at the TLS layer for
  those two nodes (in addition to the existing VLESS Encryption PQC layer
  and the existing SHA-256 certificate pinning already present in their
  Mihomo/sing-box/URI outputs via `FP_SHA256`/`FP_BASE64`).
- Updated both the pretty-printed install-time JSON generator and the
  minified post-install hot-add JSON generator so freshly-added protocols
  match freshly-installed ones.

## 2.3.1-guided-fixed-domain-xhttp-pqc-ech - 2026-08-13

- Added `argox -g` and a fresh-install menu entry for guided fixed-domain
  VLESS + XHTTP + PQC + ECH + Argo + CDN deployment.
- The guided path asks only for the fixed Tunnel hostname and hidden Tunnel
  token/one-line JSON, then selects safe defaults and free local ports.
- Added strict fixed-domain and Tunnel credential validation to prevent
  temporary-tunnel fallback or accidental overwrite of an existing install.

## 2.3.0-vless-xhttp-pqc-ech-argo-cdn - 2026-08-13

- Added the complete fixed-tunnel VLESS + XHTTP + PQC + ECH + Argo + CDN path.
- Changed the CDN XHTTP default to `packet-up` for HTTP-middlebox compatibility.
- Added strict ECH settings with dynamic HTTPS-record lookup through Cloudflare DoH.
- Added the standard VLESS URI `ech` parameter.
- Added Mihomo `ech-opts` and removed `client-fingerprint` when ECH is active.
- Added a full native Xray client at `subscribe/xray-xhttp-pqc-ech.json`.
- Added `config-vless-xhttp-pqc-ech-argo-cdn.conf`.
- Fixed the installed `argox` launcher recursively invoking itself.
- Reject invalid named-tunnel credentials instead of silently using Quick Tunnel.
- Replaced third-party default CDN candidates with Cloudflare-owned hostnames.

## 2.2.3-pqc-strong-reality-domain-reality-pqc - 2026-07-06

- Reality Vision / Reality gRPC explicitly join the VLESS PQC strong path.
- Reality server inbound keeps `decryption=mlkem768x25519plus...600s...`.
- Reality client VLESS URI keeps `encryption=mlkem768x25519plus...1rtt...`.
- Clash / Mihomo Reality Vision and Reality gRPC output includes the VLESS `encryption` field.
- Keeps `REALITY_DOMAIN` as the client connection address and `TLS_SERVER` as the Reality SNI/camouflage domain.
- Keeps strong mode defaults: `ENABLE_VLESS_PQC='y'`, `VLESS_PQC_STRICT='y'`, `VLESS_PQC_DISABLE_0RTT='y'`.

## 2.2.2-pqc-strong-reality-domain - 2026-07-06

- Added Reality custom connection domain via `REALITY_DOMAIN`.
- Added install-time input, non-interactive config support, and `argox -d` modification support.
- Preserved manually selected Reality protocols in temporary Argo mode.
