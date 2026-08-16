# ArgoX Hotfix / Release Notes 2.3.7

### 2.3.7：Shadowrocket + PassWall / PassWall2

- Shadowrocket XHTTP 改为标准 VLESS URI + `extra=` 完整 JSON，支持携带上下行分离、PQC 与 ECH；建议 Shadowrocket 2.2.88+。
- 新增 PassWall/PassWall2 专用订阅、单节点 URI 和 `passwall-xhttp-extra.json` 手工兜底。
- `/auto` 增加 PassWall User-Agent 识别。
- 新增客户端导入 URI 的 URL 解码回归测试，防止复杂嵌套字段在编码阶段丢失。

## VLESS + XHTTP + PQC + ECH + Argo + CDN

### 2.3.6：XHTTP 上下行分离

- 新增 `ENABLE_XHTTP_SPLIT`，默认关闭；开启后上行仍使用 `SERVER`，下行通过 Xray `xhttpSettings.extra.downloadSettings` 使用独立 `XHTTP_DOWNLOAD_SERVER:XHTTP_DOWNLOAD_PORT`。
- 下行可以选择另一 Cloudflare 优选入口，但 `Host/SNI` 继续使用 `ARGO_DOMAIN`，因此不需要第二个 Tunnel Public Hostname 或第二套服务端 XHTTP inbound。
- 原生 Xray 配置输出 `downloadSettings` + `stream-down`；Mihomo provider 输出 `xhttp-opts.download-settings`。
- `stream-one` 与 `downloadSettings` 不兼容，脚本在开启分离时自动将上行切换为 `stream-up`；默认 `packet-up` 不受影响。
- `argox -g`、高级配置模板和安装后的“修改配置”菜单都可以开关上下行分离。

- 固定 Cloudflare Tunnel 的 XHTTP CDN 节点默认使用 `packet-up`，适配
  Cloudflare CDN、Argo Tunnel、Nginx HTTP/1.1 回源链路。
- VLESS Encryption 继续使用 `mlkem768x25519plus`；服务端 `decryption`
  使用 `600s`，客户端 `encryption` 强制使用 `1rtt`，默认拒绝 0-RTT。
- 新增 ECH 客户端运行时配置，默认动态查询
  `cloudflare-ech.com+https://1.1.1.1/dns-query`。
- 标准 VLESS URI 新增 `ech` 参数。
- Mihomo 输出新增 `ech-opts`，并在启用 ECH 时自动移除冲突的
  `client-fingerprint`。
- 新增 `/etc/argox/subscribe/xray-xhttp-pqc-ech.json` 原生 Xray 完整
  客户端配置。
- 新增专用非交互模板
  `config-vless-xhttp-pqc-ech-argo-cdn.conf`。
- 默认 CDN 候选仅保留 Cloudflare 自有域名。
- 新增固定域名傻瓜式安装：`sudo bash argox.sh -c -g`，也可在首次安装菜单选择
  第 3 项。仅输入固定 Tunnel 域名和隐藏的 Tunnel Token / 单行 JSON 后继续，
  自动设置 XHTTP、PQC、ECH、CDN、UUID、路径与可用本地端口。
- 引导安装仅接受固定 Tunnel Token / JSON，拒绝临时域名、占位凭据和覆盖已有
  ArgoX 安装；需要先在 Cloudflare 后台为该 Tunnel 配置同名 Public Hostname。

## 升级注意

推荐使用专用模板重新部署。若只替换现有安装的脚本，先备份
`/etc/argox`，再执行：

```bash
sudo install -m 700 argox.sh /etc/argox/argox.sh
sudo sh -c 'printf '\''#!/usr/bin/env bash\nexec bash /etc/argox/argox.sh "$@"\n'\'' > /etc/argox/ax.sh'
sudo chmod 700 /etc/argox/ax.sh
sudo ln -sfn /etc/argox/ax.sh /usr/bin/argox
sudo argox -v
sudo argox -r
sudo argox -n
```

若旧的 XHTTP inbound 仍为 `mode=auto`，可删除再重新添加
`xhttp-h1.1-cdn`，或重新安装以应用 `packet-up`。Cloudflare 区域必须启用
ECH；临时 `trycloudflare.com` 隧道仍不支持本组合。

本版本还修复了旧版 `/usr/bin/argox` 快捷入口递归调用自身的问题，并在固定
隧道凭据无效时直接停止安装，不再静默降级为 Quick Tunnel。