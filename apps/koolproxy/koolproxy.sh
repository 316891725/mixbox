
# 1|koolproxy.txt|https://kprule.com/koolproxy.txt|静态规则
# 1|daily.txt|https://kprule.com/daily.txt|每日规则
# 1|kp.dat|https://kprule.com/kp.dat|视频规则
# 1|user.txt||自定义规则
# 0|easylistchina.txt|https://kprule.com/easylistchina.txt|ABP规则
# 0|chengfeng.txt|https://kprule.com/chengfeng.txt|乘风规则
# 1|fanboy.txt|https://kprule.com/fanboy.txt|Fanboy规则

DATA_PATH=${MBROOT}/apps/${appname}/data

update_rules() {

    loginfo "下载kp规则：koolproxy.txt..."
    wgetsh ${DATA_PATH}/rules/koolproxy.txt ${kp_rule_koolproxy}

    loginfo "下载kp规则：daily.txt..."
    wgetsh ${DATA_PATH}/rules/daily.txt ${kp_rule_daily}

    loginfo "下载kp规则：kp.dat..."
    wgetsh ${DATA_PATH}/rules/kp.dat ${kp_rule_dat}

}

start_koolproxy () {
    loginfo "开启${appname}主进程..."
    EXT_ARG=""
    if [ "$mode" == "1" ]; then
        loginfo "启动${appname}为全局模式！"
        cat > ${DATA_PATH}/source.list <<-EOF
1|koolproxy.txt|${kp_rule_koolproxy}|
1|daily.txt|${kp_rule_daily}|
1|kp.dat|${kp_rule_dat}|
1|user.txt||
EOF
    fi

    if [ "$mode" == "2" ]; then
        loginfo "启动${appname}为黑名单模式！"
        cat > ${DATA_PATH}/source.list <<-EOF
1|koolproxy.txt|${kp_rule_koolproxy}|
1|daily.txt|${kp_rule_daily}|
1|kp.dat|${kp_rule_dat}|
1|user.txt||
EOF
    fi

    if [ "$mode" == "3" ]; then
        loginfo "启动${appname}为视频模式！"
        cat > ${DATA_PATH}/source.list <<-EOF
1|kp.dat|${kp_rule_dat}|
1|user.txt||
EOF
    fi
    [ "$MODEL" == "R3P" ] && EXT_ARG="-c 4"
    ${MBROOT}/apps/${appname}/${appname} $EXT_ARG -b ${MBROOT}/apps/${appname}/data -d 
}

add_ipset_conf () {
    if [ "$mode" == "2" ]; then
        loginfo "添加黑名单软链接..."
        cp -rf ${DATA_PATH}/koolproxy_ipset.conf ${MBTMP}
        dnsmasq_add_config koolproxy_ipset.conf
        dnsmasq_restart=1
    fi
}

remove_ipset_conf () {
    if [ -L "/tmp/etc/dnsmasq.d/koolproxy_ipset.conf" ]; then
        loginfo "移除黑名单软链接..."
        dnsmasq_del_config koolproxy_ipset.conf
    fi
}

restart_dnsmasq () {
    if [ "$dnsmasq_restart" == "1" ]; then
        loginfo "重启dnsmasq进程..."
        dnsmasq_reload
    fi
}

create_ipset () {
    loginfo "创建ipset名单..."
    ipset -N white_kp_list nethash
    ipset -N black_koolproxy iphash
}

add_white_black_ip(){
    ip_lan="0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 224.0.0.0/4 240.0.0.0/4"
    for ip in $ip_lan
    do
        ipset -A white_kp_list $ip >/dev/null 2>&1

    done
    ipset -A black_koolproxy 110.110.110.110 >/dev/null 2>&1
}

get_mode_name() {
    case "$1" in
        0)
            echo "不过滤"
        ;;
        1)
            echo "http模式"
        ;;
        2)
            echo "http + https"
        ;;
    esac
}

get_jump_mode () {
    case "$1" in
        0)
            echo "-j"
        ;;
        *)
            echo "-g"
        ;;
    esac
}

get_action_chain () {
    case "$1" in
        0)
            echo "RETURN"
        ;;
        1)
            echo "KOOLPROXY_HTTP"
        ;;
        2)
            echo "KOOLPROXY_HTTPS"
        ;;
    esac
}

factor () {
    if [ -z "$1" ] || [ -z "$2" ]; then
        echo ""
    else
        echo "$2 $1"
    fi
}

flush_nat () {
    loginfo "移除nat规则..."
    cd /tmp
    iptables -t nat -S | grep -E "KOOLPROXY|KOOLPROXY_HTTP|KOOLPROXY_HTTPS" | sed 's/-A/iptables -t nat -D/g'|sed 1,3d > clean.sh && chmod 777 clean.sh && ./clean.sh && rm clean.sh
    iptables -t nat -X KOOLPROXY > /dev/null 2>&1
    iptables -t nat -X KOOLPROXY_HTTP > /dev/null 2>&1
    iptables -t nat -X KOOLPROXY_HTTPS > /dev/null 2>&1
    ipset -F black_koolproxy > /dev/null 2>&1 && ipset -X black_koolproxy > /dev/null 2>&1
    ipset -F white_kp_list > /dev/null 2>&1 && ipset -X white_kp_list > /dev/null 2>&1
}

