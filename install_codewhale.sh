#!/bin/bash
# ════════════════════════════════════════════════════════════
#  🐋  CodeWhale 一键安装脚本 (菜单版 · 断点续装 · 国内镜像)
#
#  ⚡ 一行安装:
#    bash <(curl -s https://raw.githubusercontent.com/<你的用户名>/<仓库名>/main/install_codewhale.sh)
#
#  首次运行自动: 装依赖 → 下 Ubuntu 容器 → 装 Rust → 编译 CodeWhale → 开机菜单
#  ⚠ 首次编译 ~20 分钟，全程约 3-4GB 空间
# ════════════════════════════════════════════════════════════
#  v2.9  2026-05-31  新增: 自动 rustup update + 编译失败自动清缓存重试 + TUI 依赖补全
#  v2.8  2026-05-31  重构: git clone + --locked 编译 (根治依赖冲突)
#  v2.7  2026-05-30  新增: 编译日志保存 + 失败时暂停等回车
#  v2.6  2026-05-30  修复: cargo 编译错误信息不再被过滤
#  v2.5  2026-05-30  修复: cargo config 覆盖写入防 TOML 损坏
#  v2.4  2026-05-30  新增: libdbus-1-dev 编译依赖
#  v2.3  2026-05-30  新增: coreutils 引导修复 (basename 等缺失命令)
#  v2.2  2026-05-30  修复: proot 硬链接→符号链接 自动修复
#  v2.1  2026-05-30  新增: gzip 下载校验 + 错误诊断收集
#  v2.0  2026-05-30  初始: 8 步安装 + 4 镜像源
# ════════════════════════════════════════════════════════════
set +e  # 菜单模式，不自动退出

# ─── 颜色 ───
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'
C='\033[0;36m'; P='\033[0;35m'; B='\033[1m'; N='\033[0m'

# ─── 路径 ───
STATEDIR="$HOME/.codewhale_install"
TH="/data/data/com.termux/files/home"
PREFIX="/data/data/com.termux/files/usr"

mkdir -p "$STATEDIR"

# ─── 工具函数 ───
log()  { echo -e "  ${G}[✓]${N} $*"; }
warn() { echo -e "  ${Y}[!]${N} $*"; }
err()  { echo -e "  ${R}[✗]${N} $*"; }
info() { echo -e "  ${C}[→]${N} $*"; }
step_header() { echo -e "\n${B}${C}── $*${N}"; }

is_done()   { [ -f "$STATEDIR/$1" ]; }
is_failed() { [ -f "$STATEDIR/${1}_failed" ]; }
mark_done() { rm -f "$STATEDIR/${1}_failed"; touch "$STATEDIR/$1"; }
mark_fail() { rm -f "$STATEDIR/$1"; touch "$STATEDIR/${1}_failed"; }
mark_clear() { rm -f "$STATEDIR/$1" "$STATEDIR/${1}_failed"; }

# 读取镜像选择
get_mirror() { cat "$STATEDIR/mirror" 2>/dev/null || echo "official"; }

# ─── 错误诊断收集 ───
collect_diag() {
    local tag="$1"
    local diagfile="$STATEDIR/diag_${tag}.log"
    {
        echo "======== $(date) ========"
        echo "--- 磁盘空间 ---"
        df -h "$STATEDIR" 2>/dev/null
        df -h "$PREFIX" 2>/dev/null
        echo "--- 下载文件 ---"
        ls -lh "$STATEDIR/ubuntu-base.tar.gz" 2>/dev/null
        echo "--- 文件类型 ---"
        file "$STATEDIR/ubuntu-base.tar.gz" 2>/dev/null || echo "(file 命令不可用)"
        echo "--- gzip 测试 ---"
        gzip -t "$STATEDIR/ubuntu-base.tar.gz" 2>&1
        echo "exit=$?"
        echo "--- tar 版本 ---"
        tar --version 2>&1 | head -1
        echo "--- gunzip 测试 ---"
        gunzip --version 2>&1 | head -1
        echo "--- 目标目录 ---"
        local cdir="$PREFIX/var/lib/proot-distro/containers/ubuntu"
        local rdir="$cdir/rootfs"
        ls -ld "$cdir" 2>/dev/null || echo "容器目录不存在"
        ls -ld "$rdir" 2>/dev/null || echo "rootfs 目录不存在"
        echo "--- rootfs 内容 (如果存在) ---"
        ls -la "$rdir" 2>/dev/null | head -15 || echo "无内容"
        echo "--- 解压测试 (试解压首个文件) ---"
        gunzip -c "$STATEDIR/ubuntu-base.tar.gz" 2>&1 | tar -tv 2>&1 | head -20
        echo "exit=${PIPESTATUS[0]}/${PIPESTATUS[1]}"
        echo "--- 进程列表 ---"
        ps aux 2>/dev/null | head -10 || ps | head -10
        echo "======== END ========"
    } > "$diagfile" 2>/dev/null

    echo ''
    echo -e "  ${Y}╔══════════════════════════════════════════╗${N}"
    echo -e "  ${Y}║  错误诊断已保存                          ║${N}"
    echo -e "  ${Y}║  ${diagfile}${N}"
    echo -e "  ${Y}╚══════════════════════════════════════════╝${N}"
    echo ''
    echo -e "  ${C}请执行: cat ${diagfile}${N}"
    echo -e "  ${C}将输出截图发给开发者排查${N}"
    echo ''
}

# 检查必备命令
check_cmd() {
    command -v "$1" >/dev/null 2>&1 && return 0
    warn "缺少命令: $1，尝试安装..."
    pkg install "$1" -y -qq 2>/dev/null && return 0
    return 1
}

