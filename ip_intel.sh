#!/usr/bin/env bash
# ============================================================================
#  GHOST PANEL v1.0 (versão Linux / macOS / Termux)
#  Porte do ip_intel.bat (Batch + PowerShell) para Bash.
#
#  Dependências obrigatórias : bash 3.2+, curl, jq
#  Dependências opcionais    : dig ou host (DNS), ping, traceroute/tracepath,
#                              timeout ou nc (scan de portas)
#
#  Uso: chmod +x ip_intel.sh && ./ip_intel.sh
# ============================================================================

BATDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
UA='Mozilla/5.0'

# garante locale UTF-8 (acentos e alinhamento corretos)
case "${LC_ALL:-${LANG:-}}" in
    *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) ;;
    *) export LC_ALL=C.UTF-8 ;;
esac

REPORT=()
T_INPUT=""
T_IP=""
T_LAT=""
T_LON=""
LAST_ERR=""

# ---------------------------------------------------------------- cores
RST=$'\e[0m'
color_code() {
    case "$1" in
        cyan)     printf '\e[36m' ;;
        yellow)   printf '\e[33m' ;;
        green)    printf '\e[32m' ;;
        red)      printf '\e[31m' ;;
        white)    printf '\e[97m' ;;
        darkgray) printf '\e[90m' ;;
        *)        printf '\e[37m' ;;
    esac
}

# ---------------------------------------------------------------- helpers
have() { command -v "$1" >/dev/null 2>&1; }

out_line() {
    local t="$1" c="${2:-gray}"
    printf '%s%s%s\n' "$(color_code "$c")" "$t" "$RST"
    REPORT+=("$t")
}

title() { out_line ""; out_line "=== $1 ===" cyan; }

kv() {
    local k="$1" v="$2"
    [[ -z "${v//[[:space:]]/}" ]] && v="N/D"
    local pad=$((24 - ${#k})) sp
    (( pad < 1 )) && pad=1
    printf -v sp '%*s' "$pad" ''
    out_line "  ${k}${sp}: ${v}" white
}

yn() {
    case "$1" in
        true)  printf 'SIM' ;;
        false) printf 'NÃO' ;;
        *)     printf 'N/D' ;;
    esac
}

wait_key() { echo; read -r -p "  ENTER para voltar ao menu" _; }

# j <json> <filtro-jq> -> imprime valor (vazio se null)
j() {
    printf '%s' "$1" | jq -r "(try ($2) catch null) | if . == null then empty else tostring end" 2>/dev/null
}

# get_json <url> -> imprime JSON; retorna 1 em falha
get_json() {
    local out rc
    out="$(curl -sSL -m 15 -A "$UA" "$1" 2>&1)"; rc=$?
    if [[ $rc -ne 0 ]]; then LAST_ERR="$out"; return 1; fi
    if ! printf '%s' "$out" | jq -e . >/dev/null 2>&1; then
        LAST_ERR="resposta inválida"; return 1
    fi
    printf '%s' "$out"
}

