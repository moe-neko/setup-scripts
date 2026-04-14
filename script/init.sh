#!/bin/bash

# =================================================================
# 颜色与变量定义
# =================================================================
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

MARKER="$HOME/.initial_update_done"
ZSH_CUSTOM=${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}

# =================================================================
# 新增：提权命令处理（核心修改）
# =================================================================
if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
    echo -e "${GREEN}已检测到 sudo，将使用 sudo 执行需要权限的操作${NC}"
else
    SUDO=""
    echo -e "${YELLOW}未检测到 sudo，将以当前用户权限直接执行（推荐使用 root 用户运行）${NC}"
fi

# 检查权限：没有 sudo 时必须是 root 用户
if [ -z "$SUDO" ] && [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}错误: 当前既没有 sudo 权限，也没有以 root 用户运行脚本。${NC}"
    echo -e "${RED}请切换到 root 用户（su - 或直接用 root 登录）后重新运行。${NC}"
    exit 1
fi

# 统一的提权执行函数
run_as_root() {
    if [ -n "$SUDO" ]; then
        $SUDO "$@"
    else
        "$@"
    fi
}

# =================================================================
# 第一部分：非可选项 (仅在第一次运行时执行)
# =================================================================
if [ ! -f "$MARKER" ]; then
    echo -e "${BLUE}>>> 检测到首次运行，开始基础环境配置...${NC}"

    # 1. Update & Upgrade
    echo -e "${GREEN}[1/3] 正在更新系统软件包...${NC}"
    run_as_root apt update && run_as_root apt upgrade -y

    # 2. 安装基础依赖
    echo -e "${GREEN}[2/3] 安装基础工具集...${NC}"
    DEPENDS=(zsh unzip git command-not-found htop net-tools bind9-dnsutils neovim wget curl mtr tmux ufw)
    run_as_root apt install -y "${DEPENDS[@]}"

    # 3. 配置 Oh-My-Zsh (针对当前用户)
    echo -e "${GREEN}[3/3] 配置 Oh-My-Zsh 环境...${NC}"
    if [ ! -d "$HOME/.oh-my-zsh" ]; then
        sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
        # 只有在有 sudo 时才使用 sudo chsh（root 用户不需要 sudo）
        if [ -n "$SUDO" ]; then
            run_as_root chsh -s "$(which zsh)" "$USER"
        else
            chsh -s "$(which zsh)" "$USER" 2>/dev/null || true
        fi
    fi

    # 安装插件与主题
    [[ ! -d "$ZSH_CUSTOM/themes/powerlevel10k" ]] && git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$ZSH_CUSTOM/themes/powerlevel10k"
    [[ ! -d "$ZSH_CUSTOM/plugins/zsh-autosuggestions" ]] && git clone https://github.com/zsh-users/zsh-autosuggestions "$ZSH_CUSTOM/plugins/zsh-autosuggestions"
    [[ ! -d "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting" ]] && git clone https://github.com/zsh-users/zsh-syntax-highlighting.git "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting"

    # 修改 .zshrc 配置
    sed -i 's/ZSH_THEME="robbyrussell"/ZSH_THEME="simple"/' "$HOME/.zshrc"
    if ! grep -q "zsh-autosuggestions" "$HOME/.zshrc"; then
        sed -i 's/plugins=(git)/plugins=(git zsh-autosuggestions zsh-syntax-highlighting command-not-found)/' "$HOME/.zshrc"
    fi

    # 写入标记文件
    touch "$MARKER"
    echo -e "${BLUE}>>> 基础环境初始化完成！${NC}"
else
    echo -e "${YELLOW}>>> 基础环境已处于初始化状态，跳过安装步骤。${NC}"
fi

# =================================================================
# 4. SSH 安全配置 (系统级配置)
# =================================================================
echo -e "${GREEN}[4/6] SSH 安全增强配置...${NC}"
OVERWRITE_CONF="/etc/ssh/sshd_config.d/99-overwrite.conf"

# 准备临时文件
TEMP_SSH_CONF=$(mktemp)

# 公钥配置
read -p "是否上传 SSH 公钥？(y/n): " confirm_pubkey
if [[ $confirm_pubkey == [yY] ]]; then
    read -p "请输入你的公钥内容 (ssh-rsa ...): " pubkey_content
    mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
    echo "$pubkey_content" >> "$HOME/.ssh/authorized_keys"
    chmod 600 "$HOME/.ssh/authorized_keys"
    echo "PubkeyAuthentication yes" >> "$TEMP_SSH_CONF"
fi

# 端口配置
read -p "是否更改 SSH 端口？(默认不修改输入n, 否则输入端口号): " ssh_port
if [[ $ssh_port =~ ^[0-9]+$ ]]; then
    echo "Port $ssh_port" >> "$TEMP_SSH_CONF"
    run_as_root ufw allow "$ssh_port"/tcp
    echo -e "${YELLOW}已在 UFW 中放行端口 $ssh_port${NC}"
fi

# 禁用密码登录
read -p "是否禁止密码登录？(y/n): " disable_password
if [[ $disable_password == [yY] ]]; then
    echo "PasswordAuthentication no" >> "$TEMP_SSH_CONF"
fi

