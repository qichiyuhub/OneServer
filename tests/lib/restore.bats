#!/usr/bin/env bats
#
# script/ops/restore.sh —— 归档落点与覆盖前副本
#
# manifest 记录的是备份源，不是恢复落点。这组用例从主流程入口钉住两者的
# 分界：落点必须来自本机 state 或显式 --into，数据库与文件不能再写回归档
# 自称的名字。所有系统副作用都换成记录桩，测试不会碰真实 MySQL、归档或站点。

setup() {
    load "${BATS_TEST_DIRNAME}/../helper/load.sh"
    RESTORE="${OS_TEST_REPO_ROOT}/script/ops/restore.sh"
    STUB="${BATS_TEST_TMPDIR}/restore-stub.sh"
    TRACE="${BATS_TEST_TMPDIR}/trace"

    # 与真实脚本只差 bootstrap 装配和入口；入口形态改变时必须让测试显式失败。
    [ "$(tail -n 1 "${RESTORE}")" = 'main "$@"' ]
    sed -e '/^source \/opt\/oneserver\/lib\/bootstrap\.sh$/d' -e '$d' \
        "${RESTORE}" >"${STUB}"
}

restore_run() {
    run bash -c "
        source '${OS_TEST_REPO_ROOT}/lib/bootstrap.sh'
        source '${STUB}'
        TRACE='${TRACE}'
        TEST_TMP='${BATS_TEST_TMPDIR}'
        $1
    "
}