# ─── 修复 proot 环境下 tar 硬链接失败 ───
# proot 的 ptrace 翻译不支持 link() 系统调用，导致 tar 无法创建硬链接
# 本函数解析 tar stderr 中的 "Cannot hard link" 错误，用符号链接代替
fix_hardlinks() {
    local errfile="$1"
    local rootfs="$2"
    local fixed=0
    local skipped=0

    [ ! -f "$errfile" ] && return 0

    while IFS= read -r line; do
        # 格式: tar: PATH1: Cannot hard link to 'PATH2': Permission denied
        local linkpath
        local target
        linkpath=$(echo "$line" | sed -n "s/^tar: \(.*\): Cannot hard link to '.*': Permission denied/\1/p")
        target=$(echo "$line" | sed -n "s/.*Cannot hard link to '\(.*\)': Permission denied/\1/p")

        [ -z "$linkpath" ] && continue
        [ -z "$target" ] && continue

        local linkfull="$rootfs/$linkpath"
        local targetfull="$rootfs/$target"

        # 目标文件必须存在
        if [ ! -f "$targetfull" ] && [ ! -d "$targetfull" ]; then
            skipped=$((skipped + 1))
            continue
        fi

        # 创建符号链接（用绝对路径，确保跨目录解析正确）
        if ln -sf "/$target" "$linkfull" 2>/dev/null; then
            fixed=$((fixed + 1))
        else
            # 符号链接失败，尝试直接复制
            if cp -a "$targetfull" "$linkfull" 2>/dev/null; then
                fixed=$((fixed + 1))
            else
                skipped=$((skipped + 1))
            fi
        fi
    done < "$errfile"

    log "硬链接修复: ${fixed} 个已转为符号链接, ${skipped} 个跳过"
}

# ─── 步骤定义 ───
STEPS=(
    "step_01:Termux 包 + proot-distro"
    "step_02:安装 Ubuntu 容器"
    "step_03:Ubuntu 编译依赖"
    "step_04:安装 Rust"
    "step_05:编译 codewhale-cli"
    "step_06:编译 codewhale-tui"
    "step_07:Ubuntu 配置"
    "step_08:Termux 启动菜单"
)

# ─── 状态图标 ───
step_icon() {
    if is_done "$1"; then
        echo -e "${G}[✓]${N}"
    elif is_failed "$1"; then
        echo -e "${R}[✗]${N}"
    else
        echo -e "${Y}[·]${N}"
    fi
}

# ─── Banner ───
show_banner() {
    clear
    echo -e "${C}"
    echo '   ▄████████  ▄██████▄  ████████▄ ████████▄'
    echo '  ███    ███ ███    ███ ███   ▀███ ███   ▀███'
    echo '  ███    █▀  ███    ███ ███    ███ ███    ███'
    echo '  ███        ███    ███ ███    ███ ███    ███'
    echo '  ███        ███    ███ ███    ███ ███    ███'
    echo '  ███    █▄  ███    ███ ███    ███ ███    ███'
    echo '  ███    ███ ███    ███ ███   ▄███ ███   ▄███'
    echo '   ████████▀  ▀██████▀  ████████▀  ████████▀'
    echo -e "${N}"
    echo -e "  ${B}🐋 CodeWhale 一键安装  ${C}v2.9${N}"
    echo -e "  DeepSeek AI 编程助手 · 手机原生"
    echo ''
}

# ─── 状态表 ───
show_status() {
    echo -e "${B}安装进度:${N}"
    local mirror=$(get_mirror)
    local mirror_name
    case "$mirror" in
        official) mirror_name="官方源 (rootfs→清华)" ;;
        tsinghua) mirror_name="清华 TUNA" ;;
        ustc)     mirror_name="中科大 USTC" ;;
        aliyun)   mirror_name="阿里云 (pkg→官方)" ;;
        huawei)   mirror_name="华为云 (pkg→清华)" ;;
        *)        mirror_name="$mirror" ;;
    esac
    echo -e "  镜像: ${C}${mirror_name}${N}"
    echo ''
    local all_done=true; local any_fail=false
    for s in "${STEPS[@]}"; do
        local sid="${s%%:*}"; local sname="${s#*:}"
        echo -e "  $(step_icon "$sid") $sname"
        if ! is_done "$sid"; then all_done=false; fi
        if is_failed "$sid"; then any_fail=true; fi
    done
    echo ''
    if $all_done; then
        echo -e "  ${G}━━ 全部安装完成！重启 Termux 即可使用 ━━${N}"
    elif $any_fail; then
        echo -e "  ${Y}有步骤失败，选择 [1] 重试或 [3] 单独重试${N}"
    fi
    echo ''
}

# ─── 环境检查 ───
check_env() {
    if [ ! -d /data/data/com.termux ]; then
        echo ''
        err "请在 Termux 中运行此脚本。"
        echo ''
        exit 1
    fi
}

# ─── API Key (有缓存则跳过) ───
ensure_api_key() {
    if [ -f "$STATEDIR/api_key" ]; then
        CW_API_KEY=$(cat "$STATEDIR/api_key" 2>/dev/null)
        log "API Key 已缓存: ${CW_API_KEY:0:10}..."
        return 0
    fi
    echo ''
    echo -e "${B}需要 DeepSeek API Key${N}"
    echo '  没有? → https://platform.deepseek.com/api_keys (注册即送额度)'
    echo ''
    echo -n '请输入 API Key (sk-...): '
    read -r CW_API_KEY < /dev/tty
    CW_API_KEY=$(echo "$CW_API_KEY" | xargs)
    if [ -z "$CW_API_KEY" ]; then
        err "API Key 不能为空。"
        echo ''
        return 1
    fi
    echo "$CW_API_KEY" > "$STATEDIR/api_key"
    log "API Key: ${CW_API_KEY:0:10}..."
    return 0
}

# ════════════════════════════════════════════════════════
#  镜像源配置
# ════════════════════════════════════════════════════════

# 各镜像的 URL (2026-05-30 实测)
# official: Ubuntu rootfs 不可达 → rootfs 走清华
# aliyun:   Termux 源 404 → pkg 走官方
# huawei:   Termux 源 HTML 重定向 → pkg 走清华
mirror_urls() {
    case "$1" in
        official)
            TERMUX_MIRROR="https://packages.termux.dev/apt/termux-main"
            UBUNTU_APT="http://ports.ubuntu.com/ubuntu-ports" ;;
        tsinghua)
            TERMUX_MIRROR="https://mirrors.tuna.tsinghua.edu.cn/termux/apt/termux-main"
            UBUNTU_APT="https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports" ;;
        ustc)
            TERMUX_MIRROR="https://mirrors.ustc.edu.cn/termux/apt/termux-main"
            UBUNTU_APT="https://mirrors.ustc.edu.cn/ubuntu-ports" ;;
        aliyun)
            TERMUX_MIRROR="https://packages.termux.dev/apt/termux-main"
            UBUNTU_APT="https://mirrors.aliyun.com/ubuntu-ports" ;;
        huawei)
            TERMUX_MIRROR="https://mirrors.tuna.tsinghua.edu.cn/termux/apt/termux-main"
            UBUNTU_APT="https://repo.huaweicloud.com/ubuntu-ports" ;;
    esac
}

