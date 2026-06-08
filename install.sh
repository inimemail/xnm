#!/usr/bin/env bash
# Xboard-Node multi-instance manager.
# One machine can bind multiple Xboard node IDs through a single xboard-node service.

set -o pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

INSTALL_URL="https://raw.githubusercontent.com/cedar2025/xboard-node/dev/install.sh"
SERVICE_NAME="xboard-node"
CONFIG_FILE="/etc/xboard-node/config.yml"
NAMES_FILE="/etc/xboard-node/xb-node.names.tsv"

print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

pause() {
    echo ""
    read -r -p "按回车返回主菜单..." </dev/tty
}

require_tty() {
    if [ ! -t 0 ] && [ ! -c /dev/tty ]; then
        print_error "当前环境没有可交互的 TTY，无法显示菜单。"
        exit 1
    fi
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        print_error "请使用 root 或 sudo 运行此脚本。"
        exit 1
    fi
}

install_dependencies() {
    print_info "正在检查基础依赖..."

    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
            curl wget ca-certificates nano systemd
    elif command -v yum >/dev/null 2>&1; then
        yum install -y -q curl wget ca-certificates nano systemd
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y -q curl wget ca-certificates nano systemd
    else
        print_warn "未检测到 apt/yum/dnf，跳过自动安装依赖。"
    fi
}

xbctl_exists() {
    command -v xbctl >/dev/null 2>&1 || [ -x /usr/local/bin/xbctl ]
}

xbctl_cmd() {
    if command -v xbctl >/dev/null 2>&1; then
        command xbctl "$@"
    else
        /usr/local/bin/xbctl "$@"
    fi
}

service_exists() {
    systemctl list-unit-files 2>/dev/null | grep -q "^${SERVICE_NAME}\.service"
}

read_required() {
    local prompt="$1"
    local var_name="$2"
    local value=""

    while [ -z "$value" ]; do
        read -r -p "$prompt" value </dev/tty
        if [ -z "$value" ]; then
            print_warn "不能为空，请重新输入。"
        fi
    done

    printf -v "$var_name" '%s' "$value"
}

read_panel_token() {
    read_required "面板地址: " PANEL
    read_required "Token: " TOKEN

    if ! [[ "$PANEL" =~ ^https?:// ]]; then
        print_error "面板地址必须以 http:// 或 https:// 开头。"
        return 1
    fi
}

read_positive_int() {
    local prompt="$1"
    local var_name="$2"
    local value=""

    while true; do
        read_required "$prompt" value
        if [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -gt 0 ]; then
            printf -v "$var_name" '%s' "$value"
            return 0
        fi
        print_warn "请输入大于 0 的数字。"
    done
}

read_label() {
    local prompt="$1"
    local var_name="$2"
    local value=""

    while true; do
        read_required "$prompt" value
        if [[ "$value" == *$'\t'* || "$value" == *"#"* ]]; then
            print_warn "名称不能包含 Tab 或 #，请换一个。"
            value=""
            continue
        fi
        printf -v "$var_name" '%s' "$value"
        return 0
    done
}

read_optional() {
    local prompt="$1"
    local default_value="$2"
    local var_name="$3"
    local value=""

    read -r -p "$prompt [$default_value]: " value </dev/tty
    if [ -z "$value" ]; then
        value="$default_value"
    fi

    if [[ "$value" == *$'\t'* || "$value" == *"#"* ]]; then
        print_warn "不能包含 Tab 或 #。"
        return 1
    fi

    printf -v "$var_name" '%s' "$value"
}

read_optional_positive_int() {
    local prompt="$1"
    local default_value="$2"
    local var_name="$3"
    local value=""

    while true; do
        read -r -p "$prompt [$default_value]: " value </dev/tty
        if [ -z "$value" ]; then
            value="$default_value"
        fi
        if [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -gt 0 ]; then
            printf -v "$var_name" '%s' "$value"
            return 0
        fi
        print_warn "请输入大于 0 的数字。"
    done
}

read_optional_panel() {
    local default_value="$1"
    local var_name="$2"
    local value=""

    while true; do
        read_optional "面板地址" "$default_value" value || continue
        if [[ "$value" =~ ^https?:// ]]; then
            printf -v "$var_name" '%s' "$value"
            return 0
        fi
        print_warn "面板地址必须以 http:// 或 https:// 开头。"
    done
}

read_kernel() {
    local value=""
    read -r -p "内核 [singbox/xray，默认 singbox]: " value </dev/tty
    case "$value" in
        ""|singbox|SingBox|SINGBOX)
            KERNEL="singbox"
            ;;
        xray|Xray|XRAY)
            KERNEL="xray"
            ;;
        *)
            print_warn "未知内核，已使用默认 singbox。"
            KERNEL="singbox"
            ;;
    esac
}

read_optional_kernel() {
    local default_value="$1"
    local var_name="$2"
    local value=""

    read -r -p "内核 [$default_value]: " value </dev/tty
    if [ -z "$value" ]; then
        value="$default_value"
    fi

    case "$value" in
        singbox|SingBox|SINGBOX)
            printf -v "$var_name" '%s' "singbox"
            ;;
        xray|Xray|XRAY)
            printf -v "$var_name" '%s' "xray"
            ;;
        *)
            print_warn "未知内核，已保留 $default_value。"
            printf -v "$var_name" '%s' "$default_value"
            ;;
    esac
}