# 跑一条完整的本地归档恢复。归档固定叫 site:wordpress，参数决定本机落点；
# 第五个参数为空表示不提供 --into，用来覆盖同名回滚的既有默认行为。
archive_main_run() {
    local dest_name=${1} dest_db=${2} dest_dir=${3} archive_dir=${4} into=${5-}
    local mode=${6:-all} only=${7-}
    mkdir -p "${dest_dir}"
    printf "%s\n" \
        "define( 'DB_NAME', 'old_db' );" \
        "define( 'DB_USER', 'old_user' );" \
        "define( 'DB_PASSWORD', 'old_pass' );" \
        "define( 'DB_HOST', 'old_host' );" >"${dest_dir}/wp-config.php"

    local into_arg=''
    [[ -z ${into} ]] || into_arg="OS_ARG_MAP[into]='${into}'"

    restore_run "
        OS_NON_INTERACTIVE=1
        OS_FORCE_DESTROY=1
        OS_ARG_MAP[from]=local
        OS_ARG_MAP[target]='site:wordpress'
        OS_ARG_MAP[file]='20260812-010203.tar.gz'
        OS_ARG_MAP[mode]='${mode}'
        OS_ARG_MAP[only]='${only}'
        OS_ARG_MAP[site-url]=''
        ${into_arg}

        os::require_cmd() { return 0; }
        local_targets() { RS_ENTRIES='site:wordpress'; }
        local_archives() { RS_ENTRIES='20260812-010203.tar.gz'; }
        archive_desc() { printf '%s' 'test archive'; }
        fetch_archive() { RS_ARCHIVE=\"\${TEST_TMP}/archive.tar.gz\"; }
        verify_archive() { return 0; }
        read_manifest() {
            RS_MF_TYPE=site
            RS_MF_NAME=wordpress
            RS_MF_SOURCE='${archive_dir}'
            RS_MF_ROOT=wordpress
            RS_MF_DB=wp_wordpress
            RS_MF_CREATED=2026-08-12T01:02:03Z
            RS_MF_HOST=source-host
            RS_MF_SITE_TYPE=wordpress
        }

        os::state_has() { [[ \"\${1}\" == 'wordpress:${dest_name}' ]]; }
        os::state_list() {
            [[ \"\${1}\" == wordpress ]] && printf '%s\\n' 'wordpress:${dest_name}'
        }
        os::state_get() {
            case \"\${1}|\${2}\" in
                'wordpress:${dest_name}|path') printf '%s' '${dest_dir}' ;;
                'wordpress:${dest_name}|db') printf '%s' '${dest_db}' ;;
                'wordpress:${dest_name}|db_user') printf '%s' '${dest_name}_user' ;;
                'wordpress:${dest_name}|db_host') printf '%s' localhost ;;
                *) printf '%s' \"\${3-}\" ;;
            esac
        }
        os::secure_load() {
            printf 'SECURE=%s\\n' \"\${1}\" >>\"\${TRACE}\"
            printf -v \"\${2}\" '%s' local-secret
        }
        probe::component_version() { OS_PROBE_VALUE=''; }

        os::tmpdir() {
            mkdir -p \"\${TEST_TMP}/work\"
            printf -v \"\${1}\" '%s' \"\${TEST_TMP}/work\"
        }
        os::query() {
            printf 'QUERY=%s\\n' \"\$*\" >>\"\${TRACE}\"
            printf '%s\\n' dump >\"\${TEST_TMP}/work/database.sql\"
            OS_RUN_OUTPUT=''
            return 0
        }
        os::run() {
            printf 'RUN=%s\\n' \"\$*\" >>\"\${TRACE}\"
            return 0
        }
        os::sql_exec() {
            printf 'SQL=%s\\n' \"\${3}\" >>\"\${TRACE}\"
            return 0
        }
        restore_files() {
            printf 'FILES=%s|%s|%s|%s\\n' \"\$1\" \"\$2\" \"\$3\" \"\$4\" >>\"\${TRACE}\"
            return 0
        }
        os::replace_line() {
            printf 'REPLACE=%s\\n' \"\$*\" >>\"\${TRACE}\"
            return 0
        }
        os::record_change() { return 0; }
        os::destroy_confirm() {
            printf 'CONFIRM=%s\\n' \"\${3}\" >>\"\${TRACE}\"
            return 0
        }
        os::critical_begin() { return 0; }
        os::critical_end() { return 0; }
        os::output() { return 0; }
        post_restore_hints() { return 0; }
        ex_check_prefix() { return 0; }

        main
    "
}

@test "归档站不在 state：以 3 停下且不调用 tar 或 mysql" {
    restore_run '
        OS_NON_INTERACTIVE=1
        OS_ARG_MAP[from]=local
        OS_ARG_MAP[target]="site:wordpress"
        OS_ARG_MAP[file]="20260812-010203.tar.gz"

        os::require_cmd() { return 0; }
        local_targets() { RS_ENTRIES="site:wordpress"; }
        local_archives() { RS_ENTRIES="20260812-010203.tar.gz"; }
        archive_desc() { printf "%s" test; }
        fetch_archive() { RS_ARCHIVE="${TEST_TMP}/archive.tar.gz"; }
        verify_archive() { return 0; }
        read_manifest() {
            RS_MF_TYPE=site
            RS_MF_NAME=wordpress
            RS_MF_SOURCE=/srv/wordpress
            RS_MF_ROOT=wordpress
            RS_MF_DB=wp_wordpress
            RS_MF_CREATED=now
            RS_MF_HOST=source-host
            RS_MF_SITE_TYPE=wordpress
        }
        os::state_has() { return 1; }
        os::state_list() { return 0; }
        os::state_get() { printf "%s" "${3-}"; }
        tar() { printf "TAR\n" >>"${TRACE}"; return 0; }
        mysql() { printf "MYSQL\n" >>"${TRACE}"; return 0; }
        os::query() { printf "QUERY=%s\n" "$*" >>"${TRACE}"; return 0; }
        os::run() { printf "RUN=%s\n" "$*" >>"${TRACE}"; return 0; }

        main
    '
    [ "${status}" -eq 3 ]
    [[ "${output}" == *'本机没有登记站点 wordpress'* ]]
    [[ "${output}" == *'未做任何改动'* ]]
    if [[ -f ${TRACE} ]]; then
        ! grep -Eq 'TAR|MYSQL|tar|mysql' "${TRACE}"
    fi
}

@test "同名站的库不符：只列本机落点且没有归档默认项" {
    restore_run '
        RS_MF_TYPE=site
        RS_MF_NAME=wordpress
        RS_MF_SOURCE=/srv/archive-wordpress
        RS_MF_ROOT=wordpress
        RS_MF_DB=wp_wordpress
        RS_MF_SITE_TYPE=wordpress

        os::state_has() { [[ "${1}" == wordpress:wordpress ]]; }
        os::state_list() { printf "%s\n" wordpress:wordpress; }
        os::state_get() {
            case "${1}|${2}" in
                wordpress:wordpress\|path) printf "%s" /srv/live-wordpress ;;
                wordpress:wordpress\|db) printf "%s" wp_wordpress1 ;;
            esac
        }
        os::select() {
            printf "ARG=<%s>\n" "$@"
            printf -v "${5}" "%s" site:wordpress
        }

        rs_plan_dest
        printf "DEST=%s|%s\n" "${EX_DEST_DB}" "${EX_DEST_DIR}"
    '
    [ "${status}" -eq 0 ]
    [[ "${output}" == *'ARG=<--required>'* ]]
    [[ "${output}" == *'本机站点 wordpress（库 wp_wordpress1 · 目录 /srv/live-wordpress）'* ]]
    [[ "${output}" == *'DEST=wp_wordpress1|/srv/live-wordpress'* ]]
}