apply_mirror_termux() {
    local m="$1"
    mirror_urls "$m"
    local sl="$PREFIX/etc/apt/sources.list"
    if [ -f "$sl" ]; then
        sed -i "s|https\?://[^/]*/termux[^ ]*|${TERMUX_MIRROR}|g" "$sl" 2>/dev/null
    fi
}

# Ubuntu rootfs 直链下载 (绕过 proot-distro 的 Docker Hub)
# 用镜像站的 ubuntu-base tar.gz
get_ubuntu_rootfs_url() {
    local mirror="$1"
    local version="${2:-26.04}"
    local arch="arm64"
    case "$mirror" in
        official|tsinghua)
            echo "https://mirrors.tuna.tsinghua.edu.cn/ubuntu-cdimage/ubuntu-base/releases/${version}/release/ubuntu-base-${version}-base-${arch}.tar.gz" ;;
        ustc)
            echo "https://mirrors.ustc.edu.cn/ubuntu-cdimage/ubuntu-base/releases/${version}/release/ubuntu-base-${version}-base-${arch}.tar.gz" ;;
        aliyun)
            echo "https://mirrors.aliyun.com/ubuntu-cdimage/ubuntu-base/releases/${version}/release/ubuntu-base-${version}-base-${arch}.tar.gz" ;;
        huawei)
            echo "https://repo.huaweicloud.com/ubuntu-cdimage/ubuntu-base/releases/${version}/release/ubuntu-base-${version}-base-${arch}.tar.gz" ;;
    esac
}

