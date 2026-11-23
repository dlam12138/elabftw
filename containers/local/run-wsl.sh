#!/usr/bin/env bash
set -euo pipefail
umask 077

runtime="${XDG_DATA_HOME:-$HOME/.local/share}/elabftw-local"
state="$runtime/run"
lock="$state/service.lock"
url=https://127.0.0.1:8080
cert="$runtime/tls/cert.pem"
action=${1:-status}

fail() {
    printf '%s\n' "$*" >&2
    exit 1
}

running() {
    [[ -f "$lock" ]] && ! flock -n "$lock" true
}

healthy() {
    local body
    body=$(curl --noproxy '*' --cacert "$cert" --fail --silent --max-time 3 "$url/healthcheck.php") &&
        [[ "$body" == ok ]]
}

case "$action" in
    status|probe)
        if running; then
            if healthy; then
                [[ "$action" == probe ]] || printf 'Running at %s\n' "$url"
                exit 0
            fi
            [[ "$action" == probe ]] || printf 'Starting or unhealthy. See %s/logs.\n' "$runtime"
            exit 2
        fi
        [[ "$action" == probe ]] || printf 'Stopped\n'
        exit 1
        ;;
    stop)
        if ! running; then
            printf 'Stopped\n'
            exit 0
        fi
        read -r pid started < "$state/supervisor" || fail "Supervisor has not recorded its process yet."
        [[ "$pid" =~ ^[1-9][0-9]*$ && "$started" =~ ^[0-9]+$ ]] ||
            fail "Invalid supervisor record."
        [[ "$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null)" == "$started" ]] ||
            fail "Supervisor process no longer matches its record."
        kill -TERM "$pid"
        flock -w 50 "$lock" true || fail "Timed out waiting for shutdown. See $runtime/logs."
        printf 'Stopped\n'
        exit 0
        ;;
    run) ;;
    *) fail "Use run, status, or stop." ;;
esac

mkdir -p "$state" "$runtime"/{cache,exports,logs,mysql,secrets,uploads} "$state/mysql/mysqld"
exec 9>"$lock"
flock -n 9 || fail "This eLabFTW instance already has a supervisor."
exec >> "$runtime/logs/service.log" 2>&1
printf '\nStarting eLabFTW at %s\n' "$(date -Is)"
printf '%s %s\n' "$$" "$(awk '{print $22}' "/proc/$$/stat")" > "$state/supervisor"

bwrap="$runtime/tools/bwrap"
app_root="$runtime/images/elabftw"
db_root="$runtime/images/mysql"
secrets="$runtime/secrets"
[[ -x "$bwrap" && -x "$app_root/init" && -x "$db_root/usr/sbin/mysqld" ]] ||
    fail "Prepared OCI runtime files are missing. See containers/local/README.md."

for image in "$app_root" "$db_root"; do
    for file in hosts resolv.conf; do
        [[ -e "$image/etc/$file" ]] || touch "$image/etc/$file"
    done
done
mkdir -p "$app_root/var/cache/elabftw" "$app_root/var/lib/elabftw/"{uploads,exports}
[[ -e "$app_root/.dockerenv" ]] || touch "$app_root/.dockerenv"

base=(
    --clearenv --setenv PATH /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    --setenv HOME /tmp --unshare-user --unshare-pid --as-pid-1 --die-with-parent
)
app=(
    "${base[@]}" --uid 1000 --gid 1000 --ro-bind "$app_root" /
    --dev /dev --proc /proc --tmpfs /run --tmpfs /tmp
    --ro-bind /etc/hosts /etc/hosts --ro-bind /etc/resolv.conf /etc/resolv.conf
    --chdir /elabftw
)
db=(
    "${base[@]}" --uid 999 --gid 999 --ro-bind "$db_root" /
    --dev /dev --proc /proc --tmpfs /tmp
    --ro-bind /etc/hosts /etc/hosts --ro-bind /etc/resolv.conf /etc/resolv.conf
    --bind "$runtime/mysql" /var/lib/mysql --bind "$state/mysql" /run
)

if [[ -d "$runtime/mysql/mysql" ]]; then
    [[ -s "$secrets/root" && -s "$secrets/db" && -s "$secrets/key" ]] ||
        fail "The initialized database needs its original files from $secrets."
fi
for file in root db; do
    if [[ ! -e "$secrets/$file" ]]; then
        openssl rand -hex 32 > "$secrets/$file.new"
        mv -T "$secrets/$file.new" "$secrets/$file"
    fi
    [[ $(<"$secrets/$file") =~ ^[0-9a-f]{64}$ ]] || fail "Invalid password file $secrets/$file."