@test "数据库归档：第一层只给原库与覆盖入口，选覆盖后才列数据库" {
    restore_run '
        RS_MF_TYPE=db
        RS_MF_NAME=forgejo
        RS_MF_DB=forgejo

        os::require_cmd() { return 0; }
        ex_db_exists() { [[ "${1}" == forgejo || "${1}" == target_b ]]; }
        os::sql_query() {
            OS_RUN_OUTPUT=$'"'"'forgejo\ntarget_a\ntarget_b'"'"'
            return 0
        }
        os::select() {
            case "$*" in
                *恢复到哪个数据库*)
                    printf "FIRST_ARG=%s\n" "$@"
                    printf -v "${4}" "%s" __pick_db__
                    ;;
                *选择要覆盖的本机数据库*)
                    printf "SECOND_ARG=%s\n" "$@"
                    printf -v "${6}" "%s" db:target_b
                    ;;
            esac
        }

        rs_plan_dest
        printf "DEST=%s|CREATE=%s\n" "${EX_DEST_DB}" "${RS_DEST_DB_CREATE}"
    '
    [ "${status}" -eq 0 ]
    [[ "${output}" == *'FIRST_ARG=db:forgejo=本机同名数据库 forgejo（覆盖现有内容）'* ]]
    [[ "${output}" == *'FIRST_ARG=__pick_db__=本机其他数据库（下一步选择）'* ]]
    [[ "${output}" != *'FIRST_ARG=db:target_a=target_a'* ]]
    [[ "${output}" == *'SECOND_ARG=db:target_a=target_a'* ]]
    [[ "${output}" == *'SECOND_ARG=db:target_b=target_b'* ]]
    [[ "${output}" == *'DEST=target_b|CREATE=0'* ]]
    [[ "${output}" != *wordpress* ]]
}