ensure_state_dir() {
    mkdir -p "$(dirname "$NAMES_FILE")"
    touch "$NAMES_FILE"
}

remember_binding() {
    local label="$1"
    local kind="$2"
    local panel="$3"
    local target_id="$4"
    local kernel="$5"
    local node_type="${6:-}"
    local created_at
    local tmp_file

    ensure_state_dir
    created_at="$(date '+%F %T' 2>/dev/null || date)"
    tmp_file="${NAMES_FILE}.tmp.$$"

    awk -F '\t' -v kind="$kind" -v panel="$panel" -v target_id="$target_id" \
        '!(($2 == kind) && ($3 == panel) && ($4 == target_id))' "$NAMES_FILE" > "$tmp_file" 2>/dev/null || true
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$label" "$kind" "$panel" "$target_id" "$kernel" "$node_type" "$created_at" >> "$tmp_file"
    mv "$tmp_file" "$NAMES_FILE"
}

forget_binding() {
    local kind="$1"
    local panel="$2"
    local target_id="$3"
    local tmp_file

    ensure_state_dir
    tmp_file="${NAMES_FILE}.tmp.$$"
    awk -F '\t' -v kind="$kind" -v panel="$panel" -v target_id="$target_id" \
        '!(($2 == kind) && ($3 == panel) && ($4 == target_id))' "$NAMES_FILE" > "$tmp_file" 2>/dev/null || true
    mv "$tmp_file" "$NAMES_FILE"
}

print_managed_bindings() {
    ensure_state_dir

    if [ ! -s "$NAMES_FILE" ]; then
        print_warn "还没有本脚本记录的节点名称。新添加节点后会自动显示在这里。"
        return 1
    fi

    printf '\n'
    printf '%-4s %-18s %-8s %-10s %-9s %-14s %s\n' "序号" "名称" "类型" "ID" "内核" "节点类型" "面板"
    printf '%-4s %-18s %-8s %-10s %-9s %-14s %s\n' "----" "------------------" "--------" "----------" "---------" "--------------" "----------------"
    awk -F '\t' '
        NF >= 5 {
            label=$1; kind=$2; panel=$3; target_id=$4; kernel=$5; node_type=$6;
            if (node_type == "") node_type="-";
            printf "%-4d %-18s %-8s %-10s %-9s %-14s %s\n", NR, label, kind, target_id, kernel, node_type, panel
        }
    ' "$NAMES_FILE"
}