done
if [[ ! -e "$secrets/key" ]]; then
    "$bwrap" "${app[@]}" -- /usr/bin/php84 -r \
        'require "vendor/autoload.php"; echo \Defuse\Crypto\Key::createNewRandomKey()->saveToAsciiSafeString();' \
        > "$secrets/key.new"
    mv -T "$secrets/key.new" "$secrets/key"
fi
[[ $(<"$secrets/key") =~ ^[0-9a-f]{136}$ ]] || fail "Invalid application key file $secrets/key."
printf '[client]\nuser=root\npassword=%s\n' "$(<"$secrets/root")" > "$secrets/root.cnf"

if [[ ! -e "$runtime/tls" ]]; then
    tls_stage=$(mktemp -d "$runtime/.tls.XXXXXXXX")
    openssl req -x509 -newkey rsa:2048 -noenc -sha256 -days 825 -subj '/CN=localhost' \
        -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1' \
        -keyout "$tls_stage/key.pem" -out "$tls_stage/cert.pem"
    mv -T "$tls_stage" "$runtime/tls"
fi
[[ -s "$cert" && -s "$runtime/tls/key.pem" ]] || fail "TLS certificate or key is missing."

sed 's/^[[:space:]]*listen 8080 ssl default_server;/    listen 127.0.0.1:8080 ssl default_server;/' \
    "$app_root/etc/nginx/https.conf" > "$state/https.conf"
[[ $(grep -Ec '^[[:space:]]*listen[[:space:]]' "$state/https.conf") == 1 ]] &&
    grep -q 'listen 127.0.0.1:8080 ssl default_server;' "$state/https.conf" ||
    fail "The nginx image template has an unexpected listener configuration."

sed 's@127\.0\.0\.1:9000@unix:/run/php/fpm.sock@g' \
    "$app_root/etc/nginx/common.conf.tpl" > "$state/common.conf"
sed -e 's@^listen = 127\.0\.0\.1:9000$@listen = /run/php/fpm.sock@' \
    -e '/^listen.allowed_clients =/d' \
    "$app_root/etc/php84/php-fpm.d/elabpool.conf.tpl" > "$state/elabpool.conf"
grep -q 'fastcgi_pass.*unix:/run/php/fpm.sock;' "$state/common.conf" &&
    grep -qx 'listen = /run/php/fpm.sock' "$state/elabpool.conf" ||
    fail "The image has unexpected PHP-FPM templates."

# The two credential values are validated hex strings. Feed sed through stdin.
awk '
    index($0, "s/%DB_PASSWORD%/") {
        print "    printf \"s/%%DB_PASSWORD%%/%s/\\n\" \"$db_password\" | sed -i -f - \"$f\""
        db++
        next
    }
    index($0, "s/%SECRET_KEY%/") {
        print "    printf \"s/%%SECRET_KEY%%/%s/\\n\" \"$secret_key\" | sed -i -f - \"$f\""
        key++
        next
    }
    { print }
    END { if (db != 1 || key != 1) exit 1 }
' "$app_root/usr/sbin/docker-entrypoint.sh" > "$state/docker-entrypoint.sh" ||
    fail "The image has an unexpected credential template."
chmod 700 "$state/docker-entrypoint.sh"

[[ -z "$(ss -H -ltn '( sport = :8080 or sport = :13306 )')" ]] ||
    fail "A required WSL port (8080 or 13306) is already in use."

mysql_client=(
    "${db[@]}" --ro-bind "$secrets/root.cnf" /run/local-root.cnf
)
query_db() {
    timeout 4s "$bwrap" "${mysql_client[@]}" -- /usr/bin/mysql \
        --defaults-extra-file=/run/local-root.cnf --socket=/run/mysqld/mysql.sock \
        --batch --skip-column-names --execute "$1"
}

reap() {
    local job=$1
    if ! timeout 10s tail --pid="$job" -f /dev/null; then
        printf 'Process %s exceeded its shutdown deadline.\n' "$job"
        kill -KILL "$job" 2>/dev/null || true
    fi
    wait "$job" || true
}

db_job=
web_job=
shutdown() {
    if [[ -n "$web_job" ]] && kill -0 "$web_job" 2>/dev/null; then
        local child
        child=$(sed -nE 's/.*"child-pid":[[:space:]]*([0-9]+).*/\1/p' "$state/web.info" 2>/dev/null || true)
        if [[ "$child" =~ ^[1-9][0-9]*$ ]] &&
            [[ "$(ps -o ppid= -p "$child" | tr -d ' ')" == "$web_job" ]]; then
            kill -TERM "$child" 2>/dev/null || true
        else
            kill -TERM "$web_job" 2>/dev/null || true
        fi
        reap "$web_job"
    fi
    if [[ -n "$db_job" ]] && kill -0 "$db_job" 2>/dev/null; then
        if ! timeout 20s "$bwrap" "${mysql_client[@]}" \
            -- /usr/bin/mysqladmin --defaults-extra-file=/run/local-root.cnf \
            --socket=/run/mysqld/mysql.sock shutdown; then
            kill -TERM "$db_job" 2>/dev/null || true
        fi
        reap "$db_job"
    fi
}
trap shutdown EXIT
trap 'exit 0' TERM INT