@test "数据库归档：原库不存在时确认使用项目的 mariadb create 命令" {
    restore_run '
        OS_NON_INTERACTIVE=1
        RS_MF_TYPE=db
        RS_MF_NAME=forgejo
        RS_MF_DB=forgejo
        CREATED=0

        os::require_cmd() { return 0; }
        ex_db_exists() { [[ ${CREATED} -eq 1 ]]; }
        os::sql_query() { OS_RUN_OUTPUT=""; return 0; }
        os::lock_release() { printf "LOCK=release\n"; }
        os::lock_acquire() { printf "LOCK=acquire\n"; }
        os::record_change() { printf "CHANGE=%s\n" "$*"; }
        os::defer() { printf "DEFER_ARG=%s\n" "$@"; }
        os::run_out() {
            printf "CREATE_ARG=%s\n" "$@"
            CREATED=1
            OS_RUN_SKIPPED=0
            OS_RUN_OUTPUT="{}"
            return 0
        }

        rs_plan_dest
        printf "PLAN=%s|CREATE=%s\n" "${EX_DEST_DB}" "${RS_DEST_DB_CREATE}"
        rs_create_database "${EX_DEST_DB}"
    '
    [ "${status}" -eq 0 ]
    [[ "${output}" == *'PLAN=forgejo|CREATE=1'* ]]
    [[ "${output}" == *'LOCK=release'*'LOCK=acquire'* ]]
    [[ "${output}" == *'CREATE_ARG=通过数据库管理创建恢复目标'* ]]
    [[ "${output}" == *'CREATE_ARG=mariadb'* ]]
    [[ "${output}" == *'CREATE_ARG=create'* ]]
    [[ "${output}" == *'CREATE_ARG=--name=forgejo'* ]]
    [[ "${output}" == *'CREATE_ARG=--user=forgejo'* ]]
    [[ "${output}" == *'CREATE_ARG=--allow-any-host=n'* ]]
    [[ "${output}" == *'CREATE_ARG=--auto-password=y'* ]]
    [[ "${output}" == *'CREATE_ARG=--output=json'* ]]
    [[ "${output}" == *'CREATE_ARG=--non-interactive'* ]]
    [[ "${output}" == *'CHANGE=通过数据库管理创建了恢复目标 db:forgejo'* ]]
    [[ "${output}" == *'DEFER_ARG=rs_remove_created_database'* ]]
    [[ "${output}" == *'DEFER_ARG=forgejo'* ]]
}

@test "数据库归档：新建落点的失败回滚仍走项目 MariaDB 删除命令" {
    local bindir="${BATS_TEST_TMPDIR}/rollback-bin"
    local rollback_trace="${BATS_TEST_TMPDIR}/rollback-args"
    mkdir -p "${bindir}"
    printf '%s\n' \
        '#!/bin/bash' \
        "printf '%s\\n' \"\$@\" >'${rollback_trace}'" \
        'exit 0' >"${bindir}/oneserver"
    chmod +x "${bindir}/oneserver"

    restore_run "
        OS_BIN_DIR='${bindir}'
        OS_LOCK_HELD=1
        os::lock_release() { printf 'LOCK=release\\n'; OS_LOCK_HELD=0; }
        os::lock_acquire() { printf 'LOCK=acquire\\n'; OS_LOCK_HELD=1; }

        rs_remove_created_database forgejo
    "
    [ "${status}" -eq 0 ]
    [[ "${output}" == *'LOCK=release'*'LOCK=acquire'* ]]
    grep -Fxq mariadb "${rollback_trace}"
    grep -Fxq delete "${rollback_trace}"
    grep -Fxq -- '--name=forgejo' "${rollback_trace}"
    grep -Fxq -- '--confirm-drop=forgejo' "${rollback_trace}"
    grep -Fxq -- '--force-destroy' "${rollback_trace}"
    grep -Fxq -- '--non-interactive' "${rollback_trace}"
}

@test "数据库归档：新建空库不伪造恢复前副本，导入失败说明会回滚" {
    restore_run '
        SNAPSHOT_CALLED=0
        snapshot_db() { SNAPSHOT_CALLED=1; }
        os::sql_ident() { printf "`%s`" "${1}"; }
        os::sql_exec() { return 0; }
        os::run() { return 1; }

        rc=0
        restore_db forgejo "${TEST_TMP}/database.sql" 0 1 || rc=$?
        printf "RC=%s|SNAPSHOT=%s|PRE=%s\n" "${rc}" "${SNAPSHOT_CALLED}" "${RS_PRE_CREATED}"
    '
    [ "${status}" -eq 0 ]
    [[ "${output}" == *'将通过失败回滚撤销'* ]]
    [[ "${output}" == *'RC=1|SNAPSHOT=0|PRE=0'* ]]
    [[ "${output}" != *'上面那份恢复前副本'* ]]
}