read_binding_by_index() {
    local prompt="$1"
    local index=""
    local row=""

    print_managed_bindings || return 1
    echo ""
    read_positive_int "$prompt" index

    row="$(awk -F '\t' -v idx="$index" 'NR == idx { print; exit }' "$NAMES_FILE")"
    if [ -z "$row" ]; then
        print_error "没有这个序号：$index"
        return 1
    fi

    IFS=$'\t' read -r SELECTED_LABEL SELECTED_KIND SELECTED_PANEL SELECTED_TARGET_ID SELECTED_KERNEL SELECTED_NODE_TYPE SELECTED_CREATED_AT <<< "$row"
}

run_official_installer() {
    local mode="$1"
    shift

    install_dependencies || return 1
    print_info "正在调用官方 xboard-node installer (${mode} mode)..."
    curl -fsSL "$INSTALL_URL" | bash -s -- --mode "$mode" "$@"
}

install_first_node() {
    print_info "=== 首次绑定节点 ==="

    read_label "名称: " LABEL
    read_panel_token || return 1
    read_positive_int "节点 ID: " NODE_ID
    read_kernel

    if run_official_installer node --panel "$PANEL" --token "$TOKEN" --node-id "$NODE_ID" --kernel "$KERNEL"; then
        hash -r
        systemctl daemon-reload >/dev/null 2>&1 || true
        remember_binding "$LABEL" "node" "$PANEL" "$NODE_ID" "$KERNEL" ""
        print_success "初始化完成。"
        show_instances
    else
        print_error "安装或初始化失败，请检查面板地址、Token、节点 ID 和网络。"
        return 1
    fi
}

install_machine_mode() {
    print_info "=== 绑定机器 ==="

    read_label "名称: " LABEL
    read_panel_token || return 1
    read_positive_int "机器 ID: " MACHINE_ID
    read_kernel

    if run_official_installer machine --panel "$PANEL" --token "$TOKEN" --machine-id "$MACHINE_ID" --kernel "$KERNEL"; then
        hash -r
        systemctl daemon-reload >/dev/null 2>&1 || true
        remember_binding "$LABEL" "machine" "$PANEL" "$MACHINE_ID" "$KERNEL" ""
        print_success "机器模式初始化完成。"
        show_instances
    else
        print_error "机器模式初始化失败。"
        return 1
    fi
}

ensure_xbctl() {
    if xbctl_exists; then
        return 0
    fi

    print_error "未检测到 xbctl。请先执行菜单 1 初始化 xboard-node。"
    return 1
}

add_node_binding_raw() {
    local panel="$1"
    local token="$2"
    local node_id="$3"
    local kernel="$4"
    local node_type="${5:-}"
    local args=(bind add-node --panel-url "$panel" --token "$token" --node-id "$node_id" --kernel "$kernel")

    if [ -n "$node_type" ]; then
        args+=(--node-type "$node_type")
    fi

    xbctl_cmd "${args[@]}" || xbctl_cmd bind add-node --panel "$panel" --token "$token" --node-id "$node_id" --kernel "$kernel"
}

add_machine_binding_raw() {
    local panel="$1"
    local token="$2"
    local machine_id="$3"
    local kernel="$4"

    xbctl_cmd bind add-machine --panel-url "$panel" --token "$token" --machine-id "$machine_id" --kernel "$kernel" \
        || xbctl_cmd bind add-machine --panel "$panel" --token "$token" --machine-id "$machine_id" --kernel "$kernel"
}

remove_binding_raw() {
    local kind="$1"
    local panel="$2"
    local target_id="$3"

    if [ "$kind" = "node" ]; then
        xbctl_cmd bind remove-node --panel-url "$panel" --node-id "$target_id" \
            || xbctl_cmd bind remove-node --panel "$panel" --node-id "$target_id"
    elif [ "$kind" = "machine" ]; then
        xbctl_cmd bind remove-machine --panel-url "$panel" --machine-id "$target_id" \
            || xbctl_cmd bind remove-machine --panel "$panel" --machine-id "$target_id"
    else
        print_error "未知绑定类型：$kind"
        return 1
    fi
}