# 写入配置文件
if [ -s "$TEMP_SSH_CONF" ]; then
    run_as_root mkdir -p /etc/ssh/sshd_config.d/
    run_as_root cp "$TEMP_SSH_CONF" "$OVERWRITE_CONF"
    
    # 重启 SSH 服务 (兼容 Ubuntu 24.04 / Debian socket 模式)
    run_as_root systemctl daemon-reload
    if run_as_root systemctl is-active --quiet ssh.socket; then
        run_as_root systemctl restart ssh.socket
    else
        run_as_root systemctl restart ssh
    fi
    echo -e "${GREEN}SSH 配置已更新并重启${NC}"
fi
rm -f "$TEMP_SSH_CONF"

# =================================================================
# 5. 可选安装项菜单 (引导提权)
# =================================================================
echo -e "${GREEN}[5/6] 进入可选组件安装...${NC}"

install_caddy() {
    run_as_root apt install -y debian-keyring debian-archive-keyring apt-transport-https
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | run_as_root gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | run_as_root tee /etc/apt/sources.list.d/caddy-stable.list
    run_as_root apt update && run_as_root apt install caddy -y
    run_as_root ufw allow http && run_as_root ufw allow https
}

install_docker() {
    curl -fsSL https://get.docker.com -o get-docker.sh
    run_as_root sh get-docker.sh && rm get-docker.sh
}

install_easytier() {
    wget -O /tmp/easytier.sh "https://raw.githubusercontent.com/EasyTier/EasyTier/main/script/install.sh"
    run_as_root bash /tmp/easytier.sh install --no-gh-proxy
    run_as_root systemctl disable --now easytier@default
    echo -e "${YELLOW}EasyTier 已安装。请手动编辑 /opt/easytier/config/default.conf${NC}"
}

install_singbox() {
    run_as_root mkdir -p /etc/apt/keyrings
    curl -fsSL https://sing-box.app/gpg.key | run_as_root gpg --dearmor -o /etc/apt/keyrings/sagernet.gpg
    echo "deb [signed-by=/etc/apt/keyrings/sagernet.gpg] https://deb.sagernet.org/ * main" | run_as_root tee /etc/apt/sources.list.d/sagernet.list
    run_as_root apt update && run_as_root apt install sing-box -y
}

install_log_maintenance() {
    echo -e "${GREEN}配置日志限制与自动清理...${NC}"
    
    # 1. 配置 journald 限制
    JOURNAL_CONF="/etc/systemd/journald.conf.d/99-custom.conf"
    run_as_root mkdir -p /etc/systemd/journald.conf.d/

    run_as_root tee "$JOURNAL_CONF" > /dev/null <<EOF
[Journal]
SystemMaxUse=100M
SystemKeepFree=200M
SystemMaxFileSize=20M
RuntimeMaxUse=50M
EOF

    echo -e "${GREEN}journald 限制已写入 ${JOURNAL_CONF}${NC}"

    # 重启 journald
    run_as_root systemctl restart systemd-journald

    # 2. 创建清理脚本
    CLEAN_SCRIPT="/usr/local/bin/system-cleanup.sh"
    run_as_root tee "$CLEAN_SCRIPT" > /dev/null <<'EOF'
#!/bin/bash

# apt 缓存清理
apt-get clean

# journal 清空（彻底）
journalctl --rotate
journalctl --vacuum-time=1s

EOF

    run_as_root chmod +x "$CLEAN_SCRIPT"

    # 3. 创建 systemd service
    SERVICE_FILE="/etc/systemd/system/system-cleanup.service"
    run_as_root tee "$SERVICE_FILE" > /dev/null <<EOF
[Unit]
Description=Monthly System Cleanup

[Service]
Type=oneshot
ExecStart=$CLEAN_SCRIPT
EOF

    # 4. 创建 systemd timer（每月执行）
    TIMER_FILE="/etc/systemd/system/system-cleanup.timer"
    run_as_root tee "$TIMER_FILE" > /dev/null <<EOF
[Unit]
Description=Run system cleanup monthly

[Timer]
OnCalendar=monthly
Persistent=true

[Install]
WantedBy=timers.target
EOF

    # 启用 timer
    run_as_root systemctl daemon-reexec
    run_as_root systemctl daemon-reload
    run_as_root systemctl enable --now system-cleanup.timer

    echo -e "${GREEN}日志限制 + 自动清理已启用（每月执行）${NC}"
}

while true; do
    echo -e "${BLUE}请选择安装组件 (输入数字，q 退出):${NC}"
    echo "1) Caddy (自动 UFW)"
    echo "2) Docker"
    echo "3) EasyTier"
    echo "4) sing-box"
    echo "5) s-ui (脚本可能接管终端)"
    echo "6) 3x-ui (脚本可能接管终端)"
    echo "7) 安装hysteria2"
    echo "8) 日志限制 + 自动清理（适合小内存VPS）"
    echo "q) 退出"
    read -p "选择: " opt
    case $opt in
        1) install_caddy ;;
        2) install_docker ;;
        3) install_easytier ;;
        4) install_singbox ;;
        5) bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh) ;;
        6) bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) ;;
        7) bash <(curl -fsSL https://get.hy2.sh/) ;;
        8) install_log_maintenance ;;
        q) break ;;
        *) echo "无效选项" ;;
    esac
done

# =================================================================
# 6. 收尾
# =================================================================
echo -e "${GREEN}[6/6] 环境配置完成！${NC}"
echo -e "${YELLOW}请重新连接 SSH 或执行 'zsh' 进入新环境。${NC}"