@test "路径归档：第一层不混入站点，其他登记路径放在第二层" {
    restore_run '
        RS_MF_TYPE=path
        RS_MF_NAME=forgejo-data
        RS_MF_SOURCE=/srv/forgejo

        os::state_list() {
            [[ ${1} == backup-path ]] && printf "%s\n" backup-path:docs
        }
        os::state_get() {
            [[ "${1}|${2}" == "backup-path:docs|source" ]] && printf "%s" /srv/docs
        }
        os::select() {
            printf "PICK=%s\n" "$*"
            printf -v "${4}" "%s" path:forgejo-data
        }

        rs_plan_dest
        printf "DEST=%s\n" "${EX_DEST_DIR}"
    '
    [ "${status}" -eq 0 ]
    [[ "${output}" == *'path:forgejo-data=备份中记录的路径 /srv/forgejo'* ]]
    [[ "${output}" == *'__pick_path__=本机其他已登记路径（下一步选择）'* ]]
    [[ "${output}" != *wordpress* ]]
    [[ "${output}" == *'DEST=/srv/forgejo'* ]]
}

@test "MariaDB 菜单不再暴露独立备份与恢复动作" {
    local manager="${OS_TEST_REPO_ROOT}/script/manage/db_manager.sh"
    run grep -nE "backup=备份数据库|restore=从备份恢复|action_(backup|restore)" "${manager}"
    [ "${status}" -eq 1 ]
    grep -Fq '@args         [--action=<list|create|delete|allow-containers>]' "${manager}"
}

@test "--into=site:x：库、文件与凭据全部使用 x 的 state" {
    local dest="${BATS_TEST_TMPDIR}/site-x"
    archive_main_run x wp_x "${dest}" "${BATS_TEST_TMPDIR}/archive-wordpress" site:x
    [ "${status}" -eq 0 ]
    grep -Fq 'DROP DATABASE IF EXISTS `wp_x`; CREATE DATABASE `wp_x`' "${TRACE}"
    grep -Fq "FILES=${BATS_TEST_TMPDIR}/archive.tar.gz|${dest}|wordpress|" "${TRACE}"
    grep -Fq 'SECURE=wordpress.x.db_pass' "${TRACE}"
    grep -Fq 'CONFIRM=site:x' "${TRACE}"
    grep -Fq 'RUN=备份恢复前的数据库' "${TRACE}"
    ! grep -Fq 'DROP DATABASE IF EXISTS `wp_wordpress`' "${TRACE}"
}

@test "不给 --into：同名且 state 完全一致时仍按原名回滚" {
    local dest="${BATS_TEST_TMPDIR}/wordpress"
    archive_main_run wordpress wp_wordpress "${dest}" "${dest}" ''
    [ "${status}" -eq 0 ]
    grep -Fq 'DROP DATABASE IF EXISTS `wp_wordpress`; CREATE DATABASE `wp_wordpress`' "${TRACE}"
    grep -Fq "FILES=${BATS_TEST_TMPDIR}/archive.tar.gz|${dest}|wordpress|" "${TRACE}"
    grep -Fq 'SECURE=wordpress.wordpress.db_pass' "${TRACE}"
    grep -Fq 'CONFIRM=site:wordpress' "${TRACE}"
    grep -Fq 'RUN=备份恢复前的数据库' "${TRACE}"
}

@test "--only=wp-config.php：部分恢复仍会读取落点凭据并改写配置" {
    local dest="${BATS_TEST_TMPDIR}/site-x-config"
    archive_main_run x wp_x "${dest}" "${BATS_TEST_TMPDIR}/archive-wordpress" site:x files wp-config.php
    [ "${status}" -eq 0 ]
    grep -Fq 'SECURE=wordpress.x.db_pass' "${TRACE}"
    grep -Fq 'REPLACE=--backup' "${TRACE}"
    grep -Fq "${dest}/wp-config.php" "${TRACE}"
    grep -Fq 'CONFIRM=site:x' "${TRACE}"
    ! grep -Fq 'SQL=' "${TRACE}"
}