add_node_binding() {
    if ! xbctl_exists; then
        install_first_node
        return $?
    fi

    print_info "=== 添加节点 ==="
    read_label "名称: " LABEL
    read_panel_token || return 1
    read_positive_int "节点 ID: " NODE_ID
    read_kernel

    read -r -p "节点类型，可留空: " NODE_TYPE </dev/tty

    if add_node_binding_raw "$PANEL" "$TOKEN" "$NODE_ID" "$KERNEL" "$NODE_TYPE"; then
        remember_binding "$LABEL" "node" "$PANEL" "$NODE_ID" "$KERNEL" "$NODE_TYPE"
        print_success "节点绑定已添加。"
        restart_service
        show_instances
    else
        print_error "添加失败。请确认 xbctl 版本支持 bind add-node，并检查参数。"
        return 1
    fi
}

add_machine_binding() {
    if ! xbctl_exists; then
        install_machine_mode
        return $?
    fi

    print_info "=== 添加机器 ==="
    read_label "名称: " LABEL
    read_panel_token || return 1
    read_positive_int "机器 ID: " MACHINE_ID
    read_kernel

    if add_machine_binding_raw "$PANEL" "$TOKEN" "$MACHINE_ID" "$KERNEL"; then
        remember_binding "$LABEL" "machine" "$PANEL" "$MACHINE_ID" "$KERNEL" ""
        print_success "机器绑定已添加。"
        restart_service
        show_instances
    else
        print_error "添加机器绑定失败。"
        return 1
    fi
}

remove_binding_by_instance() {
    ensure_xbctl || return 1
    read_binding_by_index "序号: " || return 1

    echo ""
    print_warn "删除：$SELECTED_LABEL"
    read -r -p "确认？[y/N]: " confirm </dev/tty
    if ! [[ "$confirm" =~ ^[Yy]$ ]]; then
        print_warn "已取消删除。"
        return 0
    fi

    delete_selected_binding
}

delete_selected_binding() {
    if remove_binding_raw "$SELECTED_KIND" "$SELECTED_PANEL" "$SELECTED_TARGET_ID"; then
        forget_binding "$SELECTED_KIND" "$SELECTED_PANEL" "$SELECTED_TARGET_ID"
        print_success "绑定已删除。"
        restart_service
    else
        print_error "删除失败。可到工具里查看全部绑定记录。"
        return 1
    fi
}