apply_mirror_ubuntu_apt() {
    local m="$1"
    mirror_urls "$m"
    proot-distro login ubuntu -- bash -c "
        sed -i 's|https\?://[^/]*/ubuntu-ports|${UBUNTU_APT}|g' /etc/apt/sources.list 2>/dev/null
        sed -i 's|https\?://[^/]*/ubuntu-ports|${UBUNTU_APT}|g' /etc/apt/sources.list.d/*.list 2>/dev/null
    " 2>/dev/null
}

set_mirror() {
    local m="$1"
    echo "$m" > "$STATEDIR/mirror"
    log "镜像源已设为: $m"

    step_header "应用镜像源..."
    apply_mirror_termux "$m"     && log "Termux pkg 源已切换"
    # Ubuntu rootfs 通过直链下载，无需修改 proot-distro 配置

    # Ubuntu apt 源 (如果已安装)
    if proot-distro list 2>/dev/null | grep -q ubuntu; then
        apply_mirror_ubuntu_apt "$m" && log "Ubuntu apt 源已切换"
    fi
}

# ─── 镜像源菜单 ───
mirror_menu() {
    clear
    echo -e "${B}选择镜像源${N}"
    echo -e "  ${Y}国内用户建议选清华或中科大，下载快很多${N}"
    echo ''
    local current=$(get_mirror)
    echo -e "  ${C}当前: ${current}${N}"
    echo ''
    echo '  [1] 官方源         (rootfs=清华)'
    echo '  [2] 清华 TUNA      ★ 推荐'
    echo '  [3] 中科大 USTC    ★ 推荐'
    echo '  [4] 阿里云         (pkg=官方)'
    echo '  [5] 华为云         (pkg=清华)'
    echo '  [b] 返回'
    echo ''
    echo -n '选择 [1-5/b]: '
    read -r c < /dev/tty
    case "$c" in
        1) set_mirror official ;;
        2) set_mirror tsinghua ;;
        3) set_mirror ustc ;;
        4) set_mirror aliyun ;;
        5) set_mirror huawei ;;
        *) return ;;
    esac
    echo ''
    echo -n '按回车继续...'; read -r _ < /dev/tty
}

# ════════════════════════════════════════════════════════
#  安装步骤
# ════════════════════════════════════════════════════════

# Ubuntu 内执行命令
ubuntu_exec() {
    proot-distro login ubuntu -- bash -c "$1" 2>&1
}

# ─── 步骤 1: Termux 包 ───
do_step_01() {
    is_done step_01 && { log "步骤 1 已完成，跳过"; return 0; }
    step_header "步骤 1/8: Termux 包 + proot-distro"
    mark_clear step_01

    local mirror=$(get_mirror)
    apply_mirror_termux "$mirror"

    info "更新包列表..."
    pkg update -y -qq || { err "pkg update 失败"; mark_fail step_01; return 1; }

    info "升级包..."
    pkg upgrade -y -qq || warn "pkg upgrade 部分失败 (非致命)"

    info "安装 proot-distro curl..."
    pkg install proot-distro curl -y -qq || { err "pkg install 失败"; mark_fail step_01; return 1; }

    mark_done step_01
    log "步骤 1 完成"
    return 0
}

# ─── 步骤 2: Ubuntu 容器 (直链下载，绕过 Docker Hub) ───
do_step_02() {
    is_done step_02 && { log "步骤 2 已完成，跳过"; return 0; }
    step_header "步骤 2/8: 安装 Ubuntu 容器"

    if proot-distro list 2>/dev/null | grep -q ubuntu; then
        log "Ubuntu 已安装"
        mark_done step_02
        local mirror=$(get_mirror)
        apply_mirror_ubuntu_apt "$mirror"
        return 0
    fi

    mark_clear step_02

    local mirror=$(get_mirror)
    local CONTAINER_DIR="$PREFIX/var/lib/proot-distro/containers/ubuntu"
    local ROOTFS_DIR="$CONTAINER_DIR/rootfs"

    # 尝试 26.04，失败则 24.04
    local rootfs_url
    local downloaded=false

    for ver in "26.04" "24.04"; do
        rootfs_url=$(get_ubuntu_rootfs_url "$mirror" "$ver")
        info "尝试下载 Ubuntu ${ver} rootfs (~35MB)..."
        info "URL: $rootfs_url"

        local retry=0
        while [ $retry -lt 3 ]; do
            curl -L --progress-bar -f -o "$STATEDIR/ubuntu-base.tar.gz" "$rootfs_url" || {
                warn "HTTP 下载失败"
                break
            }

            info "校验文件完整性..."
            if gzip -t "$STATEDIR/ubuntu-base.tar.gz" 2>/dev/null; then
                log "文件校验通过 (${ver})"
                downloaded=true
                break 2
            fi

            retry=$((retry + 1))
            warn "文件损坏 (网络不稳定), 重试 ${retry}/3..."
            rm -f "$STATEDIR/ubuntu-base.tar.gz"
        done
        warn "Ubuntu ${ver} 下载失败，尝试下一个版本..."
    done

    if ! $downloaded; then
        err "所有 Ubuntu 版本下载失败"
        warn "建议: 回到主菜单 → [2] 换镜像源 → 重试"
        mark_fail step_02
        return 1
    fi

    # 创建容器目录结构
    mkdir -p "$ROOTFS_DIR"

    # 确保必备命令可用
    check_cmd "gzip" || true

    local tar_errfile="$STATEDIR/tar_stderr.log"

    info "解压 rootfs..."
    # proot 的 ptrace 不支持 link() 系统调用，硬链接会报 Permission denied
    # 策略：先解压（允许硬链接报错），再自动修复缺失的硬链接为符号链接
    local unpack_ok=false

    gunzip -c "$STATEDIR/ubuntu-base.tar.gz" 2>/dev/null         | tar -x -C "$ROOTFS_DIR" 2>"$tar_errfile"
    local tar_rc=$?

    if [ $tar_rc -eq 0 ]; then
        unpack_ok=true
        log "解压成功（无错误）"
    elif grep -q "Cannot hard link" "$tar_errfile" 2>/dev/null; then
        # 硬链接失败 → 这是 proot 的已知限制，用符号链接修复
        warn "部分硬链接创建失败（proot 限制），自动修复中..."
        fix_hardlinks "$tar_errfile" "$ROOTFS_DIR"

        # 检查是否有其他致命错误
        local other_errs
        other_errs=$(grep -v "Cannot hard link\|Permission denied" "$tar_errfile" 2>/dev/null | grep -v "^$" | wc -l)
        if [ "$other_errs" -eq 0 ]; then
            unpack_ok=true
            log "解压成功（硬链接已转为符号链接）"
        else
            echo ''
            echo -e "  ${Y}其他解压警告:${N}"
            grep -v "Cannot hard link\|Permission denied" "$tar_errfile" 2>/dev/null | grep -v "^$" | tail -10
            echo ''
            unpack_ok=true
            log "解压成功（存在非致命警告）"
        fi
    fi

    if $unpack_ok; then
        rm -f "$tar_errfile"
    else
        echo ''
        echo -e "  ${R}━━━━━━━━━━ 解压错误详情 ━━━━━━━━━━${N}"
        grep -v "Cannot hard link\|Permission denied" "$tar_errfile" 2>/dev/null | tail -20
        echo -e "  ${R}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
        echo ''

        err "解压失败，正在收集诊断信息..."
        collect_diag "step02"

        rm -rf "$CONTAINER_DIR" 2>/dev/null
        rm -f "$STATEDIR/ubuntu-base.tar.gz"
        mark_fail step_02
        return 1
    fi

    # 基础配置
    info "配置 Ubuntu 基础环境..."

    # DNS
    echo "nameserver 119.29.29.29" > "$ROOTFS_DIR/etc/resolv.conf"
    echo "nameserver 223.5.5.5" >> "$ROOTFS_DIR/etc/resolv.conf"

    # 读取 codename
    local codename
    codename=$(grep VERSION_CODENAME "$ROOTFS_DIR/etc/os-release" 2>/dev/null | cut -d= -f2)
    [ -z "$codename" ] && codename="resolute"

    # apt 源
    local apt_mirror
    case "$mirror" in
        tsinghua) apt_mirror="https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports" ;;
        ustc)     apt_mirror="https://mirrors.ustc.edu.cn/ubuntu-ports" ;;
        aliyun)   apt_mirror="https://mirrors.aliyun.com/ubuntu-ports" ;;
        huawei)   apt_mirror="https://repo.huaweicloud.com/ubuntu-ports" ;;
        *)        apt_mirror="http://ports.ubuntu.com/ubuntu-ports" ;;
    esac

    cat > "$ROOTFS_DIR/etc/apt/sources.list" << APTEOF
deb ${apt_mirror} ${codename} main restricted universe multiverse
deb ${apt_mirror} ${codename}-updates main restricted universe multiverse
deb ${apt_mirror} ${codename}-security main restricted universe multiverse
APTEOF

    # hostname
    echo "localhost" > "$ROOTFS_DIR/etc/hostname"

    # 清理下载文件
    rm -f "$STATEDIR/ubuntu-base.tar.gz"

    log "Ubuntu ${codename} 部署完成 ($mirror 镜像)"
    mark_done step_02
    return 0
}

# ─── 步骤 3: 编译依赖 ───
do_step_03() {
    is_done step_03 && { log "步骤 3 已完成，跳过"; return 0; }
    step_header "步骤 3/8: Ubuntu 编译依赖"
    mark_clear step_03

    # 确保 apt 源正确
    local mirror=$(get_mirror)
    apply_mirror_ubuntu_apt "$mirror"

    # 引导修复: 手动解压 rootfs 跳过了 dpkg 配置阶段，标准路径 (如 /usr/bin/basename)
    # 可能缺失。Ubuntu 26.04 的 coreutils 是单二进制 /usr/bin/coreutils，
    # 所有子命令依赖硬链接→符号链接。先确保 base-files 等包的 preinst 脚本能运行。
    info "引导修复: 补全 coreutils 标准路径符号链接..."
    ubuntu_exec '
        CORE="/usr/bin/coreutils"
        if [ -x "$CORE" ]; then
            fixed=0
            for cmd in basename cat chgrp chmod chown cp cut date dd df dir echo                        env false head hostname id kill ln ls mkdir mknod mktemp                        mv nice nohup nproc pwd readlink rm rmdir sed sh sleep                        sort stat stty su sync tail tee test touch tr true tty                        uname uniq uptime wc whoami yes [ arch b2sum base32 base64                        chcon chroot cksum comm csplit dircolors dirname du expand                        expr factor fmt fold groups hashsum hostid install join link                        logname md5sum mkfifo nl numfmt od paste pathchk pinky pr                        printenv printf ptx realpath relpath runcon seq sha1sum                        sha224sum sha256sum sha384sum sha512sum shred shuf split                        stdbuf sum tac timeout truncate tsort unexpand unlink users                        vdir who; do
                if [ ! -e "/usr/bin/$cmd" ] && [ ! -e "/bin/$cmd" ]; then
                    ln -sf "$CORE" "/usr/bin/$cmd" 2>/dev/null && fixed=$((fixed + 1))
                fi
            done
            echo "coreutils 符号链接已补全: ${fixed} 个"
        else
            echo "警告: /usr/bin/coreutils 不存在，尝试安装 coreutils..."
            apt install -y coreutils 2>/dev/null || echo "跳过，继续..."
        fi

        # 确保 bash 可用 (某些包 preinst 依赖)
        [ ! -e /bin/bash ] && [ -x /usr/bin/bash ] && ln -sf /usr/bin/bash /bin/bash 2>/dev/null
        [ ! -e /bin/sh   ] && [ -x /usr/bin/dash ]  && ln -sf /usr/bin/dash  /bin/sh   2>/dev/null
        [ ! -e /bin/sh   ] && [ -x /bin/dash ]       && ln -sf dash             /bin/sh   2>/dev/null
        echo "基础 shell 符号链接已确认"
    ' || warn "引导修复部分失败 (继续尝试 apt)"

    info "apt update..."
    ubuntu_exec 'apt update -qq' || { err "apt update 失败"; mark_fail step_03; return 1; }

    info "apt upgrade..."
    ubuntu_exec 'apt upgrade -y -qq' || warn "apt upgrade 部分失败 (非致命)"

    info "安装 build-essential libssl-dev pkg-config curl libdbus-1-dev git libncurses-dev libpng-dev..."
    ubuntu_exec 'apt install -y -qq build-essential pkg-config libssl-dev curl libdbus-1-dev git libncurses-dev libpng-dev'
    local rc=$?

    if [ $rc -ne 0 ]; then
        err "apt install 失败"
        mark_fail step_03
        return 1
    fi

    mark_done step_03
    log "步骤 3 完成"
    return 0
}

# ─── 步骤 4: Rust ───
do_step_04() {
    is_done step_04 && { log "步骤 4 已完成，跳过"; return 0; }
    step_header "步骤 4/8: 安装 Rust"
    mark_clear step_04

    ubuntu_exec '
        if [ -f "$HOME/.cargo/env" ] && [ -x "$HOME/.cargo/bin/rustc" ]; then
            echo "Rust 已安装: $($HOME/.cargo/bin/rustc --version)"
            echo "更新 Rust 到最新稳定版..."
            . "$HOME/.cargo/env"
            rustup update stable 2>/dev/null || echo "更新跳过"
            rustc --version
            exit 0
        fi
        curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
        . "$HOME/.cargo/env"
        rustup update stable 2>/dev/null || echo "更新跳过"
        rustc --version
    '
    local rc=$?

    if [ $rc -ne 0 ]; then
        err "Rust 安装失败"
        mark_fail step_04
        return 1
    fi

    mark_done step_04
    log "步骤 4 完成"
    return 0
}

# ─── cargo 编译辅助 ───
setup_cargo_config() {
    ubuntu_exec '
        . "$HOME/.cargo/env"
        mkdir -p ~/.cargo
        # 每次重建 cargo config（避免追加模式导致 TOML 损坏）
        cat > ~/.cargo/config.toml << EOF
[build]
jobs = 2

[net]
retry = 3

[term]
progress.when = "auto"
progress.width = 80
EOF
        echo "cargo config OK"
    '
}

# ─── 确保 git 在 Ubuntu 容器中可用 ───
ensure_git() {
    local step="$1"
    info "检查 git..."
    ubuntu_exec '
        if command -v git >/dev/null 2>&1; then
            echo "git 已可用"
        else
            echo "安装 git..."
            apt update -qq 2>/dev/null
            apt install -y git ca-certificates unzip 2>&1 || {
                echo "git 安装失败！请回到菜单 [3] 重跑步骤 3 安装依赖。"
                exit 1
            }
        fi
        # 清除可能冲突的旧配置
        git config --global --unset http.sslBackend 2>/dev/null || true
        git config --global http.postBuffer 524288000 2>/dev/null || true
        git config --global http.lowSpeedLimit 0 2>/dev/null || true
        git config --global http.lowSpeedTime 999999 2>/dev/null || true
        echo "git 配置完成"
    ' 2>&1 || {
        err "git 未安装，无法克隆仓库。请先在菜单 [3] 中重跑步骤 3。"
        mark_fail "$step"
        return 1
    }
}

# ─── 步骤 5: codewhale-cli ───
do_step_05() {
    is_done step_05 && { log "步骤 5 已完成，跳过"; return 0; }
    step_header "步骤 5/8: 编译 codewhale-cli"
    mark_clear step_05

    setup_cargo_config

    echo -e "  ${Y}⏳ 此步骤 ~15 分钟，保持屏幕常亮${N}"
    echo ''

    local cargo_log="$STATEDIR/cargo_cli.log"
    local repo="$STATEDIR/CodeWhale"

    ensure_git step_05 || return 1

    # 克隆 / 更新仓库（使用 --locked 需要完整的 Cargo.lock）
    ubuntu_exec '
        REPO_URL="https://github.com/Hmbown/CodeWhale.git"
        if [ -d ~/CodeWhale/.git ] && [ -f ~/CodeWhale/crates/cli/Cargo.toml ]; then
            echo "仓库已存在，更新中..."
            cd ~/CodeWhale && git pull --ff-only 2>/dev/null && echo "已更新" || {
                echo "更新失败，重新克隆..."
                rm -rf ~/CodeWhale
            }
        else
            rm -rf ~/CodeWhale
        fi
        if [ -d ~/CodeWhale/.git ]; then
            echo "仓库可用"
            exit 0
        fi
        rm -rf ~/CodeWhale
        echo "克隆仓库..."
        if GIT_SSL_NO_VERIFY=1 git clone --depth 1 "$REPO_URL" ~/CodeWhale 2>&1; then
            echo "克隆成功"
            exit 0
        fi
        # git 失败 → 用 curl 直接下载 zip
        echo "git 克隆失败，改用 curl 下载..."
        rm -rf ~/CodeWhale
        curl -fsSL -o /tmp/codewhale-main.zip "https://github.com/Hmbown/CodeWhale/archive/refs/heads/main.zip" 2>&1 || {
            echo "curl 下载失败"
            exit 1
        }
        mkdir -p ~/CodeWhale
        unzip -qo /tmp/codewhale-main.zip -d /tmp/codewhale-tmp 2>&1 || {
            echo "解压失败"
            exit 1
        }
        mv /tmp/codewhale-tmp/CodeWhale-main/* ~/CodeWhale/ 2>/dev/null
        mv /tmp/codewhale-tmp/CodeWhale-main/.[!.]* ~/CodeWhale/ 2>/dev/null
        rm -rf /tmp/codewhale-tmp /tmp/codewhale-main.zip
        echo "curl 下载完成"
    ' || {
        err "仓库克隆失败，请检查网络连接。可尝试菜单 [2] 切换镜像源后重试。"
        mark_fail step_05
        return 1
    }

    ubuntu_exec '
        . "$HOME/.cargo/env"
        cd ~/CodeWhale
        cargo install --path crates/cli --locked 2>&1 | tee /tmp/cargo_build.log | while IFS= read -r line; do
            case "$line" in
                *Compiling*)
                    pkg=$(echo "$line" | grep -oP "Compiling \K\S+" || true)
                    [ -n "$pkg" ] && printf "  \r  [编译] %-45s" "$pkg"
                    ;;
                *error:*|*Error:*|*error[E*|*warning:*)
                    echo ""; echo "  $line"
                    ;;
                *Installed*|*Finished*|*Replacing*)
                    echo ""; echo "  ✓ $line"
                    ;;
            esac
        done
        ret=${PIPESTATUS[0]}
        [ $ret -ne 0 ] && exit $ret

        echo ""
        ~/.cargo/bin/codewhale --version
    '
    local rc=$?

    # 拉取构建日志
    proot-distro login ubuntu -- cat /tmp/cargo_build.log > "$cargo_log" 2>/dev/null

    if [ $rc -ne 0 ]; then
        warn "首次编译失败，清理 cargo 缓存后重试..."
        ubuntu_exec 'rm -rf ~/.cargo/registry/index ~/.cargo/registry/cache 2>/dev/null; echo "缓存已清理"'

        # 重试
        ubuntu_exec '
            . "$HOME/.cargo/env"
            cd ~/CodeWhale
            cargo install --path crates/cli --locked 2>&1 | tee /tmp/cargo_build.log | while IFS= read -r line; do
                case "$line" in
                    *Compiling*)
                        pkg=$(echo "$line" | grep -oP "Compiling \K\S+" || true)
                        [ -n "$pkg" ] && printf "  \r  [编译] %-45s" "$pkg"
                        ;;
                    *error:*|*Error:*|*error[E*|*warning:*)
                        echo ""; echo "  $line"
                        ;;
                    *Installed*|*Finished*|*Replacing*)
                        echo ""; echo "  ✓ $line"
                        ;;
                esac
            done
            ret=${PIPESTATUS[0]}
            [ $ret -ne 0 ] && exit $ret

            echo ""
            ~/.cargo/bin/codewhale --version
        '
        rc=$?
        proot-distro login ubuntu -- cat /tmp/cargo_build.log > "$cargo_log" 2>/dev/null
    fi

    if [ $rc -ne 0 ]; then
        echo ''
        echo -e "  ${R}━━━━━━━━━━ 错误摘要 (完整日志: ${cargo_log}) ━━━━━━━━━━${N}"
        grep -i "error" "$cargo_log" 2>/dev/null | tail -20
        echo -e "  ${R}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
        echo ''
        echo -n '按回车返回菜单...'; read -r _ < /dev/tty
        err "codewhale-cli 编译失败"
        mark_fail step_05
        return 1
    fi

    mark_done step_05
    log "步骤 5 完成"
    return 0
}

# ─── 步骤 6: codewhale-tui ───
do_step_06() {
    is_done step_06 && { log "步骤 6 已完成，跳过"; return 0; }
    step_header "步骤 6/8: 编译 codewhale-tui"
    mark_clear step_06

    echo -e "  ${Y}⏳ 此步骤 ~5 分钟${N}"
    echo ''

    local cargo_log="$STATEDIR/cargo_tui.log"

    ensure_git step_06 || return 1

    # 确保仓库存在（步骤 5 可能已跳过）
    ubuntu_exec '
        REPO_URL="https://github.com/Hmbown/CodeWhale.git"
        if [ -d ~/CodeWhale/.git ] && [ -f ~/CodeWhale/crates/tui/Cargo.toml ]; then
            echo "仓库已就绪"
            exit 0
        fi
        rm -rf ~/CodeWhale
        echo "克隆仓库..."
        if GIT_SSL_NO_VERIFY=1 git clone --depth 1 "$REPO_URL" ~/CodeWhale 2>&1; then
            echo "克隆成功"
        else
            echo "git 失败，curl 下载..."
            curl -fsSL -o /tmp/codewhale-main.zip "https://github.com/Hmbown/CodeWhale/archive/refs/heads/main.zip" && {
                mkdir -p ~/CodeWhale
                unzip -qo /tmp/codewhale-main.zip -d /tmp/codewhale-tmp
                mv /tmp/codewhale-tmp/CodeWhale-main/* ~/CodeWhale/ 2>/dev/null
                mv /tmp/codewhale-tmp/CodeWhale-main/.[!.]* ~/CodeWhale/ 2>/dev/null
                rm -rf /tmp/codewhale-tmp /tmp/codewhale-main.zip
                echo "curl 下载完成"
            } || { echo "下载失败"; exit 1; }
        fi
    ' || { err "仓库克隆失败"; mark_fail step_06; return 1; }

    ubuntu_exec '
        . "$HOME/.cargo/env"
        cd ~/CodeWhale
        # --locked: 锁定 Cargo.lock 避免依赖版本冲突（Ubuntu 容器无需 --no-default-features）
        cargo install --path crates/tui --locked 2>&1 | tee /tmp/cargo_build.log | while IFS= read -r line; do
            case "$line" in
                *Compiling*)
                    pkg=$(echo "$line" | grep -oP "Compiling \K\S+" || true)
                    [ -n "$pkg" ] && printf "  \r  [编译] %-45s" "$pkg"
                    ;;
                *error:*|*Error:*|*error[E*|*warning:*)
                    echo ""; echo "  $line"
                    ;;
                *Installed*|*Finished*|*Replacing*)
                    echo ""; echo "  ✓ $line"
                    ;;
            esac
        done
        ret=${PIPESTATUS[0]}
        [ $ret -ne 0 ] && exit $ret

        echo ""
        ~/.cargo/bin/codewhale-tui --version
    '
    local rc=$?

    # 拉取构建日志
    proot-distro login ubuntu -- cat /tmp/cargo_build.log > "$cargo_log" 2>/dev/null

    if [ $rc -ne 0 ]; then
        warn "首次编译失败，清理 cargo 缓存后重试..."
        ubuntu_exec 'rm -rf ~/.cargo/registry/index ~/.cargo/registry/cache 2>/dev/null; echo "缓存已清理"'

        # 重试
        ubuntu_exec '
            . "$HOME/.cargo/env"
            cd ~/CodeWhale
            cargo install --path crates/tui --locked 2>&1 | tee /tmp/cargo_build.log | while IFS= read -r line; do
                case "$line" in
                    *Compiling*)
                        pkg=$(echo "$line" | grep -oP "Compiling \K\S+" || true)
                        [ -n "$pkg" ] && printf "  \r  [编译] %-45s" "$pkg"
                        ;;
                    *error:*|*Error:*|*error[E*|*warning:*)
                        echo ""; echo "  $line"
                        ;;
                    *Installed*|*Finished*|*Replacing*)
                        echo ""; echo "  ✓ $line"
                        ;;
                esac
            done
            ret=${PIPESTATUS[0]}
            [ $ret -ne 0 ] && exit $ret

            echo ""
            ~/.cargo/bin/codewhale-tui --version
        '
        rc=$?
        proot-distro login ubuntu -- cat /tmp/cargo_build.log > "$cargo_log" 2>/dev/null
    fi

    if [ $rc -ne 0 ]; then
        echo ''
        echo -e "  ${R}━━━━━━━━━━ 错误摘要 (完整日志: ${cargo_log}) ━━━━━━━━━━${N}"
        grep -i "error" "$cargo_log" 2>/dev/null | tail -20
        echo -e "  ${R}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
        echo ''
        echo -n '按回车返回菜单...'; read -r _ < /dev/tty
        err "codewhale-tui 编译失败"
        mark_fail step_06
        return 1
    fi

    mark_done step_06
    log "步骤 6 完成"
    return 0
}

# ─── 步骤 7: Ubuntu 配置 ───
do_step_07() {
    is_done step_07 && { log "步骤 7 已完成，跳过"; return 0; }
    step_header "步骤 7/8: Ubuntu 配置"
    mark_clear step_07

    local AK=$(cat "$STATEDIR/api_key" 2>/dev/null)
    if [ -z "$AK" ]; then
        err "API Key 丢失，请重新输入"
        rm -f "$STATEDIR/api_key"
        ensure_api_key || { mark_fail step_07; return 1; }
        AK=$(cat "$STATEDIR/api_key" 2>/dev/null)
    fi

    ubuntu_exec "
        . \"\$HOME/.cargo/env\"

        # cargo env in bashrc
        if ! grep -q '.cargo/env' ~/.bashrc 2>/dev/null; then
            echo 'source \"\$HOME/.cargo/env\"' >> ~/.bashrc
        fi

        # API Key
        sed -i '/^export DEEPSEEK_API_KEY=/d' ~/.bashrc 2>/dev/null || true
        sed -i '/^export OPENAI_API_KEY=/d' ~/.bashrc 2>/dev/null || true
        sed -i '/^export OPENAI_BASE_URL=/d' ~/.bashrc 2>/dev/null || true
        cat >> ~/.bashrc << BRC
export DEEPSEEK_API_KEY=\"${AK}\"
export OPENAI_API_KEY=\"${AK}\"
export OPENAI_BASE_URL=\"https://api.deepseek.com/v1\"
BRC

        # codewhale config
        mkdir -p ~/.codewhale
        cat > ~/.codewhale/config.toml << CFG
api_key = \"${AK}\"
default_text_model = \"deepseek-v4-pro\"
provider = \"deepseek\"
auth_mode = \"api_key\"
reasoning_effort = \"auto\"

[providers.deepseek]
api_key = \"${AK}\"

[projects.\"/root\"]
trust_level = \"trusted\"
CFG

        echo '配置写入完成'
    "

    mark_done step_07
    log "步骤 7 完成"
    return 0
}

# ─── 步骤 8: Termux 启动器 ───
do_step_08() {
    is_done step_08 && { log "步骤 8 已完成，跳过"; return 0; }
    step_header "步骤 8/8: Termux 启动菜单"
    mark_clear step_08

    cat > "$TH/launcher.sh" << 'LAUNCHER'
#!/bin/bash
while true; do
    clear
    echo "===== Termux 启动菜单 ====="
    echo "[1] CodeWhale (AI 编程助手)"
    echo "[2] 进入 Ubuntu 终端"
    echo "[t] 退出到普通终端"
    echo "[q] 退出 Termux"
    echo "==========================="
    echo ""
    read -p "> " c
    case "$c" in
        1) echo "启动 CodeWhale..."; sleep 0.3
           proot-distro login ubuntu -- bash -ic '/root/.cargo/bin/codewhale' ;;
        2) echo "进入 Ubuntu..."; sleep 0.3
           proot-distro login ubuntu ;;
        t|T) echo "输入 bash launcher.sh 返回菜单"; exec bash ;;
        q|Q) echo "再见"; exit 0 ;;
        *) echo "无效"; sleep 0.5 ;;
    esac
done
LAUNCHER
    chmod +x "$TH/launcher.sh"

    cat > "$TH/.bashrc" << 'BASHRC'
if [ -z "$TMUX" ] && [ -z "$CW_GUARD" ]; then
    export CW_GUARD=1
    [ -f "$HOME/launcher.sh" ] && bash "$HOME/launcher.sh"
fi
BASHRC

    mkdir -p "$TH/.termux"
    cat > "$TH/.termux/termux.properties" << 'PROPS'
extra-keys = [['ESC','/','-','HOME','UP','END','PGUP'],['TAB','CTRL','ALT','LEFT','DOWN','RIGHT','ENTER']]
extra-keys-style = always
use-black-ui = true
terminal-cursor-style = bar
PROPS

    mark_done step_08
    log "步骤 8 完成"
    return 0
}

# ─── 运行所有未完成步骤 ───
run_all() {
    local mirror=$(get_mirror)
    if [ "$mirror" = "official" ]; then
        echo ''
        warn "当前使用官方源，国内可能很慢。"
        echo -n '建议先切换镜像源，是否继续? [Y/n]: '
        read -r c < /dev/tty
        if [ "$c" = "n" ] || [ "$c" = "N" ]; then
            return
        fi
    fi

    ensure_api_key || return

    do_step_01 || return
    do_step_02 || return
    do_step_03 || return
    do_step_04 || return
    do_step_05 || return
    do_step_06 || return
    do_step_07 || return
    do_step_08 || return

    echo ''
    echo -e "${G}${B}══════════════════════════════════════════${N}"
    echo -e "${G}${B}  全部安装完成！${N}"
    echo -e "${G}${B}══════════════════════════════════════════${N}"
    echo ''
    echo '  重启 Termux 或运行 termux-reload-settings'
    echo '  新会话自动进入启动菜单。'
    echo ''
    echo -n '按回车返回菜单...'; read -r _ < /dev/tty
}

# ─── 单独步骤菜单 ───
single_step_menu() {
    while true; do
        clear
        echo -e "${B}单独安装步骤${N}"
        echo ''
        local i=1
        for s in "${STEPS[@]}"; do
            local sid="${s%%:*}"; local sname="${s#*:}"
            echo -e "  [${i}] $(step_icon "$sid") $sname"
            i=$((i+1))
        done
        echo ''
        echo '  [a] 全部未完成步骤'
        echo '  [b] 返回主菜单'
        echo ''
        echo -n '选择: '
        read -r c < /dev/tty

        case "$c" in
            1) mark_clear step_01; do_step_01; echo -n '按回车继续...'; read -r _ < /dev/tty ;;
            2) mark_clear step_02; do_step_02; echo -n '按回车继续...'; read -r _ < /dev/tty ;;
            3) mark_clear step_03; do_step_03; echo -n '按回车继续...'; read -r _ < /dev/tty ;;
            4) mark_clear step_04; do_step_04; echo -n '按回车继续...'; read -r _ < /dev/tty ;;
            5) mark_clear step_05; do_step_05; echo -n '按回车继续...'; read -r _ < /dev/tty ;;
            6) mark_clear step_06; do_step_06; echo -n '按回车继续...'; read -r _ < /dev/tty ;;
            7) mark_clear step_07; do_step_07; echo -n '按回车继续...'; read -r _ < /dev/tty ;;
            8) mark_clear step_08; do_step_08; echo -n '按回车继续...'; read -r _ < /dev/tty ;;
            a|A) ensure_api_key && run_all_unattended; echo -n '按回车继续...'; read -r _ < /dev/tty ;;
            b|B) return ;;
            *) ;;
        esac
    done
}

# 自动跑全部（不检查镜像源）
run_all_unattended() {
    do_step_01 || return
    do_step_02 || return
    do_step_03 || return
    do_step_04 || return
    do_step_05 || return
    do_step_06 || return
    do_step_07 || return
    do_step_08 || return
}

# ─── 重置 ───
reset_all() {
    echo ''
    echo -n '确定要清除所有安装进度? [y/N]: '
    read -r c < /dev/tty
    if [ "$c" = "y" ] || [ "$c" = "Y" ]; then
        rm -rf "$STATEDIR"
        mkdir -p "$STATEDIR"
        log "进度已清除"
    fi
    echo -n '按回车继续...'; read -r _ < /dev/tty
}

# ════════════════════════════════════════════════════════
#  主菜单
# ════════════════════════════════════════════════════════
main_menu() {
    local first_run=true
    while true; do
        check_env

        if $first_run; then
            show_banner
            first_run=false
        else
            clear
            echo -e "${B}🐋 CodeWhale 安装管理  ${C}v2.9${N}"
            echo ''
        fi

        show_status

        echo '  [1] 全部安装 (自动从断点继续)'
        echo '  [2] 切换镜像源'
        echo '  [3] 单步安装 / 重试'
        echo '  [4] 重置安装进度'
        echo '  [q] 退出'
        echo ''

        # 检查是否全部完成
        local all_done=true
        for s in "${STEPS[@]}"; do
            is_done "${s%%:*}" || { all_done=false; break; }
        done
        if $all_done; then
            echo -e "  ${G}全部完成！运行 termux-reload-settings 后重启 Termux${N}"
            echo ''
        fi

        echo -n '选择 [1-4/q]: '
        read -r c < /dev/tty

        case "$c" in
            1) run_all ;;
            2) mirror_menu ;;
            3) single_step_menu ;;
            4) reset_all ;;
            q|Q) echo ''; echo '再见。'; exit 0 ;;
            *) ;;
        esac
    done
}

# ─── 入口 ───
main_menu