valid_ipv4() {
    local ip="$1" o
    [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    local IFS=.
    for o in $ip; do (( 10#$o <= 255 )) || return 1; done
    return 0
}

valid_ipv6() { [[ "$1" == *:* && "$1" =~ ^[0-9a-fA-F:.]+$ ]]; }

is_private() {
    local ip="$1" a b c d
    if valid_ipv6 "$ip"; then
        [[ "$ip" == "::1" ]] && return 0
        shopt -s nocasematch
        [[ "$ip" =~ ^(fe80|fc|fd) ]]; local r=$?
        shopt -u nocasematch
        return $r
    fi
    valid_ipv4 "$ip" || return 1
    IFS=. read -r a b c d <<<"$ip"
    a=$((10#$a)); b=$((10#$b))
    (( a == 10 || a == 127 || a == 0 )) && return 0
    (( a == 172 && b >= 16 && b <= 31 )) && return 0
    (( a == 192 && b == 168 )) && return 0
    (( a == 169 && b == 254 )) && return 0
    (( a == 100 && b >= 64 && b <= 127 )) && return 0
    return 1
}

# dns_q <tipo> <nome> -> valores, um por linha
dns_q() {
    local type="$1" name="$2"
    if have dig; then
        dig +short +time=3 +tries=1 "$type" "$name" 2>/dev/null | sed '/^;;/d;/^$/d'
    elif have host; then
        host -W 3 -t "$type" "$name" 2>/dev/null | grep -v 'not found\|has no\|NXDOMAIN\|timed out' |
            sed -E 's/^.* (has address|has IPv6 address|mail is handled by|name server|descriptive text|is an alias for) //' |
            sed '/^$/d'
    elif [[ "$type" == "A" ]] && have getent; then
        getent ahostsv4 "$name" 2>/dev/null | awk '{print $1}' | sort -u
    fi
}

resolve_target() {
    local t="$1" r
    t="${t#"${t%%[![:space:]]*}"}"; t="${t%"${t##*[![:space:]]}"}"
    t="${t#*://}"; t="${t%%/*}"
    [[ -z "$t" ]] && return 1
    [[ "$t" =~ ^[A-Za-z0-9._:-]+$ ]] || return 1
    if valid_ipv4 "$t" || valid_ipv6 "$t"; then printf '%s' "$t"; return 0; fi
    r="$(dns_q A "$t" | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' | head -n1)"
    if [[ -z "$r" ]] && have getent; then
        r="$(getent ahostsv4 "$t" 2>/dev/null | awk 'NR==1{print $1}')"
    fi
    [[ -n "$r" ]] && { printf '%s' "$r"; return 0; }
    return 1
}

set_target() {
    local t="$1" ip clean
    ip="$(resolve_target "$t")"
    if [[ -z "$ip" ]]; then
        printf '%s  Alvo inválido ou não resolvido.%s\n' "$(color_code red)" "$RST"
        return 1
    fi
    clean="${t#*://}"; clean="${clean%%/*}"
    clean="${clean#"${clean%%[![:space:]]*}"}"; clean="${clean%"${clean##*[![:space:]]}"}"
    T_INPUT="$clean"; T_IP="$ip"; T_LAT=""; T_LON=""
    return 0
}

need_target() {
    [[ -n "$T_IP" ]] && return 0
    local t
    read -r -p "  Digite o IP ou domínio alvo: " t
    set_target "$t"
}

confirm_scan() {
    echo
    printf '%s  AVISO: escaneie apenas IPs seus ou com autorização.%s\n' "$(color_code yellow)" "$RST"
    local r
    read -r -p "  Continuar? (S/N) " r
    [[ "$r" =~ ^[sS] ]]
}

open_url() {
    if have termux-open-url; then termux-open-url "$1" >/dev/null 2>&1
    elif have xdg-open; then xdg-open "$1" >/dev/null 2>&1 &
    elif have open; then open "$1" >/dev/null 2>&1
    else printf '  Sem navegador disponível. Copie: %s\n' "$1"; fi
}

url_host() { if [[ "$1" == *:* ]]; then printf '[%s]' "$1"; else printf '%s' "$1"; fi; }

# ---------------------------------------------------------------- módulos
do_geo() {
    local ip="$T_IP" g w v
    title "GEOLOCALIZAÇÃO E REDE (ip-api.com)"
    if is_private "$ip"; then
        out_line "  IP privado/local/reservado: sem dados públicos de geolocalização." yellow
        return
    fi
    g="$(get_json "http://ip-api.com/json/${ip}?lang=pt-BR&fields=status,message,continent,country,countryCode,region,regionName,city,district,zip,lat,lon,timezone,offset,currency,isp,org,as,asname,reverse,mobile,proxy,hosting,query")"
    if [[ -z "$g" || "$(j "$g" .status)" != "success" ]]; then
        out_line "  Falha na consulta: $(j "$g" .message) $LAST_ERR" red
    else
        T_LAT="$(j "$g" .lat)"; T_LON="$(j "$g" .lon)"
        kv "IP" "$(j "$g" .query)"
        kv "Continente" "$(j "$g" .continent)"
        kv "País" "$(j "$g" .country) ($(j "$g" .countryCode))"
        kv "Estado/Região" "$(j "$g" .regionName) ($(j "$g" .region))"
        kv "Cidade" "$(j "$g" .city)"
        kv "Distrito" "$(j "$g" .district)"
        kv "CEP/ZIP" "$(j "$g" .zip)"
        kv "Coordenadas" "$T_LAT, $T_LON"
        kv "Google Maps" "https://www.google.com/maps?q=$T_LAT,$T_LON"
        kv "Fuso horário" "$(j "$g" .timezone)"
        v="$(j "$g" .offset)"
        [[ -n "$v" ]] && v="$(awk -v o="$v" 'BEGIN{printf "%.1f", o/3600}')"
        kv "Offset UTC (h)" "$v"
        kv "Moeda" "$(j "$g" .currency)"
        kv "ISP" "$(j "$g" .isp)"
        kv "Organização" "$(j "$g" .org)"
        kv "AS" "$(j "$g" .as)"
        kv "Nome do AS" "$(j "$g" .asname)"
        kv "Reverse DNS" "$(j "$g" .reverse)"
        kv "Rede móvel" "$(yn "$(j "$g" .mobile)")"
        kv "Proxy/VPN/Tor" "$(yn "$(j "$g" .proxy)")"
        kv "Hosting/Datacenter" "$(yn "$(j "$g" .hosting)")"
    fi

    title "SEGUNDA FONTE (ipwho.is)"
    w="$(get_json "https://ipwho.is/$ip")"
    if [[ -z "$w" || "$(j "$w" .success)" != "true" ]]; then
        out_line "  Falha na consulta: $(j "$w" .message) $LAST_ERR" red
    else
        if [[ -z "$T_LAT" ]]; then T_LAT="$(j "$w" .latitude)"; T_LON="$(j "$w" .longitude)"; fi
        kv "Tipo" "$(j "$w" .type)"
        kv "País" "$(j "$w" .country) ($(j "$w" .country_code))"
        kv "Capital" "$(j "$w" .capital)"
        kv "Região" "$(j "$w" .region)"
        kv "Cidade" "$(j "$w" .city)"
        kv "CEP" "$(j "$w" .postal)"
        kv "Coordenadas" "$(j "$w" .latitude), $(j "$w" .longitude)"
        v="$(j "$w" .calling_code)"; [[ -n "$v" ]] && v="+$v"
        kv "DDI" "$v"
        kv "União Europeia" "$(yn "$(j "$w" .is_eu)")"
        kv "ASN" "$(j "$w" .connection.asn)"
        kv "Organização" "$(j "$w" .connection.org)"
        kv "ISP" "$(j "$w" .connection.isp)"
        kv "Domínio" "$(j "$w" .connection.domain)"
        kv "Fuso" "$(j "$w" .timezone.id)"
        kv "UTC" "$(j "$w" .timezone.utc)"
        kv "Hora local no alvo" "$(j "$w" .timezone.current_time)"
    fi
}

do_idb() {
    local ip="$T_IP" raw code body x n
    title "SHODAN INTERNETDB (portas, CVEs e tags - sem scan, sem chave)"
    if [[ "$ip" == *:* ]]; then out_line "  InternetDB: somente IPv4." yellow; return; fi
    if is_private "$ip"; then out_line "  IP privado: não se aplica." yellow; return; fi
    raw="$(curl -sS -L -m 15 -A "$UA" -w $'\n%{http_code}' "https://internetdb.shodan.io/$ip" 2>&1)"
    code="${raw##*$'\n'}"; body="${raw%$'\n'*}"
    if [[ "$code" == "404" ]]; then
        out_line "  Sem informações no índice da Shodan (isso não significa que o IP esteja limpo)." yellow
        return
    fi
    if [[ "$code" != "200" ]] || ! printf '%s' "$body" | jq -e . >/dev/null 2>&1; then
        out_line "  Falha ao consultar a InternetDB: HTTP $code $body" red
        return
    fi
    kv "Portas abertas" "$(j "$body" '(.ports // []) | sort | join(", ")')"
    kv "Hostnames" "$(j "$body" '(.hostnames // []) | map(select(. != null and . != "")) | join(", ")')"
    kv "Tags" "$(j "$body" '(.tags // []) | map(select(. != null and . != "")) | join(", ")')"
    while IFS= read -r x; do [[ -n "$x" ]] && kv "Software (CPE)" "$x"; done \
        < <(printf '%s' "$body" | jq -r '(.cpes // [])[]? | select(. != null and . != "")' 2>/dev/null)
    n="$(j "$body" '(.vulns // []) | length')"
    kv "CVEs conhecidas" "${n:-0}"
    while IFS= read -r x; do
        [[ -n "$x" ]] && out_line "    $x  https://nvd.nist.gov/vuln/detail/$x" red
    done < <(printf '%s' "$body" | jq -r '(.vulns // [])[]? | select(. != null and . != "")' 2>/dev/null)
    out_line "  Obs: dados atualizados semanalmente; CVEs são inferidas pela versão do serviço (podem ser falsos positivos)." darkgray
}

do_rdap() {
    local ip="$T_IP" r="" u k v role info
    title "WHOIS / RDAP (registro do bloco de IP)"
    if is_private "$ip"; then out_line "  IP privado: sem registro público." yellow; return; fi
    for u in "https://rdap.org/ip/$ip" "https://rdap.lacnic.net/rdap/ip/$ip" \
             "https://rdap.arin.net/registry/ip/$ip" "https://rdap.db.ripe.net/ip/$ip" \
             "https://rdap.apnic.net/ip/$ip"; do
        r="$(get_json "$u")"
        if [[ -n "$r" && -n "$(j "$r" .handle)" ]]; then break; fi
        r=""
    done
    if [[ -z "$r" ]]; then out_line "  Falha ao consultar RDAP: $LAST_ERR" red; return; fi
    kv "Nome da rede" "$(j "$r" .name)"
    kv "Handle" "$(j "$r" .handle)"
    kv "Faixa de IPs" "$(j "$r" .startAddress) - $(j "$r" .endAddress)"
    kv "CIDR" "$(j "$r" '[.cidr0_cidrs[]? | ((.v4prefix // .v6prefix) + "/" + (.length | tostring))] | join(", ")')"
    kv "Tipo" "$(j "$r" .type)"
    kv "País" "$(j "$r" .country)"
    kv "Bloco pai" "$(j "$r" .parentHandle)"
    kv "Status" "$(j "$r" '(.status // []) | if type == "array" then join(", ") else . end')"
    while IFS=$'\t' read -r k v; do
        [[ -n "$k" ]] && kv "Evento: $k" "$v"
    done < <(printf '%s' "$r" | jq -r '.events[]? | [.eventAction, .eventDate] | @tsv' 2>/dev/null)
    while IFS=$'\t' read -r role info; do
        [[ -z "$role$info" ]] && continue
        kv "Contato [$role]" "$info"
    done < <(printf '%s' "$r" | jq -r '
        def vc($t): first(.vcardArray[1][]? | select(.[0] == $t) | .[3]) // empty;
        .entities[]? | [ ((.roles // []) | join(",")),
                         ([ (vc("fn")), (vc("email")), (vc("tel")) ] | map(tostring) | join(" | ")) ] | @tsv' 2>/dev/null)
    while IFS= read -r v; do
        [[ -n "$v" ]] && kv "Observação" "$v"
    done < <(printf '%s' "$r" | jq -r '.remarks[]? | select(.description) | (.description | if type == "array" then join(" ") else tostring end)' 2>/dev/null)
}

do_dns() {
    local ip="$T_IP" ptr type x
    title "DNS"
    if have dig; then ptr="$(dig +short +time=3 +tries=1 -x "$ip" 2>/dev/null | head -n1)"
    elif have host; then ptr="$(host -W 3 "$ip" 2>/dev/null | awk '/pointer/{print $NF; exit}')"
    elif have getent; then ptr="$(getent hosts "$ip" 2>/dev/null | awk '{print $2; exit}')"
    fi
    kv "Hostname (PTR)" "${ptr:-Sem registro PTR}"
    if [[ "$T_INPUT" != "$ip" ]]; then
        out_line "  Domínio informado: $T_INPUT" gray
        if ! have dig && ! have host; then
            out_line "  Instale 'dig' (dnsutils/bind-tools) ou 'host' para consultar registros." yellow
            return
        fi
        for type in A AAAA MX NS TXT CNAME; do
            while IFS= read -r x; do
                [[ -n "$x" ]] && kv "Registro $type" "$x"
            done < <(dns_q "$type" "$T_INPUT")
        done
    fi
}

do_ping() {
    local ip="$T_IP" i out t x ttl="" times=() recv=0 lost wopt pcmd
    title "PING / LATÊNCIA / TTL"
    if ! have ping; then out_line "  'ping' não instalado." red; return; fi
    wopt="2"; [[ "$(uname)" == "Darwin" ]] && wopt="2000"
    pcmd=(ping)
    [[ "$ip" == *:* ]] && have ping6 && pcmd=(ping6)
    for i in 1 2 3 4 5; do
        out="$("${pcmd[@]}" -c 1 -W "$wopt" "$ip" 2>&1)"
        t="$(printf '%s' "$out" | sed -nE 's/.*time[=<]([0-9.]+) *ms.*/\1/p' | head -n1)"
        if [[ -n "$t" ]]; then
            times+=("$t"); recv=$((recv + 1))
            x="$(printf '%s' "$out" | sed -nE 's/.*[Tt][Tt][Ll]=([0-9]+).*/\1/p' | head -n1)"
            [[ -n "$x" ]] && ttl="$x"
            out_line "  Resposta de ${ip}: tempo=${t}ms TTL=${ttl:-N/D}" green
        else
            out_line "  Sem resposta / tempo esgotado" yellow
        fi
    done
    lost=$((5 - recv))
    kv "Pacotes" "enviados=5, recebidos=$recv, perdidos=$lost ($((lost * 20))%)"
    if (( recv > 0 )); then
        kv "Latência mín/média/máx" "$(printf '%s\n' "${times[@]}" | awk 'NR==1{mn=mx=$1} {s+=$1; if($1<mn)mn=$1; if($1>mx)mx=$1} END{printf "%s / %.1f / %s ms", mn, s/NR, mx}')"
        if [[ -n "$ttl" ]]; then
            local os
            if   (( ttl <= 64 ));  then os="Linux/Unix/Android/macOS/iOS (TTL inicial 64)"
            elif (( ttl <= 128 )); then os="Windows (TTL inicial 128)"
            else os="Roteador/dispositivo de rede (TTL inicial 255)"; fi
            kv "SO provável (estimativa)" "$os"
        fi
    else
        out_line "  Sem resposta ICMP (host offline ou ICMP bloqueado)." yellow
    fi
}

do_trace() {
    local ip="$T_IP" line cmd=()
    title "TRACEROUTE (até 15 saltos)"
    if have traceroute; then cmd=(traceroute -n -m 15 -w 1 "$ip")
    elif have tracepath; then cmd=(tracepath -n -m 15 "$ip")
    elif have mtr; then cmd=(mtr -n -r -c 1 -m 15 "$ip")
    else
        out_line "  Nenhum utilitário de traceroute encontrado (instale: traceroute)." yellow
        return
    fi
    while IFS= read -r line; do
        [[ -n "${line//[[:space:]]/}" ]] && out_line "  $line" gray
    done < <("${cmd[@]}" 2>&1)
}

tcp_open() {
    local ip="$1" p="$2"
    if have timeout; then
        timeout 3 bash -c "exec 3<>/dev/tcp/$ip/$p" >/dev/null 2>&1
    elif have nc; then
        nc -z -w 3 "$ip" "$p" >/dev/null 2>&1
    else
        bash -c "exec 3<>/dev/tcp/$ip/$p" >/dev/null 2>&1
    fi
}

do_ports() {
    local ip="$T_IP" tmp entry p name open=0 total=0
    local list="21:FTP 22:SSH 23:Telnet 25:SMTP 53:DNS 80:HTTP 110:POP3 111:RPC 135:MSRPC 139:NetBIOS 143:IMAP 443:HTTPS 445:SMB 465:SMTPS 587:SMTP-Submission 993:IMAPS 995:POP3S 1433:MSSQL 1723:PPTP 2082:cPanel 3306:MySQL 3389:RDP 5432:PostgreSQL 5900:VNC 6379:Redis 8080:HTTP-Alt 8443:HTTPS-Alt 27017:MongoDB"
    title "SCAN DE PORTAS COMUNS (TCP)"
    tmp="$(mktemp -d 2>/dev/null || echo "/tmp/ghost_$$")"; mkdir -p "$tmp"
    for entry in $list; do
        p="${entry%%:*}"; total=$((total + 1))
        ( tcp_open "$ip" "$p" && : > "$tmp/$p" ) &
    done
    wait
    for entry in $list; do
        p="${entry%%:*}"; name="${entry#*:}"
        if [[ -e "$tmp/$p" ]]; then
            out_line "$(printf '  %-6s ABERTA   %s' "$p" "$name")" green
            open=$((open + 1))
        fi
    done
    rm -rf "$tmp"
    out_line "  Portas abertas: $open de $total testadas (fechadas/filtradas omitidas)." gray
}

do_headers() {
    local ip="$T_IP" h u hdrs first line k v
    title "CABEÇALHOS HTTP/HTTPS"
    h="$(url_host "$ip")"
    for u in "http://$h" "https://$h"; do
        out_line "  -> $u" yellow
        hdrs="$(curl -sk -m 7 -A "$UA" -D - -o /dev/null "$u" 2>/dev/null | tr -d '\r')"
        if [[ -z "$hdrs" ]]; then out_line "     Sem resposta." darkgray; continue; fi
        first="$(printf '%s\n' "$hdrs" | head -n1)"
        v="$(printf '%s' "$first" | sed -E 's/^HTTP\/[0-9.]+ +//')"
        kv "Status" "$v"
        while IFS= read -r line; do
            [[ "$line" == *:* ]] || continue
            k="${line%%:*}"; v="${line#*:}"; v="${v# }"
            kv "$k" "$v"
        done < <(printf '%s\n' "$hdrs" | tail -n +2)
    done
}

do_blacklist() {
    local ip="$T_IP" rev z res listed=0 o1 o2 o3 o4
    title "REPUTAÇÃO - BLACKLISTS DNSBL"
    if [[ "$ip" == *:* ]]; then out_line "  DNSBL: somente IPv4 suportado." yellow; return; fi
    if is_private "$ip"; then out_line "  IP privado: não se aplica." yellow; return; fi
    if ! have dig && ! have host && ! have getent; then
        out_line "  Instale 'dig' ou 'host' para consultar DNSBLs." yellow; return
    fi
    IFS=. read -r o1 o2 o3 o4 <<<"$ip"
    rev="$o4.$o3.$o2.$o1"
    for z in zen.spamhaus.org bl.spamcop.net b.barracudacentral.org dnsbl-1.uceprotect.net psbl.surriel.com dnsbl.dronebl.org; do
        res="$(dns_q A "$rev.$z" | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' | head -n1)"
        if [[ -n "$res" ]]; then
            if [[ "$res" == 127.255.255.* ]]; then
                out_line "$(printf '  %-26s INCONCLUSIVO (consulta recusada)' "$z")" yellow
            else
                out_line "$(printf '  %-26s LISTADO (%s)' "$z" "$res")" red
                listed=$((listed + 1))
            fi
        else
            out_line "$(printf '  %-26s limpo' "$z")" green
        fi
    done
    kv "Listas que listam o IP" "$listed"
}

do_links() {
    local ip="$T_IP" names=() urls=() i=1 n
    names=(AbuseIPDB Shodan Censys VirusTotal GreyNoise IPinfo "BGP HE" "Cisco Talos")
    urls=("https://www.abuseipdb.com/check/$ip" "https://www.shodan.io/host/$ip"
          "https://search.censys.io/hosts/$ip" "https://www.virustotal.com/gui/ip-address/$ip"
          "https://viz.greynoise.io/ip/$ip" "https://ipinfo.io/$ip"
          "https://bgp.he.net/ip/$ip" "https://talosintelligence.com/reputation_center/lookup?search=$ip")
    if [[ -n "$T_LAT" ]]; then names+=("Google Maps"); urls+=("https://www.google.com/maps?q=$T_LAT,$T_LON"); fi
    title "FONTES EXTERNAS"
    for n in "${!names[@]}"; do
        out_line "$(printf '  [%s] %-12s %s' "$i" "${names[$n]}" "${urls[$n]}")" white
        i=$((i + 1))
    done
    echo
    read -r -p "  Número para abrir no navegador (T = todos, ENTER = voltar): " n
    if [[ "$n" =~ ^[tT]$ ]]; then
        for i in "${!urls[@]}"; do open_url "${urls[$i]}"; done
    elif [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#urls[@]} )); then
        open_url "${urls[$((n - 1))]}"
    fi
}

save_report() {
    local dir="$BATDIR/relatorios" safe f
    mkdir -p "$dir" 2>/dev/null
    [[ -w "$dir" ]] || { dir="$HOME/relatorios"; mkdir -p "$dir" 2>/dev/null; }
    safe="${T_IP//[^0-9a-fA-F.]/_}"
    f="$dir/ip_${safe}_$(date +%Y%m%d_%H%M%S).txt"
    if printf '%s\n' "${REPORT[@]}" > "$f" 2>/dev/null; then
        printf '%s  Relatório salvo em: %s%s\n' "$(color_code green)" "$f" "$RST"
    else
        printf '%s  Não foi possível salvar o relatório.%s\n' "$(color_code red)" "$RST"
    fi
}

do_all() {
    need_target || return
    local scan=0
    confirm_scan && scan=1
    REPORT=()
    out_line "RELATÓRIO GHOST PANEL - $(date '+%d/%m/%Y %H:%M:%S')" yellow
    kv "Alvo informado" "$T_INPUT"
    kv "IP analisado" "$T_IP"
    do_geo; do_idb; do_rdap; do_dns; do_ping; do_blacklist; do_headers
    (( scan )) && do_ports
    do_trace
    out_line ""
    save_report
}

show_menu() {
    clear
    local C Y G D alvo
    C="$(color_code cyan)"; Y="$(color_code yellow)"; G="$(color_code green)"; D="$(color_code darkgray)"
    echo
    printf '%s  ==============================================%s\n' "$C" "$RST"
    printf '%s                GHOST PANEL  v1.0%s\n' "$Y" "$RST"
    printf '%s  ==============================================%s\n' "$C" "$RST"
    if [[ -n "$T_IP" ]]; then alvo="$T_INPUT  [$T_IP]"; else alvo="(nenhum)"; fi
    printf '%s  Alvo atual: %s%s\n' "$G" "$alvo" "$RST"
    printf '%s  ----------------------------------------------%s\n' "$D" "$RST"
    echo "   1  Definir alvo (IP ou domínio)"
    echo "   2  Usar meu IP público"
    printf '%s   3  RELATÓRIO COMPLETO (tudo + salvar .txt)%s\n' "$Y" "$RST"
    echo "   4  Geolocalização e rede (2 fontes)"
    echo "   5  WHOIS / RDAP"
    echo "   6  DNS / reverso / registros"
    echo "   7  Ping, latência e TTL"
    echo "   8  Traceroute"
    echo "   9  Scan de portas comuns"
    echo "  10  Cabeçalhos HTTP/HTTPS"
    echo "  11  Reputação (blacklists)"
    echo "  12  Links externos (Shodan, AbuseIPDB, Maps...)"
    echo "  13  Salvar saída atual em .txt"
    printf '%s  14  Shodan InternetDB (portas/CVEs sem scan)%s\n' "$Y" "$RST"
    echo "   0  Sair"
    printf '%s  ----------------------------------------------%s\n' "$D" "$RST"
}

check_deps() {
    local miss=()
    have curl || miss+=(curl)
    have jq   || miss+=(jq)
    if (( ${#miss[@]} )); then
        printf '%sFaltando dependências: %s%s\n' "$(color_code red)" "${miss[*]}" "$RST"
        echo "Instale com:"
        echo "  Termux : pkg install ${miss[*]}"
        echo "  Debian : sudo apt install ${miss[*]}"
        echo "  Arch   : sudo pacman -S ${miss[*]}"
        echo "  macOS  : brew install ${miss[*]}"
        exit 1
    fi
}

main() {
    check_deps
    trap 'echo; exit 0' INT
    local op t m
    while true; do
        show_menu
        read -r -p "  Opção: " op || exit 0
        op="${op//[[:space:]]/}"
        case "$op" in
            0)  clear; exit 0 ;;
            1)  read -r -p "  IP ou domínio: " t
                set_target "$t" && printf '%s  Alvo definido: %s%s\n' "$(color_code green)" "$T_IP" "$RST"
                wait_key ;;
            2)  m="$(get_json 'https://api.ipify.org?format=json')"; m="$(j "$m" .ip)"
                if [[ -n "$m" ]] && set_target "$m"; then
                    printf '%s  Seu IP público: %s%s\n' "$(color_code green)" "$m" "$RST"
                else
                    printf '%s  Não foi possível obter seu IP.%s\n' "$(color_code red)" "$RST"
                fi
                wait_key ;;
            3)  do_all; wait_key ;;
            4)  need_target && { REPORT=(); do_geo; }; wait_key ;;
            5)  need_target && { REPORT=(); do_rdap; }; wait_key ;;
            6)  need_target && { REPORT=(); do_dns; }; wait_key ;;
            7)  need_target && { REPORT=(); do_ping; }; wait_key ;;
            8)  need_target && { REPORT=(); do_trace; }; wait_key ;;
            9)  need_target && confirm_scan && { REPORT=(); do_ports; }; wait_key ;;
            10) need_target && { REPORT=(); do_headers; }; wait_key ;;
            11) need_target && { REPORT=(); do_blacklist; }; wait_key ;;
            12) need_target && do_links; wait_key ;;
            13) if [[ -n "$T_IP" && ${#REPORT[@]} -gt 0 ]]; then save_report
                else printf '%s  Nada para salvar ainda.%s\n' "$(color_code yellow)" "$RST"; fi
                wait_key ;;
            14) need_target && { REPORT=(); do_idb; }; wait_key ;;
            *)  printf '%s  Opção inválida.%s\n' "$(color_code red)" "$RST"; sleep 1 ;;
        esac
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