edit_selected_binding() {
    ensure_xbctl || return 1

    echo ""
    print_info "直接回车表示保留原值。"
    read_optional "名称" "$SELECTED_LABEL" NEW_LABEL || return 1
    read_optional_panel "$SELECTED_PANEL" NEW_PANEL

    read -r -p "Token [留空保留原绑定，仅改菜单记录]: " NEW_TOKEN </dev/tty
    if [ "$SELECTED_KIND" = "node" ]; then
        read_optional_positive_int "节点 ID" "$SELECTED_TARGET_ID" NEW_TARGET_ID
        read -r -p "节点类型 [${SELECTED_NODE_TYPE:-自动识别}]: " NEW_NODE_TYPE </dev/tty
        if [ -z "$NEW_NODE_TYPE" ] || [ "$NEW_NODE_TYPE" = "自动识别" ]; then
            NEW_NODE_TYPE="$SELECTED_NODE_TYPE"
        fi
    else
        read_optional_positive_int "机器 ID" "$SELECTED_TARGET_ID" NEW_TARGET_ID
        NEW_NODE_TYPE=""
    fi
    read_optional_kernel "$SELECTED_KERNEL" NEW_KERNEL

    local changed_remote=0
    local key_changed=0
    if [ "$NEW_PANEL" != "$SELECTED_PANEL" ] || [ "$NEW_TARGET_ID" != "$SELECTED_TARGET_ID" ] || [ "$NEW_KERNEL" != "$SELECTED_KERNEL" ] || [ "$NEW_NODE_TYPE" != "$SELECTED_NODE_TYPE" ]; then
        changed_remote=1
    fi
    if [ "$NEW_PANEL" != "$SELECTED_PANEL" ] || [ "$NEW_TARGET_ID" != "$SELECTED_TARGET_ID" ]; then
        key_changed=1
    fi

    if [ -z "$NEW_TOKEN" ] && { [ "$changed_remote" -eq 1 ] || [ "$key_changed" -eq 1 ]; }; then
        print_error "面板地址、ID、内核或节点类型改变时必须填写 Token。"
        return 1
    fi

    if [ "$changed_remote" -eq 0 ] && [ -z "$NEW_TOKEN" ]; then
        forget_binding "$SELECTED_KIND" "$SELECTED_PANEL" "$SELECTED_TARGET_ID"
        remember_binding "$NEW_LABEL" "$SELECTED_KIND" "$SELECTED_PANEL" "$SELECTED_TARGET_ID" "$SELECTED_KERNEL" "$SELECTED_NODE_TYPE"
        SELECTED_LABEL="$NEW_LABEL"
        print_success "已更新菜单记录。"
        return 0
    fi

    if [ "$key_changed" -eq 1 ]; then
        print_warn "将重新绑定：先添加新绑定，成功后删除旧绑定。"
    else
        print_warn "将更新当前绑定。"
    fi
    read -r -p "继续？[y/N]: " confirm </dev/tty
    if ! [[ "$confirm" =~ ^[Yy]$ ]]; then
        print_warn "已取消。"
        return 0
    fi

    if [ "$SELECTED_KIND" = "node" ]; then
        add_node_binding_raw "$NEW_PANEL" "$NEW_TOKEN" "$NEW_TARGET_ID" "$NEW_KERNEL" "$NEW_NODE_TYPE" || {
            print_error "新绑定添加失败，旧绑定未删除。"
            return 1
        }
    else
        add_machine_binding_raw "$NEW_PANEL" "$NEW_TOKEN" "$NEW_TARGET_ID" "$NEW_KERNEL" || {
            print_error "新绑定添加失败，旧绑定未删除。"
            return 1
        }
    fi

    if [ "$key_changed" -eq 1 ]; then
        remove_binding_raw "$SELECTED_KIND" "$SELECTED_PANEL" "$SELECTED_TARGET_ID" || print_warn "新绑定已添加，但旧绑定删除失败，请稍后在管理里删除旧绑定。"
        forget_binding "$SELECTED_KIND" "$SELECTED_PANEL" "$SELECTED_TARGET_ID"
    else
        forget_binding "$SELECTED_KIND" "$SELECTED_PANEL" "$SELECTED_TARGET_ID"
    fi
    remember_binding "$NEW_LABEL" "$SELECTED_KIND" "$NEW_PANEL" "$NEW_TARGET_ID" "$NEW_KERNEL" "$NEW_NODE_TYPE"

    SELECTED_LABEL="$NEW_LABEL"
    SELECTED_PANEL="$NEW_PANEL"
    SELECTED_TARGET_ID="$NEW_TARGET_ID"
    SELECTED_KERNEL="$NEW_KERNEL"
    SELECTED_NODE_TYPE="$NEW_NODE_TYPE"

    restart_service
    print_success "绑定已更新。"
}

remove_binding_advanced() {
    ensure_xbctl || return 1

    echo "1. 节点"
    echo "2. 机器"
    echo "0. 返回"
    read -r -p "选择: " remove_choice </dev/tty

    case "$remove_choice" in
        1)
            read_required "面板地址: " PANEL
            read_positive_int "节点 ID: " NODE_ID
            remove_binding_raw "node" "$PANEL" "$NODE_ID"
            ;;
        2)
            read_required "面板地址: " PANEL
            read_positive_int "机器 ID: " MACHINE_ID
            remove_binding_raw "machine" "$PANEL" "$MACHINE_ID"
            ;;
        0)
            return 0
            ;;
        *)
            print_error "无效选择。"
            return 1
            ;;
    esac

    if [ $? -eq 0 ]; then
        print_success "绑定已删除。"
        restart_service
        show_instances
    else
        print_error "删除失败。"
        return 1
    fi
}