"$bwrap" "${db[@]}" --ro-bind "$secrets/root" /run/local-root \
    --ro-bind "$secrets/db" /run/local-db \
    --setenv MYSQL_ROOT_PASSWORD_FILE /run/local-root --setenv MYSQL_PASSWORD_FILE /run/local-db \
    --setenv MYSQL_DATABASE elabftw --setenv MYSQL_USER elabftw \
    -- /usr/local/bin/docker-entrypoint.sh mysqld --bind-address=127.0.0.1 --port=13306 \
    --mysqlx=OFF --socket=/run/mysqld/mysql.sock --pid-file=/run/mysqld/mysql.pid \
    >> "$runtime/logs/mysql.log" 2>&1 &
db_job=$!

deadline=$((SECONDS + 75))
until [[ $(query_db 'SELECT @@port' 2>/dev/null || true) == 13306 ]]; do
    (( SECONDS < deadline )) && kill -0 "$db_job" 2>/dev/null ||
        fail "MySQL did not become ready. See $runtime/logs/mysql.log."
    sleep 1
done

auto_init=false
tables=$(query_db "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'elabftw'")
case "$tables" in
    0) auto_init=true ;;
    104)
        # The pinned image's install ends by seeding all four branding IDs.
        complete=$(query_db 'SELECT EXISTS(SELECT 1 FROM elabftw.config) AND
            EXISTS(SELECT 1 FROM elabftw.teams) AND
            (SELECT COUNT(*) FROM elabftw.branding WHERE id IN (1, 2, 3, 4)) = 4')
        [[ "$complete" == 1 ]] || fail "Database initialization is incomplete. Use a known-good backup."
        ;;
    *) fail "Expected an empty database or the complete 104-table schema, found $tables tables." ;;
esac
printf 'MySQL is ready with %s application tables. Automatic initialization %s.\n' "$tables" "$auto_init"

"$bwrap" "${app[@]}" --info-fd 3 --ro-bind "$state/https.conf" /etc/nginx/https.conf \
    --ro-bind "$state/common.conf" /etc/nginx/common.conf.tpl \
    --ro-bind "$state/elabpool.conf" /etc/php84/php-fpm.d/elabpool.conf.tpl \
    --ro-bind "$state/docker-entrypoint.sh" /usr/sbin/docker-entrypoint.sh \
    --ro-bind "$runtime/tls" /run/local-tls \
    --ro-bind "$secrets/db" /run/local-db --ro-bind "$secrets/key" /run/local-key \
    --bind "$runtime/cache" /var/cache/elabftw \
    --bind "$runtime/uploads" /var/lib/elabftw/uploads --bind "$runtime/exports" /var/lib/elabftw/exports \
    --setenv S6_READ_ONLY_ROOT 1 --setenv S6_BEHAVIOUR_IF_STAGE2_FAILS 2 \
    --setenv ELABFTW_VERSION 261123-d8a796a --setenv TZ Asia/Shanghai --setenv PHP_TIMEZONE Asia/Shanghai \
    --setenv SITE_URL "$url" --setenv TLS_CERT_PATH /run/local-tls/cert.pem \
    --setenv TLS_KEY_PATH /run/local-tls/key.pem \
    --setenv DB_HOST 127.0.0.1 --setenv DB_PORT 13306 --setenv DB_USER elabftw --setenv DB_NAME elabftw \
    --setenv AUTO_DB_INIT "$auto_init" --setenv AUTO_DB_UPDATE false \
    --setenv PUBCHEM_PUG_URL https://pubchem.ncbi.nlm.nih.gov/rest/pug \
    --setenv PUBCHEM_PUG_VIEW_URL https://pubchem.ncbi.nlm.nih.gov/rest/pug_view/data \
    -- /bin/sh -c 'export DB_PASSWORD="$(cat /run/local-db)" SECRET_KEY="$(cat /run/local-key)"; exec /init' \
    3>"$state/web.info" >> "$runtime/logs/web.log" 2>&1 &
web_job=$!

wait -n "$db_job" "$web_job" || true
fail "An instance process exited. See $runtime/logs."