@test "无效 --into：按参数错误以 2 停下且没有写入" {
    local dest="${BATS_TEST_TMPDIR}/site-x-invalid"
    archive_main_run x wp_x "${dest}" "${BATS_TEST_TMPDIR}/archive-wordpress" site:missing
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'指定的恢复目标无效'* ]]
    if [[ -f ${TRACE} ]]; then
        ! grep -Eq 'SQL=|FILES=|RUN=' "${TRACE}"
    fi
}

@test "mysqldump 失败：在 DROP/CREATE 前中止恢复" {
    restore_run '
        mkdir -p "${TEST_TMP}/bin"
        printf "%s\n" "#!/bin/bash" "printf called >\"${TEST_TMP}/mysqldump.called\"" "exit 9" \
            >"${TEST_TMP}/bin/mysqldump"
        chmod +x "${TEST_TMP}/bin/mysqldump"
        os::run() {
            printf "RUN=%s\n" "$*" >>"${TRACE}"
            local desc=${1}
            shift
            [[ ${1-} != -- ]] || shift
            [[ ${desc} == 备份恢复前的数据库 ]] || return 0
            local -a cmd=("$@")
            cmd[${#cmd[@]}-1]="${TEST_TMP}/snapshot.sql.gz"
            PATH="${TEST_TMP}/bin:${PATH}" "${cmd[@]}"
        }
        os::sql_exec() {
            printf "SQL=%s\n" "${3}" >>"${TRACE}"
            return 0
        }

        restore_db wp_target "${TEST_TMP}/database.sql"
    '
    [ "${status}" -eq 1 ]
    [[ "${output}" == *'当前数据库备份失败，恢复中止'* ]]
    [ -f "${BATS_TEST_TMPDIR}/mysqldump.called" ]
    grep -Fq 'RUN=备份恢复前的数据库' "${TRACE}"
    ! grep -Fq 'SQL=' "${TRACE}"
    ! grep -Fq '导入数据库转储' "${TRACE}"
}

@test "site-url：配置前缀不符时只改数据库里唯一的 options 表" {
    local conf="${BATS_TEST_TMPDIR}/wp-config.php"
    printf "%s\n" '$table_prefix = '\''live_'\'';' >"${conf}"
    restore_run "
        os::sql_query() {
            case \"\${1}\" in
                定位站点地址表) OS_RUN_OUTPUT=archive_options ;;
                读取当前站点地址) OS_RUN_OUTPUT='siteurl https://old.example' ;;
            esac
            return 0
        }
        os::sql_exec() {
            printf 'SQL=%s\\n' \"\${3}\" >>\"\${TRACE}\"
            return 0
        }
        os::record_change() { return 0; }

        set_site_url '${conf}' wp_x https://new.example
    "
    [ "${status}" -eq 0 ]
    grep -Fq 'UPDATE `wp_x`.`archive_options`' "${TRACE}"
    ! grep -Fq 'UPDATE `wp_x`.`live_options`' "${TRACE}"
}

@test "site-url：配置前缀不符且有多个 options 表时拒绝 UPDATE" {
    local conf="${BATS_TEST_TMPDIR}/wp-config-ambiguous.php"
    printf "%s\n" '$table_prefix = '\''live_'\'';' >"${conf}"
    restore_run "
        os::sql_query() {
            OS_RUN_OUTPUT=\$'archive_options\\nother_options'
            return 0
        }
        os::sql_exec() {
            printf 'SQL=%s\\n' \"\${3}\" >>\"\${TRACE}\"
            return 0
        }

        set_site_url '${conf}' wp_x https://new.example
    "
    [ "${status}" -eq 1 ]
    [[ "${output}" == *'无法在库 wp_x 里唯一定位'* ]]
    [ ! -f "${TRACE}" ]
}