record_existing_binding() {
    print_info "=== 同步已有节点 ==="

    if xbctl_exists; then
        echo ""
        print_info "xbctl 列表"
        xbctl_cmd list 2>/dev/null || xbctl_cmd instance list 2>/dev/null || true
        echo ""
    fi

    read_label "名称: " LABEL
    echo "1. 节点"
    echo "2. 机器"
    read -r -p "类型: " kind_choice </dev/tty

    case "$kind_choice" in
        1)
            KIND="node"
            read_positive_int "节点 ID: " TARGET_ID
            read -r -p "节点类型，可留空: " NODE_TYPE </dev/tty
            ;;
        2)
            KIND="machine"
            read_positive_int "机器 ID: " TARGET_ID
            NODE_TYPE=""
            ;;
        *)
            print_error "无效选择。"
            return 1
            ;;
    esac

    read_required "面板地址: " PANEL
    read_kernel
    remember_binding "$LABEL" "$KIND" "$PANEL" "$TARGET_ID" "$KERNEL" "$NODE_TYPE"

    print_success "已加入列表，后续可按序号管理。"
    show_instances
}

rename_binding() {
    read_binding_by_index "请输入要重命名的序号: " || return 1
    read_label "请输入新名称: " NEW_LABEL

    remember_binding "$NEW_LABEL" "$SELECTED_KIND" "$SELECTED_PANEL" "$SELECTED_TARGET_ID" "$SELECTED_KERNEL" "$SELECTED_NODE_TYPE"
    print_success "已重命名为：$NEW_LABEL"
    show_instances
}

show_instances() {
    if ensure_xbctl; then
        echo ""
        print_info "脚本列表里的节点"
        print_managed_bindings || true

        echo ""
        print_info "xboard-node 实际运行的节点"
        xbctl_cmd list 2>/dev/null || xbctl_cmd instance list 2>/dev/null || true
    fi
}

show_instance_detail() {
    ensure_xbctl || return 1
    if [ -z "${SELECTED_LABEL:-}" ]; then
        read_binding_by_index "序号: " || return 1
    fi

    echo ""
    print_info "绑定信息"
    echo "名称：$SELECTED_LABEL"
    echo "类型：$SELECTED_KIND"
    echo "面板：$SELECTED_PANEL"
    echo "ID：$SELECTED_TARGET_ID"
    echo "内核：$SELECTED_KERNEL"
    echo "节点类型：${SELECTED_NODE_TYPE:-自动识别}"
    echo "添加时间：${SELECTED_CREATED_AT:-未知}"

    echo ""
    print_info "xbctl 信息"
    local instance_key="${SELECTED_PANEL}:${SELECTED_KIND}:${SELECTED_TARGET_ID}"
    xbctl_cmd inspect "$instance_key" \
        || xbctl_cmd instance get "$instance_key" \
        || xbctl_cmd list 2>/dev/null \
        || print_error "未能读取官方实例详情。"
}

manage_one_binding() {
    ensure_xbctl || return 1
    read_binding_by_index "序号: " || return 1

    while true; do
        clear
        echo -e "${CYAN}====== $SELECTED_LABEL ======${NC}"
        echo "类型：$SELECTED_KIND    ID：$SELECTED_TARGET_ID"
        echo "面板：$SELECTED_PANEL"
        echo ""
        echo "1. 节点详情"
        echo "2. 修改信息"
        echo "3. 删除节点"
        echo "4. 返回"
        echo -e "${CYAN}============================${NC}"
        read -r -p "选择: " action </dev/tty

        case "$action" in
            1) show_instance_detail; pause ;;
            2)
                edit_selected_binding
                pause
                ;;
            3)
                print_warn "删除：$SELECTED_LABEL"
                read -r -p "确认？[y/N]: " confirm </dev/tty
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    if delete_selected_binding; then
                        pause
                        return 0
                    fi
                else
                    print_warn "已取消。"
                fi
                pause
                ;;
            4) return 0 ;;
            *) print_error "无效选择。"; pause ;;
        esac
    done
}

