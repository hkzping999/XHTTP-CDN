#!/usr/bin/env bash

# 当前脚本版本号
VERSION='2.3.7-r2-connectivity-fix-visible-token (2026.08.15)'

# Strong edition: protect generated credentials and disable third-party GitHub proxy by default.
umask 077
# Safe edition: third-party GitHub proxy disabled to reduce supply-chain risk
GITHUB_PROXY=()

# 协议列表和对应的节点标签，顺序必须一一对应
PROTOCOL_LIST=("VLESS + Reality Vision" "Hysteria2" "VLESS + Reality gRPC" "VLESS + WS" "VMess + WS" "Trojan + WS" "Shadowsocks + WS" "VLESS + XHTTP CDN (H2/H1 fallback)" "VLESS + XHTTP HTTP/3 Direct" "Trojan Direct" "Shadowsocks 2022 Direct")
NODE_TAG=(     "reality-vision"         "hysteria2" "reality-grpc"         "vless-ws"   "vmess-ws"   "trojan-ws"   "ss-ws"            "xhttp-h1.1-cdn"             "xhttp-h3-direct"             "trojan-direct" "ss2022-direct")
# 稳定安全默认协议：仅启用 Argo/trycloudflare 最稳定的 WS + Nginx 链路。
# 直连类协议（Reality/Hysteria2/XHTTP Direct/Trojan Direct/SS2022）仍可手动选择，但不再默认全选，避免 Xray 因新协议字段兼容性失败。
STABLE_DEFAULT_PROTOCOLS="e"

# 端口范围限制
MIN_PORT=100
MAX_PORT=65520
MIN_HOPPING_PORT=10000
MAX_HOPPING_PORT=65535

# 各变量默认值
WS_PATH_DEFAULT='argox'
WORK_DIR='/etc/argox'
TEMP_DIR='/tmp/argox'
CUSTOM_FILE="$WORK_DIR/custom"
FIREWALL_STATE_DIR="${WORK_DIR}/firewall"
SERVICE_FIREWALL_STATE_FILE="${FIREWALL_STATE_DIR}/service_ports.list"

# 本项目仓库地址与 raw 脚本地址。当脚本通过
#   bash <(curl -Ls https://raw.githubusercontent.com/.../main/argox.sh)
# 或 wget 管道方式运行时，${BASH_SOURCE[0]} 指向一次性的匿名管道
# （如 /dev/fd/63），不是可重复读取的普通文件；create_shortcut() 需要用
# 这个地址重新拉取一份完整脚本落盘，而不是尝试从已经被读过一部分的管道
# 里 cp 自己（那样会读到不完整/被截断的内容）。
ARGOX_REPO_URL='https://github.com/hkzping999/XHTTP-CDN'
ARGOX_RAW_URL='https://raw.githubusercontent.com/hkzping999/XHTTP-CDN/main/argox.sh'
TLS_SERVER='addons.mozilla.org'
# Reality 客户端连接地址：留空则使用 SERVER_IP；不要与 Reality 伪装 SNI/TLS_SERVER 混用。
REALITY_DOMAIN=${REALITY_DOMAIN:-''}
START_PORT_DEFAULT='30000'  # WS/XHTTP 内部端口起始值，各协议在此基础上顺数
NGINX_PORT_DEFAULT='8080'   # Nginx 默认端口，可交互修改
# Cloudflare-owned anycast hostnames only; custom domains/IPs are still accepted.
CDN_DOMAIN=("www.cloudflare.com" "speed.cloudflare.com" "one.one.one.one" "developers.cloudflare.com")
SUBSCRIBE_TEMPLATE="LOCAL_EMBEDDED"
DEFAULT_XRAY_VERSION='latest-pqc-required'

# 后量子加密 / PQC defaults
# y: 所有 VLESS 家族协议均使用 Xray VLESS Encryption（mlkem768x25519plus = ML-KEM-768 + X25519 hybrid）
#    包括 Reality Vision / Reality gRPC：REALITY 负责伪装与抗探测，VLESS Encryption 负责 PQC 混合加密。
# n: 回退到传统 VLESS encryption=none / decryption=none
ENABLE_VLESS_PQC=${ENABLE_VLESS_PQC:-'y'}
# y: 如果当前 Xray 不支持 vlessenc，则中止，避免误以为已启用 PQC
# n: 失败时回退到传统 VLESS
VLESS_PQC_STRICT=${VLESS_PQC_STRICT:-'y'}
# 可预置成对参数；留空时安装时自动执行 xray vlessenc 生成
VLESS_PQC_DECRYPTION=${VLESS_PQC_DECRYPTION:-''}
VLESS_PQC_ENCRYPTION=${VLESS_PQC_ENCRYPTION:-''}
# Strong mode: require the expected hybrid PQC prefix and avoid 0-RTT by default.
VLESS_PQC_REQUIRE_PREFIX=${VLESS_PQC_REQUIRE_PREFIX:-'mlkem768x25519plus'}
VLESS_PQC_DISABLE_0RTT=${VLESS_PQC_DISABLE_0RTT:-'y'}
VLESS_PQC_RESUME=${VLESS_PQC_RESUME:-'600s'}
# CDN XHTTP uses packet-up by default because it survives HTTP middleboxes and
# does not depend on Cloudflare gRPC/streaming-upload switches.
XHTTP_CDN_MODE=${XHTTP_CDN_MODE:-'packet-up'}
# Optional XHTTP asymmetric transport. When enabled, upload uses the normal CDN
# entry while downloadSettings opens an independent XHTTP connection.
ENABLE_XHTTP_SPLIT=${ENABLE_XHTTP_SPLIT:-'n'}
XHTTP_DOWNLOAD_SERVER=${XHTTP_DOWNLOAD_SERVER:-''}
XHTTP_DOWNLOAD_PORT=${XHTTP_DOWNLOAD_PORT:-''}

# Encrypted Client Hello / ECH (client side; Cloudflare terminates edge TLS).
# A fixed ECH_CONFIG may be supplied. Otherwise Xray dynamically resolves the
# HTTPS record of ECH_QUERY_DOMAIN through ECH_DNS and follows its TTL.
ENABLE_ECH=${ENABLE_ECH:-'y'}
ECH_STRICT=${ECH_STRICT:-'y'}
ECH_CONFIG=${ECH_CONFIG:-''}
ECH_QUERY_DOMAIN=${ECH_QUERY_DOMAIN:-'cloudflare-ech.com'}
ECH_DNS=${ECH_DNS:-'https://doh.pub/dns-query'}
# Set by `argox -g` or the fresh-install menu. It intentionally collects only
# the fixed Tunnel hostname and its credentials, then uses safe defaults.
GUIDED_XHTTP_INSTALL=${GUIDED_XHTTP_INSTALL:-''}
# n: default only VLESS-family protocols are allowed; set y to keep VMess/Trojan/SS compatibility protocols.
ALLOW_LEGACY_PROTOCOLS=${ALLOW_LEGACY_PROTOCOLS:-'n'}

export DEBIAN_FRONTEND=noninteractive

cleanup_temp() {
  rm -rf "$TEMP_DIR"
}

trap cleanup_temp EXIT
trap 'cleanup_temp; echo -e '\''\n'\''; exit 1' INT QUIT TERM

mkdir -p "$TEMP_DIR"

E[0]="Language:\n 1. English (default) \n 2. 简体中文"
C[0]="${E[0]}"
E[1]="VLESS + XHTTP packet-up + ML-KEM-768/X25519 PQC + ECH + Argo Tunnel + Cloudflare CDN; native Xray and Mihomo client outputs"
C[1]="新增 VLESS + XHTTP packet-up + ML-KEM-768/X25519 PQC + ECH + Argo Tunnel + Cloudflare CDN 一体化链路，并输出原生 Xray 与 Mihomo 客户端配置"
E[2]="Project to create Argo tunnels and Xray specifically for VPS, detailed:[https://github.com/hkzping999/Argo-reality-pqc]\n Features:\n\t • Allows the creation of Argo tunnels via Token, Json and ad hoc methods. Safe edition: do not obtain json via third-party websites; use Cloudflare official dashboard only.\n\t • Extremely fast installation method, saving users time.\n\t • Support system: Ubuntu, Debian, CentOS, Alpine and Arch Linux 3.\n\t • Support architecture: AMD,ARM and s390x\n"
C[2]="本项目专为 VPS 添加 Argo 隧道及 Xray,详细说明: [https://github.com/hkzping999/Argo-reality-pqc]\n 脚本特点:\n\t • 允许通过 Token, Json 及 临时方式来创建 Argo 隧道,安全版不建议通过第三方网站获取 json，请仅使用 Cloudflare 官方后台生成 Token/Json\n\t • 极速安装方式,大大节省用户时间\n\t • 智能判断操作系统: Ubuntu 、Debian 、CentOS 、Alpine 和 Arch Linux,请务必选择 LTS 系统\n\t • 支持硬件结构类型: AMD 和 ARM\n"
E[3]="Input errors up to 5 times.The script is aborted."
C[3]="输入错误达5次,脚本退出"
E[4]="UUID should be 36 characters, please re-enter (\${a} times remaining)"
C[4]="UUID 应为36位字符,请重新输入 (剩余\${a}次)"
E[5]="The script supports Debian, Ubuntu, CentOS, Alpine, Armbian or Arch systems only. Feedback: [https://github.com/hkzping999/Argo-reality-pqc/issues]"
C[5]="本脚本只支持 Debian、Ubuntu、CentOS、Alpine、Armbian 或 Arch 系统，问题反馈:[https://github.com/hkzping999/Argo-reality-pqc/issues]"
E[6]="Port Hopping range (current: \${_val}) [leave blank to disable]"
C[6]="端口跳跃范围 (当前：\${_val}) [留空则禁用]"
E[7]="Install dependence-list:"
C[7]="安装依赖列表:"
E[8]="All dependencies already exist and do not need to be installed additionally."
C[8]="所有依赖已存在，不需要额外安装"
E[9]="To upgrade, press [y]. No upgrade by default:"
C[9]="升级请按 [y]，默认不升级:"
E[10]="\${TOTAL_STEPS:+(\${STEP_NUM}/\${TOTAL_STEPS}) }Please enter Argo Domain (Default is temporary domain if left blank):"
C[10]="\${TOTAL_STEPS:+(\${STEP_NUM}/\${TOTAL_STEPS}) }请输入 Argo 域名 (如果没有，可以跳过以使用 Argo 临时域名):"
E[11]="Please enter Argo Token, Argo Json or Cloudflare API\n\n [*] Token: Visit https://dash.cloudflare.com/ , Zero Trust > Networks > Connectors > Create a tunnel > Select Cloudflared\n\n [*] Json: Safe edition recommends generating it only from the official Cloudflare dashboard\n\n [*] Cloudflare API: Visit https://dash.cloudflare.com/profile/api-tokens > Create Token > Create Custom Token > Add the following permissions:\n - Account > Cloudflare One Connectors: cloudflared > Edit\n - Zone > DNS > Edit\n\n - Account Resources: Include > Required Account\n - Zone Resources: Include > Specific zone > Argo Root Domain"
C[11]="请输入 Argo Token, Argo Json 或者 Cloudflare API\n\n [*] Token: 访问 https://dash.cloudflare.com/ ，Zero Trust > 网络 > 连接器 > 创建隧道 > 选择 Cloudflared\n\n [*] Json: 安全版建议仅从 Cloudflare 官方后台生成，不使用第三方网站\n\n [*] Cloudflare API: 访问 https://dash.cloudflare.com/profile/api-tokens > 创建令牌 > 创建自定义令牌 > 添加以下权限:\n - 帐户 > Cloudflare One连接器: Cloudflared > 编辑\n - 区域 > DNS > 编辑\n\n - 帐户资源: 包括 > 所需账户\n - 区域资源: 包括 > 特定区域 > 所需域名"
E[12]="(\${STEP_NUM}/\${TOTAL_STEPS}) Please enter Xray UUID (Default is \${UUID_DEFAULT}):"
C[12]="(\${STEP_NUM}/\${TOTAL_STEPS}) 请输入 Xray UUID (默认为 \${UUID_DEFAULT}):"
E[13]="(\${STEP_NUM}/\${TOTAL_STEPS}) Please enter Xray WS Path (Default is \${WS_PATH_DEFAULT}):"
C[13]="(\${STEP_NUM}/\${TOTAL_STEPS}) 请输入 Xray WS 路径 (默认为 \${WS_PATH_DEFAULT}):"
E[14]="Xray WS Path only allow uppercase and lowercase letters, numeric characters, hyphens, underscores, dots and @, please re-enter (\${a} times remaining):"
C[14]="Xray WS 路径只允许英文大小写、数字、连字符、下划线、点和@字符，请重新输入 (剩余\${a}次):"
E[15]="ArgoX script has not been installed yet."
C[15]="ArgoX 脚本还没有安装"
E[16]="ArgoX is completely uninstalled."
C[16]="ArgoX 已彻底卸载"
E[17]="Version"
C[17]="脚本版本"
E[18]="New features"
C[18]="功能新增"
E[19]="System infomation"
C[19]="系统信息"
E[20]="Operating System"
C[20]="当前操作系统"
E[21]="Kernel"
C[21]="内核"
E[22]="Architecture"
C[22]="处理器架构"
E[23]="Virtualization"
C[23]="虚拟化"
E[24]="Choose:"
C[24]="请选择:"
E[25]="Curren architecture \$(uname -m) is not supported. Feedback: [https://github.com/hkzping999/argox/issues]"
C[25]="当前架构 \$(uname -m) 暂不支持,问题反馈:[https://github.com/hkzping999/ArgoX]"
E[26]="Not install"
C[26]="未安装"
E[27]="close"
C[27]="关闭"
E[28]="open"
C[28]="开启"
E[29]="View links (argox -n)"
C[29]="查看节点信息 (argox -n)"
E[30]="Change the Argo tunnel (argox -t)"
C[30]="更换 Argo 隧道 (argox -t)"
E[31]="Sync Argo and Xray to the latest version (argox -v)"
C[31]="同步 Argo 和 Xray 至最新版本 (argox -v)"
E[32]="Upgrade kernel, turn on BBR, change Linux system (argox -b)"
C[32]="升级内核、安装BBR、DD脚本 (argox -b)"
E[33]="Uninstall (argox -u)"
C[33]="卸载 (argox -u)"
E[34]="Install ArgoX script (argo + xray)"
C[34]="安装 ArgoX 脚本 (argo + xray)"
E[35]="Exit"
C[35]="退出"
E[36]="Please enter the correct number"
C[36]="请输入正确数字"
E[37]="successful"
C[37]="成功"
E[38]="failed"
C[38]="失败"
E[39]="ArgoX is not installed."
C[39]="ArgoX 未安装"
E[40]="Argo tunnel is: \${ARGO_TYPE}\\\n The domain is: \${ARGO_DOMAIN}"
C[40]="Argo 隧道类型为: \${ARGO_TYPE}\\\n 域名是: \${ARGO_DOMAIN}"
E[41]="Argo tunnel type:\n 1. Try (VLESS + XHTTP not supported)\n 2. Token or Json"
C[41]="Argo 隧道类型:\n 1. Try（不支持 VLESS + XHTTP）\n 2. Token 或者 Json"
E[42]="\${TOTAL_STEPS:+(\${STEP_NUM}/\${TOTAL_STEPS}) }Please select or enter the preferred address (domain / IPv4 / [IPv6], optional :port), the default is \${CDN_DOMAIN[0]}:"
C[42]="\${TOTAL_STEPS:+(\${STEP_NUM}/\${TOTAL_STEPS}) }请选择或者填入优选地址（域名 / IPv4 / [IPv6]，可选 :端口），默认为 \${CDN_DOMAIN[0]}:"
E[43]="\${APP} local version: \${LOCAL}.\\\t The newest version: \${ONLINE}"
C[43]="\${APP} 本地版本: \${LOCAL}.\\\t 最新版本: \${ONLINE}"
E[44]="No upgrade required."
C[44]="不需要升级"
E[45]="Argo authentication message does not match the rules, neither Token nor Json, script exits. Feedback:[ttps://github.com/hkzping999//argox/issues]"
C[45]="Argo 认证信息不符合规则，既不是 Token，也是不是 Json，脚本退出，问题反馈:[https://github.com/hkzping999/ArgoX/issues]"
E[46]="Connect"
C[46]="连接"
E[47]="The script must be run as root, you can enter sudo -i and then download and run again. Feedback:[https://github.com/hkzping999/ArgoX/issues]"
C[47]="必须以root方式运行脚本，可以输入 sudo -i 后重新下载运行，问题反馈:[https://github.com/hkzping999/ArgoX/issues]"
E[48]="Downloading the latest version \${APP} failed, script exits. Feedback:[https://github.com/hkzping999/ArgoX/issues]"
C[48]="下载最新版本 \${APP} 失败，脚本退出，问题反馈:[https://github.com/hkzping999/ArgoX/issues]"
E[49]="(\${STEP_NUM}/\${TOTAL_STEPS}) Please enter the node name. (Default is \${NODE_NAME_DEFAULT}):"
C[49]="(\${STEP_NUM}/\${TOTAL_STEPS}) 请输入节点名称 (默认为 \${NODE_NAME_DEFAULT}):"
E[50]="\${APP[*]} services are not enabled, node information cannot be output. Press [y] if you want to open."
C[50]="\${APP[*]} 服务未开启，不能输出节点信息。如需打开请按 [y]: "
E[51]="Install Sing-box multi-protocol scripts [https://github.com/hkzping999/sing-box]"
C[51]="安装 Sing-box 协议全家桶脚本 [hhttps://github.com/hkzping999/sing-box]"
E[52]="Memory Usage"
C[52]="内存占用"
E[53]="The xray service is detected to be installed. Script exits."
C[53]="检测到已安装 xray 服务，脚本退出!"
E[54]="Warp / warp-go was detected to be running. Please enter the correct server IP:"
C[54]="检测到 warp / warp-go 正在运行，请输入确认的服务器 IP:"
E[55]="The script runs today: \${TODAY}. Total: \${TOTAL}"
C[55]="脚本当天运行次数: \${TODAY}，累计运行次数: \${TOTAL}"
E[56]="\${TOTAL_STEPS:+(\${STEP_NUM}/\${TOTAL_STEPS}) }Please enter the starting port for all protocols. Must be \${MIN_PORT}-\${MAX_PORT}, need \${NUM} consecutive free ports (Default: \${START_PORT_DEFAULT}):"
C[56]="\${TOTAL_STEPS:+(\${STEP_NUM}/\${TOTAL_STEPS}) }请输入所有协议的起始端口，必须是 \${MIN_PORT}-\${MAX_PORT}，需要 \${NUM} 个连续空闲端口(默认为 \${START_PORT_DEFAULT}):"
E[57]="Install sba scripts (argo + sing-box) [https://github.com/hkzping999/sba]"
C[57]="安装 sba 脚本 (argo + sing-box) [https://github.com/hkzping999/sba]"
E[58]="No server ip, script exits. Feedback:[https://github.com/hkzping999/sing-box/issues]"
C[58]="没有 server ip，脚本退出，问题反馈:[https://github.com/hkzping999/sing-box/issues]"
E[59]="(\${STEP_NUM}/\${TOTAL_STEPS}) Please enter VPS IP (Default is: \${SERVER_IP_DEFAULT}):"
C[59]="(\${STEP_NUM}/\${TOTAL_STEPS}) 请输入 VPS IP (默认为: \${SERVER_IP_DEFAULT}):"
E[60]="Please enter new value (press Enter to skip):"
C[60]="请输入新值 (回车跳过):"
E[61]="Port already in use:"
C[61]="端口已被占用:"
E[62]="Create shortcut [ argox ] successfully."
C[62]="创建快捷 [ argox ] 指令成功!"
E[63]="The full template can be found at:\n https://t.me/ztvps/67\n https://github.com/chika0801/sing-box-examples/tree/main/Tun"
C[63]="完整模板可参照:\n https://t.me/ztvps/67\n https://github.com/chika0801/sing-box-examples/tree/main/Tun"
E[64]="subscribe"
C[64]="订阅"
E[65]="To uninstall Nginx press [y], it is not uninstalled by default:"
C[65]="如要卸载 Nginx 请按 [y]，默认不卸载:"
E[66]="Adaptive Clash / V2rayN / NekoBox / ShadowRocket / SFI / SFA / SFM Clients"
C[66]="自适应 Clash / V2rayN / NekoBox / ShadowRocket / SFI / SFA / SFM 客户端"
E[67]="not set"
C[67]="未设置"
E[68]="(\${STEP_NUM}/\${TOTAL_STEPS}) Nginx is used for subscription, QR code output, and WS/XHTTP protocol proxying. Please enter the port number, must be \${MIN_PORT}-\${MAX_PORT} (Default: \${NGINX_PORT_DEFAULT}):"
C[68]="(\${STEP_NUM}/\${TOTAL_STEPS}) Nginx 用于订阅输出、二维码生成以及 WS/XHTTP 协议的反代分流，请输入端口号，必须是 \${MIN_PORT}-\${MAX_PORT}(默认为 \${NGINX_PORT_DEFAULT}):"
E[69]="Set SElinux: enforcing --> disabled"
C[69]="设置 SElinux: enforcing --> disabled"
E[70]="ArgoX is not installed and cannot change the CDN."
C[70]="ArgoX 未安装，不能更换 CDN"
E[71]="Current CDN is: \${CDN_NOW}"
C[71]="当前 CDN 为: \${CDN_NOW}"
E[72]="Please select or enter a new preferred address (domain / IPv4 / [IPv6], optional :port; press Enter to keep the current one):"
C[72]="请选择或输入新的优选地址（域名 / IPv4 / [IPv6]，可选 :端口；回车保持当前值）:"
E[73]="CDN has been changed from \${CDN_NOW} to \${CDN_NEW}"
C[73]="CDN 已从 \${CDN_NOW} 更改为 \${CDN_NEW}"
E[74]="Unable to access api.github.com. This may be due to IP restrictions (HTTP/1.1 403 Rate Limit Exceeded). Please try again later"
C[74]="无法访问 api.github.com，可能是由于 IP 限制导致的（HTTP/1.1 403 Rate Limit Exceeded），请稍后重试"
E[75]="When using shadows-ws in Nekobox, set UoT to 2 to enable UDP over TCP."
C[75]="在 Nekobox 中使用 shadows-ws 时，将 UoT 设为 2，即可启用 UDP over TCP 功能"
E[76]="Change preferred address / Reality connection domain / SNI / node info (argox -d)"
C[76]="更换优选地址 / Reality 连接域名 / SNI / 节点信息 (argox -d)"
E[77]="Quick install mode (argox -k)"
C[77]="极速安装模式 (argox -l)"
E[78]="Using Cloudflare API to create Tunnel and handle DNS config..."
C[78]="使用 Cloudflare API 创建 Tunnel 和处理 DNS 配置..."
E[79]="Found existing tunnel with the same name. Tunnel ID: \$EXISTING_TUNNEL_ID. Status: \$EXISTING_TUNNEL_STATUS. Overwrite? [y/N] (default y):"
C[79]="发现同名隧道已创建，隧道 ID: \$EXISTING_TUNNEL_ID，状态: \$EXISTING_TUNNEL_STATUS。是否覆盖? [y/N] (默认为 y):"
E[80]="Continue with quick fast tunnel"
C[80]="使用临时隧道继续"
E[81]="Invalid access token. Please roll at https://dash.cloudflare.com/profile/api-tokens to re-generate."
C[81]="Token 访问令牌无效。请在 https://dash.cloudflare.com/profile/api-tokens 轮转，以重新获取"
E[82]="Network request URL structure is wrong. Missing Zone ID"
C[82]="网络请求地址（URL）结构不对，缺少 Zone ID"
E[83]="Token zone resource failed. The tunnel root domain and the authorized domain of the token are inconsistent. Please go to https://dash.cloudflare.com/profile/api-tokens to re-authorize."
C[83]="Token 区域资源获取失败，隧道的根域名和 Token 授权的域名不一致，请到 https://dash.cloudflare.com/profile/api-tokens 检查"
E[84]="API execution failed. Response: \$RESPONSE"
C[84]="执行 API 失败，返回: \$RESPONSE"
E[85]="API does not have enough permissions. Please check at https://dash.cloudflare.com/profile/api-tokens\n\n [*] Token: Visit https://dash.cloudflare.com/ , Zero Trust > Networks > Connectors > Create a tunnel > Select Cloudflared\n\n [*] Json: Safe edition recommends generating it only from the official Cloudflare dashboard\n\n [*] Cloudflare API: Visit https://dash.cloudflare.com/profile/api-tokens > Create Token > Create Custom Token > Add the following permissions:\n - Account > Cloudflare One Connectors: cloudflared > Edit\n - Zone > DNS > Edit\n\n - Account Resources: Include > Required Account\n - Zone Resources: Include > Specific zone > Argo Root Domain"
C[85]="API 没有足够权限，请在 https://dash.cloudflare.com/profile/api-tokens 检查 Token 权限配置\n\n [*] Token: 访问 https://dash.cloudflare.com/ ，Zero Trust > 网络 > 连接器 > 创建隧道 > 选择 Cloudflared\n\n [*] Json: 安全版建议仅从 Cloudflare 官方后台生成，不使用第三方网站\n\n [*] Cloudflare API: 访问 https://dash.cloudflare.com/profile/api-tokens > 创建令牌 > 创建自定义令牌 > 添加以下权限:\n - 帐户 > Cloudflare One连接器: Cloudflared > 编辑\n - 区域 > DNS > 编辑\n\n - 帐户资源: 包括 > 所需账户\n - 区域资源: 包括 > 特定区域 > 所需域名"
E[86]="Please enter [Token, Json, API] value:"
C[86]="请输入 [Token, Json, API] 的值:"
E[87]="(\${STEP_NUM}/\${TOTAL_STEPS:-?}) Select protocols to install (e.g. bdf). a = all (default):"
C[87]="(\${STEP_NUM}/\${TOTAL_STEPS:-?}) 选择要安装的协议（如 bdf），a = 全部（默认）:"
E[88]="Installed protocols."
C[88]="已安装的协议"
E[89]="Please select protocols to remove (multiple allowed, Enter to skip):"
C[89]="请选择需要删除的协议（可多选，回车跳过）:"
E[90]="Uninstalled protocols."
C[90]="未安装的协议"
E[91]="Please select protocols to add (multiple allowed, Enter to skip):"
C[91]="请选择需要增加的协议（可多选，回车跳过）:"
E[92]="Confirm all protocols for reloading."
C[92]="确认重装的所有协议"
E[93]="Press [n] if there is an error, other keys to continue:"
C[93]="如有错误请按 [n]，其他键继续:"
E[94]="No protocols left. Use [ argox -u ] to uninstall all."
C[94]="没有协议剩下，如确定请重新执行 [ argox -u ] 卸载所有"
E[95]="Add / Remove protocols (argox -r)"
C[95]="增加 / 删除协议 (argox -r)"
E[96]="Keep protocols"
C[96]="保留协议"
E[97]="Add protocols"
C[97]="新增协议"
E[98]="\${TOTAL_STEPS:+(\${STEP_NUM}/\${TOTAL_STEPS}) }Please enter the Reality privateKey, skip to generate randomly (Default is random):"
C[98]="\${TOTAL_STEPS:+(\${STEP_NUM}/\${TOTAL_STEPS}) }请输入 Reality 的密钥(privateKey)，跳过则随机生成 (默认为随机生成):"
E[99]="Invalid Reality privateKey, generating randomly..."
C[99]="Reality 私钥无效，随机生成中..."
E[100]=" a. all (default)"
C[100]=" a. 全部（默认）"
E[101]="${PROTOCOL_LIST[7]} (Temporary tunnel NOT supported)"
C[101]="${PROTOCOL_LIST[7]}（临时隧道不支持）"
E[102]="Cannot get quicktunnel domain."
C[102]="获取临时隧道域名失败"
E[103]="No change was made."
C[103]="未做任何修改"
E[104]="Port Hopping: ISPs sometimes block or throttle persistent UDP on a single port. Port hopping works around this by forwarding a range of ports to the Hysteria2 listen port via iptables NAT.\n Tip1: Recommended ~1000 ports, min: \$MIN_HOPPING_PORT, max: \$MAX_HOPPING_PORT.\n Tip2: NAT machines have very few open ports (20-30); use with caution.\n Leave blank to disable."
C[104]="端口跳跃介绍：运营商有时会阻断或限速单个 UDP 端口的持续连接，端口跳跃通过 iptables NAT 将端口段转发到 Hysteria2 监听端口来解决这个问题。\n Tip1: 推荐约 1000 个端口，最小值：\$MIN_HOPPING_PORT，最大值：\$MAX_HOPPING_PORT。\n Tip2: NAT 机器可开放端口很少（20-30 个），请谨慎使用。\n 留空则禁用该功能。"
E[105]="\${TOTAL_STEPS:+(\${STEP_NUM}/\${TOTAL_STEPS}) }Enter port range for Hysteria2 port hopping (e.g. 50000:51000). Leave blank to disable:"
C[105]="\${TOTAL_STEPS:+(\${STEP_NUM}/\${TOTAL_STEPS}) }请输入 Hysteria2 端口跳跃范围（如 50000:51000），留空禁用:"
E[106]="Please select what to modify:"
C[106]="请选择修改项目:"
E[107]="Preferred address (current: \${_val})"
C[107]="优选地址 (当前：\${_val})"
E[108]="SNI / TLS domain (current: \${_val}) [Reality & Hysteria2]"
C[108]="SNI / TLS 域名 (当前：\${_val}) [Reality 和 Hysteria2 共用]"
E[109]="Node name (current: \${_val})"
C[109]="节点名称 (当前：\${_val})"
E[110]="UUID / Password (current: \${_val})"
C[110]="UUID / 密码 (当前：\${_val})"
E[111]="Server IP (current: \${_val})"
C[111]="服务器 IP (当前：\${_val})"
E[112]="Invalid IP address format"
C[112]="IP 地址格式错误"
E[113]="(VLESS + XHTTP not supported)"
C[113]="（不支持 VLESS + XHTTP）"
E[114]="Port range out of bounds. Start must be \${MIN_HOPPING_PORT}–\${MAX_HOPPING_PORT}, end must be \${MIN_HOPPING_PORT}–\${MAX_HOPPING_PORT}, and start < end."
C[114]="端口范围超界。起始端口必须在 \${MIN_HOPPING_PORT}–\${MAX_HOPPING_PORT} 之间，结束端口同理，且起始 < 结束。"
E[115]="UFW was detected. Firewall rules will be managed by UFW, and iptables / netfilter-persistent will not be installed."
C[115]="检测到 UFW。防火墙规则将由 UFW 管理，不再安装 iptables / netfilter-persistent"
E[116]="UFW is not active. Firewall rules were written, but you should manually enable UFW to make sure the policy is applied."
C[116]="UFW 未处于激活状态。防火墙规则已写入，但建议手动启用 UFW 以确保策略生效"
E[117]="Failed to update UFW firewall rules. Please check UFW configuration files manually."
C[117]="更新 UFW 防火墙规则失败，请手动检查 UFW 配置文件"
E[118]="Invalid preferred address format. Please enter a domain, IPv4, or [IPv6], optionally with :port."
C[118]="优选地址格式错误。请输入域名、IPv4 或 [IPv6]，并可选附带 :端口。"
E[119]="xray listen ports  (current: \${_val})"
C[119]="xray 监听端口  (当前：\${_val})"
E[120]="Hysteria2 bandwidth  (current: up \${HY2_UP_NOW} Mbps, down \${HY2_DOWN_NOW} Mbps)"
C[120]="Hysteria2 带宽  (当前: 上行 \${HY2_UP_NOW} Mbps, 下行 \${HY2_DOWN_NOW} Mbps)"
E[121]="Please enter Hysteria2 client upload speed in Mbps (e.g. 200):"
C[121]="请输入 Hysteria2 客户端上行速率 Mbps（纯数字，如 200）:"
E[122]="Please enter Hysteria2 client download speed in Mbps (e.g. 1000):"
C[122]="请输入 Hysteria2 客户端下行速率 Mbps（纯数字，如 1000）:"
E[123]="Invalid input, please enter a positive integer."
C[123]="输入无效，请输入正整数。"
E[124]="The order of the selected protocols and ports is as follows:"
C[124]="选择的协议及端口次序如下:"
E[125]="Reality connection domain (current: \${_val}) [leave blank to use VPS IP]"
C[125]="Reality 连接域名 / 自定义域名 (当前：\${_val}) [留空则使用 VPS IP]"
E[126]="\${TOTAL_STEPS:+(\${STEP_NUM}/\${TOTAL_STEPS}) }Please enter Reality connection domain, IPv4 or IPv6. Leave blank to use VPS IP:"
C[126]="\${TOTAL_STEPS:+(\${STEP_NUM}/\${TOTAL_STEPS}) }请输入 Reality 连接域名、IPv4 或 IPv6。留空则使用 VPS IP:"
E[127]="Invalid Reality connection address. Please enter a domain, IPv4, or IPv6 without port."
C[127]="Reality 连接地址格式错误。请输入不带端口的域名、IPv4 或 IPv6。"
E[128]="Guided fixed-domain deployment: enter the Cloudflare-hosted Tunnel hostname (for example: xhttp.example.com):"
C[128]="傻瓜式固定域名部署：请输入 Cloudflare 托管的 Tunnel 域名（如 xhttp.example.com）："
E[129]="Paste the Cloudflare Tunnel token or one-line credentials JSON (input is visible; verify it is complete):"
C[129]="请粘贴 Cloudflare Tunnel Token 或单行凭据 JSON（输入明文可见，请确认完整无缺）："
E[130]="Invalid fixed Tunnel hostname. Enter a Cloudflare-hosted domain; trycloudflare.com is not supported."
C[130]="固定 Tunnel 域名无效。请输入 Cloudflare 托管的域名；不支持 trycloudflare.com。"
E[131]="Invalid Tunnel credential. Paste the complete Tunnel token or one-line credentials JSON."
C[131]="Tunnel 凭据无效。请粘贴完整的 Tunnel Token 或单行凭据 JSON。"
E[132]="Starting guided VLESS + XHTTP + PQC + ECH + Argo + CDN deployment with secure defaults..."
C[132]="正在以安全默认值开始 VLESS + XHTTP + PQC + ECH + Argo + CDN 傻瓜式部署……"
E[133]="Guided fixed-domain VLESS + XHTTP + PQC + ECH + Argo + CDN install (argox -g)"
C[133]="固定域名 VLESS + XHTTP + PQC + ECH + Argo + CDN 傻瓜式安装（argox -g）"
E[134]="For this guided flow, create the Cloudflare Tunnel and Published application first. Its Service URL must be http://localhost:8080, then paste the Tunnel token below. API tokens remain available in the advanced installer."
C[134]="傻瓜式流程需要先在 Cloudflare 后台创建 Tunnel 和对应的 Published application / Public Hostname，并把 Service URL 设置为 http://localhost:8080；然后再粘贴该 Tunnel Token。API Token 请使用高级安装流程。"
E[135]="An existing ArgoX installation was found. Guided install will not overwrite it."
C[135]="检测到已有 ArgoX 安装。傻瓜式安装不会覆盖现有部署。"
E[136]="Cloudflare CDN entry point used by the client to reach the tunnel (domain or IP)"
C[136]="客户端连接隧道所用的 Cloudflare CDN 优选入口（域名或 IP）"
E[137]="Enable ML-KEM-768/X25519 hybrid post-quantum VLESS Encryption"
C[137]="是否开启 ML-KEM-768/X25519 混合后量子 VLESS Encryption 加密"
E[138]="Abort immediately on PQC validation failure instead of silently downgrading"
C[138]="PQC 校验失败时是否直接中止安装（而不是悄悄降级为普通加密）"
E[139]="Disable 0-RTT resumption and use 1-RTT only"
C[139]="是否禁用 0-RTT 快速恢复，只使用 1-RTT"
E[140]="XHTTP CDN mode (auto / stream-one / stream-up / packet-up)"
C[140]="XHTTP CDN 模式（auto / stream-one / stream-up / packet-up）"
E[141]="Enable ECH (Encrypted Client Hello)"
C[141]="是否开启 ECH（加密客户端问候，Encrypted Client Hello）"
E[142]="Abort immediately on ECH validation failure instead of silently disabling ECH"
C[142]="ECH 校验失败时是否直接中止安装（而不是悄悄关闭 ECH）"
E[143]="Domain used to query the HTTPS/ECH DNS record"
C[143]="用于查询 HTTPS/ECH DNS 记录的域名"
E[144]="DNS resolver (DoH/DoU) used to fetch the ECH config"
C[144]="用于获取 ECH 配置的 DNS 解析服务器（DoH/DoU 地址）"
E[145]="Invalid choice, please enter one of: auto, stream-one, stream-up, packet-up."
C[145]="输入无效，请输入以下之一：auto、stream-one、stream-up、packet-up。"
E[146]="Invalid DNS resolver format. Example: https://1.1.1.1/dns-query"
C[146]="DNS 解析服务器格式无效，示例：https://1.1.1.1/dns-query"
E[147]="Step-by-step guided install: VLESS + XHTTP + PQC + Argo + CDN + ECH. Press Enter to accept the value shown in [brackets], or type a new value then Enter."
C[147]="逐步引导安装：VLESS + XHTTP + PQC + Argo + CDN + ECH。方括号 [ ] 内为默认值，直接回车即采用默认值，或手动输入新值后回车确认。"
E[148]="Invalid domain format, using default value instead."
C[148]="域名格式无效，将使用默认值。"
E[149]="default"
C[149]="默认"
E[150]="Invalid input, please enter y or n. Using default value instead."
C[150]="输入无效，请输入 y 或 n，将使用默认值。"
E[151]="Configuration summary:"
C[151]="配置汇总："
E[152]="Proceed with installation using the above configuration? [Y/n]"
C[152]="确认使用以上配置开始安装？[Y/n]"
E[153]="Found a leftover directory from a previous incomplete or failed installation (no running Argo/Xray/Nginx service was detected). Cleaning it up automatically before continuing."
C[153]="检测到一个之前安装失败或中途中断遗留下来的残留目录（未检测到任何正在运行的 Argo/Xray/Nginx 服务），将自动清理后继续安装。"
E[154]="Enable XHTTP uplink/downlink separation (client downloadSettings)"
C[154]="是否开启 XHTTP 上下行分离（客户端 downloadSettings）"
E[155]="Downlink Cloudflare entry point; may differ from uplink (domain/IP, optional :port)"
C[155]="下行 Cloudflare 优选入口；可与上行不同（域名/IP，可选 :port）"
E[156]="Invalid downlink entry point. Falling back to the uplink entry point."
C[156]="下行优选入口格式无效，将回退为上行优选入口。"
E[157]="XHTTP stream-one cannot be combined with downloadSettings; switching uplink mode to stream-up."
C[157]="XHTTP stream-one 不能与 downloadSettings 同时使用；已自动把上行模式切换为 stream-up。"
E[158]="XHTTP uplink/downlink separation (current: \${_val})"
C[158]="XHTTP 上下行分离（当前：\${_val}）"

# 自定义字体彩色，read 函数
warning() { echo -e "\033[31m\033[01m$*\033[0m"; }         # 红色
error() { echo -e "\033[31m\033[01m$*\033[0m" && exit 1; } # 红色
info() { echo -e "\033[32m\033[01m$*\033[0m"; }            # 绿色
hint() { echo -e "\033[33m\033[01m$*\033[0m"; }            # 黄色
reading() { read -rp "$(info "$1")" "$2"; }

# 标记哪些文本需要 eval
declare -A TEXT_NEEDS_EVAL
for _text_i in "${!E[@]}"; do
  [[ "${E[${_text_i}]}" == *'$'* || "${C[${_text_i}]}" == *'$'* ]] && TEXT_NEEDS_EVAL[${_text_i}]=1
done
unset _text_i

text() {
  local -n _text_arr="${L}"        # nameref 指向 E 或 C，零子进程
  local _text_val="${_text_arr[$*]}"
  if [[ -n "${TEXT_NEEDS_EVAL[$*]:-}" ]]; then
    eval "printf '%s' \"${_text_val}\""
  else
    printf '%s' "${_text_val}"
  fi
}

# 转换字母和 ASCII 码之间的关系，支持单个字符和数字的双向转换，第二个参数可选 '++' 表示字母加一
asc() {
  if [[ "$1" = [a-z] ]]; then
    [ "$2" = '++' ] && printf "\\$(printf '%03o' "$(( $(printf "%d" "'$1'") + 1 ))")" || printf "%d" "'$1'"
  else
    [[ "$1" =~ ^[0-9]+$ ]] && printf "\\$(printf '%03o' "$1")"
  fi
}

# 检查端口占用，ss 命令输出格式较复杂且不稳定，使用全局变量 PORT_SNAPSHOT 来存储快照，避免多次调用 ss 导致性能问题
refresh_port_snapshot() {
  PORT_SNAPSHOT=$(ss -nltup 2>/dev/null)
}

# 判断端口是否被占用，使用预先获取的 PORT_SNAPSHOT 进行匹配，避免多次调用 ss 导致性能问题
is_port_in_use() {
  local _PORT="$1"
  grep -qE "(^|[[:space:]])[^[:space:]]*:${_PORT}([[:space:]]|$)" <<< "$PORT_SNAPSHOT"
}

# 检测是否启用 Github CDN
# Safe edition: third-party CDN/proxy detection is disabled.
check_cdn() {
  GH_PROXY=''
  return 0
}

# 检测是否解锁 chatGPT，以决定是否使用 warp 链式代理或者是 direct out
# Safe edition: disabled external OpenAI/ChatGPT probing to avoid unnecessary outbound requests.
check_chatgpt() {
  echo "unlock"
  return 0
}

# 脚本当天及累计运行次数统计
# Safe edition: disabled telemetry/reporting to third-party stat endpoint.
statistics_of_run-times() {
  return 0
}

# 从 inbound.json 实时解析已安装协议列表，grep pattern 由 NODE_TAG 数组自动构建
# 新增协议只需在顶部 NODE_TAG 数组里追加，此处无需手动维护
get_installed_protocols() {
  [ -s $WORK_DIR/inbound.json ] || return
  local _TAG_PATTERN
  _TAG_PATTERN=$(IFS='|'; echo "${NODE_TAG[*]}")
  $WORK_DIR/jq -r '.inbounds[].tag' $WORK_DIR/inbound.json 2>/dev/null \
    | grep -oE "$_TAG_PATTERN"
}

# 读取或更新 custom 文件中的 key=value（可用 . $CUSTOM_FILE 批量加载）
write_custom() {
  local _KEY="$1" _VAL="$2"
  mkdir -p "$WORK_DIR" 2>/dev/null || true
  touch "$CUSTOM_FILE" 2>/dev/null || true
  chmod 600 "$CUSTOM_FILE" 2>/dev/null || true
  if [ -s "$CUSTOM_FILE" ] && grep -q "^${_KEY}=" "$CUSTOM_FILE"; then
    sed -i "s|^${_KEY}=.*|${_KEY}=${_VAL}|" "$CUSTOM_FILE"
  else
    echo "${_KEY}=${_VAL}" >> "$CUSTOM_FILE"
  fi
  chmod 600 "$CUSTOM_FILE" 2>/dev/null || true
}

truthy() {
  case "${1,,}" in y|yes|true|1|on|enable|enabled|开启|是) return 0 ;; *) return 1 ;; esac
}


is_vless_protocol_letter() {
  case "$1" in b|d|e|i|j) return 0 ;; *) return 1 ;; esac
}

filter_protocols_for_strong_mode() {
  truthy "${ALLOW_LEGACY_PROTOCOLS:-n}" && return 0
  local _filtered=() _p
  for _p in "${INSTALL_PROTOCOLS[@]}"; do
    if is_vless_protocol_letter "$_p"; then
      _filtered+=("$_p")
    fi
  done
  if [ "${#_filtered[@]}" -eq 0 ]; then
    read -r -a INSTALL_PROTOCOLS <<< "$STABLE_DEFAULT_PROTOCOLS"
  else
    INSTALL_PROTOCOLS=("${_filtered[@]}")
  fi
}

normalize_vless_pqc_server_ticket() {
  # Inbound/server decryption 3rd block is ticket validity, e.g. 600s or 100-500s.
  local _v="$1" _resume="${VLESS_PQC_RESUME:-600s}"
  if truthy "${VLESS_PQC_DISABLE_0RTT:-y}"; then
    printf '%s' "$_v" | sed -E "s/^(mlkem768x25519plus\.[^.]+\.)(0rtt|1rtt|[0-9]+s|[0-9]+-[0-9]+s)\./\1${_resume}./"
  else
    printf '%s' "$_v"
  fi
}

normalize_vless_pqc_client_ticket() {
  # Outbound/client encryption 3rd block must be 0rtt or 1rtt, not 600s.
  # Strong mode disables 0-RTT by converting any 0rtt/time value to 1rtt.
  local _v="$1" _client_rtt="${VLESS_PQC_CLIENT_RTT:-1rtt}"
  if truthy "${VLESS_PQC_DISABLE_0RTT:-y}"; then
    printf '%s' "$_v" | sed -E "s/^(mlkem768x25519plus\.[^.]+\.)(0rtt|1rtt|[0-9]+s|[0-9]+-[0-9]+s)\./\1${_client_rtt}./"
  else
    printf '%s' "$_v"
  fi
}

validate_vless_pqc_values() {
  truthy "${ENABLE_VLESS_PQC:-y}" || return 0
  has_vless_protocol_selected || return 0
  local _prefix="${VLESS_PQC_REQUIRE_PREFIX:-mlkem768x25519plus}"
  if [[ "${VLESS_SERVER_DECRYPTION:-none}" != ${_prefix}.* || "${VLESS_CLIENT_ENCRYPTION:-none}" != ${_prefix}.* ]]; then
    if truthy "${VLESS_PQC_STRICT:-y}"; then
      error "
 VLESS PQC strict check failed: expected ${_prefix}.*, got decryption='${VLESS_SERVER_DECRYPTION:-empty}', encryption='${VLESS_CLIENT_ENCRYPTION:-empty}'.
"
    else
      warning "
 VLESS PQC prefix check failed, but strict mode is disabled.
"
    fi
  fi
  if truthy "${VLESS_PQC_DISABLE_0RTT:-y}" && { [[ "${VLESS_SERVER_DECRYPTION:-}" == *'.0rtt.'* ]] || [[ "${VLESS_CLIENT_ENCRYPTION:-}" == *'.0rtt.'* ]]; }; then
    if truthy "${VLESS_PQC_STRICT:-y}"; then
      error "
 VLESS PQC strict check failed: 0-RTT is disabled, but generated parameters still contain .0rtt.
"
    else
      warning "
 VLESS PQC 0-RTT check failed, but strict mode is disabled.
"
    fi
  fi
  if [[ "${VLESS_CLIENT_ENCRYPTION:-}" =~ ^mlkem768x25519plus\.[^.]+\.[0-9]+(-[0-9]+)?s\. ]]; then
    if truthy "${VLESS_PQC_STRICT:-y}"; then
      error "
 VLESS PQC strict check failed: client encryption 3rd block must be 0rtt or 1rtt, not a server ticket time.
"
    else
      warning "
 VLESS PQC client encryption rtt check failed, but strict mode is disabled.
"
    fi
  fi
}

protect_secret_files() {
  chmod 700 "$WORK_DIR" 2>/dev/null || true
  chmod 700 "$WORK_DIR/subscribe" 2>/dev/null || true
  chmod 600 "$CUSTOM_FILE" 2>/dev/null || true
  chmod 600 "$WORK_DIR"/*.json "$WORK_DIR"/*.yml "$WORK_DIR"/*.yaml "$WORK_DIR"/*.log 2>/dev/null || true
  chmod 600 "$WORK_DIR"/inbound.json "$WORK_DIR"/outbound.json "$WORK_DIR"/tunnel.json "$WORK_DIR"/tunnel.yml 2>/dev/null || true
  chmod 600 "${ARGO_DAEMON_FILE:-/nonexistent}" "${XRAY_DAEMON_FILE:-/nonexistent}" 2>/dev/null || true
  chmod 700 "$WORK_DIR/cloudflared" "$WORK_DIR/xray" "$WORK_DIR/jq" "$WORK_DIR/argox-url-watch.sh" "$WORK_DIR/ax.sh" 2>/dev/null || true
}

verify_vless_pqc_installation() {
  truthy "${ENABLE_VLESS_PQC:-y}" || return 0
  has_vless_protocol_selected || return 0
  if [ -s "$WORK_DIR/inbound.json" ]; then
    if ! grep -q '"decryption"[[:space:]]*:[[:space:]]*"mlkem768x25519plus' "$WORK_DIR/inbound.json" 2>/dev/null; then
      error "
 VLESS PQC verification failed: inbound.json does not contain decryption=mlkem768x25519plus*.
"
    fi
    if truthy "${VLESS_PQC_DISABLE_0RTT:-y}" && grep -q '\.0rtt\.' "$WORK_DIR/inbound.json" 2>/dev/null; then
      error "
 VLESS PQC verification failed: 0-RTT is disabled but inbound.json still contains .0rtt.
"
    fi
  fi
}

has_vless_protocol_selected() {
  local _p _t
  for _p in "${INSTALL_PROTOCOLS[@]}"; do
    [[ "$_p" =~ ^[bdeij]$ ]] && return 0
  done
  for _t in "${REINSTALL_TAGS[@]}"; do
    [[ "$_t" =~ ^(reality-vision|reality-grpc|vless-ws|xhttp-h1.1-cdn|xhttp-h3-direct)$ ]] && return 0
  done
  get_installed_protocols 2>/dev/null | grep -Eq '^(reality-vision|reality-grpc|vless-ws|xhttp-h1.1-cdn|xhttp-h3-direct)$' && return 0
  return 1
}

url_encode() {
  local _s="$1"
  if [ -x "$WORK_DIR/jq" ]; then
    printf '%s' "$_s" | "$WORK_DIR/jq" -sRr @uri 2>/dev/null && return 0
  elif command -v jq >/dev/null 2>&1; then
    printf '%s' "$_s" | jq -sRr @uri 2>/dev/null && return 0
  elif command -v python3 >/dev/null 2>&1; then
    printf '%s' "$_s" | python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.stdin.read(), safe=""))' 2>/dev/null && return 0
  fi
  printf '%s' "$_s"
}

has_xhttp_cdn_selected() {
  local _p _t
  for _p in "${INSTALL_PROTOCOLS[@]}"; do
    [ "$_p" = 'i' ] && return 0
  done
  for _t in "${REINSTALL_TAGS[@]}"; do
    [ "$_t" = 'xhttp-h1.1-cdn' ] && return 0
  done
  get_installed_protocols 2>/dev/null | grep -qx 'xhttp-h1.1-cdn' && return 0
  return 1
}

disable_ech_runtime() {
  ECH_CLIENT_CONFIG=''
  ECH_CLIENT_CONFIG_QUERY=''
  ECH_URI_PARAM=''
  MIHOMO_ECH_OPTS=''
  MIHOMO_TLS_FINGERPRINT=', client-fingerprint: chrome'
}

ech_runtime_values() {
  ENABLE_ECH="${enableEch:-${ENABLE_ECH:-y}}"
  ECH_STRICT="${echStrict:-${ECH_STRICT:-y}}"
  ECH_CONFIG="${echConfig:-${ECH_CONFIG:-}}"
  ECH_QUERY_DOMAIN="${echQueryDomain:-${ECH_QUERY_DOMAIN:-cloudflare-ech.com}}"
  ECH_DNS="${echDns:-${ECH_DNS:-https://1.1.1.1/dns-query}}"
  XHTTP_CDN_MODE="${xhttpCdnMode:-${XHTTP_CDN_MODE:-packet-up}}"

  case "$XHTTP_CDN_MODE" in
    auto|stream-one|stream-up|packet-up) ;;
    *)
      if truthy "$ECH_STRICT"; then
        error "
 Invalid XHTTP_CDN_MODE '${XHTTP_CDN_MODE}'. Use auto, stream-one, stream-up, or packet-up.
"
      fi
      warning "
 Invalid XHTTP_CDN_MODE '${XHTTP_CDN_MODE}', falling back to packet-up.
"
      XHTTP_CDN_MODE='packet-up'
      ;;
  esac

  if ! truthy "$ENABLE_ECH" || ! has_xhttp_cdn_selected; then
    disable_ech_runtime
    return 0
  fi

  if [ -z "$ECH_CONFIG" ]; then
    if [ -z "$ECH_QUERY_DOMAIN" ] ||
       ! validate_reality_addr "$ECH_QUERY_DOMAIN" ||
       ! [[ "$ECH_DNS" =~ ^(udp|https|h2c|https\+local)://[^[:space:]\&\;\|]+$ ]]; then
      if truthy "$ECH_STRICT"; then
        error "
 ECH strict check failed. ECH_QUERY_DOMAIN or ECH_DNS is invalid.
"
      fi
      warning "
 ECH settings are invalid; ECH has been disabled for generated clients.
"
      disable_ech_runtime
      return 0
    fi
    ECH_CLIENT_CONFIG="${ECH_QUERY_DOMAIN}+${ECH_DNS}"
  elif [[ "$ECH_CONFIG" =~ ^[A-Za-z0-9._-]+\+(udp|https|h2c|https\+local)://[^[:space:]\&\;\|]+$ ]] ||
       [[ "$ECH_CONFIG" =~ ^(udp|https|h2c|https\+local)://[^[:space:]\&\;\|]+$ ]] ||
       [[ "$ECH_CONFIG" =~ ^[A-Za-z0-9_+/=-]+$ ]]; then
    ECH_CLIENT_CONFIG="$ECH_CONFIG"
  else
    if truthy "$ECH_STRICT"; then
      error "
 ECH strict check failed. ECH_CONFIG must be a fixed base64 ECHConfig or a supported DNS query expression.
"
    fi
    warning "
 ECH_CONFIG is invalid; ECH has been disabled for generated clients.
"
    disable_ech_runtime
    return 0
  fi

  ECH_CLIENT_CONFIG_QUERY=$(url_encode "$ECH_CLIENT_CONFIG")
  ECH_URI_PARAM="&ech=${ECH_CLIENT_CONFIG_QUERY}"
  MIHOMO_TLS_FINGERPRINT=''

  # Mihomo resolves ECH through its own DNS stack. It cannot consume Xray's
  # custom DNS-transport expression, so pass either the fixed config or only
  # the domain whose HTTPS record should be queried.
  if [[ "$ECH_CLIENT_CONFIG" =~ ^[A-Za-z0-9_+/=-]+$ ]]; then
    MIHOMO_ECH_OPTS=", ech-opts: {enable: true, config: \"${ECH_CLIENT_CONFIG}\"}"
  else
    local _mihomo_query_domain="$ARGO_DOMAIN"
    if [[ "$ECH_CLIENT_CONFIG" =~ ^([A-Za-z0-9._-]+)\+ ]]; then
      _mihomo_query_domain="${BASH_REMATCH[1]}"
    fi
    MIHOMO_ECH_OPTS=", ech-opts: {enable: true, query-server-name: ${_mihomo_query_domain}}"
  fi
}

xhttp_split_runtime_values() {
  ENABLE_XHTTP_SPLIT="${enableXhttpSplit:-${ENABLE_XHTTP_SPLIT:-n}}"
  XHTTP_DOWNLOAD_SERVER="${xhttpDownloadServer:-${XHTTP_DOWNLOAD_SERVER:-}}"
  XHTTP_DOWNLOAD_PORT="${xhttpDownloadPort:-${XHTTP_DOWNLOAD_PORT:-}}"

  if ! truthy "$ENABLE_XHTTP_SPLIT" || ! has_xhttp_cdn_selected; then
    return 0
  fi

  if [ "${XHTTP_CDN_MODE:-packet-up}" = 'stream-one' ]; then
    warning "\n $(text 157) \n"
    XHTTP_CDN_MODE='stream-up'
  fi

  [ -z "$XHTTP_DOWNLOAD_SERVER" ] && XHTTP_DOWNLOAD_SERVER="${SERVER:-}"
  [ -z "$XHTTP_DOWNLOAD_PORT" ] && XHTTP_DOWNLOAD_PORT="${SERVER_PORT:-443}"

  # Normalize bracketed IPv6 from hand-written config so Xray receives the
  # address itself; brackets are only needed when formatting host:port text.
  if [[ "$XHTTP_DOWNLOAD_SERVER" =~ ^\[([0-9A-Fa-f:]+)\]$ ]]; then
    XHTTP_DOWNLOAD_SERVER="${BASH_REMATCH[1]}"
  fi

  if ! validate_reality_addr "$XHTTP_DOWNLOAD_SERVER"; then
    error "\n Invalid XHTTP_DOWNLOAD_SERVER '${XHTTP_DOWNLOAD_SERVER}'. Use a domain, IPv4, or IPv6 without a path. \n"
  fi
  if ! [[ "$XHTTP_DOWNLOAD_PORT" =~ ^[0-9]+$ ]] || [ "$XHTTP_DOWNLOAD_PORT" -lt 1 ] || [ "$XHTTP_DOWNLOAD_PORT" -gt 65535 ]; then
    error "\n Invalid XHTTP_DOWNLOAD_PORT '${XHTTP_DOWNLOAD_PORT}'. Use 1-65535. \n"
  fi
}

build_xhttp_client_extra_json() {
  local _split='false'
  truthy "${ENABLE_XHTTP_SPLIT:-n}" && _split='true'

  "$WORK_DIR/jq" -cn \
    --argjson split "$_split" \
    --arg down_server "${XHTTP_DOWNLOAD_SERVER:-$SERVER}" \
    --arg down_port "${XHTTP_DOWNLOAD_PORT:-${SERVER_PORT:-443}}" \
    --arg sni "$ARGO_DOMAIN" \
    --arg path "/${WS_PATH}-xh" \
    --arg ech "${ECH_CLIENT_CONFIG:-}" '
    def tls($sni; $ech): ({
      serverName: $sni,
      alpn: ["h2", "http/1.1"],
      fingerprint: "chrome"
    } + (if $ech != "" then {echConfigList: $ech} else {} end));
    def down($addr; $port; $sni; $path; $ech): {
      address: $addr,
      port: ($port | tonumber),
      network: "xhttp",
      security: "tls",
      tlsSettings: tls($sni; $ech),
      xhttpSettings: {
        host: $sni,
        path: $path,
        extra: {xPaddingBytes: "100-1000"}
      }
    };
    ({
      xPaddingBytes: "100-1000",
      noSSEHeader: true,
      scMaxEachPostBytes: "1000000-2000000",
      scMinPostsIntervalMs: "30-30",
      scMaxBufferedPosts: 30
    } + (if $split then {downloadSettings: down($down_server; $down_port; $sni; $path; $ech)} else {} end))'
}

write_passwall_xhttp_extra() {
  local _out="$WORK_DIR/subscribe/passwall-xhttp-extra.json"
  if ! has_xhttp_cdn_selected || [[ "$ARGO_DOMAIN" =~ trycloudflare\.com$ ]] || [ -z "$ARGO_DOMAIN" ]; then
    rm -f "$_out" 2>/dev/null || true
    return 0
  fi
  build_xhttp_client_extra_json | "$WORK_DIR/jq" . > "$_out" || {
    rm -f "$_out" 2>/dev/null || true
    return 1
  }
  chmod 600 "$_out" 2>/dev/null || true
}

validate_reality_addr() {
  local _raw="$1" _host _o1 _o2 _o3 _o4
  _raw="${_raw//[[:space:]]/}"
  [ -z "$_raw" ] && return 0

  # Reality 连接地址只接收 host，不接收端口、路径或 URL。
  [[ "$_raw" == *'/'* ]] && return 1
  if [[ "$_raw" =~ ^https?:// ]]; then
    return 1
  fi

  # [IPv6] -> IPv6
  if [[ "$_raw" =~ ^\[([0-9A-Fa-f:]+)\]$ ]]; then
    _host="${BASH_REMATCH[1]}"
  else
    _host="$_raw"
  fi

  # IPv4 with octet bounds
  if [[ "$_host" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
    _o1="${BASH_REMATCH[1]}"; _o2="${BASH_REMATCH[2]}"; _o3="${BASH_REMATCH[3]}"; _o4="${BASH_REMATCH[4]}"
    for _oct in "$_o1" "$_o2" "$_o3" "$_o4"; do
      [ "$_oct" -le 255 ] || return 1
    done
    return 0
  fi

  # IPv6（宽松校验，但必须只包含十六进制和冒号，并且至少包含一个冒号）
  if [[ "$_host" == *:* && "$_host" =~ ^[0-9A-Fa-f:]+$ ]]; then
    return 0
  fi

  # Domain，禁止以 - 开头/结尾的 label，TLD 2-63 位。
  if [[ "$_host" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; then
    return 0
  fi

  return 1
}

is_fixed_argo_domain() {
  local _domain="${1,,}"
  _domain="${_domain//[[:space:]]/}"
  [ -n "$_domain" ] || return 1
  [[ "$_domain" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]] || return 1
  [[ "$_domain" =~ (^|\.)trycloudflare\.com$ ]] && return 1
  return 0
}

is_cloudflare_tunnel_token() {
  [[ "$1" =~ ^[A-Za-z0-9_=-]{120,400}$ ]]
}

is_cloudflare_tunnel_json() {
  [[ "$1" == \{*\} && "$1" == *'"TunnelSecret"'* && "$1" == *'"TunnelID"'* ]]
}

is_cloudflare_tunnel_credential() {
  is_cloudflare_tunnel_token "$1" || is_cloudflare_tunnel_json "$1"
}

reality_connect_addr() {
  local _addr="${REALITY_DOMAIN:-${realityDomain:-}}"
  [ "$_addr" = "__REALITY_DOMAIN_UNSET__" ] && _addr=''
  [ -z "$_addr" ] && _addr="$SERVER_IP"
  printf '%s' "$_addr"
}

uri_host() {
  local _h="$1"
  _h="${_h#[}"
  _h="${_h%]}"
  if [[ "$_h" == *:* ]]; then
    printf '[%s]' "$_h"
  else
    printf '%s' "$_h"
  fi
}

vless_pqc_runtime_values() {
  # 兼容 custom 文件的小驼峰变量名
  ENABLE_VLESS_PQC="${enableVlessPqc:-${ENABLE_VLESS_PQC:-y}}"
  VLESS_PQC_STRICT="${vlessPqcStrict:-${VLESS_PQC_STRICT:-y}}"
  VLESS_PQC_REQUIRE_PREFIX="${vlessPqcRequirePrefix:-${VLESS_PQC_REQUIRE_PREFIX:-mlkem768x25519plus}}"
  VLESS_PQC_DISABLE_0RTT="${vlessPqcDisable0Rtt:-${VLESS_PQC_DISABLE_0RTT:-y}}"
  VLESS_PQC_RESUME="${vlessPqcResume:-${VLESS_PQC_RESUME:-600s}}"
  VLESS_PQC_CLIENT_RTT="${vlessPqcClientRtt:-${VLESS_PQC_CLIENT_RTT:-1rtt}}"
  ALLOW_LEGACY_PROTOCOLS="${allowLegacyProtocols:-${ALLOW_LEGACY_PROTOCOLS:-n}}"
  VLESS_PQC_DECRYPTION="${vlessPqcDecryption:-${VLESS_PQC_DECRYPTION:-}}"
  VLESS_PQC_ENCRYPTION="${vlessPqcEncryption:-${VLESS_PQC_ENCRYPTION:-}}"

  if truthy "$ENABLE_VLESS_PQC" && [ -n "$VLESS_PQC_DECRYPTION" ] && [ -n "$VLESS_PQC_ENCRYPTION" ]; then
    VLESS_PQC_DECRYPTION=$(normalize_vless_pqc_server_ticket "$VLESS_PQC_DECRYPTION")
    VLESS_PQC_ENCRYPTION=$(normalize_vless_pqc_client_ticket "$VLESS_PQC_ENCRYPTION")
    VLESS_SERVER_DECRYPTION="$VLESS_PQC_DECRYPTION"
    VLESS_CLIENT_ENCRYPTION="$VLESS_PQC_ENCRYPTION"
    validate_vless_pqc_values
  else
    VLESS_SERVER_DECRYPTION='none'
    VLESS_CLIENT_ENCRYPTION='none'
  fi
  VLESS_CLIENT_ENCRYPTION_QUERY=$(url_encode "$VLESS_CLIENT_ENCRYPTION")
}

prepare_vless_pqc_keys() {
  VLESS_SERVER_DECRYPTION='none'
  VLESS_CLIENT_ENCRYPTION='none'
  VLESS_CLIENT_ENCRYPTION_QUERY='none'

  truthy "${ENABLE_VLESS_PQC:-y}" || { vless_pqc_runtime_values; return 0; }
  has_vless_protocol_selected || { vless_pqc_runtime_values; return 0; }

  # 优先复用已有配置；避免每次查看节点或改协议时重置客户端参数
  if [ -s "$CUSTOM_FILE" ]; then
    local _old_dec _old_enc _old_en _old_strict _old_prefix _old_0rtt _old_resume _old_client_rtt _old_legacy
    _old_dec=$(awk -F= '/^vlessPqcDecryption=/{print $2; exit}' "$CUSTOM_FILE")
    _old_enc=$(awk -F= '/^vlessPqcEncryption=/{print $2; exit}' "$CUSTOM_FILE")
    _old_en=$(awk -F= '/^enableVlessPqc=/{print $2; exit}' "$CUSTOM_FILE")
    _old_strict=$(awk -F= '/^vlessPqcStrict=/{print $2; exit}' "$CUSTOM_FILE")
    _old_prefix=$(awk -F= '/^vlessPqcRequirePrefix=/{print $2; exit}' "$CUSTOM_FILE")
    _old_0rtt=$(awk -F= '/^vlessPqcDisable0Rtt=/{print $2; exit}' "$CUSTOM_FILE")
    _old_resume=$(awk -F= '/^vlessPqcResume=/{print $2; exit}' "$CUSTOM_FILE")
    _old_client_rtt=$(awk -F= '/^vlessPqcClientRtt=/{print $2; exit}' "$CUSTOM_FILE")
    _old_legacy=$(awk -F= '/^allowLegacyProtocols=/{print $2; exit}' "$CUSTOM_FILE")
    [ -z "$VLESS_PQC_DECRYPTION" ] && VLESS_PQC_DECRYPTION="$_old_dec"
    [ -z "$VLESS_PQC_ENCRYPTION" ] && VLESS_PQC_ENCRYPTION="$_old_enc"
    [ -z "$ENABLE_VLESS_PQC" ] && ENABLE_VLESS_PQC="${_old_en:-y}"
    [ -z "$VLESS_PQC_STRICT" ] && VLESS_PQC_STRICT="${_old_strict:-y}"
    [ -z "$VLESS_PQC_REQUIRE_PREFIX" ] && VLESS_PQC_REQUIRE_PREFIX="${_old_prefix:-mlkem768x25519plus}"
    [ -z "$VLESS_PQC_DISABLE_0RTT" ] && VLESS_PQC_DISABLE_0RTT="${_old_0rtt:-y}"
    [ -z "$VLESS_PQC_RESUME" ] && VLESS_PQC_RESUME="${_old_resume:-600s}"
    [ -z "$VLESS_PQC_CLIENT_RTT" ] && VLESS_PQC_CLIENT_RTT="${_old_client_rtt:-1rtt}"
    [ -z "$ALLOW_LEGACY_PROTOCOLS" ] && ALLOW_LEGACY_PROTOCOLS="${_old_legacy:-n}"
  fi

  if [ -z "$VLESS_PQC_DECRYPTION" ] || [ -z "$VLESS_PQC_ENCRYPTION" ]; then
    local _xray_bin _out
    if [ -x "$WORK_DIR/xray" ]; then
      _xray_bin="$WORK_DIR/xray"
    elif [ -x "$TEMP_DIR/xray" ]; then
      _xray_bin="$TEMP_DIR/xray"
    else
      _xray_bin=''
    fi

    if [ -n "$_xray_bin" ]; then
      _out=$("$_xray_bin" vlessenc 2>/dev/null || true)
      local _section _flat
      _section=$(printf '%s\n' "$_out" | awk '/Authentication:[[:space:]]*ML-KEM-768/{flag=1; next} flag && /Authentication:/{flag=0} flag')
      [ -z "$_section" ] && _section="$_out"
      _flat=$(printf '%s' "$_section" | tr -d '\r\n')
      VLESS_PQC_DECRYPTION=$(printf '%s\n' "$_flat" | sed -n 's/.*"decryption"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
      VLESS_PQC_ENCRYPTION=$(printf '%s\n' "$_flat" | sed -n 's/.*"encryption"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
      if [ -z "$VLESS_PQC_DECRYPTION" ] || [ -z "$VLESS_PQC_ENCRYPTION" ]; then
        VLESS_PQC_DECRYPTION=$(printf '%s\n' "$_out" | awk -F'"' '/"decryption"[[:space:]]*:/{v=$4} END{print v}')
        VLESS_PQC_ENCRYPTION=$(printf '%s\n' "$_out" | awk -F'"' '/"encryption"[[:space:]]*:/{v=$4} END{print v}')
      fi
    fi
  fi

  if [ -z "$VLESS_PQC_DECRYPTION" ] || [ -z "$VLESS_PQC_ENCRYPTION" ]; then
    if truthy "${VLESS_PQC_STRICT:-y}"; then
      error "\n Xray vlessenc 不可用，无法生成 VLESS 后量子加密参数。请升级到支持 VLESS Encryption 的 Xray-core，或设置 ENABLE_VLESS_PQC='n' 回退。\n"
    else
      warning "\n Xray vlessenc 不可用，已回退到 VLESS encryption=none。\n"
      VLESS_PQC_DECRYPTION=''
      VLESS_PQC_ENCRYPTION=''
    fi
  fi

  vless_pqc_runtime_values

  if [ "$VLESS_SERVER_DECRYPTION" != 'none' ]; then
    write_custom 'enableVlessPqc' 'y'
    write_custom 'vlessPqcStrict' "${VLESS_PQC_STRICT:-y}"
    write_custom 'vlessPqcRequirePrefix' "${VLESS_PQC_REQUIRE_PREFIX:-mlkem768x25519plus}"
    write_custom 'vlessPqcDisable0Rtt' "${VLESS_PQC_DISABLE_0RTT:-y}"
    write_custom 'vlessPqcResume' "${VLESS_PQC_RESUME:-600s}"
    write_custom 'vlessPqcClientRtt' "${VLESS_PQC_CLIENT_RTT:-1rtt}"
    write_custom 'allowLegacyProtocols' "${ALLOW_LEGACY_PROTOCOLS:-n}"
    write_custom 'vlessPqcDecryption' "$VLESS_SERVER_DECRYPTION"
    write_custom 'vlessPqcEncryption' "$VLESS_CLIENT_ENCRYPTION"
  else
    write_custom 'enableVlessPqc' "${ENABLE_VLESS_PQC:-n}"
    write_custom 'vlessPqcStrict' "${VLESS_PQC_STRICT:-y}"
    write_custom 'vlessPqcRequirePrefix' "${VLESS_PQC_REQUIRE_PREFIX:-mlkem768x25519plus}"
    write_custom 'vlessPqcDisable0Rtt' "${VLESS_PQC_DISABLE_0RTT:-y}"
    write_custom 'vlessPqcResume' "${VLESS_PQC_RESUME:-600s}"
    write_custom 'vlessPqcClientRtt' "${VLESS_PQC_CLIENT_RTT:-1rtt}"
    write_custom 'allowLegacyProtocols' "${ALLOW_LEGACY_PROTOCOLS:-n}"
  fi
}

# 选择中英语言
select_language() {
  if [ -z "$L" ]; then
    local _LANG_IN_CUSTOM
    [ -s "$CUSTOM_FILE" ] && _LANG_IN_CUSTOM=$(awk -F= '/^language=/{print $2}' "$CUSTOM_FILE")
    case "${_LANG_IN_CUSTOM,,}" in
      e|english ) L=E ;;
      c|chinese ) L=C ;;
      * ) [ -z "$L" ] && L=E && ! grep -q 'noninteractive_install' <<< "$NONINTERACTIVE_INSTALL" && hint "\n $(text 0) \n" && reading " $(text 24) " LANGUAGE
      [ "$LANGUAGE" = 2 ] && L=C ;;
    esac
  fi
}

# 只允许 root 用户安装脚本
check_root() {
  [ "$(id -u)" != 0 ] && error "\n $(text 47) \n"
}

# 判断处理器架构
check_arch() {
  case $(uname -m) in
    aarch64|arm64 )
      ARGO_ARCH=arm64; XRAY_ARCH=arm64-v8a; JQ_ARCH=arm64; QRENCODE_ARCH=arm64
      ;;
    x86_64|amd64 )
      ARGO_ARCH=amd64; XRAY_ARCH=64; JQ_ARCH=amd64; QRENCODE_ARCH=amd64
      ;;
    armv7l )
      ARGO_ARCH=arm; XRAY_ARCH=arm32-v7a; JQ_ARCH=armhf; QRENCODE_ARCH=arm
      ;;
    * )
      error " $(text 25) "
  esac
}


# 本地化订阅模板：安全版不再从外部仓库下载 clash / sing-box 模板
write_local_clash_template() {
  local _out="$1"
  cat > "$_out" <<'LOCAL_CLASH_TEMPLATE'
mixed-port: 7890
allow-lan: true
bind-address: '*'
mode: rule
log-level: info
ipv6: true
external-controller: 127.0.0.1:10000

proxy-providers:
  NODE_NAME:
    type: http
    url: PROXY_PROVIDERS_URL
    interval: 3600
    path: ./profiles/NODE_NAME.yaml
    health-check:
      enable: true
      url: https://www.gstatic.com/generate_204
      interval: 300

proxy-groups:
  - name: 节点选择
    type: select
    use:
      - NODE_NAME
    proxies:
      - ♻️ 自动选择
      - DIRECT
  - name: ♻️ 自动选择
    type: url-test
    use:
      - NODE_NAME
    url: https://www.gstatic.com/generate_204
    interval: 300
    tolerance: 50
  - name: 漏网之鱼
    type: select
    use:
      - NODE_NAME
    proxies:
      - 节点选择
      - ♻️ 自动选择
      - DIRECT

rules:
  - GEOIP,LAN,DIRECT
  - GEOIP,CN,DIRECT
  - MATCH,漏网之鱼
LOCAL_CLASH_TEMPLATE
}

write_local_sing_box_template() {
  local _out="$1"
  cat > "$_out" <<'LOCAL_SING_BOX_TEMPLATE'
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "experimental": {
    "cache_file": {
      "enabled": true
    },
    "clash_api": {
      "external_controller": "127.0.0.1:9090",
      "default_mode": "rule"
    }
  },
  "dns": {
    "servers": [
      {
        "tag": "local",
        "address": "local"
      }
    ]
  },
  "inbounds": [
    {
      "type": "mixed",
      "tag": "mixed-in",
      "listen": "127.0.0.1",
      "listen_port": 7890
    }
  ],
  "outbounds": [
    "<OUTBOUND_REPLACE>",
    {
      "type": "selector",
      "tag": "Proxy",
      "outbounds": [
        "<NODE_REPLACE>",
        "direct"
      ]
    },
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "rules": [],
    "final": "Proxy"
  }
}
LOCAL_SING_BOX_TEMPLATE
}

write_xray_xhttp_pqc_ech_client() {
  local _out="$WORK_DIR/subscribe/xray-xhttp-pqc-ech.json"
  xhttp_split_runtime_values
  if ! has_xhttp_cdn_selected ||
     [[ "$ARGO_DOMAIN" =~ trycloudflare\.com$ ]] ||
     [ -z "$ARGO_DOMAIN" ] ||
     [ -z "$ECH_CLIENT_CONFIG" ] ||
     [ "${VLESS_CLIENT_ENCRYPTION:-none}" = 'none' ]; then
    rm -f "$_out" 2>/dev/null || true
    return 0
  fi

  local _split='false'
  truthy "${ENABLE_XHTTP_SPLIT:-n}" && _split='true'

  "$WORK_DIR/jq" -n \
    --arg server "$SERVER" \
    --arg port "${SERVER_PORT:-443}" \
    --arg uuid "$UUID" \
    --arg encryption "$VLESS_CLIENT_ENCRYPTION" \
    --arg sni "$ARGO_DOMAIN" \
    --arg path "/${WS_PATH}-xh" \
    --arg mode "${XHTTP_CDN_MODE:-packet-up}" \
    --arg ech "$ECH_CLIENT_CONFIG" \
    --argjson split "$_split" \
    --arg down_server "${XHTTP_DOWNLOAD_SERVER:-$SERVER}" \
    --arg down_port "${XHTTP_DOWNLOAD_PORT:-${SERVER_PORT:-443}}" '
    def tls($sni; $ech): {
      serverName: $sni,
      alpn: ["h2", "http/1.1"],
      fingerprint: "chrome",
      minVersion: "1.3",
      maxVersion: "1.3",
      curvePreferences: ["X25519MLKEM768", "X25519"],
      echConfigList: $ech
    };
    def down($addr; $port; $sni; $path; $ech): {
      address: $addr,
      port: ($port | tonumber),
      network: "xhttp",
      security: "tls",
      tlsSettings: tls($sni; $ech),
      xhttpSettings: {
        host: $sni,
        path: $path,
        extra: {xPaddingBytes: "100-1000"}
      }
    };
    {
      log: {loglevel: "warning"},
      inbounds: [
        {tag: "socks-in", listen: "127.0.0.1", port: 10808, protocol: "socks", settings: {udp: true}},
        {tag: "http-in", listen: "127.0.0.1", port: 10809, protocol: "http", settings: {}}
      ],
      outbounds: [
        {
          tag: "proxy",
          protocol: "vless",
          settings: {address: $server, port: ($port | tonumber), id: $uuid, encryption: $encryption},
          streamSettings: {
            network: "xhttp",
            security: "tls",
            tlsSettings: tls($sni; $ech),
            xhttpSettings: {
              host: $sni,
              path: $path,
              mode: $mode,
              extra: ({
                xPaddingBytes: "100-1000",
                noSSEHeader: true,
                scMaxEachPostBytes: "1000000-2000000",
                scMinPostsIntervalMs: "30-30",
                scMaxBufferedPosts: 30
              } + (if $split then {downloadSettings: down($down_server; $down_port; $sni; $path; $ech)} else {} end))
            }
          }
        },
        {tag: "direct", protocol: "freedom"},
        {tag: "block", protocol: "blackhole"}
      ],
      routing: {domainStrategy: "AsIs", rules: []}
    }' > "$_out" || {
      rm -f "$_out" 2>/dev/null || true
      error "
 Failed to generate the native Xray VLESS + XHTTP + PQC + ECH client configuration.
"
    }
  chmod 600 "$_out" 2>/dev/null || true

  # Validate against the exact Xray binary installed on the target VPS. This
  # catches future schema/core mismatches (PQC, ECH, XHTTP/downloadSettings)
  # before the generated client file is advertised to the user.
  if [ -x "$WORK_DIR/xray" ]; then
    local _xray_test_log="$TEMP_DIR/xray-client-test.log"
    if ! "$WORK_DIR/xray" run -test -c "$_out" >"$_xray_test_log" 2>&1; then
      warning "
 Native Xray client config validation failed. Xray reported:
"
      sed -n '1,120p' "$_xray_test_log" 2>/dev/null || true
      rm -f "$_out" 2>/dev/null || true
      error "
 Native Xray VLESS + XHTTP + PQC + ECH client config failed Xray run -test. 
"
    fi
    rm -f "$_xray_test_log" 2>/dev/null || true
  fi
}

qrencode_print() {
  local _data="$1"
  if [ -x "$WORK_DIR/qrencode" ]; then
    "$WORK_DIR/qrencode" "$_data" 2>/dev/null || true
  elif command -v qrencode >/dev/null 2>&1; then
    qrencode -t ANSIUTF8 "$_data" 2>/dev/null || true
  else
    echo "Local QR display unavailable: install package 'qrencode' to show terminal QR code."
  fi
}

# 查安装及运行状态，下标0: argo，下标1: xray，下标2: nginx；状态码: 26 未安装， 27 已安装未运行， 28 运行中
check_install() {
  [ -s $WORK_DIR/nginx.conf ] && IS_NGINX=is_nginx || IS_NGINX=no_nginx
  STATUS[0]=$(text 26)

  [ -s ${ARGO_DAEMON_FILE} ] && STATUS[0]=$(text 27) && cmd_systemctl status argo &>/dev/null && STATUS[0]=$(text 28)
  STATUS[1]=$(text 26)
  if [ -s ${XRAY_DAEMON_FILE} ]; then
    ! grep -q "$WORK_DIR" ${XRAY_DAEMON_FILE} && error " $(text 53)\n $(grep "${DAEMON_RUN_PATTERN}" ${XRAY_DAEMON_FILE}) "
    STATUS[1]=$(text 27) && cmd_systemctl status xray &>/dev/null && STATUS[1]=$(text 28)
  fi
  STATUS[2]=$(text 26)
  if [ "$IS_NGINX" = 'is_nginx' ]; then
    local _NGINX_PID=$(pgrep -f "nginx: master process" 2>/dev/null)
    [ -n "$_NGINX_PID" ] && STATUS[2]=$(text 28) || STATUS[2]=$(text 27)
  fi

  {
    write_local_clash_template "$TEMP_DIR/clash"
    write_local_sing_box_template "$TEMP_DIR/sing-box"
  } &

  mapfile -t CURRENT_PROTOCOLS < <(get_installed_protocols)

  [[ ${STATUS[0]} = "$(text 26)" ]] && [ ! -s $WORK_DIR/cloudflared ] && { wget -qO $TEMP_DIR/cloudflared ${GH_PROXY}https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$ARGO_ARCH >/dev/null 2>&1 && chmod +x $TEMP_DIR/cloudflared >/dev/null 2>&1; }&
  [[ ${STATUS[1]} = "$(text 26)" ]] && [ ! -s $WORK_DIR/xray ] && { wget -qO $TEMP_DIR/Xray.zip ${GH_PROXY}https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-$XRAY_ARCH.zip >/dev/null 2>&1; unzip -qo $TEMP_DIR/Xray.zip xray *.dat -d $TEMP_DIR >/dev/null 2>&1; }&
  [ ! -s $WORK_DIR/jq ] && { wget --continue -qO $TEMP_DIR/jq ${GH_PROXY}https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-$JQ_ARCH >/dev/null 2>&1 && chmod +x $TEMP_DIR/jq >/dev/null 2>&1; }&
  [ ! -s $WORK_DIR/qrencode ] && command -v qrencode >/dev/null 2>&1 && { mkdir -p "$WORK_DIR" >/dev/null 2>&1; ln -sf "$(command -v qrencode)" "$TEMP_DIR/qrencode" >/dev/null 2>&1; }&
}

# 为了适配 alpine，定义 cmd_systemctl 的函数
cmd_systemctl() {
  nginx_run() {
    $(command -v nginx) -c $WORK_DIR/nginx.conf
  }

  nginx_stop() {
    local NGINX_PID=$(ps -eo pid,args | awk -v work_dir="$WORK_DIR" '$0~(work_dir"/nginx.conf"){print $1;exit}')
    ss -nltp | awk -v p="$NGINX_PID" '$0 ~ "pid=" p "," {print $6}' | tr ',' '\n' | awk -F= '/^pid=/{print $2}' | sort -u | xargs -r kill -9 >/dev/null 2>&1
  }

  [ -s $WORK_DIR/nginx.conf ] && local IS_NGINX=is_nginx || local IS_NGINX=no_nginx
  local ENABLE_DISABLE=$1
  local APP=$2
  if [ "$ENABLE_DISABLE" = 'enable' ]; then
    if [ "$SYSTEM" = 'Alpine' ]; then
      rc-service $APP start >/dev/null 2>&1
      rc-update add $APP default >/dev/null 2>&1
    elif [ "$IS_CENTOS" = 'CentOS7' ]; then
      systemctl daemon-reload
      systemctl enable --now $APP >/dev/null 2>&1
      [[ "$APP" = 'xray' && "$IS_NGINX" = 'is_nginx' ]] && [ -s $WORK_DIR/nginx.conf ] && nginx_run
    else
      systemctl daemon-reload
      systemctl enable --now $APP >/dev/null 2>&1
    fi

  elif [ "$ENABLE_DISABLE" = 'disable' ]; then
    if [ "$SYSTEM" = 'Alpine' ]; then
      rc-service $APP stop >/dev/null 2>&1
      rc-update del $APP default >/dev/null 2>&1
    elif [ "$IS_CENTOS" = 'CentOS7' ]; then
      systemctl disable --now $APP >/dev/null 2>&1
      [[ "$APP" = 'xray' && "$IS_NGINX" = 'is_nginx' ]] && [ -s $WORK_DIR/nginx.conf ] && nginx_stop
    else
      systemctl disable --now $APP >/dev/null 2>&1
    fi
  elif [ "$ENABLE_DISABLE" = 'restart' ]; then
    if [ "$SYSTEM" = 'Alpine' ]; then
      rc-service $APP restart >/dev/null 2>&1
    elif [ "$IS_CENTOS" = 'CentOS7' ]; then
      systemctl daemon-reload
      systemctl restart $APP >/dev/null 2>&1
      [[ "$APP" = 'xray' && "$IS_NGINX" = 'is_nginx' ]] && [ -s $WORK_DIR/nginx.conf ] && nginx_run
    else
      systemctl daemon-reload
      systemctl restart $APP >/dev/null 2>&1
    fi
  elif [ "$ENABLE_DISABLE" = 'status' ]; then
    if [ "$SYSTEM" = 'Alpine' ]; then
      rc-service $APP status
    else
      systemctl is-active $APP
    fi
  fi
}

check_system_info() {
  [ -s /etc/os-release ] && SYS="$(awk -F '"' 'tolower($0) ~ /pretty_name/{print $2}' /etc/os-release)"
  [ -s /etc/os-release ] && OS_ID="$(awk -F '=' 'tolower($1) == "id" {gsub(/"/, "", $2); print tolower($2)}' /etc/os-release)"
  [ -s /etc/os-release ] && OS_LIKE="$(awk -F '=' 'tolower($1) == "id_like" {gsub(/"/, "", $2); print tolower($2)}' /etc/os-release)"
  [[ -z "$SYS" ]] && command -v hostnamectl >/dev/null 2>&1 && SYS="$(hostnamectl | awk -F ': ' 'tolower($0) ~ /operating system/{print $2}')"
  [[ -z "$SYS" ]] && command -v lsb_release >/dev/null 2>&1 && SYS="$(lsb_release -sd)"
  [[ -z "$SYS" && -s /etc/lsb-release ]] && SYS="$(awk -F '"' 'tolower($0) ~ /distrib_description/{print $2}' /etc/lsb-release)"
  [[ -z "$SYS" && -s /etc/redhat-release ]] && SYS="$(cat /etc/redhat-release)"
  [[ -z "$SYS" && -s /etc/issue ]] && SYS="$(sed -E '/^$|^\\/d' /etc/issue | awk -F '\\' '{print $1}' | sed 's/[ ]*$//g')"

  REGEX=("debian" "ubuntu" "centos|red hat|kernel|alma|rocky" "arch linux" "alpine" "fedora")
  RELEASE=("Debian" "Ubuntu" "CentOS" "Arch" "Alpine" "Fedora")
  PACKAGE_UPDATE=("apt -y update" "apt -y update" "yum -y update" "pacman -Sy" "apk update -f" "dnf -y update")
  PACKAGE_INSTALL=("apt -y install" "apt -y install" "yum -y install" "pacman -S --noconfirm" "apk add --no-cache" "dnf -y install")
  PACKAGE_UNINSTALL=("apt -y autoremove" "apt -y autoremove" "yum -y autoremove" "pacman -Rcnsu --noconfirm" "apk del -f" "dnf -y autoremove")

  if [ "$OS_ID" = 'armbian' ]; then
    if [[ "$OS_LIKE" =~ ubuntu ]]; then
      SYSTEM='Ubuntu'
      int=1
    else
      SYSTEM='Debian'
      int=0
    fi
    SYS="${SYS:-Armbian}"
  else
    for int in "${!REGEX[@]}"; do
      [[ "${SYS,,}" =~ ${REGEX[int]} ]] && SYSTEM="${RELEASE[int]}" && break
    done
  fi
  if [ -z "$SYSTEM" ]; then
    command -v yum >/dev/null 2>&1 && int=2 && SYSTEM='CentOS' || error " $(text 5) "
  fi

  ARGO_DAEMON_FILE='/etc/systemd/system/argo.service'; XRAY_DAEMON_FILE='/etc/systemd/system/xray.service'; DAEMON_RUN_PATTERN="ExecStart="
  if [ "$SYSTEM" = 'CentOS' ]; then
    IS_CENTOS="CentOS$(echo "$SYS" | sed "s/[^0-9.]//g" | cut -d. -f1)"
  elif [ "$SYSTEM" = 'Alpine' ]; then
    ARGO_DAEMON_FILE='/etc/init.d/argo'; XRAY_DAEMON_FILE='/etc/init.d/xray'; DAEMON_RUN_PATTERN="command_args="
  fi

  if command -v systemd-detect-virt >/dev/null 2>&1; then
    VIRT=$(systemd-detect-virt)
  elif grep -qa container= /proc/1/environ 2>/dev/null; then
    VIRT=$(tr '\0' '\n' </proc/1/environ | awk -F= '/container=/{print $2; exit}')
  elif grep -Eq '(lxc|docker|kubepods|containerd)' /proc/1/cgroup 2>/dev/null; then
    VIRT=$(grep -Eo '(lxc|docker|kubepods|containerd)' /proc/1/cgroup | sed -n 1p)
  elif command -v hostnamectl >/dev/null 2>&1; then
    VIRT=$(hostnamectl | awk '/Virtualization/{print $NF}')
  else
    command -v virt-what >/dev/null 2>&1 && ${PACKAGE_INSTALL[int]} virt-what >/dev/null 2>&1
    command -v virt-what >/dev/null 2>&1 && VIRT=$(virt-what | sed -n 1p) || VIRT=unknown
  fi
}

# 检测 IPv4 IPv6 信息
# 安全本地化版：不再访问任何第三方 IP 查询接口。
# 只读取本机默认网卡地址作为显示/默认值；公网 IP 如需用于直连协议，请在安装交互中手动输入。
check_system_ip() {
  local DEFAULT_LOCAL_INTERFACE4 DEFAULT_LOCAL_INTERFACE6 DEFAULT_LOCAL_IP4 DEFAULT_LOCAL_IP6
  DEFAULT_LOCAL_INTERFACE4=$(ip -4 route show default 2>/dev/null | awk '/default/ {for (i=0; i<NF; i++) if ($i=="dev") {print $(i+1); exit}}')
  DEFAULT_LOCAL_INTERFACE6=$(ip -6 route show default 2>/dev/null | awk '/default/ {for (i=0; i<NF; i++) if ($i=="dev") {print $(i+1); exit}}')

  [ -n "$DEFAULT_LOCAL_INTERFACE4" ] && DEFAULT_LOCAL_IP4=$(ip -4 addr show "$DEFAULT_LOCAL_INTERFACE4" 2>/dev/null | sed -n 's#.*inet \([^/]*\)/[0-9]*.*global.*#\1#gp' | head -1)
  [ -n "$DEFAULT_LOCAL_INTERFACE6" ] && DEFAULT_LOCAL_IP6=$(ip -6 addr show "$DEFAULT_LOCAL_INTERFACE6" 2>/dev/null | sed -n 's#.*inet6 \([^/]*\)/[0-9]*.*global.*#\1#gp' | head -1)

  WAN4=${WAN4:-$DEFAULT_LOCAL_IP4}
  WAN6=${WAN6:-$DEFAULT_LOCAL_IP6}
  COUNTRY4=${COUNTRY4:-local}
  COUNTRY6=${COUNTRY6:-local}
  ASNORG4=${ASNORG4:-local-only-no-external-ip-query}
  ASNORG6=${ASNORG6:-local-only-no-external-ip-query}
  EMOJI4=${EMOJI4:-}
  EMOJI6=${EMOJI6:-}

  if [ -n "$SERVER_IP" ]; then
    SERVER_IP_DEFAULT="$SERVER_IP"
  elif [ -n "$WAN4" ]; then
    SERVER_IP_DEFAULT="$WAN4"
  elif [ -n "$WAN6" ]; then
    SERVER_IP_DEFAULT="$WAN6"
  else
    SERVER_IP_DEFAULT=''
  fi
}

# 定义 Argo 变量（协议选择已在 xray_variable 中完成，此处只处理隧道配置）
argo_variable() {
  [ "${INSTALL_NGINX,,}" != 'n' ] && {
    if ! command -v nginx >/dev/null 2>&1; then
      info "\n $(text 7) nginx \n"
      ${PACKAGE_INSTALL[int]} nginx >/dev/null 2>&1
      [ "$SYSTEM" != 'Alpine' ] && systemctl disable --now nginx >/dev/null 2>&1
    fi
  } >/dev/null 2>&1 &
  NGINX_PORT=${NGINX_PORT:-"$NGINX_PORT_DEFAULT"}

  if [ -z "$SERVER_IP" ]; then
    check_system_ip
    SERVER_IP="$SERVER_IP_DEFAULT"
  fi

  if [ ! -d $WORK_DIR ]; then
    [ -z "$SERVER_IP" ] && error " $(text 58) "

    [[ "$SERVER_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && CHATGPT_STACK='-4' || CHATGPT_STACK='-6'
    if [ "$(check_chatgpt ${CHATGPT_STACK})" = 'unlock' ]; then
      CHAT_GPT_OUT_V4=direct && CHAT_GPT_OUT_V6=direct
    else
      CHAT_GPT_OUT_V4=warp-IPv4 && CHAT_GPT_OUT_V6=warp-IPv6
    fi
  fi

  ARGO_DOMAIN=$(sed 's/[ ]*//g; s/:[ ]*//' <<< "$ARGO_DOMAIN")

  unset ARGO_TOKEN ARGO_JSON
  if is_cloudflare_tunnel_json "$ARGO_AUTH"; then
    ARGO_JSON=$(printf '%s' "$ARGO_AUTH" | tr -d '[:space:]')
  elif is_cloudflare_tunnel_token "$ARGO_AUTH"; then
    ARGO_TOKEN="$ARGO_AUTH"
  elif [[ "${#ARGO_AUTH}" =~ ^[3-6][0-9]$ ]]; then
    hint "\n $(text 78) \n "
    create_argo_tunnel "${ARGO_AUTH}" "${ARGO_DOMAIN}" "${NGINX_PORT}"
    if [[ ! "$ARGO_JSON" =~ TunnelSecret ]]; then
      hint "\n $(text 80) \n "
      unset ARGO_DOMAIN
    fi
  fi

  # A named tunnel must never silently fall back to Quick Tunnel. This also
  # catches unchanged placeholders in non-interactive configuration files.
  if [[ -n "$ARGO_DOMAIN" && ! "$ARGO_DOMAIN" =~ trycloudflare\.com$ ]]; then
    is_fixed_argo_domain "$ARGO_DOMAIN" || error " $(text 45) "
    if [ -z "${ARGO_TOKEN:-}" ] && [ -z "${ARGO_JSON:-}" ]; then
      error " $(text 45) "
    fi
  fi
}

# 定义 Xray 变量（含协议选择交互）
# 根据 INSTALL_PROTOCOLS 计算安装流程总步骤数
calc_install_steps() {
  local _total=7  # 固定步骤：协议选择、起始端口、Nginx端口、VPS IP、Argo域名、UUID、节点名
  local _has_reality=false _has_ws_xhttp=false _has_hy2=false
  for _p in "${INSTALL_PROTOCOLS[@]}"; do
    [[ "$_p" =~ ^[bd]$ ]] && _has_reality=true
    [[ "$_p" =~ ^[efghi]$ ]] && _has_ws_xhttp=true
    [[ "$_p" == 'c' ]] && _has_hy2=true
  done
  grep -q 'noninteractive_install' <<< "$NONINTERACTIVE_INSTALL" && (( _total-- ))  # 非交互安装时不单独询问 VPS IP
  $_has_reality && (( _total += 2 ))  # Reality 连接域名 + 密钥
  $_has_ws_xhttp && (( _total += 2 ))  # CDN 域名 + WS 路径
  $_has_hy2 && (( _total++ ))          # 端口跳跃
  TOTAL_STEPS=$_total
}

# 生成 Reality 密钥对
generate_reality_keypair() {
  local KEYPAIR
  local _XRAY_BIN="$TEMP_DIR/xray"
  [ ! -x "$_XRAY_BIN" ] && _XRAY_BIN="$WORK_DIR/xray"

  # 如果 xray 二进制文件尚不可用（如非交互式安装且下载未完成），则回退到 openssl 生成
  if [ -x "$_XRAY_BIN" ]; then
    KEYPAIR=$($_XRAY_BIN x25519)
    REALITY_PRIVATE=$(awk '/Private/{print $NF}' <<< "$KEYPAIR")
    REALITY_PUBLIC=$(awk '/Public/{print $NF}' <<< "$KEYPAIR")
  else
    # 回退逻辑：使用 openssl 生成私钥并派生公钥
    ! command -v openssl >/dev/null 2>&1 && return
    REALITY_PRIVATE=$(openssl genpkey -algorithm x25519 -outform DER 2>/dev/null | tail -c 32 | base64 | tr '/+' '_-' | tr -d '=')
    REALITY_PUBLIC=''
  fi
}

# 定义 Xray 相关变量，包含协议选择交互和相关配置
xray_variable() {
  local STEP_NUM=0
  local TOTAL_STEPS=''
  # Pre-calculate the maximum step count with all protocols selected for prompt display.
  local _saved_protocols=("${INSTALL_PROTOCOLS[@]}")
  local _all_protocol_letters=''
  local _idx
  for _idx in "${!PROTOCOL_LIST[@]}"; do
    _all_protocol_letters+="$(asc $((98 + _idx))) "
  done
  read -r -a INSTALL_PROTOCOLS <<< "$STABLE_DEFAULT_PROTOCOLS"
  calc_install_steps
  INSTALL_PROTOCOLS=("${_saved_protocols[@]}")
  # 兼容 config.conf 字符串写法：INSTALL_PROTOCOLS='bcef' → 拆成 (b c e f)
  if [[ "${#INSTALL_PROTOCOLS[@]}" -eq 1 && ! "${INSTALL_PROTOCOLS[0]}" =~ ^[[:space:]]*$ ]]; then
    local _proto_str="${INSTALL_PROTOCOLS[0]}"
    if [[ "$_proto_str" =~ ^[aA]$ ]]; then
      read -r -a INSTALL_PROTOCOLS <<< "$STABLE_DEFAULT_PROTOCOLS"
    elif [[ "${#_proto_str}" -gt 1 ]]; then
      INSTALL_PROTOCOLS=()
      while IFS= read -r -n1 _ch; do
        [ -n "$_ch" ] && INSTALL_PROTOCOLS+=("$_ch")
      done <<< "$_proto_str"
    fi
  fi
  (( STEP_NUM++ )) || true
  if ! grep -q 'noninteractive_install' <<< "$NONINTERACTIVE_INSTALL" && [ -z "${INSTALL_PROTOCOLS[*]}" ]; then
    hint "\n $(text 87)"
    hint "$(text 100)"
    for p in "${!PROTOCOL_LIST[@]}"; do
      local letter=$(asc $((p + 98)))
      local p_name="${PROTOCOL_LIST[p]}"
      [ "$letter" = "i" ] && p_name=$(text 101)
      hint " ${letter}. ${p_name}"
    done
    reading "\n $(text 24) " CHOOSE_PROTOCOLS
  fi

  if [ -z "${INSTALL_PROTOCOLS[*]}" ]; then
    local MAX_LETTER=$(asc $((97 + ${#PROTOCOL_LIST[@]})))
    if [[ -z "$CHOOSE_PROTOCOLS" || "${CHOOSE_PROTOCOLS,,}" =~ ^a$ ]]; then
      read -r -a INSTALL_PROTOCOLS <<< "$STABLE_DEFAULT_PROTOCOLS"
    else
      local filtered
      filtered=$(grep -o . <<< "${CHOOSE_PROTOCOLS,,}" | grep -E "^[b-${MAX_LETTER}]$" | awk '!seen[$0]++' | tr -d '\n')
      [ -z "$filtered" ] && read -r -a INSTALL_PROTOCOLS <<< "$STABLE_DEFAULT_PROTOCOLS" || {
        INSTALL_PROTOCOLS=()
        while IFS= read -r -n1 ch; do
          [ -n "$ch" ] && INSTALL_PROTOCOLS+=("$ch")
        done <<< "$filtered"
      }
    fi
  fi

  # 强化版默认只保留 VLESS 家族协议，VMess/Trojan/SS 需显式 ALLOW_LEGACY_PROTOCOLS='y'
  filter_protocols_for_strong_mode

  # 协议已确定，计算总步骤数
  calc_install_steps

  # 显示选择协议及其次序，输入开始端口号
  if ! grep -q 'noninteractive_install' <<< "$NONINTERACTIVE_INSTALL" && [ -z "$START_PORT" ]; then
    hint "\n $(text 124) "
    for w in "${!INSTALL_PROTOCOLS[@]}"; do
      local _proto_idx=$(($(asc ${INSTALL_PROTOCOLS[w]}) - 98))
      local _proto_name="${PROTOCOL_LIST[$_proto_idx]}"
      [ "$w" -ge 9 ] && hint " $(( w+1 )). ${_proto_name} " || hint " $(( w+1 )) . ${_proto_name} "
    done
  fi

  local NUM=${#INSTALL_PROTOCOLS[@]}
  if ! grep -q 'noninteractive_install' <<< "$NONINTERACTIVE_INSTALL" && [ -z "$START_PORT" ]; then
    (( STEP_NUM++ )) || true
    input_start_port "$NUM"
  fi
  START_PORT=${START_PORT:-"$START_PORT_DEFAULT"}
  grep -q 'noninteractive_install' <<< "$NONINTERACTIVE_INSTALL" && SERVER_IP=${SERVER_IP:-"$SERVER_IP_DEFAULT"}
  TLS_SERVER=${TLS_SERVER:-"addons.mozilla.org"}

  for i in "${!INSTALL_PROTOCOLS[@]}"; do
    local p="${INSTALL_PROTOCOLS[$i]}"
    case "$p" in
      b) REALITY_PORT=$(( START_PORT + i )) ;;
      c) HY2_PORT=$(( START_PORT + i )) ;;
      d) GRPC_PORT=$(( START_PORT + i )) ;;
      e) VLESS_WS_PORT=$(( START_PORT + i )) ;;
      f) VMESS_WS_PORT=$(( START_PORT + i )) ;;
      g) TROJAN_WS_PORT=$(( START_PORT + i )) ;;
      h) SS_WS_PORT=$(( START_PORT + i )) ;;
      i) VLESS_XHTTP_PORT=$(( START_PORT + i )) ;;
      j) XHTTP_PORT=$(( START_PORT + i )) ;;
      k) TROJAN_PORT=$(( START_PORT + i )) ;;
      l) SS2022_PORT=$(( START_PORT + i )) ;;
    esac
  done

  INSTALL_NGINX="y"
  if ! grep -q 'noninteractive_install' <<< "$NONINTERACTIVE_INSTALL" && [ -z "$NGINX_PORT" ]; then
    (( STEP_NUM++ )) || true
    input_nginx_port
  fi
  NGINX_PORT=${NGINX_PORT:-"$NGINX_PORT_DEFAULT"}

  if ! grep -q 'noninteractive_install' <<< "$NONINTERACTIVE_INSTALL"; then
    (( STEP_NUM++ )) || true
    reading "\n $(text 59) " SERVER_IP
  fi
  SERVER_IP=${SERVER_IP:-"$SERVER_IP_DEFAULT"}

  if ! grep -q 'noninteractive_install' <<< "$NONINTERACTIVE_INSTALL"; then
    if [ -z "$ARGO_DOMAIN" ]; then
      (( STEP_NUM++ )) || true
      reading "\n $(text 10) " ARGO_DOMAIN
    fi
    if [[ -n "$ARGO_DOMAIN" && ! "$ARGO_DOMAIN" =~ trycloudflare\.com$ && -z "$ARGO_AUTH" ]]; then
      hint "\n $(text 11)"
      reading "\n $(text 86) " ARGO_AUTH
    fi
  fi

  # 稳定版保护：使用临时 trycloudflare.com / 未绑定固定域名时，保留 WS 与手动选择的 Reality。
  # Reality 客户端连接地址可由 REALITY_DOMAIN 或 SERVER_IP 独立控制；其他直连协议仍默认过滤，
  # 避免 Quick Tunnel 场景生成不可用配置，甚至导致 Xray 启动失败。
  if [[ -z "$ARGO_DOMAIN" || "$ARGO_DOMAIN" =~ trycloudflare\.com$ ]]; then
    local _stable_filtered=() _p
    for _p in "${INSTALL_PROTOCOLS[@]}"; do
      [[ " $_p " =~ ^[[:space:]]*[bdefgh][[:space:]]*$ ]] && _stable_filtered+=("$_p")
    done
    if [ "${#_stable_filtered[@]}" -eq 0 ]; then
      read -r -a INSTALL_PROTOCOLS <<< "$STABLE_DEFAULT_PROTOCOLS"
    else
      INSTALL_PROTOCOLS=("${_stable_filtered[@]}")
    fi
  fi

  filter_protocols_for_strong_mode

  local HAS_REALITY=false
  for p in "${INSTALL_PROTOCOLS[@]}"; do [[ "$p" =~ ^[bd]$ ]] && HAS_REALITY=true && break; done
  if $HAS_REALITY; then
    if [ -z "${REALITY_DOMAIN:-}" ] && [ -s "$CUSTOM_FILE" ]; then
      local _rd_in_custom
      _rd_in_custom=$(awk -F= '/^realityDomain=/{print $2}' "$CUSTOM_FILE")
      [[ -n "$_rd_in_custom" && "$_rd_in_custom" != '__REALITY_DOMAIN_UNSET__' ]] && REALITY_DOMAIN="$_rd_in_custom"
    fi
    [[ "${REALITY_DOMAIN:-}" == '__REALITY_DOMAIN_UNSET__' ]] && REALITY_DOMAIN=''
    if ! grep -q 'noninteractive_install' <<< "$NONINTERACTIVE_INSTALL"; then
      (( STEP_NUM++ )) || true
      local _REALITY_DOMAIN_PROMPT="${REALITY_DOMAIN:-}"
      reading "
 $(text 126) " _REALITY_DOMAIN_PROMPT
      REALITY_DOMAIN="${_REALITY_DOMAIN_PROMPT//[[:space:]]/}"
    else
      REALITY_DOMAIN="${REALITY_DOMAIN//[[:space:]]/}"
    fi
    [ -n "${REALITY_DOMAIN:-}" ] && validate_reality_addr "$REALITY_DOMAIN" || true
    if [ -n "${REALITY_DOMAIN:-}" ] && ! validate_reality_addr "$REALITY_DOMAIN"; then
      error " $(text 127) "
    fi

    if [ -z "$REALITY_PRIVATE" ] && [ -s "$CUSTOM_FILE" ]; then
      local _pk_in_custom
      _pk_in_custom=$(awk -F= '/^privateKey=/{print $2}' "$CUSTOM_FILE")
      [[ -n "$_pk_in_custom" && "$_pk_in_custom" != '__KEY_UNSET__' ]] && REALITY_PRIVATE="$_pk_in_custom"
      [[ -n "$REALITY_PRIVATE" && "$REALITY_PRIVATE" != '__KEY_UNSET__' ]] && REALITY_PUBLIC=$(awk -F= '/^publicKey=/{print $2}' "$CUSTOM_FILE")
    fi
    [[ "$REALITY_PRIVATE" == '__KEY_UNSET__' ]] && REALITY_PRIVATE=''
    [[ "$REALITY_PUBLIC" == '__KEY_UNSET__' ]] && REALITY_PUBLIC=''
    if [ -z "$REALITY_PRIVATE" ]; then
      if ! grep -q 'noninteractive_install' <<< "$NONINTERACTIVE_INSTALL"; then
        (( STEP_NUM++ )) || true
        reading "\n $(text 98) " REALITY_PRIVATE
      fi
      if [ -z "$REALITY_PRIVATE" ]; then
        generate_reality_keypair
      else
        # 从私钥生成公钥：优先使用 OpenSSL 本地生成，回退使用远程 API
        if command -v xxd >/dev/null 2>&1; then
          local B64 MOD PREFIX_HEX PRIV_HEX PRIV_LEN
          B64=$(printf '%s' "$REALITY_PRIVATE" | tr '_-' '/+')
          MOD=$(( ${#B64} % 4 ))
          if [ "$MOD" -eq 2 ]; then
            B64="${B64}=="
          elif [ "$MOD" -eq 3 ]; then
            B64="${B64}="
          elif [ "$MOD" -ne 0 ]; then
            B64=''
          fi

          if [ -n "$B64" ] && echo "$B64" | base64 -d > "$TEMP_DIR/_X25519_PRIV_RAW" 2>/dev/null; then
            PRIV_LEN=$(stat -c%s "$TEMP_DIR/_X25519_PRIV_RAW" 2>/dev/null || stat -f%z "$TEMP_DIR/_X25519_PRIV_RAW")
            if [ "$PRIV_LEN" -eq 32 ]; then
              PREFIX_HEX="302e020100300506032b656e04220420"
              PRIV_HEX=$(xxd -p -c 256 "$TEMP_DIR/_X25519_PRIV_RAW" | tr -d '\n')
              printf "%s%s" "$PREFIX_HEX" "$PRIV_HEX" | xxd -r -p > "$TEMP_DIR/_X25519_PRIV_DER"
              if openssl pkcs8 -inform DER -in "$TEMP_DIR/_X25519_PRIV_DER" -nocrypt -out "$TEMP_DIR/_X25519_PRIV_PEM" 2>/dev/null && \
                 openssl pkey -in "$TEMP_DIR/_X25519_PRIV_PEM" -pubout -outform DER > "$TEMP_DIR/_X25519_PUB_DER" 2>/dev/null; then
                tail -c 32 "$TEMP_DIR/_X25519_PUB_DER" > "$TEMP_DIR/_X25519_PUB_RAW"
                REALITY_PUBLIC=$(base64 -w0 "$TEMP_DIR/_X25519_PUB_RAW" | tr '+/' '-_' | sed -E 's/=+$//')
              fi
            fi
          fi
        fi

        # Safe edition: remote Reality public-key API disabled; never send private key to third party.

        # 都失败，生成随机密钥对
        if [ -z "$REALITY_PUBLIC" ]; then
          warning " $(text 99) "
          generate_reality_keypair
        fi
      fi
    fi
  fi

  local _HAS_WS_XHTTP=false _HAS_XHTTP_DIRECT=false
  for p in "${INSTALL_PROTOCOLS[@]}"; do
    [[ "$p" =~ ^[efghi]$ ]] && _HAS_WS_XHTTP=true && break
  done
  for p in "${INSTALL_PROTOCOLS[@]}"; do
    [[ "$p" == 'j' ]] && _HAS_XHTTP_DIRECT=true && break
  done

  if [ -z "$SERVER" ]; then
    if $_HAS_WS_XHTTP; then
      if ! grep -q 'noninteractive_install' <<< "$NONINTERACTIVE_INSTALL"; then
        (( STEP_NUM++ )) || true
        echo ""
        for c in "${!CDN_DOMAIN[@]}"; do
          hint " $((c+1)). ${CDN_DOMAIN[c]} "
        done
        reading "\n $(text 42) " CUSTOM_CDN
      fi
      case "$CUSTOM_CDN" in
        [1-9]|[1-9][0-9] )
          [ "$CUSTOM_CDN" -le "${#CDN_DOMAIN[@]}" ] && SERVER="${CDN_DOMAIN[$((CUSTOM_CDN-1))]}" || SERVER="${CDN_DOMAIN[0]}"
          SERVER_PORT=443
          ;;
        ?????* )
          parse_preferred_addr "$CUSTOM_CDN" || error " $(text 118) "
          SERVER="$PREFERRED_ADDR"
          SERVER_PORT="$PREFERRED_PORT"
          ;;
        * )
          SERVER="${CDN_DOMAIN[0]}"
          SERVER_PORT=443
      esac
    else
      SERVER='__CDN_UNSET__'
      SERVER_PORT=443
    fi
  fi

  if [[ -n "$SERVER" && "$SERVER" != '__CDN_UNSET__' ]]; then
    parse_preferred_addr "${SERVER}:${SERVER_PORT:-443}" || error " $(text 118) "
    SERVER="$PREFERRED_ADDR"
    SERVER_PORT="$PREFERRED_PORT"
    SERVER_DISPLAY="$PREFERRED_DISPLAY"
  fi

  if [[ " ${INSTALL_PROTOCOLS[*]} " =~ " c " ]]; then
    if ! grep -q 'noninteractive_install' <<< "$NONINTERACTIVE_INSTALL"; then
      (( STEP_NUM++ )) || true
      input_hopping_port
    elif [ -n "$PORT_HOPPING_RANGE" ]; then
      # 非交互模式：config.conf 填了 PORT_HOPPING_RANGE，直接解析
      local _R=${PORT_HOPPING_RANGE//-/:}
      PORT_HOPPING_RANGE=$_R
      PORT_HOPPING_START=${_R%:*}
      PORT_HOPPING_END=${_R#*:}
      IS_HOPPING=is_hopping
    fi
    IS_HOPPING=${IS_HOPPING:-no_hopping}
  fi

  if $_HAS_WS_XHTTP; then
    if ! grep -q 'noninteractive_install' <<< "$NONINTERACTIVE_INSTALL" && [ -z "$WS_PATH" ]; then
      (( STEP_NUM++ )) || true
      reading "\n $(text 13) " WS_PATH
    fi
    local a=5
    until [[ -z "$WS_PATH" || "$WS_PATH" =~ ^[A-Za-z0-9_.@-]+$ ]]; do
      (( a-- )) || true
      [ "$a" = 0 ] && error " $(text 3) " || reading " $(text 14) " WS_PATH
    done
    WS_PATH=${WS_PATH:-"$WS_PATH_DEFAULT"}
  fi

  if $_HAS_XHTTP_DIRECT && [[ ! " ${INSTALL_PROTOCOLS[*]} " =~ " c " ]]; then
    info "\n XHTTP Direct TLS certificate: ${WORK_DIR}/cert/cert.pem \n"
  fi

  local _uuid_step_done=false
  local a=6
  until [[ "${UUID,,}" =~ ^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ ]]; do
    (( a-- )) || true
    [ "$a" = 0 ] && error "\n $(text 3) \n"
    UUID_DEFAULT=$(cat /proc/sys/kernel/random/uuid)
    if ! grep -q 'noninteractive_install' <<< "$NONINTERACTIVE_INSTALL"; then
      $_uuid_step_done || { (( STEP_NUM++ )) || true; _uuid_step_done=true; }
      reading "\n $(text 12) " UUID
    fi
    UUID=${UUID:-"$UUID_DEFAULT"}
    [[ ! "${UUID,,}" =~ ^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ ]] && warning "\n $(text 4) "
  done

  local EMOJI_VAL="${EMOJI4:-$EMOJI6}"
  if [ -z "$NODE_NAME" ]; then
    if command -v hostname >/dev/null 2>&1; then
      local HOST_NAME=$(hostname)
    elif [ -s /etc/hostname ]; then
      local HOST_NAME=$(cat /etc/hostname)
    else
      local HOST_NAME="ArgoX"
    fi
    NODE_NAME_DEFAULT="${EMOJI_VAL}${EMOJI_VAL:+ }${HOST_NAME}"
    if ! grep -q 'noninteractive_install' <<< "$NONINTERACTIVE_INSTALL"; then
      (( STEP_NUM++ )) || true
      reading "\n $(text 49) " NODE_NAME
    fi
    NODE_NAME=${NODE_NAME:-"$HOST_NAME"}
  fi
  grep -q 'noninteractive_install' <<< "$NONINTERACTIVE_INSTALL" || NODE_NAME="${EMOJI_VAL}${EMOJI_VAL:+ }${NODE_NAME}"
  # 防止主机名或自定义节点名中的引号/反斜杠/控制字符破坏 Xray JSON。
  NODE_NAME=$(printf '%s' "$NODE_NAME" | tr -d '\r\n\t' | sed 's/["\\]/_/g')
}

# 快速安装变量初始化
fast_install_variables() {
  local _all_protocol_letters=''
  local _idx
  for _idx in "${!PROTOCOL_LIST[@]}"; do
    _all_protocol_letters+="$(asc $((98 + _idx))) "
  done
  read -r -a INSTALL_PROTOCOLS <<< "$STABLE_DEFAULT_PROTOCOLS"

  START_PORT=${START_PORT:-"$START_PORT_DEFAULT"}
  for i in "${!INSTALL_PROTOCOLS[@]}"; do
    local p="${INSTALL_PROTOCOLS[$i]}"
    case "$p" in
      b) REALITY_PORT=$(( START_PORT + i )) ;;
      c) HY2_PORT=$(( START_PORT + i )) ;;
      d) GRPC_PORT=$(( START_PORT + i )) ;;
      e) VLESS_WS_PORT=$(( START_PORT + i )) ;;
      f) VMESS_WS_PORT=$(( START_PORT + i )) ;;
      g) TROJAN_WS_PORT=$(( START_PORT + i )) ;;
      h) SS_WS_PORT=$(( START_PORT + i )) ;;
      i) VLESS_XHTTP_PORT=$(( START_PORT + i )) ;;
      j) XHTTP_PORT=$(( START_PORT + i )) ;;
      k) TROJAN_PORT=$(( START_PORT + i )) ;;
      l) SS2022_PORT=$(( START_PORT + i )) ;;
    esac
  done

  # 极速安装模式：如果填了 PORT_HOPPING_RANGE，自动解析并启用端口跳跃
  if [ -z "$IS_HOPPING" ] && [ -n "$PORT_HOPPING_RANGE" ]; then
    local _R=${PORT_HOPPING_RANGE//-/:}
    PORT_HOPPING_RANGE=$_R
    PORT_HOPPING_START=${_R%:*}
    PORT_HOPPING_END=${_R#*:}
    IS_HOPPING=is_hopping
  fi
  IS_HOPPING=${IS_HOPPING:-no_hopping}

  SERVER=${SERVER:-"${CDN_DOMAIN[0]}"}
  SERVER_PORT=${SERVER_PORT:-${cdnPort:-443}}
  if [ "$SERVER" != '__CDN_UNSET__' ]; then
    parse_preferred_addr "${SERVER}:${SERVER_PORT}" || error " $(text 118) "
    SERVER="$PREFERRED_ADDR"
    SERVER_PORT="$PREFERRED_PORT"
    SERVER_DISPLAY="$PREFERRED_DISPLAY"
  fi
  UUID=${UUID:-$(cat /proc/sys/kernel/random/uuid)}
  WS_PATH=${WS_PATH:-"$WS_PATH_DEFAULT"}
  NGINX_PORT=${NGINX_PORT:-"$NGINX_PORT_DEFAULT"}

  check_system_ip
  SERVER_IP=${SERVER_IP:-$SERVER_IP_DEFAULT}
  local EMOJI_VAL="${EMOJI4:-$EMOJI6}"
  if command -v hostname >/dev/null 2>&1; then
    local HOST_NAME=$(hostname)
  elif [ -s /etc/hostname ]; then
    local HOST_NAME=$(cat /etc/hostname)
  else
    local HOST_NAME="ArgoX"
  fi
  NODE_NAME="${EMOJI_VAL}${EMOJI_VAL:+ }${HOST_NAME}"
  NODE_NAME=$(printf '%s' "$NODE_NAME" | tr -d '\r\n\t' | sed 's/["\\]/_/g')
}

find_available_tcp_port() {
  local _start="$1" _end="$2" _port
  refresh_port_snapshot
  for ((_port=_start; _port<=_end; _port++)); do
    if ! is_port_in_use "$_port"; then
      printf '%s' "$_port"
      return 0
    fi
  done
  return 1
}

apply_guided_xhttp_infra_defaults() {
  local _path_seed

  INSTALL_PROTOCOLS=(i)
  REINSTALL_TAGS=()
  ALLOW_LEGACY_PROTOCOLS='n'

  # 这些是内部实现细节，不在用户需要逐项确认的关键参数列表内，
  # 保持固定安全默认值即可。
  VLESS_PQC_REQUIRE_PREFIX='mlkem768x25519plus'
  VLESS_PQC_RESUME='600s'
  VLESS_PQC_CLIENT_RTT='1rtt'
  VLESS_PQC_DECRYPTION=''
  VLESS_PQC_ENCRYPTION=''
  ECH_CONFIG=''
  ENABLE_XHTTP_SPLIT='n'
  XHTTP_DOWNLOAD_SERVER=''
  XHTTP_DOWNLOAD_PORT=''

  SERVER_PORT='443'
  START_PORT=$(find_available_tcp_port "$START_PORT_DEFAULT" "$MAX_PORT") || error " $(text 61) ${START_PORT_DEFAULT}-${MAX_PORT} "

  # A token-based Tunnel is remotely managed: its Public Hostname service port
  # is configured in Cloudflare, so silently changing 8080 -> 8081/8082 would
  # make cloudflared healthy while the edge returns 502. Keep the requested
  # local origin port exact and fail if it is occupied. JSON/local-config mode
  # can safely choose another free port because tunnel.yml owns the ingress.
  if is_cloudflare_tunnel_token "${ARGO_AUTH:-}"; then
    NGINX_PORT="${NGINX_PORT:-$NGINX_PORT_DEFAULT}"
    [[ "$NGINX_PORT" =~ ^[1-9][0-9]{1,4}$ ]] && [ "$NGINX_PORT" -le 65535 ] || error " $(text 68) "
    is_port_in_use "$NGINX_PORT" && error " $(text 61) ${NGINX_PORT} "
  else
    if [ -z "${NGINX_PORT:-}" ]; then
      NGINX_PORT=$(find_available_tcp_port "$NGINX_PORT_DEFAULT" "$MAX_PORT") || error " $(text 61) ${NGINX_PORT_DEFAULT}-${MAX_PORT} "
    fi
  fi

  UUID=$(cat /proc/sys/kernel/random/uuid)
  _path_seed=$(cat /proc/sys/kernel/random/uuid | tr -d '-')
  WS_PATH="xh${_path_seed:0:16}"
  NODE_NAME=''
  REALITY_DOMAIN=''
  REALITY_PRIVATE=''
  TLS_SERVER='addons.mozilla.org'
  PORT_HOPPING_RANGE=''
  check_system_ip
  SERVER_IP=${SERVER_IP:-$SERVER_IP_DEFAULT}
}

# 逐项确认一个 y/n 开关：直接回车采用默认值；输入 y/n（及常见同义词）覆盖；
# 输入既不是空也不能识别为 y/n 时，提示无效并回退默认值。
reading_yn() {
  local _prompt_text="$1" _var_name="$2" _default="$3" _input=''
  reading "\n ${_prompt_text} [y/n, $(text 149): ${_default}] " _input
  if [ -z "$_input" ]; then
    printf -v "$_var_name" '%s' "$_default"
    return 0
  fi
  case "${_input,,}" in
    y|yes|true|1|on|enable|enabled|开启|是)
      printf -v "$_var_name" '%s' 'y' ;;
    n|no|false|0|off|disable|disabled|关闭|否)
      printf -v "$_var_name" '%s' 'n' ;;
    *)
      warning "\n $(text 150) \n"
      printf -v "$_var_name" '%s' "$_default" ;;
  esac
}

# 逐项确认一个自由文本字段：直接回车采用默认值；否则使用手动输入的值。
reading_text_default() {
  local _prompt_text="$1" _var_name="$2" _default="$3" _input=''
  reading "\n ${_prompt_text} [${_default}] " _input
  if [ -z "$_input" ]; then
    printf -v "$_var_name" '%s' "$_default"
  else
    printf -v "$_var_name" '%s' "$_input"
  fi
}

reading_xhttp_mode() {
  local _default="$1" _attempts=3 _input=''
  while [ "$_attempts" -gt 0 ]; do
    reading "\n $(text 140) [${_default}] " _input
    if [ -z "$_input" ]; then
      XHTTP_CDN_MODE="$_default"
      return 0
    fi
    case "${_input,,}" in
      auto|stream-one|stream-up|packet-up)
        XHTTP_CDN_MODE="${_input,,}"
        return 0 ;;
    esac
    (( _attempts-- )) || true
    warning "\n $(text 145) \n"
  done
  XHTTP_CDN_MODE="$_default"
}

reading_ech_query_domain() {
  local _default="$1" _attempts=3 _input=''
  while [ "$_attempts" -gt 0 ]; do
    reading "\n $(text 143) [${_default}] " _input
    if [ -z "$_input" ]; then
      ECH_QUERY_DOMAIN="$_default"
      return 0
    fi
    if validate_reality_addr "$_input"; then
      ECH_QUERY_DOMAIN="${_input,,}"
      return 0
    fi
    (( _attempts-- )) || true
    warning "\n $(text 148) \n"
  done
  ECH_QUERY_DOMAIN="$_default"
}

reading_ech_dns() {
  local _default="$1" _attempts=3 _input=''
  while [ "$_attempts" -gt 0 ]; do
    reading "\n $(text 144) [${_default}] " _input
    if [ -z "$_input" ]; then
      ECH_DNS="$_default"
      return 0
    fi
    if [[ "$_input" =~ ^(udp|https|h2c|https\+local)://[^[:space:]\&\;\|]+$ ]]; then
      ECH_DNS="$_input"
      return 0
    fi
    (( _attempts-- )) || true
    warning "\n $(text 146) \n"
  done
  ECH_DNS="$_default"
}

guided_fixed_tunnel_healthcheck() {
  # This check runs only after export_list(), so the static subscription files
  # already exist. It verifies the exact route users need before we claim the
  # fixed-domain deployment is usable: Xray path -> Nginx local origin ->
  # Cloudflare Published application -> public HTTPS hostname.
  local _actual_path='' _expected_path='' _local_body='' _public_body='' _try=1

  if [ -s "$WORK_DIR/inbound.json" ] && [ -x "$WORK_DIR/jq" ]; then
    _actual_path=$(grep -v '^//' "$WORK_DIR/inbound.json" | "$WORK_DIR/jq" -r '[.inbounds[] | select((.tag | split(" ")[-1]) == "xhttp-h1.1-cdn") | .streamSettings.xhttpSettings.path] | .[0] // empty' 2>/dev/null)
  fi
  _expected_path="/${WS_PATH:-$WS_PATH_DEFAULT}-xh"

  if [ -z "$_actual_path" ]; then
    error "\n Guided deployment verification failed: the XHTTP CDN inbound/path is missing from inbound.json.\n"
  fi
  if [ "$_actual_path" != "$_expected_path" ]; then
    error "\n Guided deployment verification failed: XHTTP path mismatch. Server='${_actual_path}', exported='${_expected_path}'.\n"
  fi

  # Token tunnels are remotely managed. The route in Cloudflare must point to
  # the exact local Nginx port; a healthy cloudflared process alone does not
  # prove that the Published application route is correct.
  if [ "$L" = 'C' ]; then
    info "\n 固定域名部署校验：\n   Cloudflare 域名 = https://${ARGO_DOMAIN}\n   Cloudflare Published application Service URL 必须为 = http://localhost:${NGINX_PORT}\n   XHTTP 实际路径 = ${_actual_path}\n"
  else
    info "\n Fixed-domain deployment verification:\n   Cloudflare hostname = https://${ARGO_DOMAIN}\n   Cloudflare Published application Service URL must be = http://localhost:${NGINX_PORT}\n   Actual XHTTP path = ${_actual_path}\n"
  fi

  _local_body=$(wget -qO- --timeout=8 --tries=1 --header="Host: ${ARGO_DOMAIN}" "http://127.0.0.1:${NGINX_PORT}/${UUID}/shadowrocket-xhttp-uri.txt" 2>/dev/null || true)
  if ! grep -q '^vless://' <<< "$_local_body"; then
    error "\n Local Nginx origin verification failed at http://127.0.0.1:${NGINX_PORT}. Check nginx.conf and the Xray service before using the node.\n"
  fi

  # Give Cloudflare DNS/route a short bounded window to become reachable. This
  # is intentionally a strict guided-install check: if the public route cannot
  # return the exact file that works locally, clients will not be able to use
  # the XHTTP node either.
  while [ "$_try" -le 5 ]; do
    _public_body=$(wget -qO- --timeout=10 --tries=1 "https://${ARGO_DOMAIN}/${UUID}/shadowrocket-xhttp-uri.txt" 2>/dev/null || true)
    grep -q '^vless://' <<< "$_public_body" && break
    sleep 3
    ((_try++)) || true
  done

  if ! grep -q '^vless://' <<< "$_public_body"; then
    if [ "$L" = 'C' ]; then
      error "\n Cloudflare 固定域名公网校验失败。cloudflared 即使显示运行中，也不代表 Public Hostname 回源正确。请在 Cloudflare Tunnel -> Published application 检查：\n   Hostname: ${ARGO_DOMAIN}\n   Service URL: http://localhost:${NGINX_PORT}\n并确认该 Hostname 绑定的是你刚才粘贴 Token 对应的同一个 Tunnel。修正后可执行 argox -n 重新生成节点。\n"
    else
      error "\n Public Cloudflare hostname verification failed. A running cloudflared process does not prove the Published application route is correct. In Cloudflare Tunnel -> Published application verify:\n   Hostname: ${ARGO_DOMAIN}\n   Service URL: http://localhost:${NGINX_PORT}\nand make sure the hostname belongs to the same Tunnel as the pasted token. After fixing it, run argox -n to regenerate nodes.\n"
    fi
  fi

  if [ "$L" = 'C' ]; then
    info "\n 固定域名公网校验成功：Cloudflare -> Tunnel -> Nginx -> 订阅文件链路可达。\n"
  else
    info "\n Public hostname verification passed: Cloudflare -> Tunnel -> Nginx -> subscription file is reachable.\n"
  fi
}

guided_xhttp_install() {
  local _attempts=5 _input='' _confirm=''

  # 判断"是否已安装"要跟主菜单用同一套标准：STATUS[] 由 check_install()
  # 在进入这里之前已经填好，只要 Argo/Xray/Nginx 里任何一个被检测到"已注册"
  # 或"运行中"，才算真正装过。如果只是 $WORK_DIR 目录存在、但三个服务全部
  # 显示"未安装"，说明是上一次安装中途失败或被中断后留下的残留目录，不是
  # 一次完整安装——直接清理掉再继续，避免用户卡在"主菜单说没装、向导却说
  # 已经装了"这种死循环里出不来。
  if [[ "${STATUS[*]:-}" =~ $(text 27)|$(text 28) ]]; then
    error " $(text 135) "
  elif [ -d "$WORK_DIR" ]; then
    warning "\n $(text 153) \n"
    rm -rf "$WORK_DIR"
  fi
  info "\n $(text 134) \n"
  info "\n $(text 147) \n"
  unset ARGO_AUTH

  # ---- 1/9 固定域名（必填，会一直重试直到通过校验） ----
  while [ "$_attempts" -gt 0 ]; do
    reading "\n $(text 128) " _input
    ARGO_DOMAIN="${_input,,}"
    ARGO_DOMAIN="${ARGO_DOMAIN//[[:space:]]/}"
    if is_fixed_argo_domain "$ARGO_DOMAIN"; then
      break
    fi
    (( _attempts-- )) || true
    warning "\n $(text 130) \n"
  done
  [ -n "$ARGO_DOMAIN" ] && is_fixed_argo_domain "$ARGO_DOMAIN" || error " $(text 130) "

  # ---- 2/9 Argo Tunnel Token / JSON（必填，明文输入，会一直重试直到通过校验） ----
  _attempts=5
  while [ "$_attempts" -gt 0 ]; do
    reading "\n $(text 129) " _input
    if is_cloudflare_tunnel_credential "$_input"; then
      ARGO_AUTH="$_input"
      break
    fi
    (( _attempts-- )) || true
    warning "\n $(text 131) \n"
  done
  [ -n "${ARGO_AUTH:-}" ] && is_cloudflare_tunnel_credential "$ARGO_AUTH" || error " $(text 131) "
  unset _input

  apply_guided_xhttp_infra_defaults

  # ---- 3/9 CDN 优选入口（可回车采用默认值） ----
  reading_text_default "$(text 136)" 'SERVER' "${CDN_DOMAIN[0]}"

  # ---- 4/9 ~ 6/9 VLESS Encryption 后量子加密相关三项 ----
  reading_yn "$(text 137)" 'ENABLE_VLESS_PQC' 'y'
  reading_yn "$(text 138)" 'VLESS_PQC_STRICT' 'y'
  reading_yn "$(text 139)" 'VLESS_PQC_DISABLE_0RTT' 'y'

  # ---- XHTTP CDN 模式 ----
  reading_xhttp_mode 'packet-up'

  # ---- 可选：XHTTP 上下行分离 ----
  reading_yn "$(text 154)" 'ENABLE_XHTTP_SPLIT' 'n'
  if truthy "$ENABLE_XHTTP_SPLIT"; then
    reading_text_default "$(text 155)" 'XHTTP_DOWNLOAD_SERVER' "$SERVER"
    if parse_preferred_addr "$XHTTP_DOWNLOAD_SERVER"; then
      XHTTP_DOWNLOAD_SERVER="$PREFERRED_ADDR"
      XHTTP_DOWNLOAD_PORT="$PREFERRED_PORT"
    else
      warning "\n $(text 156) \n"
      if parse_preferred_addr "$SERVER"; then
        XHTTP_DOWNLOAD_SERVER="$PREFERRED_ADDR"
        XHTTP_DOWNLOAD_PORT="$PREFERRED_PORT"
      else
        XHTTP_DOWNLOAD_SERVER="$SERVER"
        XHTTP_DOWNLOAD_PORT="${SERVER_PORT:-443}"
      fi
    fi
    if [ "$XHTTP_CDN_MODE" = 'stream-one' ]; then
      warning "\n $(text 157) \n"
      XHTTP_CDN_MODE='stream-up'
    fi
  fi

  # ---- ECH 相关四项 ----
  reading_yn "$(text 141)" 'ENABLE_ECH' 'y'
  reading_yn "$(text 142)" 'ECH_STRICT' 'y'
  reading_ech_query_domain 'cloudflare-ech.com'
  reading_ech_dns 'https://1.1.1.1/dns-query'

  info "\n $(text 151) \n"
  info "   INSTALL_PROTOCOLS = i  (VLESS + XHTTP CDN)\n"
  info "   ARGO_DOMAIN        = ${ARGO_DOMAIN}\n"
  info "   SERVER              = ${SERVER}\n"
  info "   ENABLE_VLESS_PQC    = ${ENABLE_VLESS_PQC}\n"
  info "   VLESS_PQC_STRICT    = ${VLESS_PQC_STRICT}\n"
  info "   VLESS_PQC_DISABLE_0RTT = ${VLESS_PQC_DISABLE_0RTT}\n"
  info "   XHTTP_CDN_MODE      = ${XHTTP_CDN_MODE}\n"
  info "   ENABLE_XHTTP_SPLIT  = ${ENABLE_XHTTP_SPLIT}\n"
  if truthy "$ENABLE_XHTTP_SPLIT"; then
    info "   XHTTP_DOWNLOAD      = ${XHTTP_DOWNLOAD_SERVER}:${XHTTP_DOWNLOAD_PORT} (Host/SNI: ${ARGO_DOMAIN})\n"
  fi
  info "   ENABLE_ECH          = ${ENABLE_ECH}\n"
  info "   ECH_STRICT          = ${ECH_STRICT}\n"
  info "   ECH_QUERY_DOMAIN    = ${ECH_QUERY_DOMAIN}\n"
  info "   ECH_DNS             = ${ECH_DNS}\n"

  reading "\n $(text 152) " _confirm
  if [ -n "$_confirm" ] && ! [[ "${_confirm,,}" =~ ^y(es)?$ ]]; then
    info "\n $(text 132) \n"
    exit 0
  fi

  NONINTERACTIVE_INSTALL='noninteractive_install'
  info "\n $(text 132) \n"
  install_argox
  export_list
  create_shortcut
  guided_fixed_tunnel_healthcheck
}

# 检测并安装依赖，Alpine 额外处理 BusyBox wget 和 openrc，其他系统补充 iproute2 和 systemctl
check_dependencies() {
  local DEPS_CHECK=() DEPS_INSTALL=() TO_INSTALL=()

  # 1. 基础通用依赖 (所有系统都需要)
  DEPS_CHECK=(  "wget" "bash" "ss"       "nginx" "unzip" "openssl" "qrencode")
  DEPS_INSTALL=("wget" "bash" "iproute2" "nginx" "unzip" "openssl" "qrencode")

  # 2. 根据系统差异补充初始化系统依赖（不含防火墙，防火墙仅端口跳跃时按需安装）
  if [ "$SYSTEM" = 'Alpine' ]; then
    # Alpine 特有处理：检查 BusyBox wget
    local CHECK_WGET=$(wget 2>&1 | sed -n 1p)
    grep -qi 'busybox' <<< "$CHECK_WGET" && TO_INSTALL+=("wget")

    DEPS_CHECK+=("rc-update")
    DEPS_INSTALL+=("openrc")
  else
    DEPS_CHECK+=("systemctl")
    DEPS_INSTALL+=("systemctl")
  fi

  # 3. 统一循环检查
  for i in "${!DEPS_CHECK[@]}"; do
    ! command -v "${DEPS_CHECK[i]}" >/dev/null 2>&1 && TO_INSTALL+=("${DEPS_INSTALL[i]}")
  done

  # 4. 数组去重并执行安装
  if [ "${#TO_INSTALL[@]}" -gt 0 ]; then
    # 去重处理
    TO_INSTALL=($(printf "%s\n" "${TO_INSTALL[@]}" | sort -u))

    info "\n $(text 7) $(sed "s/ /,&/g" <<< "${TO_INSTALL[*]}") \n"

    # CentOS 通常不需要频繁 update，节省时间
    [ "$SYSTEM" != 'CentOS' ] && ${PACKAGE_UPDATE[int]} >/dev/null 2>&1
    ${PACKAGE_INSTALL[int]} "${TO_INSTALL[@]}" >/dev/null 2>&1
  else
    info "\n $(text 8) \n"
  fi

  # 5. 后置处理: 禁用 nginx 默认自启 (防止端口冲突)
  if command -v nginx >/dev/null 2>&1; then
    if [ "$SYSTEM" = 'Alpine' ]; then
      rc-update del nginx default >/dev/null 2>&1 || true
    else
      cmd_systemctl disable nginx >/dev/null 2>&1 || true
    fi
  fi
}

# 输入 WS/XHTTP 内部起始端口，连续 NUM 个端口逐一检测是否被占用
input_start_port() {
  local NUM=$1
  local PORT_ERROR_TIME=6
  while true; do
    [ "$PORT_ERROR_TIME" -lt 6 ] && unset IN_USED START_PORT
    (( PORT_ERROR_TIME-- )) || true
    if [ "$PORT_ERROR_TIME" = 0 ]; then
      error "\n $(text 3) \n"
    else
      [ -z "$START_PORT" ] && reading "\n $(text 56) " START_PORT
    fi
    START_PORT=${START_PORT:-"$START_PORT_DEFAULT"}
    if [[ "$START_PORT" =~ ^[1-9][0-9]{2,4}$ && "$START_PORT" -ge "$MIN_PORT" && "$START_PORT" -le "$MAX_PORT" ]]; then
      local IN_USED=()
      local port
      refresh_port_snapshot
      for ((port=START_PORT; port<START_PORT+NUM; port++)); do
        is_port_in_use "$port" && IN_USED+=("$port")
      done
      [ "${#IN_USED[@]}" -eq 0 ] && break || warning "\n $(text 61) ${IN_USED[*]} \n"
    fi
  done
}

# 输入 Nginx 端口
input_nginx_port() {
  local PORT_ERROR_TIME=6
  grep -q 'noninteractive_install' <<< "$NONINTERACTIVE_INSTALL" && NGINX_PORT=${NGINX_PORT:-"$NGINX_PORT_DEFAULT"}
  while true; do
    [ "$PORT_ERROR_TIME" -lt 6 ] && unset NGINX_PORT
    (( PORT_ERROR_TIME-- )) || true
    if [ "$PORT_ERROR_TIME" = 0 ]; then
      error "\n $(text 3) \n"
    else
      [ -z "$NGINX_PORT" ] && reading "\n $(text 68) " NGINX_PORT
    fi
    NGINX_PORT=${NGINX_PORT:-"$NGINX_PORT_DEFAULT"}
    if [[ "$NGINX_PORT" =~ ^[1-9][0-9]{1,4}$ && "$NGINX_PORT" -ge "$MIN_PORT" && "$NGINX_PORT" -le "$MAX_PORT" ]]; then
      refresh_port_snapshot
      is_port_in_use "$NGINX_PORT" && warning "\n $(text 61) $NGINX_PORT \n" || break
    fi
  done
}

parse_preferred_addr() {
  local _raw="$1" _host='' _port='443'
  _raw=$(printf '%s' "$_raw" | sed 's/[[:space:]]//g; s/：/:/g; s/。/./g; s/【/[/g; s/】/]/g')
  [ -z "$_raw" ] && return 1

  if [[ "$_raw" =~ ^\[([0-9A-Fa-f:]+)\](:([0-9]{1,5}))?$ ]]; then
    _host="${BASH_REMATCH[1]}"
    [ -n "${BASH_REMATCH[3]}" ] && _port="${BASH_REMATCH[3]}"
  elif [[ "$_raw" =~ ^((([0-9]{1,3})\.){3}([0-9]{1,3}))(:([0-9]{1,5}))?$ ]]; then
    _host="${BASH_REMATCH[1]}"
    [ -n "${BASH_REMATCH[6]}" ] && _port="${BASH_REMATCH[6]}"
    IFS='.' read -r _o1 _o2 _o3 _o4 <<< "$_host"
    for _oct in "$_o1" "$_o2" "$_o3" "$_o4"; do
      [[ "$_oct" =~ ^[0-9]+$ ]] || return 1
      [ "$_oct" -gt 255 ] && return 1
    done
  elif [[ "$_raw" =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?))+)(:([0-9]{1,5}))?$ ]]; then
    _host="${BASH_REMATCH[1]}"
    [ -n "${BASH_REMATCH[7]}" ] && _port="${BASH_REMATCH[7]}"
  else
    return 1
  fi

  [[ "$_port" =~ ^[0-9]+$ ]] || return 1
  [ "$_port" -lt 1 ] || [ "$_port" -gt 65535 ] && return 1

  PREFERRED_ADDR="$_host"
  PREFERRED_PORT="$_port"
  if [[ "$_host" == *:* ]]; then
    PREFERRED_DISPLAY="[$_host]:$_port"
  else
    PREFERRED_DISPLAY="$_host:$_port"
  fi
  return 0
}

# 从已安装的 inbound.json / protocols 等配置文件中读取各参数，供 export_list / change_protocols 复用
fetch_nodes_value() {
  unset SERVER_IP REALITY_PORT REALITY_PUBLIC REALITY_PRIVATE REALITY_DOMAIN REALITY_ADDR REALITY_ADDR_1 REALITY_ADDR_2 TLS_SERVER SERVER SERVER_PORT SERVER_DISPLAY UUID WS_PATH NODE_NAME SS_METHOD SS2022_PASSWORD \
        ENABLE_VLESS_PQC VLESS_PQC_STRICT VLESS_PQC_REQUIRE_PREFIX VLESS_PQC_DISABLE_0RTT VLESS_PQC_RESUME VLESS_PQC_CLIENT_RTT ALLOW_LEGACY_PROTOCOLS VLESS_PQC_DECRYPTION VLESS_PQC_ENCRYPTION VLESS_SERVER_DECRYPTION VLESS_CLIENT_ENCRYPTION VLESS_CLIENT_ENCRYPTION_QUERY \
        ENABLE_ECH ECH_STRICT ECH_CONFIG ECH_QUERY_DOMAIN ECH_DNS ECH_CLIENT_CONFIG ECH_CLIENT_CONFIG_QUERY ECH_URI_PARAM MIHOMO_ECH_OPTS MIHOMO_TLS_FINGERPRINT XHTTP_CDN_MODE ENABLE_XHTTP_SPLIT XHTTP_DOWNLOAD_SERVER XHTTP_DOWNLOAD_PORT \
        GRPC_PORT HY2_PORT VLESS_WS_PORT VMESS_WS_PORT TROJAN_WS_PORT SS_WS_PORT VLESS_XHTTP_PORT XHTTP_PORT TROJAN_PORT SS2022_PORT SERVER_IP_1 SERVER_IP_2 HY2_UP_NOW HY2_DOWN_NOW

  [ -s "$CUSTOM_FILE" ] && . "$CUSTOM_FILE"
  SERVER_IP="${serverIp:-}"
  REALITY_PRIVATE="${privateKey:-}"
  REALITY_PUBLIC="${publicKey:-}"
  REALITY_DOMAIN="${realityDomain:-${REALITY_DOMAIN:-}}"
  [ "$REALITY_DOMAIN" = "__REALITY_DOMAIN_UNSET__" ] && REALITY_DOMAIN=''
  SERVER="${cdn:-}"
  SERVER_PORT="${cdnPort:-443}"
  ENABLE_VLESS_PQC="${enableVlessPqc:-${ENABLE_VLESS_PQC:-y}}"
  VLESS_PQC_STRICT="${vlessPqcStrict:-${VLESS_PQC_STRICT:-y}}"
  VLESS_PQC_REQUIRE_PREFIX="${vlessPqcRequirePrefix:-${VLESS_PQC_REQUIRE_PREFIX:-mlkem768x25519plus}}"
  VLESS_PQC_DISABLE_0RTT="${vlessPqcDisable0Rtt:-${VLESS_PQC_DISABLE_0RTT:-y}}"
  VLESS_PQC_RESUME="${vlessPqcResume:-${VLESS_PQC_RESUME:-600s}}"
  VLESS_PQC_CLIENT_RTT="${vlessPqcClientRtt:-${VLESS_PQC_CLIENT_RTT:-1rtt}}"
  ALLOW_LEGACY_PROTOCOLS="${allowLegacyProtocols:-${ALLOW_LEGACY_PROTOCOLS:-n}}"
  VLESS_PQC_DECRYPTION="${vlessPqcDecryption:-${VLESS_PQC_DECRYPTION:-}}"
  VLESS_PQC_ENCRYPTION="${vlessPqcEncryption:-${VLESS_PQC_ENCRYPTION:-}}"
  ENABLE_ECH="${enableEch:-${ENABLE_ECH:-y}}"
  ECH_STRICT="${echStrict:-${ECH_STRICT:-y}}"
  ECH_CONFIG="${echConfig:-${ECH_CONFIG:-}}"
  ECH_QUERY_DOMAIN="${echQueryDomain:-${ECH_QUERY_DOMAIN:-cloudflare-ech.com}}"
  ECH_DNS="${echDns:-${ECH_DNS:-https://1.1.1.1/dns-query}}"
  XHTTP_CDN_MODE="${xhttpCdnMode:-${XHTTP_CDN_MODE:-packet-up}}"
  ENABLE_XHTTP_SPLIT="${enableXhttpSplit:-${ENABLE_XHTTP_SPLIT:-n}}"
  XHTTP_DOWNLOAD_SERVER="${xhttpDownloadServer:-${XHTTP_DOWNLOAD_SERVER:-}}"
  XHTTP_DOWNLOAD_PORT="${xhttpDownloadPort:-${XHTTP_DOWNLOAD_PORT:-}}"
  WS_PATH="${wsPath:-${WS_PATH:-}}"
  unset serverIp privateKey publicKey realityDomain cdn cdnPort language enableVlessPqc vlessPqcStrict vlessPqcRequirePrefix vlessPqcDisable0Rtt vlessPqcResume vlessPqcClientRtt allowLegacyProtocols vlessPqcDecryption vlessPqcEncryption \
        enableEch echStrict echConfig echQueryDomain echDns xhttpCdnMode enableXhttpSplit xhttpDownloadServer xhttpDownloadPort wsPath

  local JSON
  JSON=$(grep -v '^//' $WORK_DIR/inbound.json 2>/dev/null)
  [ -z "$JSON" ] && [ ! -s "$CUSTOM_FILE" ] && return 1
  [ -z "$JSON" ] && return 0

  REALITY_PORT=$(echo "$JSON" | $WORK_DIR/jq -r '.inbounds[0].port // empty')
  TLS_SERVER=$(echo "$JSON" | $WORK_DIR/jq -r '.inbounds[] | select(.streamSettings.security=="reality") | .streamSettings.realitySettings.serverNames[0]' 2>/dev/null | head -1)
  UUID=$(echo "$JSON" | $WORK_DIR/jq -r '.inbounds[0].settings.clients[0].id // .inbounds[0].settings.clients[0].password // .inbounds[0].settings.clients[0].auth // empty')
  WS_PATH=$(echo "$JSON" | $WORK_DIR/jq -r '.inbounds[] | select(.streamSettings.network=="ws") | .streamSettings.wsSettings.path' 2>/dev/null | head -1 | sed 's|/||; s|-vl$||; s|-vm$||; s|-tr$||; s|-sh$||; s|-xh$||')
  [ -z "$WS_PATH" ] && WS_PATH=$(echo "$JSON" | $WORK_DIR/jq -r '[.inbounds[] | select((.tag | split(" ")[-1]) == "xhttp-h1.1-cdn") | .streamSettings.xhttpSettings.path] | .[0] // empty' 2>/dev/null | sed 's|^/||; s|-xh$||')
  [ -z "$WS_PATH" ] && WS_PATH=$(echo "$JSON" | $WORK_DIR/jq -r '[.inbounds[] | select((.tag | split(" ")[-1]) == "xhttp-h3-direct") | .streamSettings.xhttpSettings.path] | .[0] // empty' 2>/dev/null | sed 's|^/||; s|-xh3$||')
  NODE_NAME=$(echo "$JSON" | $WORK_DIR/jq -r '.inbounds[0].tag // empty' | sed 's/ [^ ]*$//')
  SS_METHOD=$(echo "$JSON" | $WORK_DIR/jq -r '.inbounds[] | select(.tag | split(" ")[-1] == "ss-ws") | .settings.clients[0].method // empty' 2>/dev/null | head -1)
  SS2022_PASSWORD=$(echo "$JSON" | $WORK_DIR/jq -r '.inbounds[] | select(.tag | split(" ")[-1] == "ss2022-direct") | .settings.password // empty' 2>/dev/null | head -1)
  [ -z "$SS2022_PASSWORD" ] && SS2022_PASSWORD=$(echo "$JSON" | $WORK_DIR/jq -r '.inbounds[] | select(.tag | split(" ")[-1] == "ss2022-direct") | .settings.clients[0].password // empty' 2>/dev/null | head -1)
  [ -z "$SS_METHOD" ] && SS_METHOD=$(echo "$JSON" | $WORK_DIR/jq -r '.inbounds[] | select(.protocol=="shadowsocks") | .settings.clients[0].method // .settings.method // empty' 2>/dev/null | head -1)
  GRPC_PORT=$(echo "$JSON" | $WORK_DIR/jq -r '[.inbounds[] | select(.streamSettings.network=="grpc") | .port] | .[0] // empty' 2>/dev/null)
  HY2_PORT=$(echo "$JSON" | $WORK_DIR/jq -r '[.inbounds[] | select(.tag | split(" ")[-1] == "hysteria2") | .port] | .[0] // empty' 2>/dev/null)
  VLESS_WS_PORT=$(echo "$JSON" | $WORK_DIR/jq -r '[.inbounds[] | select(.tag | split(" ")[-1] == "vless-ws") | .port] | .[0] // empty' 2>/dev/null)
  VMESS_WS_PORT=$(echo "$JSON" | $WORK_DIR/jq -r '[.inbounds[] | select(.tag | split(" ")[-1] == "vmess-ws") | .port] | .[0] // empty' 2>/dev/null)
  TROJAN_WS_PORT=$(echo "$JSON" | $WORK_DIR/jq -r '[.inbounds[] | select(.tag | split(" ")[-1] == "trojan-ws") | .port] | .[0] // empty' 2>/dev/null)
  SS_WS_PORT=$(echo "$JSON" | $WORK_DIR/jq -r '[.inbounds[] | select(.tag | split(" ")[-1] == "ss-ws") | .port] | .[0] // empty' 2>/dev/null)
  VLESS_XHTTP_PORT=$(echo "$JSON" | $WORK_DIR/jq -r '[.inbounds[] | select(.tag | split(" ")[-1] == "xhttp-h1.1-cdn") | .port] | .[0] // empty' 2>/dev/null)
  XHTTP_PORT=$(echo "$JSON" | $WORK_DIR/jq -r '[.inbounds[] | select(.tag | split(" ")[-1] == "xhttp-h3-direct") | .port] | .[0] // empty' 2>/dev/null)
  [ -z "$TLS_SERVER" ] && TLS_SERVER=$(echo "$JSON" | $WORK_DIR/jq -r '[.inbounds[] | select(.streamSettings.network=="hysteria") | .streamSettings.tlsSettings.serverNames[0]] | .[0] // empty' 2>/dev/null)
  [ -z "$TLS_SERVER" ] && TLS_SERVER=$(echo "$JSON" | $WORK_DIR/jq -r '[.inbounds[] | select(.tag | split(" ")[-1] == "trojan-direct") | .streamSettings.tlsSettings.serverName // .streamSettings.tlsSettings.serverNames[0]] | .[0] // empty' 2>/dev/null)
  [ -z "$TLS_SERVER" ] && [ -s "$WORK_DIR/cert/cert.pem" ] && TLS_SERVER=$(openssl x509 -noout -ext subjectAltName -in "$WORK_DIR/cert/cert.pem" 2>/dev/null | awk -F 'DNS:' '/DNS:/{gsub(/,.*/,"",$2);print $2; exit}')
  [ -z "$SS2022_PASSWORD" ] && SS2022_PASSWORD="$(openssl rand -base64 16)"
  TROJAN_PORT=$(echo "$JSON" | $WORK_DIR/jq -r '[.inbounds[] | select(.tag | split(" ")[-1] == "trojan-direct") | .port] | .[0] // empty' 2>/dev/null)
  SS2022_PORT=$(echo "$JSON" | $WORK_DIR/jq -r '[.inbounds[] | select(.tag | split(" ")[-1] == "ss2022-direct") | .port] | .[0] // empty' 2>/dev/null)

  [ -z "$WS_PATH" ] && WS_PATH="$WS_PATH_DEFAULT"
  [ -z "$NODE_NAME" ] && NODE_NAME="ArgoX"
  if [[ -z "$SERVER" || "$SERVER" == '__CDN_UNSET__' ]]; then
    SERVER='__CDN_UNSET__'
    SERVER_PORT=443
    SERVER_DISPLAY='__CDN_UNSET__'
  elif parse_preferred_addr "${SERVER}:${SERVER_PORT}"; then
    SERVER="$PREFERRED_ADDR"
    SERVER_PORT="$PREFERRED_PORT"
    SERVER_DISPLAY="$PREFERRED_DISPLAY"
  else
    SERVER_PORT=443
    SERVER_DISPLAY="$SERVER"
  fi

  if [[ "$SERVER_IP" =~ : ]]; then
    SERVER_IP_1="[$SERVER_IP]"
    SERVER_IP_2="[[$SERVER_IP]]"
  else
    SERVER_IP_1="$SERVER_IP"
    SERVER_IP_2="$SERVER_IP"
  fi

  REALITY_ADDR="$(reality_connect_addr)"
  if [[ "$REALITY_ADDR" =~ : ]]; then
    REALITY_ADDR="${REALITY_ADDR#[}"
    REALITY_ADDR="${REALITY_ADDR%]}"
    REALITY_ADDR_1="[$REALITY_ADDR]"
    REALITY_ADDR_2="[[$REALITY_ADDR]]"
  else
    REALITY_ADDR_1="$REALITY_ADDR"
    REALITY_ADDR_2="$REALITY_ADDR"
  fi

  # 读取 Hysteria2 带宽参数（从订阅文件 proxies 中解析）
  if [ -n "$HY2_PORT" ] && [ -s "${WORK_DIR}/subscribe/proxies" ]; then
    local HY2_LINE=$(grep 'type: hysteria2' ${WORK_DIR}/subscribe/proxies)
    if [[ "$HY2_LINE" =~ up:[[:space:]]*\"([0-9]+)[[:space:]]*Mbps\".*down:[[:space:]]*\"([0-9]+)[[:space:]]*Mbps\" ]]; then
      HY2_UP_NOW="${BASH_REMATCH[1]}"
      HY2_DOWN_NOW="${BASH_REMATCH[2]}"
    elif [[ "$HY2_LINE" =~ down:[[:space:]]*\"([0-9]+)[[:space:]]*Mbps\".*up:[[:space:]]*\"([0-9]+)[[:space:]]*Mbps\" ]]; then
      HY2_DOWN_NOW="${BASH_REMATCH[1]}"
      HY2_UP_NOW="${BASH_REMATCH[2]}"
    fi
    HY2_UP_NOW=${HY2_UP_NOW:-200}
    HY2_DOWN_NOW=${HY2_DOWN_NOW:-1000}
  fi

  [ -n "$HY2_PORT" ] && check_port_hopping_nat
  return 0
}

# 获取 Argo 隧道域名，通过传参选择获取方式：
#   quick  - 临时隧道，查询 cloudflared metrics /quicktunnel 端点
#   config - Json/Token 隧道，查询 /config 端点，同时解析出 NGINX_PORT
fetch_tunnel_domain() {
  local _MODE="${1:-quick}"
  local _CF_PID _METRICS_ADDR
  _CF_PID=$(ps -eo pid,args | awk -v d="$WORK_DIR" '$0~(d"/cloudflared"){print $1;exit}')
  [[ "$_CF_PID" =~ ^[0-9]+$ ]] && _METRICS_ADDR=$(ss -nltp | awk -v pid="$_CF_PID" '$0 ~ "pid="pid"," {print $4; exit}' | sed 's/^\*/127.0.0.1/; s/^0\.0\.0\.0/127.0.0.1/')

  if [ "$_MODE" = 'config' ]; then
    unset ARGO_DOMAIN
    [ -z "$_METRICS_ADDR" ] && return 1
    local _CONFIG_JSON
    _CONFIG_JSON=$(wget -qO- "http://${_METRICS_ADDR}/config" 2>/dev/null)
    [ -z "$_CONFIG_JSON" ] && return 1
    [ -z "$NGINX_PORT" ] && [ -s "$WORK_DIR/nginx.conf" ] && NGINX_PORT=$(awk '/listen[[:space:]]/{gsub(/;/,""); print $2; exit}' "$WORK_DIR/nginx.conf")
    ARGO_DOMAIN=$($WORK_DIR/jq -r --arg port "$NGINX_PORT" '.config.ingress[] | select(.service == ("http://localhost:" + $port)) | .hostname ' <<< "$_CONFIG_JSON")
    return 0
  else
    unset ARGO_DOMAIN
    local _ERROR_TIME=20
    until [ -n "$ARGO_DOMAIN" ]; do
      if [ -z "$_METRICS_ADDR" ]; then
        _CF_PID=$(ps -eo pid,args | awk -v d="$WORK_DIR" '$0~(d"/cloudflared"){print $1;exit}')
        [[ "$_CF_PID" =~ ^[0-9]+$ ]] && \
          _METRICS_ADDR=$(ss -nltp | awk -v pid="$_CF_PID" '$0 ~ "pid="pid"," {print $4; exit}' \
            | sed 's/^\*/127.0.0.1/; s/^0\.0\.0\.0/127.0.0.1/')
      fi
      [ -n "$_METRICS_ADDR" ] && ARGO_DOMAIN=$(wget -qO- "http://${_METRICS_ADDR}/quicktunnel" | awk -F '"' '{print $4}')
      if [[ ! "$ARGO_DOMAIN" =~ trycloudflare\.com$ ]]; then
        (( _ERROR_TIME-- )) || true
        [ "$_ERROR_TIME" = 0 ] && warning "\n $(text 102) \n" && unset ARGO_DOMAIN && return 1
        sleep 2
      else
        break
      fi
    done
  fi
}


# 保存 trycloudflare 临时域名到本地文件（安全：只写本机，不外发）
install_trycloudflare_url_watcher() {
  cat > ${WORK_DIR}/argox-url-watch.sh << 'EOF'
#!/usr/bin/env bash
set -u
WORK_DIR="/etc/argox"
OUT_FILE="${WORK_DIR}/current_tunnel.txt"
LOG_FILE="${WORK_DIR}/argo.log"
URL=""

for i in $(seq 1 60); do
  CF_PID=$(ps -eo pid,args | awk -v d="$WORK_DIR" '$0~(d"/cloudflared"){print $1;exit}')
  if [[ "$CF_PID" =~ ^[0-9]+$ ]]; then
    METRICS_ADDR=$(ss -nltp 2>/dev/null | awk -v pid="$CF_PID" '$0 ~ "pid="pid"," {print $4; exit}' | sed 's/^\*/127.0.0.1/; s/^0\.0\.0\.0/127.0.0.1/')
    if [ -n "${METRICS_ADDR:-}" ]; then
      URL=$(wget -qO- "http://${METRICS_ADDR}/quicktunnel" 2>/dev/null | grep -Eo 'https://[-a-zA-Z0-9.]+\.trycloudflare\.com' | head -1 || true)
    fi
  fi

  if [ -z "${URL:-}" ] && [ -s "$LOG_FILE" ]; then
    URL=$(grep -Eo 'https://[-a-zA-Z0-9.]+\.trycloudflare\.com' "$LOG_FILE" | tail -1 || true)
  fi

  if [[ "${URL:-}" =~ trycloudflare\.com$ ]]; then
    umask 077
    echo "$URL" > "$OUT_FILE"
    chmod 600 "$OUT_FILE" 2>/dev/null || true
    logger -t argox "current trycloudflare url saved to ${OUT_FILE}: ${URL}" 2>/dev/null || true
    exit 0
  fi
  sleep 2
done
exit 1
EOF
  chmod +x ${WORK_DIR}/argox-url-watch.sh
}

# 检查并安装 nginx
# 生成100年自签证书（供 Hysteria2 使用）
ssl_certificate() {
  local TLS_SRV="${1:-$TLS_SERVER}"
  [ ! -d ${WORK_DIR}/cert ] && mkdir -p ${WORK_DIR}/cert
  openssl ecparam -genkey -name prime256v1 -out ${WORK_DIR}/cert/private.key 2>/dev/null
  cat > ${WORK_DIR}/cert/cert.conf << EOF
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = $(awk -F . '{print $(NF-1)"."$NF}' <<< "$TLS_SRV")

[v3_req]
subjectAltName = @alt_names

[alt_names]
DNS = ${TLS_SRV}
EOF
  openssl req -new -x509 -days 36500 \
    -key ${WORK_DIR}/cert/private.key \
    -out ${WORK_DIR}/cert/cert.pem \
    -config ${WORK_DIR}/cert/cert.conf \
    -subj "/CN=${TLS_SRV}" \
    -extensions v3_req 2>/dev/null
  rm -f ${WORK_DIR}/cert/cert.conf
}

# 生成 UFW PortHopping 备注
# 向指定的 UFW 规则文件写入 PortHopping NAT 规则块
add_port_hopping_ufw_block() {
  local RULES_FILE="$1" BLOCK_BEGIN="$2" BLOCK_END="$3" PORT_HOPPING_START="$4" PORT_HOPPING_END="$5" PORT_HOPPING_TARGET="$6" COMMENT="$7"
  [ ! -e "$RULES_FILE" ] && return 0
  [ -z "$PORT_HOPPING_START" ] || [ -z "$PORT_HOPPING_END" ] || [ -z "$PORT_HOPPING_TARGET" ] || [ -z "$COMMENT" ] && return 1
  awk -v begin="$BLOCK_BEGIN" -v end="$BLOCK_END" -v start="$PORT_HOPPING_START" -v finish="$PORT_HOPPING_END" -v target="$PORT_HOPPING_TARGET" -v comment="$COMMENT" '
    BEGIN { inserted=0 }
    {
      if ($0 ~ /^\*filter/ && inserted==0) {
        print begin
        print "*nat"
        print ":PREROUTING ACCEPT [0:0]"
        print "-A PREROUTING -p udp --dport " start ":" finish " -m comment --comment \"" comment "\" -j DNAT --to-destination :" target
        print "COMMIT"
        print end
        inserted=1
      }
      print
    }
    END {
      if (inserted==0) {
        print begin
        print "*nat"
        print ":PREROUTING ACCEPT [0:0]"
        print "-A PREROUTING -p udp --dport " start ":" finish " -m comment --comment \"" comment "\" -j DNAT --to-destination :" target
        print "COMMIT"
        print end
      }
    }
  ' "$RULES_FILE" > "${TEMP_DIR}/$(basename "$RULES_FILE")" && mv "${TEMP_DIR}/$(basename "$RULES_FILE")" "$RULES_FILE"
}

# 删除指定 UFW 规则文件中的 PortHopping NAT 规则块
del_port_hopping_ufw_block() {
  local RULES_FILE=$1
  local IP_VERSION=$2
  local TEMP_RULES_FILE

  [ ! -e "$RULES_FILE" ] && return 0

  TEMP_RULES_FILE="${TEMP_DIR}/$(basename "$RULES_FILE")"

  awk -v ip_version="$IP_VERSION" '
    BEGIN { in_block=0 }
    {
      if ($0 ~ "^# ArgoX UFW NAT .* " ip_version " BEGIN$") {
        in_block=1
        next
      }
      if (in_block==1 && $0 ~ "^# ArgoX UFW NAT .* " ip_version " END$") {
        in_block=0
        next
      }
      if (in_block==0) print
    }
  ' "$RULES_FILE" > "$TEMP_RULES_FILE" && mv "$TEMP_RULES_FILE" "$RULES_FILE"
}

# 写入 UFW PortHopping NAT 规则
add_port_hopping_ufw_rules() {
  local PH_START=$1 PH_END=$2 TARGET_PORT=$3 COMMENT
  COMMENT="ArgoX UFW NAT ${PH_START}:${PH_END} -> ${TARGET_PORT}"
  [ -z "$PH_START" ] || [ -z "$PH_END" ] || [ -z "$TARGET_PORT" ] && return 1
  local UFW_BEFORE_RULES='/etc/ufw/before.rules'
  local UFW_BEFORE6_RULES='/etc/ufw/before6.rules'
  local UFW_IPV4_BLOCK_BEGIN="# ${COMMENT} IPv4 BEGIN"
  local UFW_IPV4_BLOCK_END="# ${COMMENT} IPv4 END"
  local UFW_IPV6_BLOCK_BEGIN="# ${COMMENT} IPv6 BEGIN"
  local UFW_IPV6_BLOCK_END="# ${COMMENT} IPv6 END"

  del_port_hopping_ufw_rules >/dev/null 2>&1
  add_port_hopping_ufw_block "$UFW_BEFORE_RULES" "$UFW_IPV4_BLOCK_BEGIN" "$UFW_IPV4_BLOCK_END" "$PH_START" "$PH_END" "$TARGET_PORT" "$COMMENT" || return 1
  add_port_hopping_ufw_block "$UFW_BEFORE6_RULES" "$UFW_IPV6_BLOCK_BEGIN" "$UFW_IPV6_BLOCK_END" "$PH_START" "$PH_END" "$TARGET_PORT" "$COMMENT" || return 1
  ufw delete allow ${PH_START}:${PH_END}/udp >/dev/null 2>&1 || true
  ufw allow ${PH_START}:${PH_END}/udp comment "$COMMENT" >/dev/null 2>&1 || return 1
  ufw reload >/dev/null 2>&1 || return 1
  [ "$(ufw status 2>/dev/null | awk '/^Status/{print $NF; exit}')" != 'active' ] && warning "\n $(text 116) \n"
  return 0
}

# 删除 UFW PortHopping NAT 规则
# 同时清理 allow 与 numbered 规则，避免重复残留
del_port_hopping_ufw_rules() {
  local UFW_BEFORE_RULES='/etc/ufw/before.rules'
  local UFW_BEFORE6_RULES='/etc/ufw/before6.rules'
  local COMMENT_PREFIX='ArgoX UFW NAT'
  local RULE_NUM OLD_START OLD_END
  check_port_hopping_ufw_rules
  OLD_START="$PORT_HOPPING_START"
  OLD_END="$PORT_HOPPING_END"
  del_port_hopping_ufw_block "$UFW_BEFORE_RULES" "IPv4" >/dev/null 2>&1
  del_port_hopping_ufw_block "$UFW_BEFORE6_RULES" "IPv6" >/dev/null 2>&1
  if [ -n "$OLD_START" ] && [ -n "$OLD_END" ]; then
    ufw delete allow ${OLD_START}:${OLD_END}/udp >/dev/null 2>&1 || true
  fi
  while read -r RULE_NUM; do
    [ -n "$RULE_NUM" ] && ufw --force delete "$RULE_NUM" >/dev/null 2>&1 || true
  done < <(ufw status numbered 2>/dev/null | grep "$COMMENT_PREFIX" | awk -F'[][]' '{print $2}' | sort -rn)
  ufw reload >/dev/null 2>&1 || return 1
  unset PORT_HOPPING_START PORT_HOPPING_END PORT_HOPPING_RANGE
  return 0
}

# 检查 UFW PortHopping NAT 规则
check_port_hopping_ufw_rules() {
  unset PORT_HOPPING_START PORT_HOPPING_END PORT_HOPPING_RANGE
  local DETECTED_TARGET
  local UFW_BEFORE_RULES='/etc/ufw/before.rules'
  local UFW_BEFORE6_RULES='/etc/ufw/before6.rules'
  local UFW_RULE=''

  [ -s $WORK_DIR/inbound.json ] && DETECTED_TARGET=$($WORK_DIR/jq -r '[.inbounds[] | select(.tag | split(" ")[-1] == "hysteria2") | .port] | .[0] // empty' $WORK_DIR/inbound.json 2>/dev/null)

  if [ -s "$UFW_BEFORE_RULES" ]; then
    UFW_RULE=$(awk '/ArgoX UFW NAT .* IPv4 BEGIN/ { in_block=1; next } /ArgoX UFW NAT .* IPv4 END/ { in_block=0 } in_block && /-A PREROUTING -p udp/ { print; exit }' "$UFW_BEFORE_RULES")
  fi
  if [ -z "$UFW_RULE" ] && [ -s "$UFW_BEFORE6_RULES" ]; then
    UFW_RULE=$(awk '/ArgoX UFW NAT .* IPv6 BEGIN/ { in_block=1; next } /ArgoX UFW NAT .* IPv6 END/ { in_block=0 } in_block && /-A PREROUTING -p udp/ { print; exit }' "$UFW_BEFORE6_RULES")
  fi

  [ -z "$UFW_RULE" ] && {
    PORT_HOPPING_TARGET="$DETECTED_TARGET"
    return 0
  }

  if [[ "$UFW_RULE" =~ --dport[[:space:]]+([0-9]+):([0-9]+) ]]; then
    PORT_HOPPING_START="${BASH_REMATCH[1]}"
    PORT_HOPPING_END="${BASH_REMATCH[2]}"
    PORT_HOPPING_RANGE="${PORT_HOPPING_START}:${PORT_HOPPING_END}"
  fi
  if [[ "$UFW_RULE" =~ --to-destination[[:space:]]+:([0-9]+) ]]; then
    PORT_HOPPING_TARGET="${BASH_REMATCH[1]}"
  else
    PORT_HOPPING_TARGET="$DETECTED_TARGET"
  fi
}

# 检测防火墙后端
check_firewall_backend() {
  local UFW_STATUS
  if command -v ufw >/dev/null 2>&1; then
    UFW_STATUS=$(ufw status 2>/dev/null | awk '/^Status/{print $NF; exit}')
    [ "$UFW_STATUS" = 'active' ] && { echo 'ufw'; return; }
  fi
  if [ "$SYSTEM" = 'Alpine' ]; then
    echo 'alpine-iptables'
  elif command -v firewall-cmd >/dev/null 2>&1 || [ "$SYSTEM" = 'CentOS' ]; then
    echo 'firewalld'
  else
    echo 'iptables'
  fi
}

# 初始化防火墙状态目录
init_firewall_state_dir() {
  [ ! -d "$FIREWALL_STATE_DIR" ] && mkdir -p "$FIREWALL_STATE_DIR"
}

# 读取上一次由脚本管理的普通端口规则
# 写入本次由脚本管理的普通端口规则
# 端口数组去重追加
append_unique_port() {
  local ARRAY_NAME=$1 PORT=$2
  local -n ARRAY_REF="$ARRAY_NAME"
  [ -z "$PORT" ] && return 0
  [[ ! "$PORT" =~ ^[0-9]+$ ]] && return 0
  local ITEM
  for ITEM in "${ARRAY_REF[@]}"; do [ "$ITEM" = "$PORT" ] && return 0; done
  ARRAY_REF+=("$PORT")
}

# 收集当前应该对外开放的普通端口
add_service_port_rule_ufw() { local COMMENT="ArgoX UFW PORT $1 $2"; [ -z "$1" ] || [ -z "$2" ] && return 1; ufw allow $2/$1 comment "$COMMENT" >/dev/null 2>&1; }
del_service_port_rule_ufw() {
  local RULE_NUM COMMENT_PREFIX='ArgoX UFW PORT'
  [ -z "$1" ] || [ -z "$2" ] && return 0
  ufw --force delete allow $2/$1 >/dev/null 2>&1 || true
  while read -r RULE_NUM; do [ -n "$RULE_NUM" ] && ufw --force delete "$RULE_NUM" >/dev/null 2>&1 || true; done < <(ufw status numbered 2>/dev/null | grep "$COMMENT_PREFIX $1 $2" | awk -F'[][]' '{print $2}' | sort -rn)
}
add_service_port_rule_firewalld() { [ -z "$1" ] || [ -z "$2" ] && return 1; firewall-cmd --zone=public --add-port=$2/$1 --permanent >/dev/null 2>&1; }
del_service_port_rule_firewalld() { [ -z "$1" ] || [ -z "$2" ] && return 0; firewall-cmd --zone=public --remove-port=$2/$1 --permanent >/dev/null 2>&1; }
service_port_iptables_comment() { echo "ArgoX PORT $1 $2"; }
add_service_port_rule_iptables() {
  local COMMENT; COMMENT=$(service_port_iptables_comment "$1" "$2")
  [ -z "$1" ] || [ -z "$2" ] && return 1
  iptables -C INPUT -p $1 --dport $2 -m comment --comment "$COMMENT" -j ACCEPT >/dev/null 2>&1 || iptables -A INPUT -p $1 --dport $2 -m comment --comment "$COMMENT" -j ACCEPT >/dev/null 2>&1
  ip6tables -C INPUT -p $1 --dport $2 -m comment --comment "$COMMENT" -j ACCEPT >/dev/null 2>&1 || ip6tables -A INPUT -p $1 --dport $2 -m comment --comment "$COMMENT" -j ACCEPT >/dev/null 2>&1
}
del_service_port_rule_iptables() {
  local COMMENT; COMMENT=$(service_port_iptables_comment "$1" "$2")
  [ -z "$1" ] || [ -z "$2" ] && return 0
  iptables -D INPUT -p $1 --dport $2 -m comment --comment "$COMMENT" -j ACCEPT >/dev/null 2>&1 || true
  ip6tables -D INPUT -p $1 --dport $2 -m comment --comment "$COMMENT" -j ACCEPT >/dev/null 2>&1 || true
}

# 将 iptables/ip6tables 规则持久化到文件，并创建多路径恢复钩子（兼容 OpenVZ）
# 调用顺序：1) 直接 iptables-save 写文件（最可靠）2) netfilter-persistent save（如果有）
save_iptables_rules() {
  # 确保目录存在
  mkdir -p /etc/iptables 2>/dev/null || true
  # 直接写文件——这是最可靠的持久化方式，不依赖 netfilter-persistent 是否正常工作
  iptables-save  > /etc/iptables/rules.v4  2>/dev/null || true
  ip6tables-save > /etc/iptables/rules.v6  2>/dev/null || true
  # 额外调用 netfilter-persistent save（如果可用）
  command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1 || true
  # 安装 if-pre-up.d 钩子（OpenVZ / 无 systemd-networkd 场景的 fallback）
  install_iptables_restore_hooks
}

# 安装 iptables 规则恢复钩子，兼容 OpenVZ / 普通 Debian-Ubuntu 环境
# 路径优先级：/etc/network/if-pre-up.d > /etc/rc.local > systemd oneshot service
install_iptables_restore_hooks() {
  local HOOK_DIR='/etc/network/if-pre-up.d'
  local HOOK_FILE="${HOOK_DIR}/argox-iptables-restore"
  local RC_LOCAL='/etc/rc.local'

  # 1) if-pre-up.d 钩子（网络接口 UP 之前执行，OpenVZ 下最可靠）
  if [ -d "$HOOK_DIR" ]; then
    cat > "$HOOK_FILE" << 'EOF'
#!/bin/sh
# ArgoX iptables 规则恢复钩子（由 argox 脚本自动写入，勿手动删除）
[ -f /etc/iptables/rules.v4 ] && iptables-restore  < /etc/iptables/rules.v4  2>/dev/null || true
[ -f /etc/iptables/rules.v6 ] && ip6tables-restore < /etc/iptables/rules.v6  2>/dev/null || true
exit 0
EOF
    chmod +x "$HOOK_FILE" 2>/dev/null || true
  fi

  # 2) /etc/rc.local fallback（OpenVZ 常见引导方式）
  if [ -f "$RC_LOCAL" ]; then
    # 如果 rc.local 里已有 argox restore 行，不重复写
    if ! grep -q 'argox-iptables-restore\|argox iptables restore' "$RC_LOCAL" 2>/dev/null; then
      # 在 exit 0 之前插入恢复命令
      sed -i '/^exit 0/i # ArgoX iptables restore\n[ -f /etc/iptables/rules.v4 ] \&\& iptables-restore  < /etc/iptables/rules.v4  2>\/dev\/null || true\n[ -f /etc/iptables/rules.v6 ] \&\& ip6tables-restore < /etc/iptables/rules.v6  2>\/dev\/null || true' "$RC_LOCAL" 2>/dev/null || true
    fi
  else
    # rc.local 不存在时创建
    cat > "$RC_LOCAL" << 'EOF'
#!/bin/sh -e
# ArgoX iptables restore (auto-generated, do not remove)
[ -f /etc/iptables/rules.v4 ] && iptables-restore  < /etc/iptables/rules.v4  2>/dev/null || true
[ -f /etc/iptables/rules.v6 ] && ip6tables-restore < /etc/iptables/rules.v6  2>/dev/null || true
exit 0
EOF
    chmod +x "$RC_LOCAL" 2>/dev/null || true
    # 让 systemd 知道 rc.local 可执行
    systemctl enable rc-local >/dev/null 2>&1 || true
  fi
}

# 按后端保存 / 重载防火墙规则
reload_or_save_firewall_rules() {
  local FW_BACKEND
  FW_BACKEND=$(check_firewall_backend)
  case "$FW_BACKEND" in
    ufw ) ufw reload >/dev/null 2>&1 || true ;;
    firewalld ) firewall-cmd --reload >/dev/null 2>&1 || true ;;
    alpine-iptables ) rc-service iptables save >/dev/null 2>&1 || true; rc-service ip6tables save >/dev/null 2>&1 || true ;;
    * ) save_iptables_rules ;;
  esac
}

# 清理上一次由脚本管理的普通端口规则
purge_service_firewall_rules() {
  local FW_BACKEND PORT
  FW_BACKEND=$(check_firewall_backend)
  init_firewall_state_dir
  MANAGED_TCP_PORTS=()
  MANAGED_UDP_PORTS=()
  if [ -s "$SERVICE_FIREWALL_STATE_FILE" ]; then
    while read -r PROTO PORT; do
      case "$PROTO" in
        tcp ) MANAGED_TCP_PORTS+=("$PORT") ;;
        udp ) MANAGED_UDP_PORTS+=("$PORT") ;;
      esac
    done < "$SERVICE_FIREWALL_STATE_FILE"
  fi
  case "$FW_BACKEND" in
    ufw )
      while read -r RULE_NUM; do [ -n "$RULE_NUM" ] && ufw --force delete "$RULE_NUM" >/dev/null 2>&1 || true; done < <(ufw status numbered 2>/dev/null | grep 'ArgoX UFW PORT' | awk -F'[][]' '{print $2}' | sort -rn)
      ufw reload >/dev/null 2>&1 || true
      ;;
    firewalld )
      for PORT in "${MANAGED_TCP_PORTS[@]}"; do del_service_port_rule_firewalld tcp "$PORT"; done
      for PORT in "${MANAGED_UDP_PORTS[@]}"; do del_service_port_rule_firewalld udp "$PORT"; done
      ;;
    alpine-iptables|iptables )
      for PORT in "${MANAGED_TCP_PORTS[@]}"; do del_service_port_rule_iptables tcp "$PORT"; done
      for PORT in "${MANAGED_UDP_PORTS[@]}"; do del_service_port_rule_iptables udp "$PORT"; done
      ;;
  esac
  : > "$SERVICE_FIREWALL_STATE_FILE"
  reload_or_save_firewall_rules
}

# 同步普通服务端口规则
sync_service_firewall_rules() {
  local FW_BACKEND PORT TAG NGINX_PORT_NOW HAS_NGINX=false
  EXPOSED_TCP_PORTS=()
  EXPOSED_UDP_PORTS=()
  if [ -s "$WORK_DIR/inbound.json" ]; then
    [ -s "$WORK_DIR/nginx.conf" ] && HAS_NGINX=true
    while IFS=$'	' read -r TAG PORT; do
      [ -z "$TAG" ] || [ -z "$PORT" ] && continue
      TAG=${TAG##* }
      case "$TAG" in
        hysteria2) append_unique_port EXPOSED_UDP_PORTS "$PORT" ;;
        vless-ws|vmess-ws|trojan-ws|ss-ws|xhttp-h1.1-cdn) [ "$HAS_NGINX" = false ] && append_unique_port EXPOSED_TCP_PORTS "$PORT" ;;
        xhttp-h3-direct) append_unique_port EXPOSED_UDP_PORTS "$PORT" ;;
        ss2022-direct) append_unique_port EXPOSED_TCP_PORTS "$PORT"; append_unique_port EXPOSED_UDP_PORTS "$PORT" ;;
        *) append_unique_port EXPOSED_TCP_PORTS "$PORT" ;;
      esac
    done < <($WORK_DIR/jq -r '.inbounds[] | [.tag, .port] | @tsv' "$WORK_DIR/inbound.json" 2>/dev/null)
    if [ "$HAS_NGINX" = true ]; then
      NGINX_PORT_NOW=$(awk '/listen[[:space:]]+[0-9]+[[:space:]]*;/{gsub(/;/, "", $2); print $2; exit}' "$WORK_DIR/nginx.conf")
      append_unique_port EXPOSED_TCP_PORTS "$NGINX_PORT_NOW"
    fi
  fi
  FW_BACKEND=$(check_firewall_backend)
  purge_service_firewall_rules
  case "$FW_BACKEND" in
    ufw )
      for PORT in "${EXPOSED_TCP_PORTS[@]}"; do add_service_port_rule_ufw tcp "$PORT"; done
      for PORT in "${EXPOSED_UDP_PORTS[@]}"; do add_service_port_rule_ufw udp "$PORT"; done
      ;;
    firewalld )
      for PORT in "${EXPOSED_TCP_PORTS[@]}"; do add_service_port_rule_firewalld tcp "$PORT"; done
      for PORT in "${EXPOSED_UDP_PORTS[@]}"; do add_service_port_rule_firewalld udp "$PORT"; done
      ;;
    alpine-iptables|iptables )
      for PORT in "${EXPOSED_TCP_PORTS[@]}"; do add_service_port_rule_iptables tcp "$PORT"; done
      for PORT in "${EXPOSED_UDP_PORTS[@]}"; do add_service_port_rule_iptables udp "$PORT"; done
      ;;
  esac
  init_firewall_state_dir
  : > "$SERVICE_FIREWALL_STATE_FILE"
  for PORT in "${EXPOSED_TCP_PORTS[@]}"; do [ -n "$PORT" ] && echo "tcp $PORT" >> "$SERVICE_FIREWALL_STATE_FILE"; done
  for PORT in "${EXPOSED_UDP_PORTS[@]}"; do [ -n "$PORT" ] && echo "udp $PORT" >> "$SERVICE_FIREWALL_STATE_FILE"; done
  reload_or_save_firewall_rules
}

# 同步 Hysteria2 端口跳跃规则
sync_port_hopping_firewall_rules() {
  local HY2_TARGET DESIRED_START DESIRED_END EXISTING_START EXISTING_END EXISTING_TARGET
  HY2_TARGET=$($WORK_DIR/jq -r '[.inbounds[] | select(.tag | split(" ")[-1] == "hysteria2") | .port] | .[0] // empty' "$WORK_DIR/inbound.json" 2>/dev/null)
  check_port_hopping_nat
  EXISTING_START="$PORT_HOPPING_START"
  EXISTING_END="$PORT_HOPPING_END"
  EXISTING_TARGET="$PORT_HOPPING_TARGET"
  DESIRED_START="${PORT_HOPPING_START:-$EXISTING_START}"
  DESIRED_END="${PORT_HOPPING_END:-$EXISTING_END}"
  if [ -z "$HY2_TARGET" ]; then
    [ -n "$EXISTING_START" ] && [ -n "$EXISTING_END" ] && del_port_hopping_nat
    unset PORT_HOPPING_START PORT_HOPPING_END PORT_HOPPING_RANGE PORT_HOPPING_TARGET
    return 0
  fi
  if [ -z "$DESIRED_START" ] || [ -z "$DESIRED_END" ]; then
    [ -n "$EXISTING_START" ] && [ -n "$EXISTING_END" ] && del_port_hopping_nat
    unset PORT_HOPPING_START PORT_HOPPING_END PORT_HOPPING_RANGE
    PORT_HOPPING_TARGET="$HY2_TARGET"
    return 0
  fi
  if [ "$EXISTING_START" != "$DESIRED_START" ] || [ "$EXISTING_END" != "$DESIRED_END" ] || [ "$EXISTING_TARGET" != "$HY2_TARGET" ]; then
    [ -n "$EXISTING_START" ] && [ -n "$EXISTING_END" ] && del_port_hopping_nat
    PORT_HOPPING_START="$DESIRED_START"
    PORT_HOPPING_END="$DESIRED_END"
    PORT_HOPPING_RANGE="${DESIRED_START}:${DESIRED_END}"
    PORT_HOPPING_TARGET="$HY2_TARGET"
    add_port_hopping_nat "$PORT_HOPPING_START" "$PORT_HOPPING_END" "$PORT_HOPPING_TARGET"
  fi
}

# 同步所有防火墙规则
sync_firewall_rules() {
  sync_service_firewall_rules
  sync_port_hopping_firewall_rules
}

# 清理所有由脚本管理的防火墙规则
purge_managed_firewall_rules() {
  local FW_BACKEND
  FW_BACKEND=$(check_firewall_backend)
  purge_service_firewall_rules
  case "$FW_BACKEND" in
    ufw )
      del_port_hopping_ufw_rules >/dev/null 2>&1 || true
      ;;
    * )
      del_port_hopping_nat >/dev/null 2>&1 || true
      ;;
  esac
}

# 按需安装端口跳跃所需的防火墙依赖
# 策略：UFW → 不安装 iptables / netfilter-persistent；Alpine → iptables；CentOS 或已装 firewalld → firewalld；其他 → iptables + netfilter-persistent
install_firewall_deps() {
  local FW_BACKEND FW_CHECK=() FW_INSTALL=() FW_TO_INSTALL=()
  FW_BACKEND=$(check_firewall_backend)
  case "$FW_BACKEND" in
    ufw )
      [ "$FIREWALL_SILENT" = '1' ] || info "\n $(text 115) \n"
      return 0
      ;;
    alpine-iptables )
      command -v iptables >/dev/null 2>&1 || FW_TO_INSTALL+=("iptables")
      ;;
    firewalld )
      command -v firewall-cmd >/dev/null 2>&1 || FW_TO_INSTALL+=("firewalld")
      ;;
    * )
      command -v iptables >/dev/null 2>&1 || FW_TO_INSTALL+=("iptables")
      if ! command -v netfilter-persistent >/dev/null 2>&1 ||
         ! dpkg -s iptables-persistent >/dev/null 2>&1; then
        FW_TO_INSTALL+=("iptables-persistent")
      fi
      ;;
  esac

  if [ "${#FW_TO_INSTALL[@]}" -gt 0 ]; then
    FW_TO_INSTALL=($(printf "%s\n" "${FW_TO_INSTALL[@]}" | sort -u))
    info "\n $(text 7) $(sed "s/ /,&/g" <<< "${FW_TO_INSTALL[*]}") \n"
    [ "$SYSTEM" != 'CentOS' ] && ${PACKAGE_UPDATE[int]} >/dev/null 2>&1
    ${PACKAGE_INSTALL[int]} "${FW_TO_INSTALL[@]}" >/dev/null 2>&1
  fi
  if [ "$FW_BACKEND" = 'firewalld' ]; then
    [ "$(systemctl is-active firewalld 2>/dev/null)" != 'active' ] && cmd_systemctl enable firewalld >/dev/null 2>&1
    [ "$(firewall-cmd --zone=public --get-target 2>/dev/null)" != 'ACCEPT' ] && firewall-cmd --zone=public --set-target=ACCEPT --permanent >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1
  elif [ "$FW_BACKEND" != 'ufw' ] && [ "$FW_BACKEND" != 'alpine-iptables' ]; then
    # 普通 iptables 后端：
    # 1) 确保 netfilter-persistent 开机自启（主路径）
    # 2) 安装 if-pre-up.d / rc.local 恢复钩子（OpenVZ fallback）
    if command -v netfilter-persistent >/dev/null 2>&1; then
      systemctl enable netfilter-persistent >/dev/null 2>&1 || true
    fi
    install_iptables_restore_hooks
  fi
}

# 添加端口跳跃 NAT 规则
add_port_hopping_nat() {
  local HOP_START=$1 HOP_END=$2 HOP_TARGET=$3 FW_BACKEND COMMENT
  [[ -z "$HOP_START" || -z "$HOP_END" || -z "$HOP_TARGET" ]] && return 1
  install_firewall_deps
  FW_BACKEND=$(check_firewall_backend)
  COMMENT="NAT ${HOP_START}:${HOP_END} to ${HOP_TARGET} (ArgoX)"
  case "$FW_BACKEND" in
    ufw )
      add_port_hopping_ufw_rules "$HOP_START" "$HOP_END" "$HOP_TARGET" || warning "\n $(text 117) \n"
      ;;
    alpine-iptables )
      iptables --table nat -A PREROUTING -p udp --dport ${HOP_START}:${HOP_END} -m comment --comment "$COMMENT" -j DNAT --to-destination :${HOP_TARGET} 2>/dev/null
      ip6tables --table nat -A PREROUTING -p udp --dport ${HOP_START}:${HOP_END} -m comment --comment "$COMMENT" -j DNAT --to-destination :${HOP_TARGET} 2>/dev/null
      rc-update show default | grep -q 'iptables' || rc-update add iptables >/dev/null 2>&1
      rc-update show default | grep -q 'ip6tables' || rc-update add ip6tables >/dev/null 2>&1
      rc-service iptables save >/dev/null 2>&1
      rc-service ip6tables save >/dev/null 2>&1
      ;;
    firewalld )
      [ "$(firewall-cmd --zone=public --query-masquerade --permanent 2>/dev/null)" != 'yes' ] && firewall-cmd --zone=public --add-masquerade --permanent >/dev/null 2>&1
      firewall-cmd --zone=public --add-forward-port=port=${HOP_START}-${HOP_END}:proto=udp:toport=${HOP_TARGET} --permanent >/dev/null 2>&1
      firewall-cmd --reload >/dev/null 2>&1
      ;;
    * )
      iptables --table nat -A PREROUTING -p udp --dport ${HOP_START}:${HOP_END} -m comment --comment "$COMMENT" -j DNAT --to-destination :${HOP_TARGET} 2>/dev/null
      ip6tables --table nat -A PREROUTING -p udp --dport ${HOP_START}:${HOP_END} -m comment --comment "$COMMENT" -j DNAT --to-destination :${HOP_TARGET} 2>/dev/null
      save_iptables_rules
      ;;
  esac
}

# 删除端口跳跃 NAT 规则
del_port_hopping_nat() {
  check_port_hopping_nat
  [ -z "$PORT_HOPPING_START" ] && return
  local FW_BACKEND COMMENT
  FW_BACKEND=$(check_firewall_backend)
  COMMENT="NAT ${PORT_HOPPING_START}:${PORT_HOPPING_END} to ${PORT_HOPPING_TARGET} (ArgoX)"
  case "$FW_BACKEND" in
    ufw )
      del_port_hopping_ufw_rules || warning "\n $(text 117) \n"
      ;;
    alpine-iptables )
      iptables --table nat -D PREROUTING -p udp --dport ${PORT_HOPPING_START}:${PORT_HOPPING_END} -m comment --comment "$COMMENT" -j DNAT --to-destination :${PORT_HOPPING_TARGET} 2>/dev/null
      ip6tables --table nat -D PREROUTING -p udp --dport ${PORT_HOPPING_START}:${PORT_HOPPING_END} -m comment --comment "$COMMENT" -j DNAT --to-destination :${PORT_HOPPING_TARGET} 2>/dev/null
      ;;
    firewalld )
      firewall-cmd --zone=public --permanent --remove-forward-port=port=${PORT_HOPPING_START}-${PORT_HOPPING_END}:proto=udp:toport=${PORT_HOPPING_TARGET} >/dev/null 2>&1
      firewall-cmd --reload >/dev/null 2>&1
      ;;
    * )
      iptables --table nat -D PREROUTING -p udp --dport ${PORT_HOPPING_START}:${PORT_HOPPING_END} -m comment --comment "$COMMENT" -j DNAT --to-destination :${PORT_HOPPING_TARGET} 2>/dev/null
      ip6tables --table nat -D PREROUTING -p udp --dport ${PORT_HOPPING_START}:${PORT_HOPPING_END} -m comment --comment "$COMMENT" -j DNAT --to-destination :${PORT_HOPPING_TARGET} 2>/dev/null
      save_iptables_rules
      ;;
  esac
}

# 检查端口跳跃 NAT 规则（读取当前 UFW / iptables / firewalld）
check_port_hopping_nat() {
  local FW_BACKEND LIST
  FW_BACKEND=$(check_firewall_backend)
  unset PORT_HOPPING_START PORT_HOPPING_END PORT_HOPPING_RANGE PORT_HOPPING_TARGET
  [ -s $WORK_DIR/inbound.json ] && PORT_HOPPING_TARGET=$($WORK_DIR/jq -r '[.inbounds[] | select(.tag | split(" ")[-1] == "hysteria2") | .port] | .[0] // empty' $WORK_DIR/inbound.json 2>/dev/null)
  [ -z "$PORT_HOPPING_TARGET" ] && return
  case "$FW_BACKEND" in
    ufw )
      check_port_hopping_ufw_rules
      # 若 UFW 规则已被清空，仍保留当前 Hysteria2 监听端口，方便后续重新启用端口跳跃
      [ -z "$PORT_HOPPING_TARGET" ] && PORT_HOPPING_TARGET=$($WORK_DIR/jq -r '[.inbounds[] | select(.tag | split(" ")[-1] == "hysteria2") | .port] | .[0] // empty' $WORK_DIR/inbound.json 2>/dev/null)
      ;;
    alpine-iptables|iptables )
      LIST=$(iptables --table nat --list-rules PREROUTING 2>/dev/null | grep 'ArgoX')
      [ -n "$LIST" ] && PORT_HOPPING_RANGE=$(awk '{for(i=0;i<NF;i++) if($i=="--dport"){print $(i+1);exit}}' <<< "$LIST") && PORT_HOPPING_TARGET=$(awk '{for(i=0;i<NF;i++) if($i=="to"){print $(i+1);exit}}' <<< "$LIST")
      ;;
    firewalld )
      LIST=$(firewall-cmd --zone=public --list-all --permanent 2>/dev/null | grep "toport=${PORT_HOPPING_TARGET}")
      [ -n "$LIST" ] && PORT_HOPPING_START=$(sed "s/.*port=\([^-]\+\)-.*toport.*/\1/" <<< "$LIST") && PORT_HOPPING_END=$(sed "s/.*port=${PORT_HOPPING_START}-\([^:]\+\):.*/\1/" <<< "$LIST")
      ;;
  esac
  [ -n "$PORT_HOPPING_RANGE" ] && PORT_HOPPING_START=${PORT_HOPPING_RANGE%:*} && PORT_HOPPING_END=${PORT_HOPPING_RANGE#*:}
}

# 输入 Hysteria2 端口跳跃范围
input_hopping_port() {
  local HOPPING_ERROR_TIME=6
  until [ -n "$IS_HOPPING" ]; do
    if [ -z "$PORT_HOPPING_RANGE" ]; then
      (( HOPPING_ERROR_TIME-- )) || true
      case "$HOPPING_ERROR_TIME" in
        0 ) error "\n $(text 3) \n" ;;
        5 ) hint "\n $(text 104) \n" && reading " $(text 105) " PORT_HOPPING_RANGE ;;
        * ) reading " $(text 105) " PORT_HOPPING_RANGE ;;
      esac
    fi
    # 预处理：全角冒号/破折号统一换半角，再过滤非法字符
    PORT_HOPPING_RANGE=$(echo "$PORT_HOPPING_RANGE" | sed 's/：/:/g; s/[－—]/-/g' | tr -cd '0-9:-')
    local _R=${PORT_HOPPING_RANGE//-/:}
    if [[ "$_R" =~ ^[0-9]{4,5}:[0-9]{4,5}$ ]]; then
      PORT_HOPPING_RANGE=$_R
      PORT_HOPPING_START=${_R%:*}
      PORT_HOPPING_END=${_R#*:}
      if [[ "$PORT_HOPPING_START" -lt "$PORT_HOPPING_END" && \
            "$PORT_HOPPING_START" -ge "$MIN_HOPPING_PORT" && \
            "$PORT_HOPPING_END" -le "$MAX_HOPPING_PORT" ]]; then
        IS_HOPPING=is_hopping
      else
        warning "\n $(text 114) " && unset PORT_HOPPING_RANGE
      fi
    elif [[ -z "$PORT_HOPPING_RANGE" || "${PORT_HOPPING_RANGE,,}" =~ ^(n|no)$ ]]; then
      IS_HOPPING=no_hopping
    else
      warning "\n $(text 36) " && unset PORT_HOPPING_RANGE
    fi
  done
}

# 处理防火墙规则

# Nginx 配置文件（新架构：Nginx 作为唯一对外分流入口，按已安装协议动态生成 location）
json_nginx() {
  local PROTOCOLS_NOW
  PROTOCOLS_NOW=$(get_installed_protocols | tr '\n' ' ')
  if [ -z "$WS_PATH" ] && [ -s $WORK_DIR/inbound.json ]; then
    WS_PATH=$(grep -v '^//' $WORK_DIR/inbound.json | $WORK_DIR/jq -r '.inbounds[] | select(.streamSettings.network=="ws") | .streamSettings.wsSettings.path' | head -1 | sed 's|/||; s|-vl$||; s|-vm$||; s|-tr$||; s|-sh$||; s|-xh$||')
    [ -z "$WS_PATH" ] && WS_PATH=$(grep -v '^//' $WORK_DIR/inbound.json | $WORK_DIR/jq -r '[.inbounds[] | select((.tag | split(" ")[-1]) == "xhttp-h1.1-cdn") | .streamSettings.xhttpSettings.path] | .[0] // empty' 2>/dev/null | sed 's|^/||; s|-xh$||')
    [ -z "$WS_PATH" ] && WS_PATH=$(grep -v '^//' $WORK_DIR/inbound.json | $WORK_DIR/jq -r '[.inbounds[] | select((.tag | split(" ")[-1]) == "xhttp-h3-direct") | .streamSettings.xhttpSettings.path] | .[0] // empty' 2>/dev/null | sed 's|^/||; s|-xh3$||')
  fi
  [ -z "$WS_PATH" ] && WS_PATH="$WS_PATH_DEFAULT"
  if [ -z "$UUID" ] && [ -s $WORK_DIR/inbound.json ]; then
    UUID=$(grep -v '^//' $WORK_DIR/inbound.json | $WORK_DIR/jq -r '.inbounds[0].settings.clients[0].id // .inbounds[0].settings.clients[0].password // empty')
  fi
  if [ -z "$NGINX_PORT" ]; then
    if [ -s $WORK_DIR/nginx.conf ]; then
      NGINX_PORT=$(awk '/listen/{print $2; exit}' $WORK_DIR/nginx.conf | tr -d ';')
    fi
    NGINX_PORT=${NGINX_PORT:-"$NGINX_PORT_DEFAULT"}
  fi

  _ws_location() {
    local path=$1 port=$2
    printf '    location ~ ^%s {\n' "$path"
    printf '      proxy_pass          http://127.0.0.1:%s;\n' "$port"
    printf '      proxy_http_version  1.1;\n'
    printf '      proxy_set_header    Upgrade $http_upgrade;\n'
    printf '      proxy_set_header    Connection "upgrade";\n'
    printf '      proxy_set_header    X-Real-IP $remote_addr;\n'
    printf '      proxy_set_header    X-Forwarded-For $proxy_add_x_forwarded_for;\n'
    printf '      proxy_set_header    Host $host;\n'
    printf '      proxy_redirect      off;\n'
    printf '      proxy_buffering     off;\n'
    printf '      proxy_read_timeout  1h;\n'
    printf '      proxy_send_timeout  1h;\n'
    printf '    }\n'
  }

  _xhttp_location() {
    local path=$1 port=$2
    printf '    location ~ ^%s {\n' "$path"
    printf '      proxy_pass                  http://127.0.0.1:%s;\n' "$port"
    printf '      proxy_http_version          1.1;\n'
    printf '      proxy_set_header            Host $host;\n'
    printf '      proxy_set_header            X-Real-IP $remote_addr;\n'
    printf '      proxy_set_header            X-Forwarded-For $proxy_add_x_forwarded_for;\n'
    printf '      proxy_set_header            X-Forwarded-Proto $scheme;\n'
    printf '      proxy_redirect              off;\n'
    printf '      proxy_buffering             off;\n'
    printf '      proxy_request_buffering     off;\n'
    printf '      proxy_max_temp_file_size    0;\n'
    printf '      chunked_transfer_encoding   on;\n'
    printf '      tcp_nodelay                 on;\n'
    printf '      proxy_read_timeout          1h;\n'
    printf '      proxy_send_timeout          1h;\n'
    printf '      client_max_body_size        0;\n'
    printf '      client_body_timeout         1h;\n'
    printf '    }\n'
  }

  local SERVER_BLOCK=''

  local _PORT_VL _PORT_VM _PORT_TR _PORT_SH _PORT_XH
  if [ -s $WORK_DIR/inbound.json ] && [ -x $WORK_DIR/jq ]; then
    local JSON_CLEAN=$(grep -v '^//' $WORK_DIR/inbound.json)
    _PORT_VL=$(echo "$JSON_CLEAN" | $WORK_DIR/jq -r '[.inbounds[] | select(.tag | split(" ")[-1] == "vless-ws") | .port] | .[0] // empty' 2>/dev/null)
    _PORT_VM=$(echo "$JSON_CLEAN" | $WORK_DIR/jq -r '[.inbounds[] | select(.tag | split(" ")[-1] == "vmess-ws") | .port] | .[0] // empty' 2>/dev/null)
    _PORT_TR=$(echo "$JSON_CLEAN" | $WORK_DIR/jq -r '[.inbounds[] | select(.tag | split(" ")[-1] == "trojan-ws") | .port] | .[0] // empty' 2>/dev/null)
    _PORT_SH=$(echo "$JSON_CLEAN" | $WORK_DIR/jq -r '[.inbounds[] | select(.tag | split(" ")[-1] == "ss-ws") | .port] | .[0] // empty' 2>/dev/null)
    _PORT_XH=$(echo "$JSON_CLEAN" | $WORK_DIR/jq -r '[.inbounds[] | select(.tag | split(" ")[-1] == "xhttp-h1.1-cdn") | .port] | .[0] // empty' 2>/dev/null)
  fi
  _PORT_VL=${_PORT_VL:-${VLESS_WS_PORT}}
  _PORT_VM=${_PORT_VM:-${VMESS_WS_PORT}}
  _PORT_TR=${_PORT_TR:-${TROJAN_WS_PORT}}
  _PORT_SH=${_PORT_SH:-${SS_WS_PORT}}
  _PORT_XH=${_PORT_XH:-${VLESS_XHTTP_PORT}}

  _add_location() { SERVER_BLOCK+="$1"; SERVER_BLOCK+=$'\n\n'; }
  grep -q 'vless-ws' <<< "$PROTOCOLS_NOW" && _add_location "$(_ws_location "/${WS_PATH}-vl" "$_PORT_VL")"
  grep -q 'vmess-ws' <<< "$PROTOCOLS_NOW" && _add_location "$(_ws_location "/${WS_PATH}-vm" "$_PORT_VM")"
  grep -q 'trojan-ws' <<< "$PROTOCOLS_NOW" && _add_location "$(_ws_location "/${WS_PATH}-tr" "$_PORT_TR")"
  grep -qw 'ss-ws' <<< "$PROTOCOLS_NOW" && _add_location "$(_ws_location "/${WS_PATH}-sh" "$_PORT_SH")"
  grep -q 'xhttp-h1.1-cdn' <<< "$PROTOCOLS_NOW" && _add_location "$(_xhttp_location "/${WS_PATH}-xh" "${_PORT_XH}")"
  local SUB_BLOCK
  SUB_BLOCK=$(printf '    location ~ ^/%s/auto {
      default_type  text/plain;
      alias         %s/subscribe/$path;
    }

    location ~ ^/%s/(.*) {
      autoindex     on;
      default_type  text/plain;
      alias         %s/subscribe/$1;
    }\n' "$UUID" "$WORK_DIR" "$UUID" "$WORK_DIR")
  SERVER_BLOCK+="$SUB_BLOCK"

  cat > $WORK_DIR/nginx.conf << EOF
user  root;
worker_processes  auto;

error_log  /dev/null;
pid        /var/run/nginx.pid;

events {
  worker_connections  1024;
}

http {
  map \$http_user_agent \$path {
    default               /;
    ~*v2rayN|Neko|Throne  /base64;
    ~*clash               /clash;
    ~*ShadowRocket        /shadowrocket;
    ~*PassWall            /passwall;
    ~*SFM|SFI|SFA        /sing-box;
  }

  include           /etc/nginx/mime.types;
  default_type      application/octet-stream;
  access_log        /dev/null;
  sendfile          on;
  keepalive_timeout 65;

  server {
    listen      ${NGINX_PORT};
    server_name localhost;

${SERVER_BLOCK}
  }
}
EOF
}

# xhttp-h1.1-cdn 统一由 Nginx 分流，Tunnel 层不再直连本地 Xray inbound
use_tunnel_direct_xhttp() {
  return 1
}


# Json 生成两个配置文件
json_argo() {
  [ -z "$ARGO_JSON" ] && [ -s "$WORK_DIR/tunnel.json" ] && ARGO_JSON=$(tr -d '
' < "$WORK_DIR/tunnel.json")
  [ ! -s "$WORK_DIR/tunnel.json" ] && [ -n "$ARGO_JSON" ] && echo "$ARGO_JSON" > "$WORK_DIR/tunnel.json"

  [ -z "$ARGO_DOMAIN" ] && [ -s "$WORK_DIR/tunnel.yml" ] && ARGO_DOMAIN=$(awk '/^[[:space:]]*- hostname:/{print $3; exit}' "$WORK_DIR/tunnel.yml" 2>/dev/null)
  [ -z "$ARGO_DOMAIN" ] && fetch_tunnel_domain config >/dev/null 2>&1 || true
  [ -z "$ARGO_DOMAIN" ] && [ -s "$WORK_DIR/list" ] && ARGO_DOMAIN=$(grep -m1 '^vless.*host=.*' "$WORK_DIR/list" | sed 's@.*host=\([^&]*\).*@\1@')
  [ -z "$ARGO_DOMAIN" ] && return 1

  [ -z "$NGINX_PORT" ] && [ -s "$WORK_DIR/nginx.conf" ] && NGINX_PORT=$(awk '/listen[[:space:]]/{gsub(/;/, "", $2); print $2; exit}' "$WORK_DIR/nginx.conf")
  NGINX_PORT="${NGINX_PORT:-$NGINX_PORT_DEFAULT}"

  cat > $WORK_DIR/tunnel.yml << EOF
tunnel: $(cut -d\" -f12 <<< $ARGO_JSON)
credentials-file: $WORK_DIR/tunnel.json

ingress:
  - hostname: ${ARGO_DOMAIN}
    service: http://localhost:${NGINX_PORT}

  - service: http_status:404
EOF
}
# 创建 Argo Tunnel API
create_argo_tunnel() {
  [ -s "$WORK_DIR/inbound.json" ] && [ -x "$WORK_DIR/jq" ] && WS_PATH=$(grep -v '^//' "$WORK_DIR/inbound.json" | $WORK_DIR/jq -r '[.inbounds[] | select((.tag | split(" ")[-1]) == "xhttp-h1.1-cdn") | .streamSettings.xhttpSettings.path] | .[0] // empty' 2>/dev/null | sed 's|^/||; s|-xh$||')
  WS_PATH="${WS_PATH:-$WS_PATH_DEFAULT}"
  local CLOUDFLARE_API_TOKEN="$1"
  local ARGO_DOMAIN="$2"
  local SERVICE_PORT="$3"
  local TUNNEL_NAME=${ARGO_DOMAIN%%.*}
  local ROOT_DOMAIN=${ARGO_DOMAIN#*.}

  api_error() {
    local RESPONSE="$1"
    local CHECK_ZONE_ID="$2"

    if grep -q '"code":9109,' <<< "$RESPONSE"; then
      warning " $(text 81) " && sleep 2 && return 2
    elif grep -q '"code":7003,' <<< "$RESPONSE"; then
      warning " $(text 82) " && sleep 2 && return 3
    elif grep -q 'check_zone_id' <<< "$CHECK_ZONE_ID" && grep -q '"count":0,' <<< "$RESPONSE"; then
      warning " $(text 83) " && sleep 2 && return 4
    elif grep -q '"code":10000,' <<< "$RESPONSE"; then
      warning " $(text 85) " && sleep 2 && return 1
    elif grep -q '"success":true' <<< "$RESPONSE"; then
      return 0
    else
      warning " $(text 84) " && sleep 2 && return 5
    fi
  }

  local ZONE_RESPONSE=$(wget -qO- --content-on-error \
    --header="Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
    --header="Content-Type: application/json" \
    "https://api.cloudflare.com/client/v4/zones?name=${ROOT_DOMAIN}")

  api_error "$ZONE_RESPONSE" 'check_zone_id' || return $?

  [[ "$ZONE_RESPONSE" =~ \"id\":\"([^\"]+)\".*\"account\":\{\"id\":\"([^\"]+)\" ]] && local ZONE_ID="${BASH_REMATCH[1]}" ACCOUNT_ID="${BASH_REMATCH[2]}" || \
  return 5

  local TUNNEL_LIST=$(wget -qO- --content-on-error \
    --header="Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
    --header="Content-Type: application/json" \
    "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/cfd_tunnel?is_deleted=false")

  api_error "$TUNNEL_LIST" || return $?

  local TUNNEL_LIST_SPLIT=$(awk 'BEGIN{RS="";FS=""}{s=substr($0,index($0,"\"result\":[")+10);d=0;b="";for(i=1;i<=length(s);i++){c=substr(s,i,1);if(c=="{")d++;if(d>0)b=b c;if(c=="}"){d--;if(d==0){print b;b=""}}}}' <<< "$TUNNEL_LIST")

  while true; do
    unset TUNNEL_CHECK EXISTING_TUNNEL_ID EXISTING_TUNNEL_STATUS
    local TUNNEL_CHECK=$(grep '\"name\":\"'$TUNNEL_NAME'\"' <<< "$TUNNEL_LIST_SPLIT")
    if [[ "$TUNNEL_CHECK" =~ \"id\":\"([^\"]+)\".*\"status\":\"([^\"]+)\" ]]; then
      local EXISTING_TUNNEL_ID=${BASH_REMATCH[1]} EXISTING_TUNNEL_STATUS=${BASH_REMATCH[2]}
      grep -qw 'C' <<< "$L" && EXISTING_TUNNEL_STATUS=$(sed 's/inactive/停用（未激活）/; s/down/离线/; s/healthy/连接中/; s/degraded/降级/ ' <<< "$EXISTING_TUNNEL_STATUS")
      reading "\n $(text 79) " OVERWRITE
      if grep -qw 'n' <<< "${OVERWRITE,,}"; then
        unset ARGO_DOMAIN
        reading "\n $(text 10) " ARGO_DOMAIN
        ! grep -q '\.' <<< "$ARGO_DOMAIN" && return 5
        TUNNEL_NAME=${ARGO_DOMAIN%%.*}
        ROOT_DOMAIN=${ARGO_DOMAIN#*.}
      else
        break
      fi
    else
      unset TUNNEL_CHECK EXISTING_TUNNEL_ID EXISTING_TUNNEL_STATUS
      break
    fi
  done

  if [ -z "$EXISTING_TUNNEL_ID" ]; then
    local TUNNEL_SECRET=$(openssl rand -base64 32)

    local CREATE_RESPONSE=$(wget -qO- --content-on-error \
      --header="Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
      --header="Content-Type: application/json" \
      --post-data="{
        \"name\": \"$TUNNEL_NAME\",
        \"config_src\": \"cloudflare\",
        \"tunnel_secret\": \"$TUNNEL_SECRET\"
      }" \
      "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/cfd_tunnel")

    api_error "$CREATE_RESPONSE" || return $?

    [[ $CREATE_RESPONSE =~ \"id\":\"([^\"]+)\".*\"token\":\"([^\"]+)\" ]] && \
    local TUNNEL_ID=${BASH_REMATCH[1]} TUNNEL_TOKEN=${BASH_REMATCH[2]} || \
    return 5
  else
    local EXISTING_TUNNEL_TOKEN=$(wget -qO- --content-on-error \
      --header="Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
      --header="Content-Type: application/json" \
      "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/cfd_tunnel/${EXISTING_TUNNEL_ID}/token")

    api_error "$EXISTING_TUNNEL_TOKEN" || return $?

    local TUNNEL_ID=$EXISTING_TUNNEL_ID \
    TUNNEL_TOKEN=$(sed -n 's/.*"result":"\([^"]\+\)".*/\1/p' <<< "$EXISTING_TUNNEL_TOKEN") && \
    TUNNEL_SECRET=$(base64 -d <<< "$TUNNEL_TOKEN" | sed 's/.*"s":"\([^"]\+\)".*/\1/') || \
    return 5
  fi

  local CONFIG_RESPONSE=$(wget -qO- --content-on-error \
    --method=PUT \
    --header="Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
    --header="Content-Type: application/json" \
    --body-data="{
      \"config\": {
        \"ingress\": [
          {
            \"service\": \"http://localhost:${SERVICE_PORT}\",
            \"hostname\": \"${ARGO_DOMAIN}\"
          },
          {
            \"service\": \"http_status:404\"
          }
        ],
        \"warp-routing\": {
          \"enabled\": false
        }
      }
    }" \
    "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/configurations")

  api_error "$CONFIG_RESPONSE" || return $?

  local DNS_PAYLOAD="{
    \"name\": \"${ARGO_DOMAIN}\",
    \"type\": \"CNAME\",
    \"content\": \"${TUNNEL_ID}.cfargotunnel.com\",
    \"proxied\": true,
    \"settings\": {
      \"flatten_cname\": false
    }
  }"

  local DNS_LIST=$(wget -qO- --content-on-error \
    --header="Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
    --header="Content-Type: application/json" \
    "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records?type=CNAME&name=${ARGO_DOMAIN}")

  api_error "$DNS_LIST" || return $?

  if [[ "$DNS_LIST" =~ \"id\":\"([^\"]+)\".*\"$ARGO_DOMAIN\".*\"content\":\"([^\"]+)\" ]]; then
    local EXISTING_DNS_ID="${BASH_REMATCH[1]}" EXISTED_DNS_CONTENT="${BASH_REMATCH[2]}"

    if ! grep -qw "$EXISTING_TUNNEL_ID" <<< "${EXISTED_DNS_CONTENT%%.*}"; then
      local DNS_RESPONSE=$(wget -qO- --content-on-error \
        --method=PATCH \
        --header="Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
        --header="Content-Type: application/json" \
        --body-data="$DNS_PAYLOAD" \
        "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${EXISTING_DNS_ID}")

      api_error "$DNS_RESPONSE" || return $?
    fi
  else
    local DNS_RESPONSE=$(wget -qO- --content-on-error \
      --method=POST \
      --header="Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
      --header="Content-Type: application/json" \
      --body-data="$DNS_PAYLOAD" \
      "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records")

    api_error "$DNS_RESPONSE" || return $?
  fi

  ARGO_JSON="{\"AccountTag\":\"$ACCOUNT_ID\",\"TunnelSecret\":\"$TUNNEL_SECRET\",\"TunnelID\":\"$TUNNEL_ID\",\"Endpoint\":\"\"}"
}

install_argox() {
  xray_variable
  argo_variable

  wait
  local _HAS_REALITY_INSTALL=false
  for _p in "${INSTALL_PROTOCOLS[@]}"; do [[ "$_p" =~ ^[bd]$ ]] && _HAS_REALITY_INSTALL=true && break; done
  if $_HAS_REALITY_INSTALL; then
    if [ -n "$REALITY_PRIVATE" ] && [ -z "$REALITY_PUBLIC" ]; then
      # 有私钥无公钥（如 config.conf 只填了私钥）→ xray 已就位，从私钥推导公钥
      REALITY_PUBLIC=$($TEMP_DIR/xray x25519 -i "$REALITY_PRIVATE" | awk '/Public/{print $NF}')
      if [ -z "$REALITY_PUBLIC" ]; then
        warning " $(text 99) "
        REALITY_KEYPAIR=$($TEMP_DIR/xray x25519)
        REALITY_PRIVATE=$(awk '/Private/{print $NF}' <<< "$REALITY_KEYPAIR")
        REALITY_PUBLIC=$(awk '/Public|Password/{print $NF}' <<< "$REALITY_KEYPAIR")
      fi
    elif [ -z "$REALITY_PRIVATE" ]; then
      # 私钥也为空 → 随机生成一对
      REALITY_KEYPAIR=$($TEMP_DIR/xray x25519)
      REALITY_PRIVATE=$(awk '/Private/{print $NF}' <<< "$REALITY_KEYPAIR")
      REALITY_PUBLIC=$(awk '/Public|Password/{print $NF}' <<< "$REALITY_KEYPAIR")
    fi
  fi

  [ ! -d /etc/systemd/system ] && mkdir -p /etc/systemd/system
  mkdir -p $WORK_DIR/subscribe
  protect_secret_files
  install_trycloudflare_url_watcher
  [ "$L" = 'C' ] && write_custom 'language' 'Chinese' || write_custom 'language' 'English'
  prepare_vless_pqc_keys
  ech_runtime_values
  protect_secret_files

  write_custom 'serverIp' "${SERVER_IP}"
  if [ -n "${REALITY_DOMAIN:-}" ]; then
    validate_reality_addr "$REALITY_DOMAIN" || error " $(text 127) "
    write_custom 'realityDomain' "${REALITY_DOMAIN}"
  else
    write_custom 'realityDomain' '__REALITY_DOMAIN_UNSET__'
  fi
  write_custom 'privateKey' "${REALITY_PRIVATE:-__KEY_UNSET__}"
  write_custom 'publicKey' "${REALITY_PUBLIC:-__KEY_UNSET__}"
  write_custom 'cdn' "${SERVER:-__CDN_UNSET__}"
  write_custom 'cdnPort' "${SERVER_PORT:-443}"
  write_custom 'wsPath' "${WS_PATH:-$WS_PATH_DEFAULT}"
  write_custom 'enableEch' "${ENABLE_ECH:-y}"
  write_custom 'echStrict' "${ECH_STRICT:-y}"
  write_custom 'echConfig' "${ECH_CONFIG:-}"
  write_custom 'echQueryDomain' "${ECH_QUERY_DOMAIN:-cloudflare-ech.com}"
  write_custom 'echDns' "${ECH_DNS:-https://1.1.1.1/dns-query}"
  write_custom 'xhttpCdnMode' "${XHTTP_CDN_MODE:-packet-up}"
  write_custom 'enableXhttpSplit' "${ENABLE_XHTTP_SPLIT:-n}"
  write_custom 'xhttpDownloadServer' "${XHTTP_DOWNLOAD_SERVER:-}"
  write_custom 'xhttpDownloadPort' "${XHTTP_DOWNLOAD_PORT:-}"
  [ -s "$VARIABLE_FILE" ] && cp $VARIABLE_FILE $WORK_DIR/

  wait
  [[ ! -s $WORK_DIR/cloudflared && -x $TEMP_DIR/cloudflared ]] && mv $TEMP_DIR/cloudflared $WORK_DIR
  [[ ! -s $WORK_DIR/jq && -x $TEMP_DIR/jq ]] && mv $TEMP_DIR/jq $WORK_DIR
  [[ "$INSTALL_NGINX" != 'n' && ! -s $WORK_DIR/qrencode && -x $TEMP_DIR/qrencode ]] && mv $TEMP_DIR/qrencode $WORK_DIR
  protect_secret_files
  if [[ -n "${ARGO_JSON}" && -n "${ARGO_DOMAIN}" ]]; then
    ARGO_RUNS="$WORK_DIR/cloudflared tunnel --edge-ip-version auto --config $WORK_DIR/tunnel.yml run"
    json_argo
  elif [[ -n "${ARGO_TOKEN}" && -n "${ARGO_DOMAIN}" ]]; then
    ARGO_RUNS="$WORK_DIR/cloudflared tunnel --edge-ip-version auto run --token ${ARGO_TOKEN}"
  else
    ARGO_RUNS="$WORK_DIR/cloudflared tunnel --edge-ip-version auto --no-autoupdate --url http://localhost:${NGINX_PORT}"
  fi

  if [ "$SYSTEM" = 'Alpine' ]; then
    local COMMAND=${ARGO_RUNS%% --*}
    local ARGS=${ARGO_RUNS#$COMMAND }

    cat > ${ARGO_DAEMON_FILE} << EOF
#!/sbin/openrc-run

name="argo"
description="Cloudflare Tunnel"

command="${COMMAND}"
command_args="${ARGS}"

pidfile="/run/\${RC_SVCNAME}.pid"
command_background="yes"

output_log="${WORK_DIR}/argo.log"
error_log="${WORK_DIR}/argo.log"

depend() {
    need net
    after firewall
}

start_pre() {
    mkdir -p ${WORK_DIR} /run
    rm -f "\$pidfile"
}

start_post() {
    if echo "${ARGO_RUNS}" | grep -q -- "--url http://localhost"; then
        ${WORK_DIR}/argox-url-watch.sh >/dev/null 2>&1 &
    fi
    return 0
}

stop() {
    ebegin "Stopping \${RC_SVCNAME}"
    start-stop-daemon --stop --quiet --pidfile "\$pidfile" --retry 5
    local CF_PIDS
    CF_PIDS="\$(ps -eo pid,args | awk '\$0~/\/etc\/argox\/cloudflared/{print \$1}')"
    if [ -n "\$CF_PIDS" ]; then
        einfo "Force killing cloudflared: \$CF_PIDS"
        kill -9 \$CF_PIDS 2>/dev/null
    fi
    rm -f "\$pidfile"
    eend 0
    return 0
}
EOF
    chmod +x ${ARGO_DAEMON_FILE}

    cat > ${XRAY_DAEMON_FILE} << EOF
#!/sbin/openrc-run

name="xray"
description="Xray Service"

command="${WORK_DIR}/xray"
command_args="run -c ${WORK_DIR}/inbound.json -c ${WORK_DIR}/outbound.json"

pidfile="/run/\${RC_SVCNAME}.pid"
command_background="yes"

output_log="${WORK_DIR}/xray.log"
error_log="${WORK_DIR}/xray.log"

depend() {
    need net
    after firewall
}

start_pre() {
    mkdir -p ${WORK_DIR} /run
    chmod 700 ${WORK_DIR}
    rm -f "\$pidfile"

    ${WORK_DIR}/xray run -test -c ${WORK_DIR}/inbound.json -c ${WORK_DIR}/outbound.json >/dev/null 2>&1 || return 1

    if [ -s ${WORK_DIR}/nginx.conf ]; then
        [ -x /usr/sbin/nginx ] || return 1
        /usr/sbin/nginx -t -c ${WORK_DIR}/nginx.conf >/dev/null 2>&1 || return 1
        if ! pgrep -f "nginx.*${WORK_DIR}/nginx.conf" >/dev/null 2>&1; then
            /usr/sbin/nginx -c ${WORK_DIR}/nginx.conf >/dev/null 2>&1 || return 1
        fi
    fi
    return 0
}

stop() {
    ebegin "Stopping \${RC_SVCNAME}"
    start-stop-daemon --stop --quiet --pidfile "\$pidfile" --retry 5
    local RETVAL=\$?
    if [ \$RETVAL -ne 0 ]; then
        local XRAY_PIDS
        XRAY_PIDS="\$(ps -eo pid,args | awk -v work_dir="\$WORK_DIR" '\$0~(work_dir"/xray run"){print \$1;exit}')"
        if [ -n "\$XRAY_PIDS" ]; then
            for pid in \$XRAY_PIDS; do
                kill -9 "\$pid" 2>/dev/null
            done
        fi
    fi
    if [ -s ${WORK_DIR}/nginx.conf ] && command -v /usr/sbin/nginx >/dev/null 2>&1; then
        /usr/sbin/nginx -c ${WORK_DIR}/nginx.conf -s stop 2>/dev/null
        sleep 1
        local NGINX_REMAINING
        NGINX_REMAINING="\$(ps -eo pid,args | awk '\$0~/nginx.*\/etc\/argox\/nginx.conf/{print \$1}')"
        [ -n "\$NGINX_REMAINING" ] && kill -9 \$NGINX_REMAINING 2>/dev/null
    fi
    rm -f "\$pidfile"
    eend 0
}
EOF
    chmod +x ${XRAY_DAEMON_FILE}
  else
    local ARGO_SERVER="[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
Type=simple
NoNewPrivileges=yes
TimeoutStartSec=0"
    ARGO_SERVER+="
ExecStart=$ARGO_RUNS
Restart=on-failure
RestartSec=5s"
    [[ "$ARGO_RUNS" == *"--url http://localhost"* ]] && ARGO_SERVER+="
ExecStartPost=/bin/bash -c '${WORK_DIR}/argox-url-watch.sh >/dev/null 2>&1 &'"
    ARGO_SERVER+="

[Install]
WantedBy=multi-user.target"

    echo "$ARGO_SERVER" > ${ARGO_DAEMON_FILE}

    local XRAY_SERVICE="[Unit]
Description=Xray Service
Documentation=https://github.com/XTLS/Xray-core
After=network.target

[Service]
User=root"
    [[ "$INSTALL_NGINX" != 'n' && "$IS_CENTOS" != 'CentOS7' ]] && XRAY_SERVICE+="
ExecStartPre=/bin/bash -c 'if [ -s $WORK_DIR/nginx.conf ]; then command -v nginx >/dev/null 2>&1 || exit 1; nginx -t -c $WORK_DIR/nginx.conf >/dev/null 2>&1 || exit 1; nginx -c $WORK_DIR/nginx.conf -s reload >/dev/null 2>&1 || nginx -c $WORK_DIR/nginx.conf >/dev/null 2>&1 || exit 1; fi'"
    XRAY_SERVICE+="
ExecStartPre=$WORK_DIR/xray run -test -c $WORK_DIR/inbound.json -c $WORK_DIR/outbound.json
ExecStart=$WORK_DIR/xray run -c $WORK_DIR/inbound.json -c $WORK_DIR/outbound.json
Restart=on-failure
RestartPreventExitStatus=23

[Install]
WantedBy=multi-user.target"
    echo "$XRAY_SERVICE" > ${XRAY_DAEMON_FILE}
  fi
  protect_secret_files

  local i=1
  [ ! -s $WORK_DIR/xray ] && wait && while [ "$i" -le 20 ]; do [[ -s $TEMP_DIR/xray && -s $TEMP_DIR/geoip.dat && -s $TEMP_DIR/geosite.dat ]] && mv $TEMP_DIR/xray $TEMP_DIR/geo*.dat $WORK_DIR && break; ((i++)); sleep 2; done
  [ "$i" -ge 20 ] && local APP=Xray && error "\n $(text 48) "

  prepare_vless_pqc_keys
  protect_secret_files

  if [[ " ${INSTALL_PROTOCOLS[*]} " =~ " c " ]] || [[ " ${INSTALL_PROTOCOLS[*]} " =~ " j " ]] || [[ " ${INSTALL_PROTOCOLS[*]} " =~ " k " ]]; then
    ssl_certificate "${TLS_SERVER}"
  fi
  if [[ " ${INSTALL_PROTOCOLS[*]} " =~ " c " ]]; then
    [ "$IS_HOPPING" = 'is_hopping' ] && add_port_hopping_nat "$PORT_HOPPING_START" "$PORT_HOPPING_END" "$HY2_PORT"
  fi

  local INBOUNDS_JSON=''
  local FIRST=true

  local SS2022_PASSWORD=${SS2022_PASSWORD:-"$(openssl rand -base64 16)"}
  for proto in "${INSTALL_PROTOCOLS[@]}"; do
    local BLOCK=''
    case "$proto" in
      b)
        BLOCK=$(cat << JSONEOF
    {
      "tag": "${NODE_NAME} ${NODE_TAG[0]}",
      "protocol": "vless",
      "port": ${REALITY_PORT},
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "${VLESS_SERVER_DECRYPTION:-none}"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${TLS_SERVER}:443",
          "serverNames": [
            "${TLS_SERVER}"
          ],
          "privateKey": "${REALITY_PRIVATE}",
          "shortIds": [
            ""
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls"
        ]
      }
    }
JSONEOF
)
        ;;
      c)
        BLOCK=$(cat << JSONEOF
    {
      "tag": "${NODE_NAME} ${NODE_TAG[1]}",
      "protocol": "hysteria",
      "port": ${HY2_PORT},
      "settings": {
        "version": 2,
        "clients": [
          {
            "auth": "${UUID}"
          }
        ]
      },
      "streamSettings": {
        "network": "hysteria",
        "security": "tls",
        "tlsSettings": {
          "serverNames": [
            "${TLS_SERVER}"
          ],
          "alpn": [
            "h3"
          ],
          "certificates": [
            {
              "certificateFile": "${WORK_DIR}/cert/cert.pem",
              "keyFile": "${WORK_DIR}/cert/private.key"
            }
          ]
        }
      }
    }
JSONEOF
)
        ;;
      d)
        BLOCK=$(cat << JSONEOF
    {
      "tag": "${NODE_NAME} ${NODE_TAG[2]}",
      "protocol": "vless",
      "port": ${GRPC_PORT},
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": ""
          }
        ],
        "decryption": "${VLESS_SERVER_DECRYPTION:-none}"
      },
      "streamSettings": {
        "network": "grpc",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${TLS_SERVER}:443",
          "xver": 0,
          "serverNames": [
            "${TLS_SERVER}"
          ],
          "privateKey": "${REALITY_PRIVATE}",
          "shortIds": [
            ""
          ]
        },
        "grpcSettings": {
          "serviceName": "grpc",
          "multiMode": true
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls"
        ]
      }
    }
JSONEOF
)
        ;;
      e)
        BLOCK=$(cat << JSONEOF
    {
      "tag": "${NODE_NAME} ${NODE_TAG[3]}",
      "protocol": "vless",
      "port": ${VLESS_WS_PORT},
      "listen": "127.0.0.1",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "level": 0
          }
        ],
        "decryption": "${VLESS_SERVER_DECRYPTION:-none}"
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {
          "path": "/${WS_PATH}-vl"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ],
        "metadataOnly": false
      }
    }
JSONEOF
)
        ;;
      f)
        BLOCK=$(cat << JSONEOF
    {
      "tag": "${NODE_NAME} ${NODE_TAG[4]}",
      "protocol": "vmess",
      "port": ${VMESS_WS_PORT},
      "listen": "127.0.0.1",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "alterId": 0
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "/${WS_PATH}-vm"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ],
        "metadataOnly": false
      }
    }
JSONEOF
)
        ;;
      g)
        BLOCK=$(cat << JSONEOF
    {
      "tag": "${NODE_NAME} ${NODE_TAG[5]}",
      "protocol": "trojan",
      "port": ${TROJAN_WS_PORT},
      "listen": "127.0.0.1",
      "settings": {
        "clients": [
          {
            "password": "${UUID}"
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {
          "path": "/${WS_PATH}-tr"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ],
        "metadataOnly": false
      }
    }
JSONEOF
)
        ;;
      h)
        BLOCK=$(cat << JSONEOF
    {
      "tag": "${NODE_NAME} ${NODE_TAG[6]}",
      "protocol": "shadowsocks",
      "port": ${SS_WS_PORT},
      "listen": "127.0.0.1",
      "settings": {
        "clients": [
          {
            "method": "chacha20-ietf-poly1305",
            "password": "${UUID}"
          }
        ],
        "network": "tcp,udp"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "/${WS_PATH}-sh"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ],
        "metadataOnly": false
      }
    }
JSONEOF
)
        ;;
      i)
        BLOCK=$(cat << JSONEOF
    {
      "tag": "${NODE_NAME} ${NODE_TAG[7]}",
      "protocol": "vless",
      "port": ${VLESS_XHTTP_PORT},
      "listen": "127.0.0.1",
      "settings": {
        "clients": [
          {
            "id": "${UUID}"
          }
        ],
        "decryption": "${VLESS_SERVER_DECRYPTION:-none}"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "none",
        "xhttpSettings": {
          "mode": "${XHTTP_CDN_MODE:-packet-up}",
          "path": "/${WS_PATH}-xh",
          "extra": {
            "xPaddingBytes": "100-1000",
            "noSSEHeader": true,
            "scMaxEachPostBytes": "1000000-2000000",
            "scMinPostsIntervalMs": "30-30",
            "scMaxBufferedPosts": 30
          }
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ],
        "metadataOnly": false
      }
    }
JSONEOF
)
        ;;
      j)
        BLOCK=$(cat << JSONEOF
    {
      "tag": "${NODE_NAME} ${NODE_TAG[8]}",
      "port": ${XHTTP_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}"
          }
        ],
        "decryption": "${VLESS_SERVER_DECRYPTION:-none}"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "tls",
        "xhttpSettings": {
          "mode": "stream-up",
          "extra": {
            "alpn": [
              "h3"
            ],
            "xPaddingBytes": "100-1000",
            "noSSEHeader": true,
            "scMaxEachPostBytes": "1000000-2000000",
            "scMaxBufferedPosts": 30
          },
          "path": "/${WS_PATH}-xh3"
        },
        "tlsSettings": {
          "serverName": "${TLS_SERVER}",
          "alpn": [
            "h3"
          ],
          "minVersion": "1.3",
          "maxVersion": "1.3",
          "curvePreferences": [
            "X25519MLKEM768",
            "X25519"
          ],
          "certificates": [
            {
              "certificateFile": "${WORK_DIR}/cert/cert.pem",
              "keyFile": "${WORK_DIR}/cert/private.key"
            }
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    }
JSONEOF
)
        ;;
      k)
        BLOCK=$(cat << JSONEOF
    {
      "tag": "${NODE_NAME} ${NODE_TAG[9]}",
      "protocol": "trojan",
      "port": ${TROJAN_PORT},
      "settings": {
        "clients": [
          {
            "password": "${UUID}"
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
          "serverName": "${TLS_SERVER}",
          "minVersion": "1.3",
          "maxVersion": "1.3",
          "curvePreferences": [
            "X25519MLKEM768",
            "X25519"
          ],
          "certificates": [
            {
              "certificateFile": "${WORK_DIR}/cert/cert.pem",
              "keyFile": "${WORK_DIR}/cert/private.key"
            }
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ],
        "metadataOnly": false
      }
    }
JSONEOF
)
        ;;
      l)
        BLOCK=$(cat << JSONEOF
    {
      "tag": "${NODE_NAME} ${NODE_TAG[10]}",
      "protocol": "shadowsocks",
      "port": ${SS2022_PORT},
      "settings": {
        "method": "2022-blake3-aes-128-gcm",
        "password": "${SS2022_PASSWORD}",
        "network": "tcp,udp"
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ],
        "metadataOnly": false
      }
    }
JSONEOF
)
        ;;
    esac
    if [ -n "$BLOCK" ]; then
      $FIRST || INBOUNDS_JSON+=$',\n'
      INBOUNDS_JSON+="$BLOCK"
      FIRST=false
    fi
  done

  cat > $WORK_DIR/inbound.json << EOF
{
  "log": {
    "access": "/dev/null",
    "error": "/dev/null",
    "loglevel": "none"
  },
  "inbounds": [
${INBOUNDS_JSON}
  ]
}
EOF

  cat > $WORK_DIR/outbound.json << EOF
{
    "outbounds": [
        {
            "protocol": "freedom",
            "tag": "direct"
        },
        {
            "protocol": "blackhole",
            "settings": {},
            "tag": "block"
        }
    ],
    "routing": {
        "domainStrategy": "AsIs",
        "rules": []
    }
}
EOF

  verify_vless_pqc_installation
  protect_secret_files
  [ "$INSTALL_NGINX" != 'n' ] && json_nginx
  protect_secret_files

  check_install
  case "${STATUS[0]}" in
    "$(text 26)" )
      warning "\n Argo $(text 28) $(text 38) \n"
      ;;
    "$(text 27)" )
      cmd_systemctl enable argo
      cmd_systemctl status argo &>/dev/null && info "\n Argo $(text 28) $(text 37) \n" || warning "\n Argo $(text 28) $(text 38) \n"
      ;;
    "$(text 28)" )
      info "\n Argo $(text 28) $(text 37) \n"
  esac

  case "${STATUS[1]}" in
    "$(text 26)" )
      warning "\n Xray $(text 28) $(text 38) \n"
      ;;
    "$(text 27)" )
      cmd_systemctl enable xray
      cmd_systemctl status xray &>/dev/null && info "\n Xray $(text 28) $(text 37) \n" || warning "\n Xray $(text 28) $(text 38) \n"
      ;;
    "$(text 28)" )
      info "\n Xray $(text 28) $(text 37) \n"
  esac
  sync_firewall_rules
}

# 创建快捷方式
create_shortcut() {
  local _SCRIPT_SOURCE="${BASH_SOURCE[0]}"
  local _INSTALLED_SCRIPT="$WORK_DIR/argox.sh"

  # 如果脚本是通过 `bash <(wget -qO- .../argox.sh)` 或
  # `bash <(curl -Ls .../argox.sh)` 这种进程替换/管道方式运行的，
  # ${BASH_SOURCE[0]} 会指向一个一次性匿名管道（如 /dev/fd/63），而不是
  # 可重复读取的普通文件。此时 bash 解释器本身也在从同一个管道里往后读取
  # 尚未执行的脚本内容；如果这里再用 cp 从同一个管道读一次，会和 bash
  # 自身的读取指针互相抢占字节，结果是拷贝出一份被截断/损坏的文件，
  # 严重时还会让脚本在拷贝后提前退出。因此只有当 _SCRIPT_SOURCE 是一个
  # 普通文件（-f，例如 git clone 后本地执行、或已安装到 $WORK_DIR 下）时
  # 才直接 cp；否则改为向 $ARGOX_RAW_URL 重新发起一次独立的下载，得到一份
  # 完整、未被上层读取指针干扰的脚本内容。
  if [ -f "$_SCRIPT_SOURCE" ] && [ "$_SCRIPT_SOURCE" != "$_INSTALLED_SCRIPT" ]; then
    cp "$_SCRIPT_SOURCE" "$_INSTALLED_SCRIPT" || error " Failed to install the ArgoX command script. "
  elif [ ! -f "$_SCRIPT_SOURCE" ]; then
    [ -z "$ARGOX_RAW_URL" ] && error " Failed to install the ArgoX command script: ARGOX_RAW_URL is empty. "
    wget -qO "${TEMP_DIR}/argox.sh.fetch" "${GH_PROXY}${ARGOX_RAW_URL}" ||
      error " Failed to download the ArgoX command script from ${ARGOX_RAW_URL}. "
    # 基本合理性检查：非空、能通过 bash 语法检查，避免网络故障或代理返回
    # 错误页面时把一份坏文件当成正式安装覆盖掉旧版本。
    [ -s "${TEMP_DIR}/argox.sh.fetch" ] ||
      error " Failed to install the ArgoX command script: downloaded file is empty. "
    bash -n "${TEMP_DIR}/argox.sh.fetch" 2>/dev/null ||
      error " Failed to install the ArgoX command script: downloaded file failed syntax check. "
    mv -f "${TEMP_DIR}/argox.sh.fetch" "$_INSTALLED_SCRIPT" ||
      error " Failed to install the ArgoX command script. "
  fi
  [ -s "$_INSTALLED_SCRIPT" ] || error " Failed to install the ArgoX command script. "
  chmod 700 "$_INSTALLED_SCRIPT"

  cat > $WORK_DIR/ax.sh << EOF
#!/usr/bin/env bash

exec bash "$WORK_DIR/argox.sh" "\$@"
EOF
  chmod 700 $WORK_DIR/ax.sh
  ln -sf $WORK_DIR/ax.sh /usr/bin/argox

  if [[ ! ":$PATH:" == *":/usr/bin:"* ]]; then
    echo 'export PATH=$PATH:/usr/bin' >> ~/.bashrc
    source ~/.bashrc
  fi

  [ -s /usr/bin/argox ] && hint "\n $(text 62) "
}

export_list() {
  check_arch
  check_system_info
  check_system_ip
  check_install

  local ARGO_MEM='' XRAY_MEM='' NGINX_MEM=''
  local ARGO_PID=$(pgrep -f "$WORK_DIR/cloudflared")
  [ -n "$ARGO_PID" ] && ARGO_MEM="$(awk '/VmRSS/{printf "%.1f", $2/1024}' /proc/${ARGO_PID%% *}/status 2>/dev/null) MB"
  local XRAY_PID=$(pgrep -f "$WORK_DIR/xray")
  [ -n "$XRAY_PID" ] && XRAY_MEM="$(awk '/VmRSS/{printf "%.1f", $2/1024}' /proc/${XRAY_PID%% *}/status 2>/dev/null) MB"
  if [ "$IS_NGINX" = 'is_nginx' ]; then
    local NGINX_PID=$(pgrep -f "nginx: master process")
    [ -n "$NGINX_PID" ] && NGINX_MEM="$(awk '/VmRSS/{printf "%.1f", $2/1024}' /proc/${NGINX_PID%% *}/status 2>/dev/null) MB"
  fi

  local APP
  [ "${STATUS[0]}" != "$(text 28)" ] && APP+=(Argo)
  [ "${STATUS[1]}" != "$(text 28)" ] && APP+=(Xray)
  if [ "${#APP[@]}" -gt 0 ]; then
    reading "\n $(text 50) " OPEN_APP
    if [ "${OPEN_APP,,}" = 'y' ]; then
      [ "${STATUS[0]}" != "$(text 28)" ] && cmd_systemctl enable argo
      [ "${STATUS[1]}" != "$(text 28)" ] && cmd_systemctl enable xray
      sleep 2
      check_install
      ARGO_PID=$(pgrep -f "$WORK_DIR/cloudflared")
      [ -n "$ARGO_PID" ] && ARGO_MEM="$(awk '/VmRSS/{printf "%.1f", $2/1024}' /proc/${ARGO_PID%% *}/status) MB"
      XRAY_PID=$(pgrep -f "$WORK_DIR/xray")
      [ -n "$XRAY_PID" ] && XRAY_MEM="$(awk '/VmRSS/{printf "%.1f", $2/1024}' /proc/${XRAY_PID%% *}/status) MB"
    else
      exit
    fi
  fi

  if grep -qs "^${DAEMON_RUN_PATTERN}.*--url" ${ARGO_DAEMON_FILE}; then
    fetch_tunnel_domain quick || true
  else
    fetch_tunnel_domain config >/dev/null 2>&1 || true
    [ -z "$ARGO_DOMAIN" ] && [ -s "$WORK_DIR/tunnel.yml" ] && ARGO_DOMAIN=$(awk '/^[[:space:]]*-[[:space:]]*hostname:/{print $3; exit}' "$WORK_DIR/tunnel.yml" 2>/dev/null)
    [ -z "$ARGO_DOMAIN" ] && ARGO_DOMAIN=$(grep -m1 '^vless.*host=.*' $WORK_DIR/list 2>/dev/null | sed "s@.*host=\(.*\)&.*@\1@g")
  fi
  fetch_nodes_value
  vless_pqc_runtime_values
  ech_runtime_values
  xhttp_split_runtime_values

  local _SUB_SCHEME='https'

  local PROTOS_NOW
  PROTOS_NOW=$(get_installed_protocols | tr '
' ' ')

  local FP_SHA256='' FP_BASE64='' CERT_SNI="${TLS_SERVER:-addons.mozilla.org}"
  if grep -Eq 'hysteria2|xhttp-h3-direct|trojan-direct' <<< "$PROTOS_NOW" && [ -s ${WORK_DIR}/cert/cert.pem ]; then
    FP_SHA256=$(openssl x509 -fingerprint -noout -sha256 -in ${WORK_DIR}/cert/cert.pem 2>/dev/null | awk -F= '{print $NF}')
    FP_BASE64=$(openssl x509 -in ${WORK_DIR}/cert/cert.pem -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | openssl enc -base64 2>/dev/null)
    local _csni=$(openssl x509 -noout -ext subjectAltName -in ${WORK_DIR}/cert/cert.pem 2>/dev/null | awk -F 'DNS:' '/DNS:/{gsub(/,.*/,"",$2);print $2}')
    [ -n "$_csni" ] && CERT_SNI="$_csni"
  fi

  VMESS="{ \"v\": \"2\", \"ps\": \"${NODE_NAME} ${NODE_TAG[4]}\", \"add\": \"${SERVER}\", \"port\": \"443\", \"id\": \"${UUID}\", \"aid\": \"0\", \"scy\": \"none\", \"net\": \"ws\", \"type\": \"none\", \"host\": \"${ARGO_DOMAIN}\", \"path\": \"/${WS_PATH}-vm?ed=2560\", \"tls\": \"tls\", \"sni\": \"${ARGO_DOMAIN}\", \"alpn\": \"\" }"

  # 统一生成所有客户端订阅
  local SERVER_PORT_NOW=${SERVER_PORT:-443}
  local CLASH='proxies:' SR_SUBSCRIBE='' V2N_SUBSCRIBE='' PW_SUBSCRIBE='' SR_DISPLAY='' V2N_DISPLAY='' PW_DISPLAY=''
  local SB_OUTBOUNDS='' SB_TAGS='' SB_SEP=''
  _sb_add() { SB_OUTBOUNDS+="${SB_SEP}$1"; SB_TAGS+="${SB_SEP}$2"; SB_SEP=', '; }
  _add() {
    local clash="$1" sr="$2" v2n="$3" sb="$4" tag="$5"
    [ -n "$clash" ] && CLASH+="\n  - $clash"
    [ -n "$sr" ] && { SR_SUBSCRIBE+="$sr"$'\n'; SR_DISPLAY+="$sr\n\n"; }
    [ -n "$v2n" ] && { V2N_SUBSCRIBE+="$v2n"$'\n'; V2N_DISPLAY+="$v2n\n\n"; }
    [ -n "$sb" ] && _sb_add "$sb" "\"$tag\""
  }

  # reality-vision
  # v2.2.3: Reality 叠加 VLESS PQC。链接/Clash 使用 client encryption=1rtt；服务端 inbound 使用 decryption=600s。
  grep -q 'reality-vision' <<< "$PROTOS_NOW" && _add \
    "{name: \"${NODE_NAME} ${NODE_TAG[0]}\", type: vless, server: ${REALITY_ADDR}, port: ${REALITY_PORT}, uuid: ${UUID}, encryption: \"${VLESS_CLIENT_ENCRYPTION:-none}\", network: tcp, udp: true, tls: true, servername: ${TLS_SERVER}, flow: xtls-rprx-vision, client-fingerprint: chrome, reality-opts: {public-key: ${REALITY_PUBLIC}, short-id: \"\"} }" \
    "vless://$(echo -n "auto:${UUID}@${REALITY_ADDR_2}:${REALITY_PORT}" | base64 -w0)?remarks=${NODE_NAME// /%20}%20${NODE_TAG[0]}&obfs=none&tls=1&peer=${TLS_SERVER}&xtls=2&pbk=${REALITY_PUBLIC}" \
    "vless://${UUID}@${REALITY_ADDR_1}:${REALITY_PORT}?encryption=${VLESS_CLIENT_ENCRYPTION_QUERY:-none}&flow=xtls-rprx-vision&security=reality&sni=${TLS_SERVER}&fp=chrome&pbk=${REALITY_PUBLIC}&type=tcp&headerType=none#${NODE_NAME// /%20}%20${NODE_TAG[0]}" \
    "{ \"type\":\"vless\", \"tag\":\"${NODE_NAME} ${NODE_TAG[0]}\", \"server\":\"${REALITY_ADDR}\", \"server_port\": ${REALITY_PORT}, \"uuid\":\"${UUID}\", \"flow\":\"xtls-rprx-vision\", \"packet_encoding\":\"xudp\", \"tls\":{ \"enabled\":true, \"server_name\":\"${TLS_SERVER}\", \"utls\":{ \"enabled\":true, \"fingerprint\":\"chrome\" }, \"reality\":{ \"enabled\":true, \"public_key\":\"${REALITY_PUBLIC}\", \"short_id\":\"\" } } }" \
    "${NODE_NAME} ${NODE_TAG[0]}"

  # hysteria2
  if grep -q 'hysteria2' <<< "$PROTOS_NOW"; then
    local _h2h=''; [[ -n "$PORT_HOPPING_START" && -n "$PORT_HOPPING_END" ]] && _h2h="&mport=${HY2_PORT},${PORT_HOPPING_START}-${PORT_HOPPING_END}"
    local _sbhp=''; [[ -n "$PORT_HOPPING_START" && -n "$PORT_HOPPING_END" ]] && _sbhp=",\"server_ports\":[\"${PORT_HOPPING_START}:${PORT_HOPPING_END}\"], \"hop_interval\": \"30s\", \"hop_interval_max\": \"60s\""
    local _chop=''; [[ -n "$PORT_HOPPING_START" && -n "$PORT_HOPPING_END" ]] && _chop="ports: ${PORT_HOPPING_START}-${PORT_HOPPING_END}, hop-interval: 30, "
    local _srhop=''; [[ -n "$PORT_HOPPING_START" && -n "$PORT_HOPPING_END" ]] && _srhop="&keepalive=30"
    local _nekohop=''; [[ -n "$PORT_HOPPING_START" && -n "$PORT_HOPPING_END" ]] && _nekohop="&hop_interval=30"
    # 使用动态带宽参数，默认为 200/1000
    local _hy2_up="${HY2_UP_NOW:-200}"
    local _hy2_down="${HY2_DOWN_NOW:-1000}"
    _add \
      "{name: \"${NODE_NAME} ${NODE_TAG[1]}\", type: hysteria2, server: ${SERVER_IP}, port: ${HY2_PORT}, ${_chop}up: \"${_hy2_up} Mbps\", down: \"${_hy2_down} Mbps\", password: ${UUID}, sni: ${CERT_SNI}, skip-cert-verify: false, fingerprint: ${FP_SHA256}}" \
      "hysteria2://${UUID}@${SERVER_IP_1}:${HY2_PORT}?peer=${CERT_SNI}&hpkp=${FP_SHA256}&obfs=none&upmbps=${_hy2_up}&downmbps=${_hy2_down}${_srhop}${_h2h}#${NODE_NAME// /%20}%20${NODE_TAG[1]}" \
      "hy2://${UUID}@${SERVER_IP_1}:${HY2_PORT}?insecure=1&sni=${CERT_SNI}&upmbps=${_hy2_up}&downmbps=${_hy2_down}${_nekohop}${_h2h}#${NODE_NAME// /%20}%20${NODE_TAG[1]}" \
      "{ \"type\": \"hysteria2\", \"tag\": \"${NODE_NAME} ${NODE_TAG[1]}\", \"server\": \"${SERVER_IP}\", \"server_port\": ${HY2_PORT}${_sbhp}, \"up_mbps\": ${_hy2_up}, \"down_mbps\": ${_hy2_down}, \"password\": \"${UUID}\", \"tls\": { \"enabled\": true, \"server_name\": \"${CERT_SNI}\", \"certificate_public_key_sha256\": [\"${FP_BASE64}\"], \"alpn\": [ \"h3\" ] } }" \
      "${NODE_NAME} ${NODE_TAG[1]}"
  fi

  # reality-grpc
  # v2.2.3: Reality gRPC 同样叠加 VLESS PQC；部分客户端可能仍需使用标准 VLESS URI 导入。
  grep -q 'reality-grpc' <<< "$PROTOS_NOW" && _add \
    "{name: \"${NODE_NAME} ${NODE_TAG[2]}\", type: vless, server: ${REALITY_ADDR}, port: ${GRPC_PORT}, uuid: ${UUID}, encryption: \"${VLESS_CLIENT_ENCRYPTION:-none}\", network: grpc, udp: true, tls: true, servername: ${TLS_SERVER}, client-fingerprint: chrome, reality-opts: {public-key: ${REALITY_PUBLIC}, short-id: \"\"}, grpc-opts: {grpc-service-name: \"grpc\"} }" \
    "vless://$(echo -n "auto:${UUID}@${REALITY_ADDR_2}:${GRPC_PORT}" | base64 -w0)?remarks=${NODE_NAME// /%20}%20${NODE_TAG[2]}&path=grpc&obfs=grpc&tls=1&peer=${TLS_SERVER}&pbk=${REALITY_PUBLIC}" \
    "vless://${UUID}@${REALITY_ADDR_1}:${GRPC_PORT}?security=reality&sni=${TLS_SERVER}&fp=chrome&pbk=${REALITY_PUBLIC}&type=grpc&serviceName=grpc&encryption=${VLESS_CLIENT_ENCRYPTION_QUERY:-none}#${NODE_NAME// /%20}%20${NODE_TAG[2]}" \
    "{ \"type\": \"vless\", \"tag\":\"${NODE_NAME} ${NODE_TAG[2]}\", \"server\": \"${REALITY_ADDR}\", \"server_port\": ${GRPC_PORT}, \"uuid\": \"${UUID}\", \"packet_encoding\":\"xudp\", \"tls\": { \"enabled\": true, \"server_name\": \"${TLS_SERVER}\", \"utls\": { \"enabled\": true, \"fingerprint\": \"chrome\" }, \"reality\": { \"enabled\": true, \"public_key\": \"${REALITY_PUBLIC}\", \"short_id\": \"\" } }, \"transport\": { \"type\": \"grpc\", \"service_name\": \"grpc\" } }" \
    "${NODE_NAME} ${NODE_TAG[2]}"

  # vless-ws
  grep -q 'vless-ws' <<< "$PROTOS_NOW" && _add \
    "{name: \"${NODE_NAME} ${NODE_TAG[3]}\", type: vless, server: ${SERVER}, port: ${SERVER_PORT_NOW}, uuid: ${UUID}, encryption: "${VLESS_CLIENT_ENCRYPTION:-none}", udp: true, tls: true, servername: ${ARGO_DOMAIN}, skip-cert-verify: false, network: ws, ws-opts: {path: \"/${WS_PATH}-vl\", headers: {Host: ${ARGO_DOMAIN}}, \"max_early_data\":2560, \"early_data_header_name\":\"Sec-WebSocket-Protocol\"} }" \
    "vless://${UUID}@${SERVER}:${SERVER_PORT_NOW}?encryption=${VLESS_CLIENT_ENCRYPTION_QUERY:-none}&security=tls&type=ws&host=${ARGO_DOMAIN}&path=/${WS_PATH}-vl?ed=2560&sni=${ARGO_DOMAIN}#${NODE_NAME// /%20}%20${NODE_TAG[3]}" \
    "vless://${UUID}@${SERVER}:${SERVER_PORT_NOW}?encryption=${VLESS_CLIENT_ENCRYPTION_QUERY:-none}&security=tls&sni=${ARGO_DOMAIN}&type=ws&host=${ARGO_DOMAIN}&path=%2F${WS_PATH}-vl%3Fed%3D2560#${NODE_NAME// /%20}%20${NODE_TAG[3]}" \
    "{ \"type\":\"vless\", \"tag\":\"${NODE_NAME} ${NODE_TAG[3]}\", \"server\":\"${SERVER}\", \"server_port\":${SERVER_PORT_NOW}, \"uuid\":\"${UUID}\", \"tls\": { \"enabled\":true, \"server_name\":\"${ARGO_DOMAIN}\", \"utls\": { \"enabled\":true, \"fingerprint\":\"chrome\" } }, \"transport\": { \"type\":\"ws\", \"path\":\"/${WS_PATH}-vl\", \"headers\": { \"Host\": \"${ARGO_DOMAIN}\" }, \"max_early_data\":2560, \"early_data_header_name\":\"Sec-WebSocket-Protocol\" } }" \
    "${NODE_NAME} ${NODE_TAG[3]}"

  # vmess-ws
  grep -q 'vmess-ws' <<< "$PROTOS_NOW" && _add \
    "{name: \"${NODE_NAME} ${NODE_TAG[4]}\", type: vmess, server: ${SERVER}, port: ${SERVER_PORT_NOW}, uuid: ${UUID}, udp: true, alterId: 0, cipher: none, tls: true, servername: ${ARGO_DOMAIN}, skip-cert-verify: false, network: ws, ws-opts: {path: \"/${WS_PATH}-vm\", headers: {Host: ${ARGO_DOMAIN}}, \"max_early_data\":2560, \"early_data_header_name\":\"Sec-WebSocket-Protocol\"}}" \
    "vmess://$(echo -n "none:${UUID}@${SERVER}:${SERVER_PORT_NOW}" | base64 -w0)?remarks=${NODE_NAME// /%20}%20${NODE_TAG[4]}&obfsParam=${ARGO_DOMAIN}&path=/${WS_PATH}-vm?ed=2560&obfs=websocket&tls=1&peer=${ARGO_DOMAIN}&alterId=0" \
    "vmess://$(echo -n "$VMESS" | base64 -w0)" \
    "{ \"type\":\"vmess\", \"tag\":\"${NODE_NAME} ${NODE_TAG[4]}\", \"server\":\"${SERVER}\", \"server_port\":${SERVER_PORT_NOW}, \"uuid\":\"${UUID}\", \"tls\": { \"enabled\":true, \"server_name\":\"${ARGO_DOMAIN}\", \"utls\": { \"enabled\":true, \"fingerprint\":\"chrome\" } }, \"transport\": { \"type\":\"ws\", \"path\":\"/${WS_PATH}-vm\", \"headers\": { \"Host\": \"${ARGO_DOMAIN}\" }, \"max_early_data\":2560, \"early_data_header_name\":\"Sec-WebSocket-Protocol\" } }" \
    "${NODE_NAME} ${NODE_TAG[4]}"

  # trojan-ws
  grep -q 'trojan-ws' <<< "$PROTOS_NOW" && _add \
    "{name: \"${NODE_NAME} ${NODE_TAG[5]}\", type: trojan, server: ${SERVER}, port: ${SERVER_PORT_NOW}, password: ${UUID}, udp: true, tls: true, servername: ${ARGO_DOMAIN}, sni: ${ARGO_DOMAIN}, skip-cert-verify: false, network: ws, ws-opts: {path: \"/${WS_PATH}-tr\", headers: {Host: ${ARGO_DOMAIN}}, \"max_early_data\":2560, \"early_data_header_name\":\"Sec-WebSocket-Protocol\" } }" \
    "trojan://${UUID}@${SERVER}:${SERVER_PORT_NOW}?peer=${ARGO_DOMAIN}&plugin=obfs-local;obfs=websocket;obfs-host=${ARGO_DOMAIN};obfs-uri=/${WS_PATH}-tr?ed=2560#${NODE_NAME// /%20}%20${NODE_TAG[5]}" \
    "trojan://${UUID}@${SERVER}:${SERVER_PORT_NOW}?security=tls&sni=${ARGO_DOMAIN}&type=ws&host=${ARGO_DOMAIN}&path=/${WS_PATH}-tr?ed%3D2560#${NODE_NAME// /%20}%20${NODE_TAG[5]}" \
    "{ \"type\":\"trojan\", \"tag\":\"${NODE_NAME} ${NODE_TAG[5]}\", \"server\": \"${SERVER}\", \"server_port\": ${SERVER_PORT_NOW}, \"password\": \"${UUID}\", \"tls\": { \"enabled\":true, \"server_name\":\"${ARGO_DOMAIN}\", \"utls\": { \"enabled\":true, \"fingerprint\":\"chrome\" } }, \"transport\": { \"type\":\"ws\", \"path\":\"/${WS_PATH}-tr\", \"headers\": { \"Host\": \"${ARGO_DOMAIN}\" }, \"max_early_data\":2560, \"early_data_header_name\":\"Sec-WebSocket-Protocol\" } }" \
    "${NODE_NAME} ${NODE_TAG[5]}"

  # ss-ws
  grep -qw 'ss-ws' <<< "$PROTOS_NOW" && _add \
    "{name: \"${NODE_NAME} ${NODE_TAG[6]}\", type: ss, server: ${SERVER}, port: ${SERVER_PORT_NOW}, cipher: ${SS_METHOD}, password: ${UUID}, udp: true, plugin: v2ray-plugin, plugin-opts: { mode: websocket, host: ${ARGO_DOMAIN}, path: \"/${WS_PATH}-sh\", tls: true, servername: ${ARGO_DOMAIN}, skip-cert-verify: false, mux: false } }" \
    "ss://$(echo -n "chacha20-ietf-poly1305:${UUID}@${SERVER}:${SERVER_PORT_NOW}" | base64 -w0)?uot=2&v2ray-plugin=$(echo -n "{\"peer\":\"${ARGO_DOMAIN}\",\"mux\":false,\"path\":\"\\/${WS_PATH}-sh\",\"host\":\"${ARGO_DOMAIN}\",\"mode\":\"websocket\",\"tls\":true}" | base64 -w0)#${NODE_NAME// /%20}%20${NODE_TAG[6]}" \
    "ss://$(echo -n "${SS_METHOD}:${UUID}" | base64 -w0)@${SERVER}:${SERVER_PORT_NOW}?plugin=v2ray-plugin%3Bmode%3Dwebsocket%3Bhost%3D${ARGO_DOMAIN}%3Bpath%3D%2F${WS_PATH}-sh%3Btls%3Dtrue%3Bservername%3D${ARGO_DOMAIN}%3Bskip-cert-verify%3Dfalse%3Bmux%3D0#${NODE_NAME// /%20}%20${NODE_TAG[6]}" \
    "{ \"type\": \"shadowsocks\", \"tag\": \"${NODE_NAME} ${NODE_TAG[6]}\", \"server\": \"${SERVER}\", \"server_port\": ${SERVER_PORT_NOW}, \"method\": \"chacha20-ietf-poly1305\", \"password\": \"${UUID}\", \"udp_over_tcp\": {\"enabled\": true,\"version\": 2}, \"plugin\": \"v2ray-plugin\", \"plugin_opts\": \"mode=websocket;host=${ARGO_DOMAIN};path=/${WS_PATH}-sh;tls=true;servername=${ARGO_DOMAIN};skip-cert-verify=false;mux=0\"}" \
    "${NODE_NAME} ${NODE_TAG[6]}"

  # xhttp-h1.1-cdn（固定隧道；客户端 H2/H1 回退，Argo/Nginx H1 回源）
  # v2.3.7: Shadowrocket >=2.2.88 与 PassWall/PassWall2 使用 Xray 分享链接标准
  # 的 extra= 参数承载完整 XHTTP extra/downloadSettings；ECH 保留顶层 ech=。
  local MIHOMO_XHTTP_DOWNLOAD_OPTS='' XHTTP_CLIENT_EXTRA_JSON='' XHTTP_CLIENT_EXTRA_QUERY=''
  local XHTTP_STANDARD_URI='' XHTTP_URI_HOST=''
  XHTTP_URI_HOST=$(uri_host "$SERVER")
  if grep -q 'xhttp-h1.1-cdn' <<< "$PROTOS_NOW" && ! grep -q 'trycloudflare\.com$' <<< "${ARGO_DOMAIN}"; then
    XHTTP_CLIENT_EXTRA_JSON=$(build_xhttp_client_extra_json)
    XHTTP_CLIENT_EXTRA_QUERY=$(url_encode "$XHTTP_CLIENT_EXTRA_JSON")
    XHTTP_STANDARD_URI="vless://${UUID}@${XHTTP_URI_HOST}:${SERVER_PORT_NOW}?encryption=${VLESS_CLIENT_ENCRYPTION_QUERY:-none}&security=tls&sni=$(url_encode "${ARGO_DOMAIN}")&fp=chrome&alpn=h2%2Chttp%2F1.1&type=xhttp&host=$(url_encode "${ARGO_DOMAIN}")&path=$(url_encode "/${WS_PATH}-xh")&mode=${XHTTP_CDN_MODE:-packet-up}&extra=${XHTTP_CLIENT_EXTRA_QUERY}${ECH_URI_PARAM}#$(url_encode "${NODE_NAME} ${NODE_TAG[7]}")"
    PW_SUBSCRIBE+="$XHTTP_STANDARD_URI"$'\n'
    PW_DISPLAY+="$XHTTP_STANDARD_URI\n\n"
  fi
  if truthy "${ENABLE_XHTTP_SPLIT:-n}"; then
    local _MIHOMO_DOWN_ECH="${MIHOMO_ECH_OPTS}"
    MIHOMO_XHTTP_DOWNLOAD_OPTS=", download-settings: {path: \"/${WS_PATH}-xh\", host: \"${ARGO_DOMAIN}\", server: \"${XHTTP_DOWNLOAD_SERVER:-$SERVER}\", port: ${XHTTP_DOWNLOAD_PORT:-$SERVER_PORT_NOW}, tls: true, alpn: [h2,http/1.1], servername: \"${ARGO_DOMAIN}\"${MIHOMO_TLS_FINGERPRINT}${_MIHOMO_DOWN_ECH}}"
  fi
  grep -q 'xhttp-h1.1-cdn' <<< "$PROTOS_NOW" && ! grep -q 'trycloudflare\.com$' <<< "${ARGO_DOMAIN}" && _add \
    "{name: \"${NODE_NAME} ${NODE_TAG[7]}\", type: vless, server: ${SERVER}, port: ${SERVER_PORT_NOW}, uuid: ${UUID}, encryption: \"${VLESS_CLIENT_ENCRYPTION:-none}\", udp: true, tls: true, network: xhttp, alpn: [h2,http/1.1], servername: ${ARGO_DOMAIN}${MIHOMO_TLS_FINGERPRINT}${MIHOMO_ECH_OPTS}, xhttp-opts: {path: \"/${WS_PATH}-xh\", host: ${ARGO_DOMAIN}, mode: ${XHTTP_CDN_MODE:-packet-up}${MIHOMO_XHTTP_DOWNLOAD_OPTS}} }" \
    "$XHTTP_STANDARD_URI" \
    "$XHTTP_STANDARD_URI" \
    "" ""

  # xhttp-h3-direct
  grep -q 'xhttp-h3-direct' <<< "$PROTOS_NOW" && _add \
    "{name: \"${NODE_NAME} ${NODE_TAG[8]}\", type: vless, server: ${SERVER_IP}, port: ${XHTTP_PORT}, uuid: ${UUID}, encryption: "${VLESS_CLIENT_ENCRYPTION:-none}", udp: true, tls: true, network: xhttp, alpn: [h3], servername: ${CERT_SNI}, client-fingerprint: chrome, skip-cert-verify: false, fingerprint: ${FP_SHA256}, xhttp-opts: {path: \"/${WS_PATH}-xh3\", mode: stream-up} }" \
    "vless://$(echo -n \"auto:${UUID}@${SERVER_IP_1}:${XHTTP_PORT}\" | base64 -w0)?path=/${WS_PATH}-xh3&remarks=${NODE_NAME// /%20}%20${NODE_TAG[8]}&obfs=xhttp&tls=1&peer=${CERT_SNI}&alpn=h3&mode=stream-up&hpkp=${FP_SHA256}" \
    "vless://${UUID}@${SERVER_IP_1}:${XHTTP_PORT}?encryption=${VLESS_CLIENT_ENCRYPTION_QUERY:-none}&security=tls&sni=${CERT_SNI}&fp=chrome&alpn=h3&insecure=1&allowInsecure=1&pcs=${FP_SHA256//:/}&type=xhttp&path=%2F${WS_PATH}-xh3&mode=stream-up#${NODE_NAME// /%20}%20${NODE_TAG[8]}" \
    "" "${NODE_NAME} ${NODE_TAG[8]}"

  # trojan-direct
  grep -q 'trojan-direct' <<< "$PROTOS_NOW" && _add \
    "{name: \"${NODE_NAME} ${NODE_TAG[9]}\", type: trojan, server: ${SERVER_IP}, port: ${TROJAN_PORT}, password: ${UUID}, udp: true, tls: true, sni: ${CERT_SNI}, servername: ${CERT_SNI}, skip-cert-verify: false, fingerprint: ${FP_SHA256} }" \
    "trojan://${UUID}@${SERVER_IP_1}:${TROJAN_PORT}?peer=${CERT_SNI}&tls=1&allowInsecure=0&sni=${CERT_SNI}&hpkp=${FP_SHA256}#${NODE_NAME// /%20}%20${NODE_TAG[9]}" \
    "trojan://${UUID}@${SERVER_IP_1}:${TROJAN_PORT}?security=tls&sni=${CERT_SNI}&fp=chrome&allowInsecure=0&insecure=0&peer=${CERT_SNI}&pinSHA256=${FP_SHA256//:/}#${NODE_NAME// /%20}%20${NODE_TAG[9]}" \
    "{ \"type\":\"trojan\", \"tag\":\"${NODE_NAME} ${NODE_TAG[9]}\", \"server\": \"${SERVER_IP}\", \"server_port\": ${TROJAN_PORT}, \"password\": \"${UUID}\", \"tls\": { \"enabled\": true, \"server_name\": \"${CERT_SNI}\", \"certificate_public_key_sha256\": [\"${FP_BASE64}\"] } }" \
    "${NODE_NAME} ${NODE_TAG[9]}"

  # ss2022-direct
  grep -q 'ss2022-direct' <<< "$PROTOS_NOW" && _add \
    "{name: \"${NODE_NAME} ${NODE_TAG[10]}\", type: ss, server: ${SERVER_IP}, port: ${SS2022_PORT}, cipher: 2022-blake3-aes-128-gcm, password: ${SS2022_PASSWORD}, udp: true }" \
    "ss://$(echo -n "2022-blake3-aes-128-gcm:${SS2022_PASSWORD}@${SERVER_IP_1}:${SS2022_PORT}" | base64 -w0)#$(echo -n "${NODE_NAME# }" | sed 's/ /%20/g')%20${NODE_TAG[10]}" \
    "ss://$(echo -n "2022-blake3-aes-128-gcm:${SS2022_PASSWORD}" | base64 -w0)@${SERVER_IP_1}:${SS2022_PORT}#${NODE_NAME// /%20}%20${NODE_TAG[10]}" \
    "{ \"type\": \"shadowsocks\", \"tag\": \"${NODE_NAME} ${NODE_TAG[10]}\", \"server\": \"${SERVER_IP}\", \"server_port\": ${SS2022_PORT}, \"method\": \"2022-blake3-aes-128-gcm\", \"password\": \"${SS2022_PASSWORD}\" }" \
    "${NODE_NAME} ${NODE_TAG[10]}"

  write_xray_xhttp_pqc_ech_client
  write_passwall_xhttp_extra

  # 写入订阅文件
  echo -e "$CLASH" > $WORK_DIR/subscribe/proxies
  write_local_clash_template "$TEMP_DIR/clash"
  sed "s#NODE_NAME#${NODE_NAME}#g; s#PROXY_PROVIDERS_URL#http://${ARGO_DOMAIN}/${UUID}/proxies#" "$TEMP_DIR/clash" > $WORK_DIR/subscribe/clash
  echo -n "$SR_SUBSCRIBE" | sed -E '/^[ ]*#|^--/d' | sed '/^$/d' | base64 -w0 > $WORK_DIR/subscribe/shadowrocket
  echo -n "$PW_SUBSCRIBE" | sed -E '/^[ ]*#|^--/d' | sed '/^$/d' | base64 -w0 > $WORK_DIR/subscribe/passwall
  echo -n "$V2N_SUBSCRIBE" | sed -E '/^[ ]*#|^--/d' | sed '/^$/d' | base64 -w0 > $WORK_DIR/subscribe/base64
  if [ -n "$XHTTP_STANDARD_URI" ]; then
    printf '%s\n' "$XHTTP_STANDARD_URI" > "$WORK_DIR/subscribe/shadowrocket-xhttp-uri.txt"
    printf '%s\n' "$XHTTP_STANDARD_URI" > "$WORK_DIR/subscribe/passwall-xhttp-uri.txt"
    chmod 600 "$WORK_DIR/subscribe/shadowrocket-xhttp-uri.txt" "$WORK_DIR/subscribe/passwall-xhttp-uri.txt" 2>/dev/null || true
  else
    rm -f "$WORK_DIR/subscribe/shadowrocket-xhttp-uri.txt" "$WORK_DIR/subscribe/passwall-xhttp-uri.txt" 2>/dev/null || true
  fi

  # sing-box 订阅：纯 xhttp 场景直接跳过；其余场景仅在确实生成了 sing-box outbound 时才处理
  local SB_DISPLAY='' SB_BLOCK='' SB_LINK_BLOCK=''
  if ! grep -Eq '^[[:space:]]*(xhttp-h1\.1-cdn|xhttp-h3-direct)[[:space:]]*$' <<< "$PROTOS_NOW" || grep -Eq '(^|[[:space:]])(reality-vision|hysteria2|reality-grpc|vless-ws|vmess-ws|trojan-ws|ss-ws|trojan-direct|ss2022-direct)([[:space:]]|$)' <<< "$PROTOS_NOW"; then
    if [ -n "$SB_OUTBOUNDS" ]; then
    write_local_sing_box_template "$TEMP_DIR/sing-box"
    sed "s#\"<OUTBOUND_REPLACE>\"#${SB_OUTBOUNDS}#; s#\"<NODE_REPLACE>\"#${SB_TAGS}#g" "$TEMP_DIR/sing-box" | $WORK_DIR/jq > $WORK_DIR/subscribe/sing-box
    SB_DISPLAY=$(echo "{ \"outbounds\":[ ${SB_OUTBOUNDS} ] }" | $WORK_DIR/jq 2>/dev/null)
    SB_BLOCK="
*******************************************
┌────────────────┐
│                │
│    $(warning "Sing-box")    │
│                │
└────────────────┘
----------------------------

$(hint "${SB_DISPLAY}")

$(info "$(text 63)")"
    SB_LINK_BLOCK="

sing-box $(text 66):
${_SUB_SCHEME}://${ARGO_DOMAIN}/${UUID}/sing-box"
    else
      rm -f $WORK_DIR/subscribe/sing-box >/dev/null 2>&1 || true
    fi
  else
    rm -f $WORK_DIR/subscribe/sing-box >/dev/null 2>&1 || true
  fi

  local XRAY_ECH_LINK_BLOCK=''
  if [ -s "$WORK_DIR/subscribe/xray-xhttp-pqc-ech.json" ]; then
    XRAY_ECH_LINK_BLOCK="

Native Xray VLESS + XHTTP + PQC + ECH config:
${_SUB_SCHEME}://${ARGO_DOMAIN}/${UUID}/xray-xhttp-pqc-ech.json"
  fi

  # 显示用变量
  local CLASH_DISPLAY=$(echo -e "$CLASH" | sed '1d')

  check_system_info
  local ARGO_V=$($WORK_DIR/cloudflared -v | awk '{print $3}')
  local XRAY_V=$($WORK_DIR/xray version | awk 'NR==1 {print $2}')
  local NGINX_V=$(nginx -v 2>&1 | sed "s#.*/##")
  local SYS_INFO=" $(text 19):\n\t $(text 20): $SYS\n\t $(text 21): $(uname -r)\n\t $(text 22): $ARGO_ARCH\n\t $(text 23): $VIRT\n\t IPv4: $WAN4 $COUNTRY4 $ASNORG4\n\t IPv6: $WAN6 $COUNTRY6 $ASNORG6\n\t Argo: ${STATUS[0]}\t Version: ${ARGO_V}\t $(text 52): ${ARGO_MEM}\n\t Xray: ${STATUS[1]}\t Version: ${XRAY_V}\t $(text 52): ${XRAY_MEM}"
  [ "$IS_NGINX" = 'is_nginx' ] && SYS_INFO+="\n\t Nginx: ${STATUS[2]}\t Version: ${NGINX_V}\t $(text 52): ${NGINX_MEM}"

  EXPORT_LIST_FILE="*******************************************
┌────────────────┐  ┌────────────────┐
│                │  │                │
│     $(warning "V2rayN")     │  │    $(warning "NekoBox")     │
│                │  │                │
└────────────────┘  └────────────────┘
----------------------------
$(info "$(echo -e "${V2N_DISPLAY}")")
$(grep -qw 'ss-ws' <<< "$PROTOS_NOW" && info "\n$(text 75)")

*******************************************
┌────────────────┐
│                │
│  $(warning "Shadowrocket")  │
│                │
└────────────────┘
----------------------------

$(hint "$(echo -e "${SR_DISPLAY}")")

*******************************************
┌────────────────┐
│                │
│    $(warning "PassWall")    │
│                │
└────────────────┘
----------------------------

$(hint "$(echo -e "${PW_DISPLAY}")")

*******************************************
┌────────────────┐
│                │
│  $(warning "Clash Verge")   │
│                │
└────────────────┘
----------------------------

$(info "${CLASH_DISPLAY}")

${SB_BLOCK}

*******************************************

$(hint "Index:
${_SUB_SCHEME}://${ARGO_DOMAIN}/${UUID}/

QR code:
${_SUB_SCHEME}://${ARGO_DOMAIN}/${UUID}/qr

V2rayN / Nekoray $(text 66):
${_SUB_SCHEME}://${ARGO_DOMAIN}/${UUID}/base64${XRAY_ECH_LINK_BLOCK}")

$(hint "Clash $(text 66):
${_SUB_SCHEME}://${ARGO_DOMAIN}/${UUID}/clash${SB_LINK_BLOCK}

Shadowrocket $(text 66):
${_SUB_SCHEME}://${ARGO_DOMAIN}/${UUID}/shadowrocket
Shadowrocket XHTTP direct-import URI:
${_SUB_SCHEME}://${ARGO_DOMAIN}/${UUID}/shadowrocket-xhttp-uri.txt

PassWall / PassWall2 $(text 66):
${_SUB_SCHEME}://${ARGO_DOMAIN}/${UUID}/passwall
PassWall XHTTP direct-import URI:
${_SUB_SCHEME}://${ARGO_DOMAIN}/${UUID}/passwall-xhttp-uri.txt

PassWall XHTTP Extra JSON (manual fallback):
${_SUB_SCHEME}://${ARGO_DOMAIN}/${UUID}/passwall-xhttp-extra.json")

*******************************************

$(info " $(text 66):
${_SUB_SCHEME}://${ARGO_DOMAIN}/${UUID}/auto

 $(text 64) QRcode:
Safe edition: online QR service disabled. Use local terminal QR below.")

$(qrencode_print ${_SUB_SCHEME}://${ARGO_DOMAIN}/${UUID}/auto)
"

  echo "$EXPORT_LIST_FILE" > $WORK_DIR/list
  cat $WORK_DIR/list

  statistics_of_run-times get
}


# 增加或删除协议
change_protocols() {
  check_install
  [ "${STATUS[1]}" = "$(text 26)" ] && error "\n $(text 39) \n"

  check_system_ip

  local EXISTED_PROTOCOLS=() NOT_EXISTED_PROTOCOLS=()
  for tag in "${CURRENT_PROTOCOLS[@]}"; do
    for idx in "${!NODE_TAG[@]}"; do
      if [ "${NODE_TAG[$idx]}" = "$tag" ]; then
        local p_name="${PROTOCOL_LIST[$idx]}"
        [ "$idx" = '7' ] && p_name=$(text 101)
        EXISTED_PROTOCOLS+=("${p_name}")
        break
      fi
    done
  done
  for idx in "${!PROTOCOL_LIST[@]}"; do
    local found=false
    for tag in "${CURRENT_PROTOCOLS[@]}"; do
      [ "${NODE_TAG[$idx]}" = "$tag" ] && found=true && break
    done
    if ! $found; then
      local p_name="${PROTOCOL_LIST[$idx]}"
      [ "$idx" = '7' ] && p_name=$(text 101)
      NOT_EXISTED_PROTOCOLS+=("${p_name}")
    fi
  done

  hint "\n $(text 88) (${#EXISTED_PROTOCOLS[@]})"
  for h in "${!EXISTED_PROTOCOLS[@]}"; do
    hint " $(printf "\\$(printf '%03o' $((h+97)))"). ${EXISTED_PROTOCOLS[h]}"
  done
  reading "\n $(text 89) " REMOVE_SELECT

  local REMOVE_PROTOCOLS=() KEEP_PROTOCOLS=()
  REMOVE_SELECT=$(echo "${REMOVE_SELECT,,}" | grep -o . | grep -E "^[a-z]$" | awk '!seen[$0]++' | tr -d '\n')
  for ((j=0; j<${#REMOVE_SELECT}; j++)); do
    local ch="${REMOVE_SELECT:$j:1}"
    local ridx=$(( $(printf "%d" "'$ch") - 97 ))
    [ $ridx -lt ${#EXISTED_PROTOCOLS[@]} ] && REMOVE_PROTOCOLS+=("${EXISTED_PROTOCOLS[$ridx]}")
  done
  for p in "${EXISTED_PROTOCOLS[@]}"; do
    local in_remove=false
    for r in "${REMOVE_PROTOCOLS[@]}"; do [ "$p" = "$r" ] && in_remove=true && break; done
    $in_remove || KEEP_PROTOCOLS+=("$p")
  done

  local ADD_PROTOCOLS=()
  if [ "${#NOT_EXISTED_PROTOCOLS[@]}" -gt 0 ]; then
    hint "\n $(text 90) (${#NOT_EXISTED_PROTOCOLS[@]})"
    for i in "${!NOT_EXISTED_PROTOCOLS[@]}"; do
      hint " $(printf "\\$(printf '%03o' $((i+97)))"). ${NOT_EXISTED_PROTOCOLS[i]}"
    done
    reading "\n $(text 91) " ADD_SELECT
    ADD_SELECT=$(echo "${ADD_SELECT,,}" | grep -o . | grep -E "^[a-z]$" | awk '!seen[$0]++' | tr -d '\n')
    for ((l=0; l<${#ADD_SELECT}; l++)); do
      local ch="${ADD_SELECT:$l:1}"
      local aidx=$(( $(printf "%d" "'$ch") - 97 ))
      [ $aidx -lt ${#NOT_EXISTED_PROTOCOLS[@]} ] && ADD_PROTOCOLS+=("${NOT_EXISTED_PROTOCOLS[$aidx]}")
    done
  fi

  local REINSTALL_PROTOCOLS=("${KEEP_PROTOCOLS[@]}" "${ADD_PROTOCOLS[@]}")
  [ "${#REINSTALL_PROTOCOLS[@]}" = 0 ] && error "\n $(text 94) \n"

  hint "\n $(text 92) (${#REINSTALL_PROTOCOLS[@]})"
  [ "${#KEEP_PROTOCOLS[@]}" -gt 0 ] && hint "\n $(text 96) (${#KEEP_PROTOCOLS[@]})"
  for r in "${!KEEP_PROTOCOLS[@]}"; do hint "  $((r+1)). ${KEEP_PROTOCOLS[r]}"; done
  [ "${#ADD_PROTOCOLS[@]}" -gt 0 ] && hint "\n $(text 97) (${#ADD_PROTOCOLS[@]})"
  for r in "${!ADD_PROTOCOLS[@]}"; do hint "  $((r+1)). ${ADD_PROTOCOLS[r]}"; done
  reading "\n $(text 93) " CONFIRM
  [ "${CONFIRM,,}" = 'n' ] && exit 0

  local REINSTALL_TAGS=() REMOVE_TAGS=() ADD_TAGS=()
  for idx in "${!NODE_TAG[@]}"; do
    local tag="${NODE_TAG[$idx]}"
    local pname="${PROTOCOL_LIST[$idx]}"
    for p in "${REINSTALL_PROTOCOLS[@]}"; do
      if [ "$p" = "$pname" ] || [ "$tag" = "${NODE_TAG[7]}" -a "$p" = "$(text 101)" ]; then
        REINSTALL_TAGS+=("$tag")
        break
      fi
    done
  done

  for pname in "${REMOVE_PROTOCOLS[@]}"; do
    for idx in "${!PROTOCOL_LIST[@]}"; do
      [[ "${PROTOCOL_LIST[$idx]}" = "$pname" || ( "$idx" = '7' && "$pname" = "$(text 101)" ) ]] && REMOVE_TAGS+=("${NODE_TAG[$idx]}") && break
    done
  done
  for pname in "${ADD_PROTOCOLS[@]}"; do
    for idx in "${!PROTOCOL_LIST[@]}"; do
      [[ "${PROTOCOL_LIST[$idx]}" = "$pname" || ( "$idx" = '7' && "$pname" = "$(text 101)" ) ]] && ADD_TAGS+=("${NODE_TAG[$idx]}") && break
    done
  done

  cmd_systemctl disable xray

  local _HAS_HY2_ADD=false _HAS_HY2_KEEP=false
  for t in "${ADD_TAGS[@]}"; do [ "$t" = 'hysteria2' ] && _HAS_HY2_ADD=true && break; done
  for t in "${REINSTALL_TAGS[@]}"; do [ "$t" = 'hysteria2' ] && _HAS_HY2_KEEP=true && break; done
  if $_HAS_HY2_ADD; then
    ssl_certificate "${TLS_SERVER}"
    # 先收集端口跳跃范围，再写 NAT 规则（原逻辑顺序颠倒，NAT 参数为空）
    unset IS_HOPPING PORT_HOPPING_RANGE PORT_HOPPING_START PORT_HOPPING_END
    input_hopping_port
  fi

  local _HAS_XHTTP_DIRECT_ADD=false
  for _t in "${ADD_TAGS[@]}"; do [ "$_t" = 'xhttp-h3-direct' ] && _HAS_XHTTP_DIRECT_ADD=true && break; done
  if $_HAS_XHTTP_DIRECT_ADD; then
    ssl_certificate "${TLS_SERVER}"
  fi

  local _HAS_TROJAN_DIRECT_ADD=false
  for _t in "${ADD_TAGS[@]}"; do [ "$_t" = 'trojan-direct' ] && _HAS_TROJAN_DIRECT_ADD=true && break; done
  if $_HAS_TROJAN_DIRECT_ADD; then
    ssl_certificate "${TLS_SERVER}"
  fi

  local _HAS_REALITY_ADD=false
  for _t in "${ADD_TAGS[@]}"; do [[ "$_t" =~ ^(reality-vision|reality-grpc)$ ]] && _HAS_REALITY_ADD=true && break; done
  if $_HAS_REALITY_ADD; then
    if [ -z "${REALITY_DOMAIN:-}" ] && [ -s "$CUSTOM_FILE" ]; then
      local _rd_cp
      _rd_cp=$(awk -F= '/^realityDomain=/{print $2}' "$CUSTOM_FILE")
      [[ -n "$_rd_cp" && "$_rd_cp" != '__REALITY_DOMAIN_UNSET__' ]] && REALITY_DOMAIN="$_rd_cp"
    fi
    [[ "${REALITY_DOMAIN:-}" == '__REALITY_DOMAIN_UNSET__' ]] && REALITY_DOMAIN=''
    local _REALITY_DOMAIN_ADD="${REALITY_DOMAIN:-}"
    reading "
 $(text 126) " _REALITY_DOMAIN_ADD
    REALITY_DOMAIN="${_REALITY_DOMAIN_ADD//[[:space:]]/}"
    if [ -n "${REALITY_DOMAIN:-}" ] && ! validate_reality_addr "$REALITY_DOMAIN"; then
      error " $(text 127) "
    fi

    if [ -z "$REALITY_PRIVATE" ] && [ -s "$CUSTOM_FILE" ]; then
      local _pk_cp
      _pk_cp=$(awk -F= '/^privateKey=/{print $2}' "$CUSTOM_FILE")
      [[ -n "$_pk_cp" && "$_pk_cp" != '__KEY_UNSET__' ]] && REALITY_PRIVATE="$_pk_cp"
      [[ -n "$REALITY_PRIVATE" && "$REALITY_PRIVATE" != '__KEY_UNSET__' ]] && REALITY_PUBLIC=$(awk -F= '/^publicKey=/{print $2}' "$CUSTOM_FILE")
    fi
    [[ "$REALITY_PRIVATE" == '__KEY_UNSET__' ]] && REALITY_PRIVATE=''
    [[ "$REALITY_PUBLIC" == '__KEY_UNSET__' ]] && REALITY_PUBLIC=''
    if [ -z "$REALITY_PRIVATE" ]; then
      reading "\n $(text 98) " REALITY_PRIVATE
      if [ -z "$REALITY_PRIVATE" ]; then
        generate_reality_keypair
      else
        REALITY_PUBLIC=$($WORK_DIR/xray x25519 -i "$REALITY_PRIVATE" | awk '/Public/{print $NF}')
        if [ -z "$REALITY_PUBLIC" ]; then
          warning " $(text 99) "
          generate_reality_keypair
        fi
      fi
    fi
  fi

  for tag in "${REMOVE_TAGS[@]}"; do
    [ "$tag" = 'hysteria2' ] && del_port_hopping_nat
    if [ -x "$WORK_DIR/jq" ]; then
      grep -v '^//' $WORK_DIR/inbound.json > $TEMP_DIR/inbound_clean.json
      $WORK_DIR/jq "del(.inbounds[] | select(.tag | split(\" \")[-1] == \"$tag\"))" \
        $TEMP_DIR/inbound_clean.json > $TEMP_DIR/inbound_tmp.json \
      && mv $TEMP_DIR/inbound_tmp.json $WORK_DIR/inbound.json
    fi
  done

  local _SAVED_PRIVATE="$REALITY_PRIVATE" _SAVED_PUBLIC="$REALITY_PUBLIC" _SAVED_REALITY_DOMAIN="${REALITY_DOMAIN:-}"
  # 保存 HY2 端口跳跃状态，防止 fetch_nodes_value 内的 check_port_hopping_nat 清空
  local _SAVED_IS_HOPPING="$IS_HOPPING" _SAVED_HOP_START="$PORT_HOPPING_START" _SAVED_HOP_END="$PORT_HOPPING_END"
  fetch_nodes_value
  # 恢复端口跳跃状态（仅当新增 HY2 时有效）
  if $_HAS_HY2_ADD; then
    IS_HOPPING="$_SAVED_IS_HOPPING"
    PORT_HOPPING_START="$_SAVED_HOP_START"
    PORT_HOPPING_END="$_SAVED_HOP_END"
  fi
  [[ -n "$_SAVED_PRIVATE" && "$_SAVED_PRIVATE" != '__KEY_UNSET__' ]] && REALITY_PRIVATE="$_SAVED_PRIVATE"
  [[ -n "$_SAVED_PUBLIC" && "$_SAVED_PUBLIC" != '__KEY_UNSET__' ]] && REALITY_PUBLIC="$_SAVED_PUBLIC"
  [[ -n "$_SAVED_REALITY_DOMAIN" && "$_SAVED_REALITY_DOMAIN" != '__REALITY_DOMAIN_UNSET__' ]] && REALITY_DOMAIN="$_SAVED_REALITY_DOMAIN"
  [[ "$REALITY_PRIVATE" == '__KEY_UNSET__' ]] && REALITY_PRIVATE=''
  [[ "$REALITY_PUBLIC" == '__KEY_UNSET__' ]] && REALITY_PUBLIC=''
  [ -z "$UUID" ] && UUID=$(cat /proc/sys/kernel/random/uuid)

  local _JSON_CLEAN
  _JSON_CLEAN=$(grep -v '^//' $WORK_DIR/inbound.json 2>/dev/null)

  local _USED_PORTS=()
  for tag in "${REINSTALL_TAGS[@]}"; do
    local _EXIST_PORT
    _EXIST_PORT=$(echo "$_JSON_CLEAN" | $WORK_DIR/jq -r "[.inbounds[] | select(.tag | split(\" \")[-1] == \"$tag\") | .port] | .[0] // empty" 2>/dev/null)
    if [ -n "$_EXIST_PORT" ]; then
      _USED_PORTS+=("$_EXIST_PORT")
      case "$tag" in
        reality-vision) REALITY_PORT=$_EXIST_PORT ;;
        hysteria2) HY2_PORT=$_EXIST_PORT ;;
        reality-grpc) GRPC_PORT=$_EXIST_PORT ;;
        vless-ws) VLESS_WS_PORT=$_EXIST_PORT ;;
        vmess-ws) VMESS_WS_PORT=$_EXIST_PORT ;;
        trojan-ws) TROJAN_WS_PORT=$_EXIST_PORT ;;
        ss-ws) SS_WS_PORT=$_EXIST_PORT ;;
        xhttp-h1.1-cdn) VLESS_XHTTP_PORT=$_EXIST_PORT ;;
        xhttp-h3-direct) XHTTP_PORT=$_EXIST_PORT ;;
        trojan-direct) TROJAN_PORT=$_EXIST_PORT ;;
        ss2022-direct) SS2022_PORT=$_EXIST_PORT ;;
      esac
    fi
  done

  local _SCAN_PORT
  _SCAN_PORT=$(echo "$_JSON_CLEAN" | $WORK_DIR/jq -r '[.inbounds[].port] | min // empty' 2>/dev/null)
  _SCAN_PORT=${_SCAN_PORT:-$START_PORT_DEFAULT}

  for tag in "${REINSTALL_TAGS[@]}"; do
    local _EXIST_PORT
    _EXIST_PORT=$(echo "$_JSON_CLEAN" | $WORK_DIR/jq -r "[.inbounds[] | select(.tag | split(\" \")[-1] == \"$tag\") | .port] | .[0] // empty" 2>/dev/null)
    if [ -z "$_EXIST_PORT" ]; then
      while printf '%s\n' "${_USED_PORTS[@]}" | grep -qx "$_SCAN_PORT"; do
        (( _SCAN_PORT++ ))
      done
      local _NEW_PORT=$_SCAN_PORT
      _USED_PORTS+=("$_SCAN_PORT")
      (( _SCAN_PORT++ ))
      case "$tag" in
        reality-vision) REALITY_PORT=$_NEW_PORT ;;
        hysteria2) HY2_PORT=$_NEW_PORT ;;
        reality-grpc) GRPC_PORT=$_NEW_PORT ;;
        vless-ws) VLESS_WS_PORT=$_NEW_PORT ;;
        vmess-ws) VMESS_WS_PORT=$_NEW_PORT ;;
        trojan-ws) TROJAN_WS_PORT=$_NEW_PORT ;;
        ss-ws) SS_WS_PORT=$_NEW_PORT ;;
        xhttp-h1.1-cdn) VLESS_XHTTP_PORT=$_NEW_PORT ;;
        xhttp-h3-direct) XHTTP_PORT=$_NEW_PORT ;;
        trojan-direct) TROJAN_PORT=$_NEW_PORT ;;
        ss2022-direct) SS2022_PORT=$_NEW_PORT ;;
      esac
    fi
  done

  # 新增 HY2：input_hopping_port 已在上方 ssl_certificate 之后调用，此处直接写 NAT
  if $_HAS_HY2_ADD; then
    [ "$IS_HOPPING" = 'is_hopping' ] && add_port_hopping_nat "$PORT_HOPPING_START" "$PORT_HOPPING_END" "$HY2_PORT"
  elif $_HAS_HY2_KEEP; then
    # 保留 HY2：只检查现有规则状态，不重复写入，避免 iptables 规则叠加
    check_port_hopping_nat
  fi

  local _HAS_WS_XHTTP_ADD=false
  for _t in "${ADD_TAGS[@]}"; do
    [[ "$_t" =~ ^(vless-ws|vmess-ws|trojan-ws|ss-ws|xhttp-h1.1-cdn)$ ]] && _HAS_WS_XHTTP_ADD=true && break
  done

  if $_HAS_WS_XHTTP_ADD && [[ -z "$SERVER" || "$SERVER" == '__CDN_UNSET__' ]]; then
    echo ""
    for _c in "${!CDN_DOMAIN[@]}"; do
      hint " $((_c+1)). ${CDN_DOMAIN[_c]} "
    done
    reading "\n $(text 42) " CUSTOM_CDN
    case "$CUSTOM_CDN" in
      [1-9]|[1-9][0-9] )
        [ "$CUSTOM_CDN" -le "${#CDN_DOMAIN[@]}" ] && SERVER="${CDN_DOMAIN[$((CUSTOM_CDN-1))]}" || SERVER="${CDN_DOMAIN[0]}"
        SERVER_PORT=443
        ;;
      ?????* )
        parse_preferred_addr "$CUSTOM_CDN" || error " $(text 118) "
        SERVER="$PREFERRED_ADDR"
        SERVER_PORT="$PREFERRED_PORT"
        ;;
      * )
        SERVER="${CDN_DOMAIN[0]}"
        SERVER_PORT=443
    esac
  fi

  # 若最终协议列表中不含任何 Reality 协议，清除公私钥
  local _HAS_REALITY_FINAL=false
  for _t in "${REINSTALL_TAGS[@]}"; do
    [[ "$_t" =~ ^(reality-vision|reality-grpc)$ ]] && _HAS_REALITY_FINAL=true && break
  done
  $_HAS_REALITY_FINAL || { REALITY_PRIVATE='__KEY_UNSET__'; REALITY_PUBLIC='__KEY_UNSET__'; REALITY_DOMAIN=''; }

  # 若最终协议列表中不含任何 WS/XHTTP 协议，清除 CDN
  local _HAS_WS_XHTTP_FINAL=false
  for _t in "${REINSTALL_TAGS[@]}"; do
    [[ "$_t" =~ ^(vless-ws|vmess-ws|trojan-ws|ss-ws|xhttp-h1.1-cdn)$ ]] && _HAS_WS_XHTTP_FINAL=true && break
  done
  $_HAS_WS_XHTTP_FINAL || SERVER='__CDN_UNSET__'

  local _XHTTP_TLS_SERVER_NAME="$ARGO_DOMAIN"
  if printf '%s
' "${REINSTALL_TAGS[@]}" | grep -qx 'xhttp-h1.1-cdn'; then
    if [ -z "$_XHTTP_TLS_SERVER_NAME" ]; then
      case $(grep "${DAEMON_RUN_PATTERN}" ${ARGO_DAEMON_FILE} 2>/dev/null) in
        *--config* ) fetch_tunnel_domain config >/dev/null 2>&1 || true ;;
        *--token* ) fetch_tunnel_domain config >/dev/null 2>&1 || true ;;
        * ) fetch_tunnel_domain quick >/dev/null 2>&1 || true ;;
      esac
      _XHTTP_TLS_SERVER_NAME="$ARGO_DOMAIN"
    fi
    [ -z "$_XHTTP_TLS_SERVER_NAME" ] && _XHTTP_TLS_SERVER_NAME="$TLS_SERVER"
  fi

  prepare_vless_pqc_keys
  ech_runtime_values

  write_custom 'serverIp' "${SERVER_IP}"
  if [ -n "${REALITY_DOMAIN:-}" ]; then
    validate_reality_addr "$REALITY_DOMAIN" || error " $(text 127) "
    write_custom 'realityDomain' "${REALITY_DOMAIN}"
  else
    write_custom 'realityDomain' '__REALITY_DOMAIN_UNSET__'
  fi
  write_custom 'privateKey' "${REALITY_PRIVATE:-__KEY_UNSET__}"
  write_custom 'publicKey' "${REALITY_PUBLIC:-__KEY_UNSET__}"
  write_custom 'cdn' "${SERVER:-__CDN_UNSET__}"
  write_custom 'cdnPort' "${SERVER_PORT:-443}"
  write_custom 'wsPath' "${WS_PATH:-$WS_PATH_DEFAULT}"
  write_custom 'enableEch' "${ENABLE_ECH:-y}"
  write_custom 'echStrict' "${ECH_STRICT:-y}"
  write_custom 'echConfig' "${ECH_CONFIG:-}"
  write_custom 'echQueryDomain' "${ECH_QUERY_DOMAIN:-cloudflare-ech.com}"
  write_custom 'echDns' "${ECH_DNS:-https://1.1.1.1/dns-query}"
  write_custom 'xhttpCdnMode' "${XHTTP_CDN_MODE:-packet-up}"
  write_custom 'enableXhttpSplit' "${ENABLE_XHTTP_SPLIT:-n}"
  write_custom 'xhttpDownloadServer' "${XHTTP_DOWNLOAD_SERVER:-}"
  write_custom 'xhttpDownloadPort' "${XHTTP_DOWNLOAD_PORT:-}"

  cat > $WORK_DIR/inbound.json << EOF
{
  "log": {
    "access": "/dev/null",
    "error": "/dev/null",
    "loglevel": "none"
  },
  "inbounds": []
}
EOF

  for tag in "${REINSTALL_TAGS[@]}"; do
    local NEW_BLOCK=''
    case "$tag" in
      hysteria2) NEW_BLOCK="{\"tag\":\"${NODE_NAME} ${NODE_TAG[1]}\",\"protocol\":\"hysteria\",\"port\":${HY2_PORT},\"settings\":{\"version\":2,\"clients\":[{\"auth\":\"${UUID}\"}]},\"streamSettings\":{\"network\":\"hysteria\",\"security\":\"tls\",\"tlsSettings\":{\"serverNames\":[\"${TLS_SERVER}\"],\"alpn\":[\"h3\"],\"certificates\":[{\"certificateFile\":\"${WORK_DIR}/cert/cert.pem\",\"keyFile\":\"${WORK_DIR}/cert/private.key\"}]}}}" ;;
      vless-ws) NEW_BLOCK="{\"port\":${VLESS_WS_PORT},\"listen\":\"127.0.0.1\",\"protocol\":\"vless\",\"tag\":\"${NODE_NAME} ${NODE_TAG[3]}\",\"settings\":{\"clients\":[{\"id\":\"${UUID}\",\"level\":0}],\"decryption\":\"${VLESS_SERVER_DECRYPTION:-none}\"},\"streamSettings\":{\"network\":\"ws\",\"security\":\"none\",\"wsSettings\":{\"path\":\"/${WS_PATH}-vl\"}},\"sniffing\":{\"enabled\":true,\"destOverride\":[\"http\",\"tls\",\"quic\"],\"metadataOnly\":false}}" ;;
      vmess-ws) NEW_BLOCK="{\"port\":${VMESS_WS_PORT},\"listen\":\"127.0.0.1\",\"protocol\":\"vmess\",\"tag\":\"${NODE_NAME} ${NODE_TAG[4]}\",\"settings\":{\"clients\":[{\"id\":\"${UUID}\",\"alterId\":0}]},\"streamSettings\":{\"network\":\"ws\",\"wsSettings\":{\"path\":\"/${WS_PATH}-vm\"}},\"sniffing\":{\"enabled\":true,\"destOverride\":[\"http\",\"tls\",\"quic\"],\"metadataOnly\":false}}" ;;
      trojan-ws) NEW_BLOCK="{\"port\":${TROJAN_WS_PORT},\"listen\":\"127.0.0.1\",\"protocol\":\"trojan\",\"tag\":\"${NODE_NAME} ${NODE_TAG[5]}\",\"settings\":{\"clients\":[{\"password\":\"${UUID}\"}]},\"streamSettings\":{\"network\":\"ws\",\"security\":\"none\",\"wsSettings\":{\"path\":\"/${WS_PATH}-tr\"}},\"sniffing\":{\"enabled\":true,\"destOverride\":[\"http\",\"tls\",\"quic\"],\"metadataOnly\":false}}" ;;
      ss-ws) NEW_BLOCK="{\"port\":${SS_WS_PORT},\"listen\":\"127.0.0.1\",\"protocol\":\"shadowsocks\",\"tag\":\"${NODE_NAME} ${NODE_TAG[6]}\",\"settings\":{\"clients\":[{\"method\":\"chacha20-ietf-poly1305\",\"password\":\"${UUID}\"}],\"network\":\"tcp,udp\"},\"streamSettings\":{\"network\":\"ws\",\"wsSettings\":{\"path\":\"/${WS_PATH}-sh\"}},\"sniffing\":{\"enabled\":true,\"destOverride\":[\"http\",\"tls\",\"quic\"],\"metadataOnly\":false}}" ;;
      xhttp-h1.1-cdn) NEW_BLOCK="{\"port\":${VLESS_XHTTP_PORT},\"listen\":\"127.0.0.1\",\"protocol\":\"vless\",\"tag\":\"${NODE_NAME} ${NODE_TAG[7]}\",\"settings\":{\"clients\":[{\"id\":\"${UUID}\",\"level\":0}],\"decryption\":\"${VLESS_SERVER_DECRYPTION:-none}\"},\"streamSettings\":{\"network\":\"xhttp\",\"security\":\"none\",\"xhttpSettings\":{\"path\":\"/${WS_PATH}-xh\",\"mode\":\"${XHTTP_CDN_MODE:-packet-up}\",\"extra\":{\"xPaddingBytes\":\"100-1000\",\"noSSEHeader\":true,\"scMaxEachPostBytes\":\"1000000-2000000\",\"scMinPostsIntervalMs\":\"30-30\",\"scMaxBufferedPosts\":30}}},\"sniffing\":{\"enabled\":true,\"destOverride\":[\"http\",\"tls\",\"quic\"],\"metadataOnly\":false}}" ;;
      xhttp-h3-direct) NEW_BLOCK="{\"tag\":\"${NODE_NAME} ${NODE_TAG[8]}\",\"port\":${XHTTP_PORT},\"protocol\":\"vless\",\"settings\":{\"clients\":[{\"id\":\"${UUID}\"}],\"decryption\":\"${VLESS_SERVER_DECRYPTION:-none}\"},\"streamSettings\":{\"network\":\"xhttp\",\"security\":\"tls\",\"xhttpSettings\":{\"mode\":\"stream-up\",\"extra\":{\"alpn\":[\"h3\"],\"xPaddingBytes\":\"100-1000\",\"noSSEHeader\":true,\"scMaxEachPostBytes\":\"1000000-2000000\",\"scMaxBufferedPosts\":30},\"path\":\"/${WS_PATH}-xh3\"},\"tlsSettings\":{\"serverName\":\"${TLS_SERVER}\",\"alpn\":[\"h3\"],\"minVersion\":\"1.3\",\"maxVersion\":\"1.3\",\"curvePreferences\":[\"X25519MLKEM768\",\"X25519\"],\"certificates\":[{\"certificateFile\":\"${WORK_DIR}/cert/cert.pem\",\"keyFile\":\"${WORK_DIR}/cert/private.key\"}]}},\"sniffing\":{\"enabled\":true,\"destOverride\":[\"http\",\"tls\",\"quic\"]}}" ;;
      trojan-direct) NEW_BLOCK="{\"port\":${TROJAN_PORT},\"protocol\":\"trojan\",\"tag\":\"${NODE_NAME} ${NODE_TAG[9]}\",\"settings\":{\"clients\":[{\"password\":\"${UUID}\"}]},\"streamSettings\":{\"network\":\"tcp\",\"security\":\"tls\",\"tlsSettings\":{\"serverName\":\"${TLS_SERVER}\",\"minVersion\":\"1.3\",\"maxVersion\":\"1.3\",\"curvePreferences\":[\"X25519MLKEM768\",\"X25519\"],\"certificates\":[{\"certificateFile\":\"${WORK_DIR}/cert/cert.pem\",\"keyFile\":\"${WORK_DIR}/cert/private.key\"}]}},\"sniffing\":{\"enabled\":true,\"destOverride\":[\"http\",\"tls\",\"quic\"],\"metadataOnly\":false}}" ;;
      ss2022-direct) NEW_BLOCK="{\"port\":${SS2022_PORT},\"protocol\":\"shadowsocks\",\"tag\":\"${NODE_NAME} ${NODE_TAG[10]}\",\"settings\":{\"method\":\"2022-blake3-aes-128-gcm\",\"password\":\"${SS2022_PASSWORD}\",\"network\":\"tcp,udp\"},\"sniffing\":{\"enabled\":true,\"destOverride\":[\"http\",\"tls\",\"quic\"],\"metadataOnly\":false}}" ;;
      reality-vision) NEW_BLOCK="{\"tag\":\"${NODE_NAME} ${NODE_TAG[0]}\",\"protocol\":\"vless\",\"port\":${REALITY_PORT},\"settings\":{\"clients\":[{\"id\":\"${UUID}\",\"flow\":\"xtls-rprx-vision\"}],\"decryption\":\"${VLESS_SERVER_DECRYPTION:-none}\"},\"streamSettings\":{\"network\":\"tcp\",\"security\":\"reality\",\"realitySettings\":{\"show\":false,\"dest\":\"${TLS_SERVER}:443\",\"xver\":0,\"serverNames\":[\"${TLS_SERVER}\"],\"privateKey\":\"${REALITY_PRIVATE}\",\"shortIds\":[\"\"]}},\"sniffing\":{\"enabled\":true,\"destOverride\":[\"http\",\"tls\"]}}" ;;
      reality-grpc) NEW_BLOCK="{\"port\":${GRPC_PORT},\"protocol\":\"vless\",\"tag\":\"${NODE_NAME} ${NODE_TAG[2]}\",\"settings\":{\"clients\":[{\"id\":\"${UUID}\",\"flow\":\"\"}],\"decryption\":\"${VLESS_SERVER_DECRYPTION:-none}\"},\"streamSettings\":{\"network\":\"grpc\",\"security\":\"reality\",\"realitySettings\":{\"show\":false,\"dest\":\"${TLS_SERVER}:443\",\"xver\":0,\"serverNames\":[\"${TLS_SERVER}\"],\"privateKey\":\"${REALITY_PRIVATE}\",\"shortIds\":[\"\"]},\"grpcSettings\":{\"serviceName\":\"grpc\",\"multiMode\":true}},\"sniffing\":{\"enabled\":true,\"destOverride\":[\"http\",\"tls\"]}}" ;;
    esac
    if [ -n "$NEW_BLOCK" ] && [ -x "$WORK_DIR/jq" ]; then
      $WORK_DIR/jq --argjson block "$NEW_BLOCK" '.inbounds += [$block]' \
        $WORK_DIR/inbound.json > $TEMP_DIR/inbound_tmp.json \
        && mv $TEMP_DIR/inbound_tmp.json $WORK_DIR/inbound.json
    fi

  done

  mapfile -t CURRENT_PROTOCOLS < <(get_installed_protocols)

  json_nginx
  [ -s "$WORK_DIR/tunnel.json" ] && json_argo
  local _NGINX_PID=$(pgrep -f "nginx: master process" 2>/dev/null)
  if [ -n "$_NGINX_PID" ]; then
    nginx -c $WORK_DIR/nginx.conf -s reload >/dev/null 2>&1 || true
  else
    $(command -v nginx) -c $WORK_DIR/nginx.conf >/dev/null 2>&1 || true
  fi

  if [ ! -s "${ARGO_DAEMON_FILE}" ]; then
    argo_variable
  elif [ -s "$WORK_DIR/tunnel.json" ]; then
    cmd_systemctl restart argo
  fi

  cmd_systemctl enable xray
  sleep 2
  check_install
  cmd_systemctl status xray &>/dev/null \
    && info "\n Xray $(text 28) $(text 37) \n" \
    || warning "\n Xray $(text 28) $(text 38) \n"
  export_list
  sync_firewall_rules
}

# 更换 Argo 隧道类型
change_argo() {
  check_install
  [[ ${STATUS[0]} = "$(text 26)" ]] && error " $(text 39) "

  case $(grep "${DAEMON_RUN_PATTERN}" ${ARGO_DAEMON_FILE}) in
    *--config* )
      ARGO_TYPE='Json'
      ;;
    *--token* )
      ARGO_TYPE='Token'
      ;;
    * )
      ARGO_TYPE='Try'
      cmd_systemctl enable argo && sleep 2 && cmd_systemctl status argo &>/dev/null && fetch_tunnel_domain quick
  esac

  # 若 Try 隧道且已安装 xhttp-h1.1-cdn，在类型后附加提示
  local ARGO_TYPE="$ARGO_TYPE"
  if [ "$ARGO_TYPE" = 'Try' ] && get_installed_protocols | grep -q 'xhttp-h1.1-cdn'; then
    ARGO_TYPE="Try $(text 113)"
  fi

  # 获取当前隧道域名用于显示（Json/Token 走 /config，Try 已在上方获取）
  [ -z "$NGINX_PORT" ] && [ -s "$WORK_DIR/nginx.conf" ] && NGINX_PORT=$(awk '/listen[[:space:]]/{gsub(/;/,""); print $2; exit}' "$WORK_DIR/nginx.conf")
  [ -z "$ARGO_DOMAIN" ] && { [[ "$ARGO_TYPE" =~ ^Try ]] && fetch_tunnel_domain quick || fetch_tunnel_domain config; }
  hint "\n $(text 40) \n"
  unset ARGO_DOMAIN
  hint " $(text 41) \n" && reading " $(text 24) " CHANGE_TO
  # 切换前确保 NGINX_PORT 有值（优先从 nginx.conf 读取，兜底默认值）
  case "$CHANGE_TO" in
    1 )
      cmd_systemctl disable argo
      [ -s $WORK_DIR/tunnel.json ] && rm -f $WORK_DIR/tunnel.{json,yml}
      if [ "$SYSTEM" = 'Alpine' ]; then
        local ARGS="--edge-ip-version auto --no-autoupdate --url http://localhost:${NGINX_PORT}"
        sed -i "s@^command_args=.*@command_args=\"$ARGS\"@g" ${ARGO_DAEMON_FILE}
      else
        sed -i "s@ExecStart=.*@ExecStart=$WORK_DIR/cloudflared tunnel --edge-ip-version auto --no-autoupdate --url http://localhost:${NGINX_PORT}@g" ${ARGO_DAEMON_FILE}
      fi
      ;;
    2 )
      SERVER_IP=$(awk -F= '/^serverIp=/{print $2}' "$CUSTOM_FILE" 2>/dev/null)
      local TOTAL_STEPS=''
      [ -z "$ARGO_DOMAIN" ] && reading "\n $(text 10) " ARGO_DOMAIN
      if [[ -n "$ARGO_DOMAIN" && ! "$ARGO_DOMAIN" =~ trycloudflare\.com$ && -z "$ARGO_AUTH" ]]; then
        hint "\n $(text 11)"
        reading "\n $(text 86) " ARGO_AUTH
      fi
      argo_variable
      cmd_systemctl disable argo
      if [ -n "$ARGO_TOKEN" ]; then
        [ -s $WORK_DIR/tunnel.json ] && rm -f $WORK_DIR/tunnel.{json,yml}
        if [ "$SYSTEM" = 'Alpine' ]; then
          local ARGS="--edge-ip-version auto run --token ${ARGO_TOKEN}"
          sed -i "s@^command_args=.*@command_args=\"$ARGS\"@g" ${ARGO_DAEMON_FILE}
        else
          sed -i "s@ExecStart=.*@ExecStart=$WORK_DIR/cloudflared tunnel --edge-ip-version auto run --token ${ARGO_TOKEN}@g" ${ARGO_DAEMON_FILE}
        fi
      elif [ -n "$ARGO_JSON" ]; then
        [ -s $WORK_DIR/tunnel.json ] && rm -f $WORK_DIR/tunnel.{json,yml}
        json_argo
        if [ "$SYSTEM" = 'Alpine' ]; then
          local ARGS="--edge-ip-version auto --config $WORK_DIR/tunnel.yml run"
          sed -i "s@^command_args=.*@command_args=\"$ARGS\"@g" ${ARGO_DAEMON_FILE}
        else
          sed -i "s@ExecStart=.*@ExecStart=$WORK_DIR/cloudflared tunnel --edge-ip-version auto --config $WORK_DIR/tunnel.yml run@g" ${ARGO_DAEMON_FILE}
        fi
      fi
      ;;
    * )
      exit 0
  esac

  [ "$IS_NGINX" = 'is_nginx' ] && json_nginx
  [ -s "$WORK_DIR/tunnel.json" ] && json_argo
  cmd_systemctl enable argo
  export_list
}

# 更换优选地址 / Reality 连接域名 / Reality SNI / 节点信息
change_start_port() {
  local OLD_PORTS OLD_START_PORT OLD_CONSECUTIVE_PORTS
  local _STEP_NUM_BAK="${STEP_NUM-}" _TOTAL_STEPS_BAK="${TOTAL_STEPS-}"
  [ ! -s "$WORK_DIR/inbound.json" ] && error " $(text 70) "
  OLD_PORTS=$(grep -v '^//' "$WORK_DIR/inbound.json" | $WORK_DIR/jq -r '.inbounds[].port' 2>/dev/null)
  [ -z "$OLD_PORTS" ] && error " $(text 70) "
  OLD_START_PORT=$(awk 'NR == 1 { min = $0 } { if ($0 < min) min = $0 } END {print min}' <<< "$OLD_PORTS")
  OLD_CONSECUTIVE_PORTS=$(awk 'END { print NR }' <<< "$OLD_PORTS")
  unset STEP_NUM TOTAL_STEPS
  START_PORT=''
  input_start_port "$OLD_CONSECUTIVE_PORTS"
  STEP_NUM="$_STEP_NUM_BAK"
  TOTAL_STEPS="$_TOTAL_STEPS_BAK"
  [ -z "$START_PORT" ] && info " $(text 103) " && return
  [ "$START_PORT" = "$OLD_START_PORT" ] && info " $(text 103) " && return

  grep -v '^//' "$WORK_DIR/inbound.json"     | $WORK_DIR/jq --argjson start "$START_PORT" '.inbounds |= (to_entries | map(.value.port = ($start + .key) | .value))'     > "$TEMP_DIR/inbound_tmp.json"     && mv "$TEMP_DIR/inbound_tmp.json" "$WORK_DIR/inbound.json" || error " $(text 38) "

  fetch_nodes_value
  [ -s "$WORK_DIR/nginx.conf" ] && json_nginx
  [ -s "$WORK_DIR/tunnel.json" ] && json_argo
  cmd_systemctl restart xray
  FIREWALL_SILENT=1 sync_firewall_rules >/dev/null 2>&1 || true
  [ -s "$WORK_DIR/tunnel.json" ] && cmd_systemctl restart argo
  sleep 2
  export_list
  cmd_systemctl status xray &>/dev/null && info "
 Xray $(text 28) $(text 37)
" || warning "
 Xray $(text 27) $(text 38)
"
}

change_config() {
  [ ! -d "${WORK_DIR}" ] && error " $(text 70) "

  fetch_nodes_value || error " $(text 70) "

  local MENU_IDX=() MENU_KEY=() MENU_VAL=()

  [[ -n "$SERVER" && "$SERVER" != '__CDN_UNSET__' ]] && MENU_IDX+=(107) && MENU_KEY+=(cdn) && MENU_VAL+=("${SERVER_DISPLAY:-$SERVER}")
  [ -n "$TLS_SERVER" ] && MENU_IDX+=(108) && MENU_KEY+=(sni) && MENU_VAL+=("$TLS_SERVER")
  if get_installed_protocols 2>/dev/null | grep -Eq '^(reality-vision|reality-grpc)$'; then
    local _REALITY_DOMAIN_NOW="${REALITY_DOMAIN:-}"
    [ -z "$_REALITY_DOMAIN_NOW" ] && _REALITY_DOMAIN_NOW="$(text 67)"
    MENU_IDX+=(125) && MENU_KEY+=(realitydomain) && MENU_VAL+=("$_REALITY_DOMAIN_NOW")
  fi
  local PORTS_NOW=$(grep -v '^//' "$WORK_DIR/inbound.json" 2>/dev/null | $WORK_DIR/jq -r '.inbounds[].port' 2>/dev/null)
  if [ -n "$PORTS_NOW" ]; then
    local PORTS_NOW_START=$(awk 'NR == 1 { min = $0 } { if ($0 < min) min = $0 } END {print min}' <<< "$PORTS_NOW")
    local PORTS_NOW_COUNT=$(awk 'END { print NR }' <<< "$PORTS_NOW")
    local PORTS_NOW_END=$((PORTS_NOW_START + PORTS_NOW_COUNT - 1))
    MENU_IDX+=(119) && MENU_KEY+=(ports) && MENU_VAL+=("${PORTS_NOW_START} - ${PORTS_NOW_END}")
  fi
  [ -n "$NODE_NAME" ] && MENU_IDX+=(109) && MENU_KEY+=(name) && MENU_VAL+=("$NODE_NAME")
  [ -n "$UUID" ] && MENU_IDX+=(110) && MENU_KEY+=(uuid) && MENU_VAL+=("$UUID")
  [ -n "$SERVER_IP" ] && MENU_IDX+=(111) && MENU_KEY+=(serverip) && MENU_VAL+=("$SERVER_IP")
  if get_installed_protocols 2>/dev/null | grep -qx 'xhttp-h1.1-cdn'; then
    local _XHTTP_SPLIT_DISPLAY='off'
    if truthy "${ENABLE_XHTTP_SPLIT:-n}"; then
      _XHTTP_SPLIT_DISPLAY="on -> ${XHTTP_DOWNLOAD_SERVER:-$SERVER}:${XHTTP_DOWNLOAD_PORT:-${SERVER_PORT:-443}}"
    fi
    MENU_IDX+=(158) && MENU_KEY+=(xhttpsplit) && MENU_VAL+=("$_XHTTP_SPLIT_DISPLAY")
  fi

  # Hysteria2 带宽和端口跳跃（仅在 Hysteria2 已安装时显示）
  if [ -n "$HY2_PORT" ]; then
    # Hysteria2 带宽参数（一定有，默认 200/1000）
    HY2_UP_NOW=${HY2_UP_NOW:-200}
    HY2_DOWN_NOW=${HY2_DOWN_NOW:-1000}
    MENU_IDX+=(120) && MENU_KEY+=(hy2bw) && MENU_VAL+=("${HY2_UP_NOW}/${HY2_DOWN_NOW}")

    # 端口跳跃选项；是否已启用由 PORT_HOPPING_START/END 决定
    MENU_IDX+=(6) && MENU_KEY+=(hopping)
    if [ -n "$PORT_HOPPING_START" ]; then
      MENU_VAL+=("${PORT_HOPPING_START}:${PORT_HOPPING_END}")
    else
      MENU_VAL+=("$(text 67)")
    fi
  fi

  [ "${#MENU_IDX[@]}" -eq 0 ] && error " $(text 70) "

  hint "\n $(text 106)\n"
  for _i in "${!MENU_IDX[@]}"; do
    local _val="${MENU_VAL[_i]}"
    local _raw
    eval "_raw=\"\${${L}[${MENU_IDX[_i]}]}\""
    eval "hint \" $(( _i+1 )). ${_raw}\""
  done
  hint ""
  reading " $(text 24) " CHOOSE_NODE_INFO

  if ! [[ "$CHOOSE_NODE_INFO" =~ ^[0-9]+$ ]] || \
     [ "$CHOOSE_NODE_INFO" -lt 1 ] || \
     [ "$CHOOSE_NODE_INFO" -gt "${#MENU_IDX[@]}" ]; then
    info " $(text 103) " && return
  fi

  local IDX=$(( CHOOSE_NODE_INFO - 1 ))
  local KEY="${MENU_KEY[IDX]}"
  local OLD="${MENU_VAL[IDX]}"

  # 特殊操作路由（不走通用 reading/sed 替换）
  if [ "$KEY" = "ports" ]; then
    change_start_port
    return
  elif [ "$KEY" = "hy2bw" ]; then
    # 修改 Hysteria2 带宽 - 内联实现
    local HY2_UP HY2_DOWN
    while true; do
      reading " $(text 121) " HY2_UP
      [[ "$HY2_UP" =~ ^[1-9][0-9]*$ ]] && break
      warning " $(text 123) "
    done
    while true; do
      reading " $(text 122) " HY2_DOWN
      [[ "$HY2_DOWN" =~ ^[1-9][0-9]*$ ]] && break
      warning " $(text 123) "
    done
    sed -i -E "s/(up: \")([0-9]+)( Mbps\")/\1${HY2_UP}\3/g; s/(down: \")([0-9]+)( Mbps\")/\1${HY2_DOWN}\3/g" ${WORK_DIR}/subscribe/proxies
    export_list
    return
  elif [ "$KEY" = "hopping" ]; then
    # 保存旧状态，留空禁用时需要正确判断“是禁用成功”还是“本来就没开”
    local _OLD_HOP_START="$PORT_HOPPING_START" _OLD_HOP_END="$PORT_HOPPING_END" _OLD_HOP_RANGE="$OLD"
    # 提前保存 TARGET，del_port_hopping_nat / sync_firewall_rules 内部检查可能会重置相关变量
    local _HOP_TARGET="${PORT_HOPPING_TARGET:-$HY2_PORT}"
    unset IS_HOPPING PORT_HOPPING_RANGE PORT_HOPPING_START PORT_HOPPING_END
    input_hopping_port
    # 保存用户输入的起止端口，后续删除旧规则时内部检测可能会清空
    local _NEW_HOP_START="$PORT_HOPPING_START" _NEW_HOP_END="$PORT_HOPPING_END"
    # 先删除旧规则（无论原来是否有）
    del_port_hopping_nat
    if [ "$IS_HOPPING" = 'is_hopping' ]; then
      PORT_HOPPING_START="$_NEW_HOP_START"
      PORT_HOPPING_END="$_NEW_HOP_END"
      PORT_HOPPING_RANGE="${_NEW_HOP_START}:${_NEW_HOP_END}"
      PORT_HOPPING_TARGET="$_HOP_TARGET"
      FIREWALL_SILENT=1 add_port_hopping_nat "$PORT_HOPPING_START" "$PORT_HOPPING_END" "$PORT_HOPPING_TARGET" >/dev/null 2>&1
    else
      unset PORT_HOPPING_START PORT_HOPPING_END PORT_HOPPING_RANGE
      PORT_HOPPING_TARGET="$_HOP_TARGET"
      # 只有在未做任何修改时才提示
      if [ -z "$_NEW_HOP_START" ] && [ -z "$_OLD_HOP_START" ]; then
        info "
 $(text 103)
"
        return
      fi
    fi
    FIREWALL_SILENT=1 sync_firewall_rules >/dev/null 2>&1 || true
    export_list
    return
  elif [ "$KEY" = "xhttpsplit" ]; then
    local _NEW_SPLIT _DOWN_INPUT
    reading_yn "$(text 154)" '_NEW_SPLIT' "${ENABLE_XHTTP_SPLIT:-n}"
    if truthy "$_NEW_SPLIT"; then
      reading_text_default "$(text 155)" '_DOWN_INPUT' "${XHTTP_DOWNLOAD_SERVER:-$SERVER}"
      if ! parse_preferred_addr "$_DOWN_INPUT"; then
        warning "\n $(text 156) \n"
        parse_preferred_addr "$SERVER" || error " $(text 118) "
      fi
      ENABLE_XHTTP_SPLIT='y'
      XHTTP_DOWNLOAD_SERVER="$PREFERRED_ADDR"
      XHTTP_DOWNLOAD_PORT="$PREFERRED_PORT"
      if [ "${XHTTP_CDN_MODE:-packet-up}" = 'stream-one' ]; then
        warning "\n $(text 157) \n"
        XHTTP_CDN_MODE='stream-up'
        write_custom 'xhttpCdnMode' "$XHTTP_CDN_MODE"
      fi
      write_custom 'enableXhttpSplit' 'y'
      write_custom 'xhttpDownloadServer' "$XHTTP_DOWNLOAD_SERVER"
      write_custom 'xhttpDownloadPort' "$XHTTP_DOWNLOAD_PORT"
    else
      ENABLE_XHTTP_SPLIT='n'
      XHTTP_DOWNLOAD_SERVER=''
      XHTTP_DOWNLOAD_PORT=''
      write_custom 'enableXhttpSplit' 'n'
      write_custom 'xhttpDownloadServer' ''
      write_custom 'xhttpDownloadPort' ''
    fi
    export_list
    return
  elif [ "$KEY" = "realitydomain" ]; then
    local NEW_VAL
    reading " $(text 126) " NEW_VAL
    NEW_VAL="${NEW_VAL//[[:space:]]/}"
    if [ -n "$NEW_VAL" ]; then
      validate_reality_addr "$NEW_VAL" || error " $(text 127) "
      write_custom 'realityDomain' "$NEW_VAL"
      REALITY_DOMAIN="$NEW_VAL"
    else
      write_custom 'realityDomain' '__REALITY_DOMAIN_UNSET__'
      REALITY_DOMAIN=''
    fi
    export_list
    return
  fi

  hint ""
  if [ "$KEY" = "cdn" ]; then
    local CUSTOM_CDN NEW_PORT NEW_DISPLAY
    for _c in "${!CDN_DOMAIN[@]}"; do
      hint " $((_c+1)). ${CDN_DOMAIN[_c]} "
    done
    reading "
 $(text 72) " CUSTOM_CDN
    [ -z "$CUSTOM_CDN" ] && info " $(text 103) " && return
    case "$CUSTOM_CDN" in
      [1-9]|[1-9][0-9] )
        [ "$CUSTOM_CDN" -le "${#CDN_DOMAIN[@]}" ] && NEW_VAL="${CDN_DOMAIN[$((CUSTOM_CDN-1))]}" || NEW_VAL="${CDN_DOMAIN[0]}"
        NEW_PORT=443
        NEW_DISPLAY="$NEW_VAL"
        ;;
      * )
        parse_preferred_addr "$CUSTOM_CDN" || error " $(text 118) "
        NEW_VAL="$PREFERRED_ADDR"
        NEW_PORT="$PREFERRED_PORT"
        NEW_DISPLAY="$PREFERRED_DISPLAY"
        ;;
    esac
  else
    reading " $(text 60) " NEW_VAL
    [ -z "$NEW_VAL" ] && info " $(text 103) " && return
  fi

  if [ "$KEY" = "uuid" ]; then
    [[ ! "${NEW_VAL,,}" =~ ^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ ]] && error " $(text 3) "
  elif [ "$KEY" = "sni" ]; then
    ssl_certificate "$NEW_VAL"
  elif [ "$KEY" = "serverip" ]; then
    [[ ! "$NEW_VAL" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && [[ ! "$NEW_VAL" =~ ^[0-9a-fA-F:]+$ ]] && error " $(text 112) "
  elif [ "$KEY" = "realitydomain" ]; then
    validate_reality_addr "$NEW_VAL" || error " $(text 127) "
  fi

  # 按字段定点更新，不再全目录暴力 sed 替换
  local _IB="$WORK_DIR/inbound.json"
  local _IB_TMP="$TEMP_DIR/inbound_tmp.json"
  case "$KEY" in
    cdn)
      write_custom 'cdn' "${NEW_VAL}"
      write_custom 'cdnPort' "${NEW_PORT:-443}"
      SERVER_PORT="${NEW_PORT:-443}"
      SERVER_DISPLAY="${NEW_DISPLAY:-$NEW_VAL}"
      export_list
      return
      ;;
    serverip)
      write_custom 'serverIp' "${NEW_VAL}"
      ;;
    name)
      # 更新 inbound.json 所有 inbound 的 tag（"OLD_NAME proto" → "NEW_NAME proto"）
      if [ -s "$_IB" ] && [ -x "$WORK_DIR/jq" ]; then
        grep -v '^//' "$_IB" \
          | $WORK_DIR/jq --arg old "$OLD" --arg new "$NEW_VAL" \
              '(.inbounds[].tag) |= if startswith($old + " ") then ($new + " " + (ltrimstr($old + " "))) else . end' \
          > "$_IB_TMP" && mv "$_IB_TMP" "$_IB"
      fi
      ;;
    uuid)
      # 精确更新 inbound.json 中各协议的认证字段
      if [ -s "$_IB" ] && [ -x "$WORK_DIR/jq" ]; then
        grep -v '^//' "$_IB" \
          | $WORK_DIR/jq --arg old "$OLD" --arg new "$NEW_VAL" \
              '(.inbounds[].settings.clients[]? | (.id, .password, .auth) | select(. == $old)) = $new' \
          > "$_IB_TMP" && mv "$_IB_TMP" "$_IB"
      fi
      # UUID 用于 nginx.conf 的 location 路径，需重新生成 nginx.conf
      UUID="$NEW_VAL"
      json_nginx
      local _NGINX_PID
      _NGINX_PID=$(ps -eo pid,args | awk -v d="$WORK_DIR" '$0~(d"/nginx.conf"){print $1;exit}')
      if [ -n "$_NGINX_PID" ]; then
        nginx -c "$WORK_DIR/nginx.conf" -s reload >/dev/null 2>&1 || true
      fi
      ;;
    sni)
      # TLS_SERVER 存储在 inbound.json，精确更新所有 serverNames/serverName 字段
      if [ -s "$_IB" ] && [ -x "$WORK_DIR/jq" ]; then
        grep -v '^//' "$_IB" \
          | $WORK_DIR/jq --arg old "$OLD" --arg new "$NEW_VAL" \
              'walk(if type == "object" then
                (if has("serverNames") then .serverNames |= map(if . == $old then $new else . end) else . end) |
                (if has("serverName")  then .serverName  |= if . == $old then $new else . end else . end)
              else . end)' \
          > "$_IB_TMP" && mv "$_IB_TMP" "$_IB"
      fi
      ;;
  esac

  cmd_systemctl restart xray
  sleep 2
  cmd_systemctl status xray &>/dev/null && \
    info "\n Xray $(text 28) $(text 37) \n" || \
    warning "\n Xray $(text 27) $(text 38) \n"

  FIREWALL_SILENT=1 sync_firewall_rules >/dev/null 2>&1 || true
  export_list
}

# 卸载 ArgoX
uninstall() {
  if [ -d $WORK_DIR ]; then
    cmd_systemctl disable argo >/dev/null 2>&1
    cmd_systemctl disable xray >/dev/null 2>&1
    purge_managed_firewall_rules >/dev/null 2>&1 || true
    local _NGINX_MASTER
    _NGINX_MASTER=$(ps -eo pid,args | awk '/nginx: master process.*\/etc\/argox\/nginx.conf/{print $1;exit}')
    if [ -n "$_NGINX_MASTER" ]; then
      kill -QUIT "$_NGINX_MASTER" 2>/dev/null
      sleep 1
      kill -9 "$_NGINX_MASTER" 2>/dev/null || true
    fi
    reading "\n $(text 65) " REMOVE_NGINX
    [ "${REMOVE_NGINX,,}" = 'y' ] && ${PACKAGE_UNINSTALL[int]} nginx >/dev/null 2>&1
    [ "$SYSTEM" = 'Alpine' ] && rm -rf $WORK_DIR $TEMP_DIR /etc/init.d/{xray,argo} /usr/bin/argox || rm -rf $WORK_DIR $TEMP_DIR /etc/systemd/system/{xray,argo}.service /usr/bin/argox
    info "\n $(text 16) \n"
  else
    error "\n $(text 15) \n"
  fi
}

# Argo 与 Xray 的最新版本
version() {
  local ONLINE=$(wget -qO- "${GH_PROXY}https://api.github.com/repos/cloudflare/cloudflared/releases/latest" | grep "tag_name" | cut -d \" -f4)
  [ -z "$ONLINE" ] && error " $(text 74) "
  local LOCAL=$($WORK_DIR/cloudflared -v | awk '{for (i=0; i<NF; i++) if ($i=="version") {print $(i+1)}}')
  local APP=ARGO && info "\n $(text 43) "
  [[ -n "$ONLINE" && "$ONLINE" != "$LOCAL" ]] && reading "\n $(text 9) " UPDATE[0] || info " $(text 44) "

  ONLINE=$(wget -qO- "${GH_PROXY}https://api.github.com/repos/XTLS/Xray-core/releases/latest" | grep "tag_name" | sed "s@.*\"v\(.*\)\",@\1@g")
  [ -z "$ONLINE" ] && error " $(text 74) "
  LOCAL=$($WORK_DIR/xray version | awk '{for (i=0; i<NF; i++) if ($i=="Xray") {print $(i+1)}}')
  local APP=Xray && info "\n $(text 43) "
  [[ -n "$ONLINE" && "$ONLINE" != "$LOCAL" ]] && reading "\n $(text 9) " UPDATE[1] || info " $(text 44) "

  [[ "${UPDATE[*],,}" =~ y ]] && check_system_info
  if [ "${UPDATE[0],,}" = 'y' ]; then
    wget -O $TEMP_DIR/cloudflared ${GH_PROXY}https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$ARGO_ARCH
    if [ -s $TEMP_DIR/cloudflared ]; then
      cmd_systemctl disable argo
      chmod +x $TEMP_DIR/cloudflared && mv $TEMP_DIR/cloudflared $WORK_DIR/cloudflared
      cmd_systemctl enable argo
      cmd_systemctl status argo &>/dev/null && info " Argo $(text 28) $(text 37)" || error " Argo $(text 28) $(text 38) "
    else
      local APP=ARGO && error "\n $(text 48) "
    fi
  fi
  if [ "${UPDATE[1],,}" = 'y' ]; then
    wget -O $TEMP_DIR/Xray-linux-$XRAY_ARCH.zip ${GH_PROXY}https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-$XRAY_ARCH.zip
    if [ -s $TEMP_DIR/Xray-linux-$XRAY_ARCH.zip ]; then
      cmd_systemctl disable xray
      unzip -qo $TEMP_DIR/Xray-linux-$XRAY_ARCH.zip xray *.dat -d $WORK_DIR; rm -f $TEMP_DIR/Xray*.zip
      cmd_systemctl enable xray
      cmd_systemctl status xray &>/dev/null && info " Xray $(text 28) $(text 37)" || error " Xray $(text 28) $(text 38) "
    else
      local APP=Xray && error "\n $(text 48) "
    fi
  fi
}

# 判断当前 Argo-X 的运行状态，并对应的给菜单和动作赋值
menu_setting() {
  local PS_LIST=$(ps -eo pid,args | grep -E "$WORK_DIR.*([x]ray|[c]loudflared|[n]ginx)" | sed 's/^[ ]\+//g')
  if [[ "${STATUS[*]}" =~ $(text 27)|$(text 28) ]]; then
    if [ -s $WORK_DIR/cloudflared ]; then
      ARGO_VERSION=$($WORK_DIR/cloudflared -v | awk '{print $3}' | sed "s@^@Version: &@g")
      local ARGO_PID=$(awk '/cloudflared/{print $1}' <<< "$PS_LIST")
      local REALTIME_METRICS_PORT=$(ss -nltp | awk -v pid=${ARGO_PID} '$0 ~ "pid="pid"," {split($4, a, ":"); print a[length(a)]}')
      ss -nltp | grep -q "cloudflared.*pid=${ARGO_PID}," && ARGO_CHECKHEALTH="$(text 46): $(wget -qO- http://localhost:${REALTIME_METRICS_PORT}/healthcheck | sed "s/OK/$(text 37)/")"
    fi
    [ -s $WORK_DIR/xray ] && XRAY_VERSION=$($WORK_DIR/xray version | awk 'NR==1 {print $2}' | sed "s@^@Version: &@g")
    [ "$IS_NGINX" = 'is_nginx' ] && NGINX_VERSION=$(nginx -v 2>&1 | sed "s#.*/##; s/ (.*)//" | sed "s@^@Version: &@g")

    OPTION[1]="1 .  $(text 29)"
    if [ "${STATUS[0]}" = "$(text 28)" ]; then
      local ARGO_PID=$(pgrep -f "$WORK_DIR/cloudflared")
      [ -n "$ARGO_PID" ] && ARGO_MEMORY="$(text 52): $(awk '/VmRSS/{printf "%.1f", $2/1024}' /proc/${ARGO_PID%% *}/status 2>/dev/null) MB"
      OPTION[2]="2 .  $(text 27) Argo (argox -a)"
    else
      OPTION[2]="2 .  $(text 28) Argo (argox -a)"
    fi
    if [ "$IS_NGINX" = 'is_nginx' ]; then
      local NGINX_PID=$(pgrep -f "nginx: master process")
      [ -n "$NGINX_PID" ] && NGINX_MEMORY="$(text 52): $(awk '/VmRSS/{printf "%.1f", $2/1024}' /proc/${NGINX_PID%% *}/status 2>/dev/null) MB"
    fi
    if [ "${STATUS[1]}" = "$(text 28)" ]; then
      local XRAY_PID=$(pgrep -f "$WORK_DIR/xray")
      [ -n "$XRAY_PID" ] && XRAY_MEMORY="$(text 52): $(awk '/VmRSS/{printf "%.1f", $2/1024}' /proc/${XRAY_PID%% *}/status 2>/dev/null) MB"
      OPTION[3]="3 .  $(text 27) Xray (argox -x)"
    else
      OPTION[3]="3 .  $(text 28) Xray (argox -x)"
    fi
    OPTION[4]="4 .  $(text 30)"
    OPTION[5]="5 .  $(text 76)"
    OPTION[6]="6 .  $(text 95)"
    OPTION[7]="7 .  $(text 31)"
    OPTION[8]="8 .  $(text 32)"
    OPTION[9]="9 .  $(text 33)"
    OPTION[10]="10.  $(text 51)"
    OPTION[11]="11.  $(text 57)"

    ACTION[1]() { export_list; exit 0; }
    [[ ${STATUS[0]} = "$(text 28)" ]] &&
    ACTION[2]() {
      cmd_systemctl disable argo
      cmd_systemctl status argo &>/dev/null && error " Argo $(text 27) $(text 38) " || info "\n Argo $(text 27) $(text 37)"
    } ||
    ACTION[2]() {
      cmd_systemctl enable argo
      sleep 2
      cmd_systemctl status argo &>/dev/null && info "\n Argo $(text 28) $(text 37)" || error " Argo $(text 28) $(text 38) "
      grep -qs "^${DAEMON_RUN_PATTERN}.*--url" ${ARGO_DAEMON_FILE} && fetch_tunnel_domain quick && export_list
    }

    [[ ${STATUS[1]} = "$(text 28)" ]] &&
    ACTION[3]() {
      cmd_systemctl disable xray
      cmd_systemctl status xray &>/dev/null && error " Xray $(text 27) $(text 38) " || info "\n Xray $(text 27) $(text 37)"
    } ||
    ACTION[3]() {
      cmd_systemctl enable xray
      sleep 2
      cmd_systemctl status xray &>/dev/null && info "\n Xray $(text 28) $(text 37)" || error " Xray $(text 28) $(text 38) "
    }
    ACTION[4]() { change_argo; exit; }
    ACTION[5]() { change_config; exit; }
    ACTION[6]() { change_protocols; exit; }
    ACTION[7]() { version; exit; }
    ACTION[8]() { warning " Safe edition: remote third-party script execution is disabled."; exit; }
    ACTION[9]() { uninstall; exit; }
    ACTION[10]() { warning " Safe edition: remote third-party script execution is disabled."; exit; }
    ACTION[11]() { warning " Safe edition: remote third-party script execution is disabled."; exit; }

  else
    OPTION[1]="1.  $(text 77)"
    OPTION[2]="2.  $(text 34)"
    OPTION[3]="3.  $(text 133)"
    OPTION[4]="4.  $(text 32)"
    OPTION[5]="5.  $(text 51)"
    OPTION[6]="6.  $(text 57)"

    ACTION[1]() { NONINTERACTIVE_INSTALL='noninteractive_install'; fast_install_variables; install_argox; export_list; create_shortcut; exit;}
    ACTION[2]() { install_argox; export_list; create_shortcut; exit; }
    ACTION[3]() { guided_xhttp_install; exit; }
    ACTION[4]() { warning " Safe edition: remote third-party script execution is disabled."; exit; }
    ACTION[5]() { warning " Safe edition: remote third-party script execution is disabled."; exit; }
    ACTION[6]() { warning " Safe edition: remote third-party script execution is disabled."; exit; }
  fi

  [ "${#OPTION[@]}" -ge '10' ] && OPTION[0]="0 .  $(text 35)" || OPTION[0]="0.  $(text 35)"
  ACTION[0]() { exit; }
}

menu() {
  clear
  echo -e "======================================================================================================================\n"
  info " $(text 17): $VERSION\n $(text 18): $(text 1)\n $(text 19):\n\t $(text 20): $SYS\n\t $(text 21): $(uname -r)\n\t $(text 22): $ARGO_ARCH\n\t $(text 23): $VIRT "
  info "\t IPv4:  $WAN4 $COUNTRY4 $ASNORG4 "
  info "\t IPv6:  $WAN6 $COUNTRY6 $ASNORG6 "
  _sv() {
    local s="$1"
    if [ "$L" = 'C' ]; then
      [ "${#s}" -le 2 ] && printf '%s  ' "$s" || printf '%s' "$s"
    else
      printf '%-11s' "$s"
    fi
  }
  local _AV; printf -v _AV '%-26s' "$ARGO_VERSION"
  local _XV; printf -v _XV '%-26s' "$XRAY_VERSION"
  local _NV; printf -v _NV '%-26s' "$NGINX_VERSION"
  info "\t Argo:  $(_sv "${STATUS[0]}")  ${_AV}${ARGO_MEMORY}\t ${ARGO_CHECKHEALTH}\n\t Xray:  $(_sv "${STATUS[1]}")  ${_XV}${XRAY_MEMORY}"
  [ "$IS_NGINX" = 'is_nginx' ] && info "\t Nginx: $(_sv "${STATUS[2]}")  ${_NV}${NGINX_MEMORY}"
  echo -e "\n======================================================================================================================\n"
  for ((b=1;b<${#OPTION[*]};b++)); do hint " ${OPTION[b]} "; done
  hint " ${OPTION[0]} "
  reading "\n $(text 24) " CHOOSE

  if grep -qE "^[0-9]+$" <<< "$CHOOSE" && [ "$CHOOSE" -lt "${#OPTION[*]}" ]; then
    ACTION[$CHOOSE]
  else
    warning " $(text 36) [0-$((${#OPTION[*]}-1))] " && sleep 1 && menu
  fi
}

check_cdn
statistics_of_run-times update argox.sh 2>/dev/null

# 为了把 tag 后缀从 vless-xhttp 改为 xhttp-h1.1-cdn 做的处理，将于 2026年9月30日移除
if ls $WORK_DIR/inbound.json >/dev/null 2>&1 && grep -q 'vless-xhttp",' $WORK_DIR/inbound.json && [[ "$(date +%Y%m%d)" < "20260930" ]]; then
  sed -i "s/vless-xhttp\",$/${NODE_TAG[7]}\",/g" $WORK_DIR/inbound.json
  base64 -d $WORK_DIR/subscribe/base64 | sed "s/vless-xhttp$/${NODE_TAG[7]}/g" | base64 -w0 > $WORK_DIR/subscribe/base64
  sed -i "s/vless-xhttp\",/${NODE_TAG[7]}\",/g" $WORK_DIR/subscribe/proxies
  base64 -d $WORK_DIR/subscribe/shadowrocket | sed "s/vless-xhttp&obfsParam=/${NODE_TAG[7]}\&obfsParam=/g" | base64 -w0 > $WORK_DIR/subscribe/shadowrocket
fi

# 传参
[[ "${*,,}" =~ '-e'|'-k' ]] && L=E
[[ "${*,,}" =~ '-c'|'-b'|'-l' ]] && L=C

while getopts ":AaXxTtDdUuNnVvBbRrF:f:KkLlGg" OPTNAME; do
  case "${OPTNAME,,}" in
    a ) select_language; check_system_info; check_install
        [ "${STATUS[0]}" = "$(text 28)" ] && {
          cmd_systemctl disable argo
          cmd_systemctl status argo &>/dev/null && error " Argo $(text 27) $(text 38) " || info "\n Argo $(text 27) $(text 37)"
        } || {
          cmd_systemctl enable argo
          sleep 2
          if cmd_systemctl status argo &>/dev/null; then
            info "\n Argo $(text 28) $(text 37)"
            grep -qs "^${DAEMON_RUN_PATTERN}.*--url" ${ARGO_DAEMON_FILE} && fetch_tunnel_domain quick && export_list
          else
            error " Argo $(text 28) $(text 38) "
          fi
        }; exit 0 ;;

    x ) select_language; check_system_info; check_install
        [ "${STATUS[1]}" = "$(text 28)" ] && {
          cmd_systemctl disable xray
          cmd_systemctl status xray &>/dev/null && error " Xray $(text 27) $(text 38) " || info "\n Xray $(text 27) $(text 37)"
        } || {
          cmd_systemctl enable xray
          sleep 2
          cmd_systemctl status xray &>/dev/null && info "\n Xray $(text 28) $(text 37)" || error " Xray $(text 28) $(text 38) "
        }; exit 0 ;;
    t ) select_language; check_system_info; check_arch; change_argo; exit 0 ;;
    d ) select_language; check_system_info; change_config; exit 0 ;;
    r ) select_language; check_system_info; check_install; change_protocols; exit 0 ;;
    u ) select_language; check_system_info; uninstall; exit 0;;
    n ) select_language; check_system_info; export_list; exit 0 ;;
    v ) select_language; check_system_info; check_arch; version; exit 0;;
    b ) select_language; warning " Safe edition: remote third-party script execution is disabled."; exit ;;
    f ) NONINTERACTIVE_INSTALL='noninteractive_install'; VARIABLE_FILE=$OPTARG; . $VARIABLE_FILE ;;
    g ) GUIDED_XHTTP_INSTALL='guided_xhttp_install' ;;
    k|l ) NONINTERACTIVE_INSTALL='noninteractive_install'; fast_install_variables ;;
  esac
done

check_root
select_language
check_arch
check_system_info
check_dependencies
[ "$NONINTERACTIVE_INSTALL" != 'noninteractive_install' ] && check_system_ip
check_install
if [ "$GUIDED_XHTTP_INSTALL" = 'guided_xhttp_install' ]; then
  guided_xhttp_install
  exit
fi
menu_setting
[ "$NONINTERACTIVE_INSTALL" = 'noninteractive_install' ] && ACTION[2] || menu