lan_acess_control () {
    [ ! -f ${MBROOT}/apps/${appname}/kpcontrol.conf ] && touch ${MBROOT}/apps/${appname}/kpcontrol.conf
    cat ${MBROOT}/apps/${appname}/kpcontrol.conf | while read line
    do
        [ -z "${line}" ] && continue
        mac=$(echo ${line} | cut -d',' -f2)
        proxy_name=$(echo ${line} | cut -d',' -f1)
        proxy_mode=$(echo ${line} | cut -d',' -f3)
        loginfo "加载ACL规则:【$proxy_name】模式为:$(get_mode_name $proxy_mode)"
        iptables -t nat -A KOOLPROXY $(factor $mac "-m mac --mac-source") -p tcp $(get_jump_mode $proxy_mode) $(get_action_chain $proxy_mode)
    done
    loginfo "加载ACL规则:其余主机模式为:$(get_mode_name $koolproxy_acl_default_mode)"
}

load_nat(){
    loginfo "加载nat规则!"
    #----------------------BASIC RULES---------------------
    loginfo "写入iptables规则到nat表中..."
    # 创建KOOLPROXY nat rule
    iptables -t nat -N KOOLPROXY
    # 局域网地址不走KP
    iptables -t nat -A KOOLPROXY -m set --match-set white_kp_list dst -j RETURN
    #  生成对应CHAIN
    iptables -t nat -N KOOLPROXY_HTTP
    iptables -t nat -A KOOLPROXY_HTTP -p tcp -m multiport --dport 80,82,8080 -j REDIRECT --to-ports 3000
    iptables -t nat -N KOOLPROXY_HTTPS
    iptables -t nat -A KOOLPROXY_HTTPS -p tcp -m multiport --dport 80,82,443,8080 -j REDIRECT --to-ports 3000
    # 局域网控制
    lan_acess_control
    # 剩余流量转发到缺省规则定义的链中
    iptables -t nat -A KOOLPROXY -p tcp -j $(get_action_chain $koolproxy_acl_default_mode)
    # 重定所有流量到 KOOLPROXY
    # 全局模式和视频模式
    iptablenu=$(iptables -nvL PREROUTING -t nat | sed 1,2d | sed -n '/SHADOWSOCKS/=' | head -n1)
    if [ ! -z "$iptablenu" ];then
        let iptablenu=$iptablenu+1
    else
        iptablenu=2
    fi
    [ "$mode" == "1" ] || [ "$mode" == "3" ] && iptables -t nat -I PREROUTING $iptablenu -p tcp -j KOOLPROXY
    # ipset 黑名单模式
    [ "$mode" == "2" ] && iptables -t nat -I PREROUTING 2 -p tcp -m set --match-set black_koolproxy dst -j KOOLPROXY
}

dns_takeover () {
    iptablenu=$(iptables -t nat -L PREROUTING -v -n --line-numbers|grep "dpt:53"|awk '{print $1}')
    if [ '$iptablenu' == '' ];then
        iptables -t nat -A PREROUTING -p udp --dport 53 -j DNAT --to $LANIP >/dev/null 2>&1
    fi
}

detect_cert () {

    if [ ! -f ${DATA_PATH}/private/ca.key.pem ]; then
        loginfo "检测到首次运行，开始生成${appname}证书，用于https过滤！"
        ${MBROOT}/apps/${appname}/koolproxy --cert      
    fi
}

# update_userrule () {
#     result=$(mbdb get ${appname}.main.autorule)
#     if [ "$result" == '1' ]; then
#         cru a "${appname}"_rule "20 5 * * * ${MBROOT}/apps/${appname}/updaterules.sh"
#     else
#         cru d "${appname}"_rule
#     fi
# }

start () {

    check_running ${binfile} && exit 1
    cru a "${appname}" "0 6 * * * ${MBROOT}/apps/${appname}/${appname}.sh restart"
    detect_cert
    # update_userrule
    update_rules
    start_koolproxy
    add_ipset_conf && restart_dnsmasq
    create_ipset
    add_white_black_ip
    load_nat
    dns_takeover
    write_firewall_start
    loginfo "启动${appname}服务完成！"
    loginfo "https模式请访问http://110.110.110.110下载证书"
    
}

stop () {

    remove_ipset_conf && restart_dnsmasq
    flush_nat
    remove_firewall_start
    cru d "${appname}"
    cru d "${appname}"_rule
    loginfo "关闭${appname}主进程..."
    daemon_stop "${binfile}"
	
}

status() {

    result=$(pssh | grep ${MBROOT}/apps/${appname}/${appname} | grep -v grep | wc -l)
    if [ "$result" == '0' ]; then
        echo "未运行"
        return 1
    else
        case "$mode" in
            1) flag="全局模式" ;;
            2) flag="黑名单模式" ;;
            3) flag="视频模式" ;;
        esac
        rules=${DATA_PATH}/rules/koolproxy.txt
        rulesdate=$(cat $rules | grep "update\[rules\]" | awk '{print$3" "$4}') > /dev/null 2>&1
        [ -z "$rulesdate" ] && rulesdate="更新中"
        # kp_ver=$(${MBROOT}/apps/${appname}/${appname} -v)
        echo "运行模式: $flag, 规则: $rulesdate"
        return 0
    fi
}