restart_service() {
    if xbctl_exists; then
        xbctl_cmd service restart || systemctl restart "$SERVICE_NAME"
    else
        systemctl restart "$SERVICE_NAME"
    fi
}

start_service() {
    if xbctl_exists; then
        xbctl_cmd service start || systemctl start "$SERVICE_NAME"
    else
        systemctl start "$SERVICE_NAME"
    fi
}

stop_service() {
    if xbctl_exists; then
        xbctl_cmd service stop || systemctl stop "$SERVICE_NAME"
    else
        systemctl stop "$SERVICE_NAME"
    fi
}

show_status() {
    if xbctl_exists; then
        xbctl_cmd status || xbctl_cmd service status || true
    elif service_exists; then
        systemctl status "$SERVICE_NAME" --no-pager
    else
        print_error "${SERVICE_NAME} 服务不存在。"
    fi
}

show_logs() {
    if xbctl_exists; then
        xbctl_cmd service logs
    elif service_exists; then
        journalctl -u "$SERVICE_NAME" -f </dev/tty
    else
        print_error "${SERVICE_NAME} 服务不存在。"
    fi
}

health_check() {
    if xbctl_exists; then
        xbctl_cmd health
    else
        print_error "未检测到 xbctl，无法执行健康检查。"
    fi
}

service_menu() {
    while true; do
        clear
        echo -e "${CYAN}====== 状态与日志 ======${NC}"
        echo "1. 服务状态"
        echo "2. 实时日志"
        echo "3. 重启服务"
        echo "4. 启动服务"
        echo "5. 停止服务"
        echo "6. 健康检查"
        echo "0. 返回"
        echo -e "${CYAN}==================${NC}"
        read -r -p "选择: " choice </dev/tty

        case "$choice" in
            1) show_status; pause ;;
            2) show_logs ;;
            3) restart_service && print_success "服务已重启"; pause ;;
            4) start_service && print_success "服务已启动"; pause ;;
            5) stop_service && print_success "服务已停止"; pause ;;
            6) health_check; pause ;;
            0) return 0 ;;
            *) print_error "无效选择。"; pause ;;
        esac
    done
}

upgrade_node() {
    if xbctl_exists; then
        xbctl_cmd upgrade || bash -c "curl -fsSL '$INSTALL_URL' | bash -s -- upgrade"
    else
        bash -c "curl -fsSL '$INSTALL_URL' | bash -s -- upgrade"
    fi
}

edit_config() {
    if [ -f "$CONFIG_FILE" ]; then
        "${EDITOR:-nano}" "$CONFIG_FILE" </dev/tty
        print_warn "配置修改后请重启服务。"
    else
        print_error "配置文件不存在：$CONFIG_FILE"
    fi
}

uninstall_node() {
    print_warn "即将卸载 xboard-node。"
    print_warn "默认会保留 /etc/xboard-node 配置；选择 purge 才会彻底删除配置。"
    read -r -p "确认卸载？[y/N]: " confirm </dev/tty

    if ! [[ "$confirm" =~ ^[Yy]$ ]]; then
        print_warn "已取消卸载。"
        return 0
    fi

    read -r -p "是否同时删除配置目录 /etc/xboard-node？[y/N]: " purge </dev/tty

    if xbctl_exists; then
        if [[ "$purge" =~ ^[Yy]$ ]]; then
            xbctl_cmd uninstall --purge --yes
        else
            xbctl_cmd uninstall --yes
        fi
    else
        local args=(uninstall --yes)
        if [[ "$purge" =~ ^[Yy]$ ]]; then
            args+=(--purge)
        fi
        curl -fsSL "$INSTALL_URL" | bash -s -- "${args[@]}"
    fi
}

show_help() {
    cat <<'EOF'
用法：
  管理节点：节点列表 -> 选择序号
  添加节点：添加节点 -> 对接节点 ID
  修改节点：节点列表 -> 选择序号 -> 修改信息

说明：
  一台机器只跑一个 xboard-node.service。
  可以绑定多个面板，也可以绑定同一面板下的多个节点。
  每次新增都会单独填写面板地址、Token 和节点 ID。
  所有绑定由 xboard-node 统一运行。
  名称表只给菜单用：/etc/xboard-node/xb-node.names.tsv
EOF
}

add_bind_menu() {
    while true; do
        clear
        echo -e "${CYAN}====== 添加节点 ======${NC}"
        echo "1. 对接节点 ID"
        echo "2. 对接机器 ID"
        echo "0. 返回"
        echo -e "${CYAN}==================${NC}"
        read -r -p "选择: " choice </dev/tty

        case "$choice" in
            1) add_node_binding; pause; return 0 ;;
            2) add_machine_binding; pause; return 0 ;;
            0) return 0 ;;
            *) print_error "无效选择。"; pause ;;
        esac
    done
}

bindings_menu() {
    while true; do
        clear
        echo -e "${CYAN}====== 节点列表 ======${NC}"
        print_managed_bindings || true
        echo ""
        echo "1. 选择节点"
        echo "2. 查看服务记录"
        echo "0. 返回"
        echo -e "${CYAN}==================${NC}"
        read -r -p "选择: " choice </dev/tty

        case "$choice" in
            1) manage_one_binding ;;
            2) show_instances; pause ;;
            0) return 0 ;;
            *) print_error "无效选择。"; pause ;;
        esac
    done
}

maintenance_menu() {
    while true; do
        clear
        echo -e "${CYAN}====== 更多操作 ======${NC}"
        echo "1. 同步已有节点"
        echo "2. 删除指定节点"
        echo "3. 修改配置文件"
        echo "4. 更新程序"
        echo "5. 卸载程序"
        echo "6. 帮助说明"
        echo "0. 返回"
        echo -e "${CYAN}==================${NC}"
        read -r -p "选择: " choice </dev/tty

        case "$choice" in
            1) record_existing_binding; pause ;;
            2) remove_binding_advanced; pause ;;
            3) edit_config; pause ;;
            4) upgrade_node; pause ;;
            5) uninstall_node; pause ;;
            6) show_help; pause ;;
            0) return 0 ;;
            *) print_error "无效选择。"; pause ;;
        esac
    done
}

show_menu() {
    clear
    echo -e "${BLUE}====== Xboard-Node ======${NC}"
    echo "1. 节点列表"
    echo "2. 添加节点"
    echo "3. 状态与日志"
    echo "4. 更多操作"
    echo "0. 退出"
    echo -e "${BLUE}=========================${NC}"
    read -r -p "选择: " choice </dev/tty
}

main_menu() {
    require_tty
    require_root

    while true; do
        show_menu

        case "$choice" in
            1) bindings_menu ;;
            2) add_bind_menu ;;
            3) service_menu ;;
            4) maintenance_menu ;;
            0) exit 0 ;;
            *) print_error "无效选择。"; pause ;;
        esac
    done
}

case "${1:-menu}" in
    menu) main_menu ;;
    install) require_root; install_first_node ;;
    install-machine) require_root; install_machine_mode ;;
    add-node) require_root; add_node_binding ;;
    add-machine) require_root; add_machine_binding ;;
    list) show_instances ;;
    status) show_status ;;
    logs) show_logs ;;
    restart) require_root; restart_service ;;
    help|-h|--help) show_help ;;
    *) print_error "未知命令：$1"; show_help; exit 1 ;;
esac
