#!/bin/bash
set -euo pipefail

# 使用说明
usage() {
    echo "用法: $0 <httpd版本号>"
    echo "示例: $0 2.4.68"
    exit 1
}

# 校验入参
if [ $# -ne 1 ]; then
    usage
fi
HTTPD_VERSION="$1"

########################### 全局配置 ###########################
SRC_DOMAIN="archive.apache.org"
# rpmbuild标准目录
RPMBUILD_ROOT="${HOME}/rpmbuild"
SOURCES_DIR="${RPMBUILD_ROOT}/SOURCES"
SPEC_PATH="${RPMBUILD_ROOT}/SPECS/httpd.spec"
NETWORK_TIMEOUT=30
YUM_TIMEOUT=60
# CtyunOS源替换规则
OLD_DOMAIN="ctyunos.ctyun.cn/ctyun/ctyunos/ctyunos-2/2.0.1"
NEW_DOMAIN="repo.ctyun.cn/hostos/ctyunos-2.0.1"
REPO_DIR="/etc/yum.repos.d"
# 输出压缩包名称
OUTPUT_TAR="httpd-${HTTPD_VERSION}-rpms.tar.gz"
# 保存脚本执行原始目录
CURR_DIR=$(pwd)
# 源码包格式（httpd官方spec默认使用.tar.bz2）
TARBALL="httpd-${HTTPD_VERSION}.tar.bz2"
SRC_URL="https://${SRC_DOMAIN}/dist/httpd/${TARBALL}"
################################################################

# 日志输出
info() { echo -e "\033[32m[INFO] $1\033[0m"; }
warn() { echo -e "\033[33m[WARN] $1\033[0m"; }
err()  { echo -e "\033[31m[ERROR] $1\033[0m" >&2; exit 1; }

# 外网连通检测函数
check_internet() {
    info "【执行】外网连通检测，目标域名：${SRC_DOMAIN}，超时${NETWORK_TIMEOUT}s"
    if timeout ${NETWORK_TIMEOUT} curl --connect-timeout ${NETWORK_TIMEOUT} -I -s "${SRC_URL}" >/dev/null 2>&1; then
        info "外网访问正常"
    else
        err "无法访问外网资源 ${SRC_DOMAIN}，代理返回504超时/无法连通！
排查方案：
1. 确认代理地址、端口正确，代理服务正常运行
2. 配置全局代理环境变量后重试：
export HTTP_PROXY=http://代理IP:端口
export HTTPS_PROXY=http://代理IP:端口
export ALL_PROXY=socks5://代理IP:端口
3. 内网无代理环境取消代理变量：unset HTTP_PROXY HTTPS_PROXY ALL_PROXY
4. 务必配置NO_PROXY跳过repo.ctyun.cn内网域名，避免走代理504"
    fi
}

# 1、外网连通检测
info "【步骤1】开始外网连通检测"
check_internet

# 2、读取系统版本信息
info "【步骤2】读取 /etc/os-release 识别系统信息"
source /etc/os-release
OS_TAG=""
PKG_MGR=""
MAJOR_VER=$(echo ${VERSION_ID} | cut -d '.' -f1)

info "【执行】解析发行版ID与版本号"
if [[ "${ID}" == "centos" && "${MAJOR_VER}" == "7" ]]; then
    OS_TAG="el7"
    PKG_MGR="yum"
elif [[ "${ID}" == "bclinux" && "${MAJOR_VER}" == "8" ]]; then
    OS_TAG="el8"
    PKG_MGR="dnf"
elif [[ "${ID}" == "rocky" && "${MAJOR_VER}" =~ ^(8|9)$ ]]; then
    OS_TAG="el${MAJOR_VER}"
    PKG_MGR="dnf"
elif [[ "${ID}" == "anolis" && "${MAJOR_VER}" =~ ^(7|8|9)$ ]]; then
    OS_TAG="el${MAJOR_VER}"
    PKG_MGR="dnf"
elif [[ "${ID}" == "ctyunos" ]]; then
    OS_TAG="ctyunos"
    PKG_MGR="dnf"
else
    err "当前发行版不支持，仅兼容：
1. CentOS 7.x 全系列
2. BCLinux 8.x 全系列
3. Rocky Linux 8.x / 9.x
4. Anolis OS 7.x / 8.x / 9.x
5. CTyunOS 2.0.1 / 23.01"
fi

info "发行版ID: ${ID} | 完整版本: ${VERSION_ID} | 主版本: ${MAJOR_VER}"
info "系统标识: ${OS_TAG} | 包管理器: ${PKG_MGR}"
info "待编译 httpd 版本: ${HTTPD_VERSION}"

# 2.1、检测 apr/apr-util 版本（仅 CentOS7：apr-util 1.6.1 主包与官方源 1.5.2 devel 版本冲突问题）
# 其他系统（Anolis/Rocky/BCLinux/CtyunOS）官方源 apr/apr-util devel 版本能自动对齐，步骤5 装即可
if [[ "${OS_TAG}" == "el7" ]]; then
    info "【步骤2.1】检测 apr/apr-util 版本（CentOS7 专属：apr-util 1.6.1 主包与官方源 1.5.2 devel 版本冲突问题）"
    APR_VER=$(rpm -q apr --qf '%{VERSION}-%{RELEASE}' 2>/dev/null || echo "")
    APR_DEVEL_VER=$(rpm -q apr-devel --qf '%{VERSION}-%{RELEASE}' 2>/dev/null || echo "")
    APU_VER=$(rpm -q apr-util --qf '%{VERSION}-%{RELEASE}' 2>/dev/null || echo "")
    APU_DEVEL_VER=$(rpm -q apr-util-devel --qf '%{VERSION}-%{RELEASE}' 2>/dev/null || echo "")

    info "  apr=${APR_VER:-未安装}  apr-devel=${APR_DEVEL_VER:-未安装}"
    info "  apr-util=${APU_VER:-未安装}  apr-util-devel=${APU_DEVEL_VER:-未安装}"

    APR_ERR=""
    if [[ -z "${APR_VER}" ]]; then APR_ERR="${APR_ERR}\n  - apr 主包未安装"; fi
    if [[ -z "${APR_DEVEL_VER}" ]]; then APR_ERR="${APR_ERR}\n  - apr-devel 未安装"; fi
    if [[ -n "${APR_VER}" && -n "${APR_DEVEL_VER}" && "${APR_VER}" != "${APR_DEVEL_VER}" ]]; then APR_ERR="${APR_ERR}\n  - apr(${APR_VER}) 与 apr-devel(${APR_DEVEL_VER}) 版本不一致"; fi
    if [[ -z "${APU_VER}" ]]; then APR_ERR="${APR_ERR}\n  - apr-util 主包未安装"; fi
    if [[ -z "${APU_DEVEL_VER}" ]]; then APR_ERR="${APR_ERR}\n  - apr-util-devel 未安装"; fi
    if [[ -n "${APU_VER}" && -n "${APU_DEVEL_VER}" && "${APU_VER}" != "${APU_DEVEL_VER}" ]]; then APR_ERR="${APR_ERR}\n  - apr-util(${APU_VER}) 与 apr-util-devel(${APU_DEVEL_VER}) 版本不一致"; fi

    if [[ -n "${APR_ERR}" ]]; then
        err "apr/apr-util 检测不通过：${APR_ERR}

httpd 打包需要 apr+apr-devel、apr-util+apr-util-devel（主包与 devel 版本必须一致）。
请手动安装版本一致的 apr/apr-util 全套后重新执行脚本。

提示：CentOS7 官方源 apr/apr-util 为 1.4.8/1.5.2，若系统装的是 1.6.1 等非官方版本，
  官方源没有对应 devel 包，需从源码编译 apr/apr-util 或将系统 apr/apr-util 降级到官方版本。"
    fi
    info "apr/apr-util 版本检测通过"
else
    info "【步骤2.1】非 CentOS7 系统，apr/apr-util 依赖由步骤5 dnf install 自动装（官方源版本自动对齐），跳过预检测"
fi

# 标记：是否需要刷新软件源缓存
SKIP_CACHE_REFRESH=0

# 3、处理CtyunOS软件源替换逻辑：仅2.0.1替换域名，23.01不处理
info "【步骤3】处理系统软件源地址"
if [[ "${ID}" == "ctyunos" && "${VERSION_ID}" == "2.0.1" ]]; then
    info "【执行】检查repo文件是否已替换为新域名"
    if grep -q "${NEW_DOMAIN}" ${REPO_DIR}/*.repo 2>/dev/null; then
        info "repo URL已更新完成，跳过源缓存清理与重建"
        SKIP_CACHE_REFRESH=1
    else
        info "【执行】sed批量替换repo旧域名 ${OLD_DOMAIN} → ${NEW_DOMAIN}"
        sed -i "s|${OLD_DOMAIN}|${NEW_DOMAIN}|g" ${REPO_DIR}/*.repo 2>/dev/null || true
        info "URL替换完成，需要重建源缓存"
    fi
else
    info "【执行】检测本地repo文件是否发生变更"
    if find ${REPO_DIR} -name "*.repo" -mmin -5 | grep -q .; then
        info "检测到repo文件近期有修改，执行缓存重建"
    else
        info "repo文件无变更，跳过源缓存清理与重建"
        SKIP_CACHE_REFRESH=1
    fi
fi

# 4、仅源变更时执行缓存刷新
if [[ ${SKIP_CACHE_REFRESH} -eq 0 ]]; then
    info "【步骤4】清理软件源缓存并重建元数据，超时${YUM_TIMEOUT}s"
    info "【执行】${PKG_MGR} clean all"
    ${PKG_MGR} clean all

    info "【执行】timeout ${YUM_TIMEOUT} ${PKG_MGR} makecache"
    if timeout ${YUM_TIMEOUT} ${PKG_MGR} makecache; then
        info "软件源元数据拉取正常"
    else
        err "软件源拉取repomd.xml失败，排查：
1. rm -rf /var/cache/dnf/* 清空缓存
2. curl 测试repo连通性
3. NO_PROXY添加内网域名避免代理504"
    fi
else
    info "【步骤4】已跳过源缓存刷新流程"
fi

# 5、安装编译依赖
# httpd 依赖 apr, apr-util, pcre, openssl, zlib, lua, etc.
info "【步骤5】安装 httpd 全套编译依赖包"
if [[ "${OS_TAG}" == "el7" ]]; then
    # CentOS7：apr-devel/apr-util-devel 与系统主包版本一致性已由步骤2.1 检测通过，正常装即可
    # libxml2-devel / libuuid-devel 单独处理（不在基础 install 列表）：
    #   - libxml2-python 与 libxml2 主包版本绑定，常规 install 触发 depsolve 失败
    #   - util-linux 锁住 libuuid/libblkid/libmount 主包版本，装 libuuid-devel 默认拉新主包触发冲突
    # mod_proxy_html 需 libxml2-devel；httpd 多个模块需 libuuid-devel，必须单独解决
    # --skip-broken 兜底：跳过其他 rpmdb pre-existing 冲突包
    info "【执行】yum 安装编译依赖（CentOS7，含 apr-devel/apr-util-devel/apr-util-openssl/apr-util-ldap/brotli-devel；libxml2-devel/libuuid-devel 单独处理）"
    if ! ${PKG_MGR} install -y --skip-broken gcc gcc-c++ make autoconf libtool apr-devel apr-util-devel apr-util-openssl apr-util-ldap pcre-devel openssl-devel zlib-devel lua-devel perl-devel openldap-devel brotli-devel rpm-build wget tar curl bzip2; then
        err "yum install 基础编译依赖失败！常见原因：
1. rpmdb pre-existing 问题：运行 'yum check' 查看完整冲突列表
2. 修复建议：
   package-cleanup --problems     # 列出依赖问题
   package-cleanup --cleandupes   # 清理重复包
   rpm --rebuilddb                 # 重建 rpm 数据库"
    fi

    # libuuid-devel：util-linux 锁住 libuuid 主包版本，精确指定版本装避免主包升级
    INSTALLED_LIBUUID=$(rpm -q libuuid --qf '%{VERSION}-%{RELEASE}' 2>/dev/null || true)
    if [[ -n "${INSTALLED_LIBUUID}" ]]; then
        info "【执行】精确版本装 libuuid-devel-${INSTALLED_LIBUUID}（避免升级 libuuid 主包触发 util-linux 冲突）"
        if ! ${PKG_MGR} install -y "libuuid-devel-${INSTALLED_LIBUUID}" 2>/dev/null; then
            warn "libuuid-devel-${INSTALLED_LIBUUID} 仓库无对应版本，尝试默认装（可能仍冲突）"
            ${PKG_MGR} install -y libuuid-devel 2>/dev/null || warn "libuuid-devel 装失败，rpmbuild 时若缺 uuid.h 需手动处理"
        fi
    fi

    # mod_proxy_html 模块需要 libxml2-devel，解决 libxml2/libxml2-python 主子包版本绑定冲突
    # 方案1：yum 同时装 libxml2 libxml2-python libxml2-devel 让 depsolve 找一致解
    # 方案2：rpm -e --nodeps libxml2-python 解绑后 yum 自由装 devel + python 子包
    info "【执行】安装 libxml2-devel（mod_proxy_html 依赖，需解绑 libxml2-python 子包版本）"
    if ! ${PKG_MGR} install -y libxml2 libxml2-python libxml2-devel; then
        info "集合安装失败，降级到 rpm 解绑方案：rpm -e --nodeps libxml2-python 后重装"
        rpm -e --nodeps libxml2-python || true
        if ! ${PKG_MGR} install -y libxml2-devel libxml2-python; then
            err "libxml2-devel 安装失败，mod_proxy_html 依赖未满足，请手动处理：见上方错误"
        fi
    fi

    # brotli-devel：CentOS7 默认仓库没有，需 EPEL
    if ! ${PKG_MGR} install -y brotli-devel 2>/dev/null; then
        info "brotli-devel 默认仓库装失败，尝试启用 EPEL"
        ${PKG_MGR} install -y epel-release 2>/dev/null || ${PKG_MGR} install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm 2>/dev/null || true
        if ! ${PKG_MGR} install -y --enablerepo=epel brotli-devel 2>/dev/null; then
            warn "brotli-devel 装失败（EPEL 不可用），mod_brotli.so 不会编出，%files 会报 File not found"
        fi
    fi
elif [[ "${ID}" == "bclinux" ]]; then
    info "【执行】dnf 安装编译依赖（BC-Linux8 适配）"
    ${PKG_MGR} install -y gcc gcc-c++ make autoconf libtool apr-devel apr-util-devel apr-util-openssl apr-util-ldap pcre-devel openssl-devel zlib-devel lua-devel perl perl-devel libxml2-devel brotli-devel libuuid-devel rpm-build wget tar curl
else
    info "【执行】dnf 安装编译依赖（Rocky/Anolis/CtyunOS）"
    ${PKG_MGR} install -y gcc gcc-c++ make autoconf libtool apr-devel apr-util-devel apr-util-openssl apr-util-ldap pcre-devel openssl-devel zlib-devel lua-devel perl perl-devel libxml2-devel brotli-devel libuuid-devel rpm-build wget tar curl
fi

# 6、初始化标准rpmbuild目录（不删除已有RPMS/SRPMS，避免丢失之前的打包产物）
info "【步骤6】初始化rpmbuild构建环境"
info "【执行】清理旧的构建临时文件（BUILD/BUILDROOT），保留已有RPMS/SRPMS"
rm -rf "${RPMBUILD_ROOT}/BUILD" "${RPMBUILD_ROOT}/BUILDROOT"
mkdir -p ${RPMBUILD_ROOT}/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}

# 7、下载 httpd 源码（先下载默认格式，后续根据spec调整）
info "【步骤7】下载 httpd 源码包：${SRC_URL}"
info "【执行】切换至SOURCES目录 ${SOURCES_DIR}"
cd "${SOURCES_DIR}"

info "【执行】wget 下载源码包 ${TARBALL}（显示进度条，-q 静默会让人误以为卡住）"
if ! wget --progress=bar:force --no-check-certificate --timeout=${NETWORK_TIMEOUT} "${SRC_URL}"; then
    err "源码包下载失败，请检查代理/外网连通性！"
fi
if [ ! -f "${SOURCES_DIR}/${TARBALL}" ]; then
    err "源码包缺失：${SOURCES_DIR}/${TARBALL}"
fi
info "源码包下载完成：${SOURCES_DIR}/${TARBALL}"

# 8、处理spec，提取httpd源码中自带的spec文件
info "【步骤8】解压源码，提取httpd.spec"
TMP_EXTRACT=$(mktemp -d)
tar -xf "${TARBALL}" -C "${TMP_EXTRACT}"

# httpd 源码包自带 spec 文件路径
SPEC_FOUND=""
for spec_candidate in \
    "${TMP_EXTRACT}/httpd-${HTTPD_VERSION}/httpd.spec" \
    "${TMP_EXTRACT}/httpd-${HTTPD_VERSION}/build/pkg/rpm/httpd.spec" \
    "${TMP_EXTRACT}/httpd-${HTTPD_VERSION}/build/pkg/rpm/httpd.spec.in" \
    "${TMP_EXTRACT}/httpd-${HTTPD_VERSION}/build/rpm/httpd.spec"; do
    if [ -f "${spec_candidate}" ]; then
        SPEC_FOUND="${spec_candidate}"
        break
    fi
done

if [ -n "${SPEC_FOUND}" ]; then
    info "【执行】使用源码包内置spec文件: ${SPEC_FOUND}"
    cp "${SPEC_FOUND}" "${SPEC_PATH}"

    # 注入 _unpackaged_files_terminate_build=0：容忍 spec %files 未声明的文件（如 mod_brotli.so）
    # 这些文件不会进 rpm，仅 warning 不报错，spec 原始内容零改动
    sed -i '1i %define _unpackaged_files_terminate_build 0' "${SPEC_PATH}"

    info "【执行】保留 spec 原始 %files 声明不动（模块编不编由 spec 默认 %configure + 系统依赖检测决定）"
else
    # 若源码包中无spec文件，生成一个简单的spec
    info "【执行】源码包无内置spec文件，生成默认spec"
    cat > "${SPEC_PATH}" << EOF
%define _buildhost %(hostname)
%define httpd_version ${HTTPD_VERSION}
%define _unpackaged_files_terminate_build 0

Name:           httpd
Version:        ${HTTPD_VERSION}
Release:        1%{?dist}
Summary:        Apache HTTP Server

License:        Apache License 2.0
URL:            https://httpd.apache.org/

Source0:        httpd-${HTTPD_VERSION}.tar.bz2

BuildRequires:  gcc, make, autoconf, libtool
BuildRequires:  apr-devel, apr-util-devel, pcre-devel, openssl-devel, zlib-devel
BuildRequires:  perl-devel, libxml2-devel

Requires:       apr, apr-util, pcre, openssl-libs, zlib

%description
The Apache HTTP Server is a powerful, efficient, and extensible web server.

%prep
%setup -q -n httpd-%{httpd_version}

%build
./configure \
    --prefix=%{_prefix} \
    --sysconfdir=%{_sysconfdir}/httpd \
    --datadir=%{_datadir}/httpd \
    --with-apr=%{_prefix} \
    --with-apr-util=%{_prefix} \
    --enable-so \
    --enable-ssl \
    --enable-rewrite \
    --enable-deflate \
    --enable-expires \
    --enable-headers \
    --enable-proxy \
    --enable-proxy-http

make %{?_smp_mflags}

%install
rm -rf %{buildroot}
make install DESTDIR=%{buildroot}

%files
%{_prefix}/*
%config(noreplace) %{_sysconfdir}/httpd/*

%changelog
* $(date +%a) $(date +%b) $(date +%d) $(date +%Y) - httpd-${HTTPD_VERSION}
- Package httpd ${HTTPD_VERSION}
EOF
fi

rm -rf "${TMP_EXTRACT}"

# 9、从spec文件中解析BuildRequires并自动安装缺失的依赖
info "【步骤9】解析spec中BuildRequires，确保所有构建依赖已安装"
if command -v ${PKG_MGR} >/dev/null 2>&1; then
    # 提取所有BuildRequires行，过滤注释和空行
    SPEC_DEPS=$(grep -i '^BuildRequires:' "${SPEC_PATH}" | sed 's/^BuildRequires:\s*//' | tr ',' '\n' | xargs)
    if [ -n "${SPEC_DEPS}" ]; then
        info "【执行】安装spec中定义的额外依赖: ${SPEC_DEPS}"
        # CentOS7 rpmdb 存在 pre-existing 冲突，--skip-broken 跳过冲突包继续装其他
        # 不再静默丢弃错误：失败时 warn 提示，让第10步 rpmbuild 暴露具体缺失包
        if [[ "${OS_TAG}" == "el7" ]]; then
            if ! ${PKG_MGR} install -y --skip-broken ${SPEC_DEPS} 2>/dev/null; then
                warn "spec BuildRequires 部分包安装失败（rpmdb 冲突或版本绑定），第10步 rpmbuild 会暴露具体缺失包"
            fi
        else
            ${PKG_MGR} install -y ${SPEC_DEPS} 2>/dev/null || true
        fi
    fi
fi

# 10、仅构建二进制包 -bb
info "【步骤10】切换rpmbuild根目录，仅构建二进制rpm（rpmbuild -bb）"
cd "${RPMBUILD_ROOT}"

# 后台心跳：httpd 完整编译预计 10-30 分钟，期间几乎无新输出会让人误以为卡死
# 每 60s 打印一次到 stderr（不干扰 rpmbuild 的 stdout），让用户知道仍在编译
heartbeat() {
    local start=$(date +%s)
    while true; do
        sleep 60
        local elapsed=$(( ($(date +%s) - start) / 60 ))
        echo -e "\033[36m[心跳] $(date '+%H:%M:%S') rpmbuild 仍在运行，已耗时 ${elapsed} 分钟...\033[0m" >&2
    done
}
heartbeat &
HEARTBEAT_PID=$!
cleanup_heartbeat() {
    kill ${HEARTBEAT_PID} 2>/dev/null || true
    wait ${HEARTBEAT_PID} 2>/dev/null || true
}
trap cleanup_heartbeat EXIT

# apr-devel/apr-util-devel 已由步骤2.1 检测版本一致并装好，spec BuildRequires 检查能通过
# 正常 rpmbuild -bb（不用 --nodeps），真实缺包在 %build 阶段暴露
info "【执行】rpmbuild -bb SPECS/httpd.spec"
info "  httpd 完整编译预计 10-30 分钟，期间心跳每 60s 打印一次进度，请耐心等待"
if ! rpmbuild -bb SPECS/httpd.spec; then
    err "rpmbuild -bb 失败，详见上方错误（可能是真实缺包或编译失败）"
fi

# 编译成功，停止心跳
trap - EXIT
cleanup_heartbeat
info "rpmbuild 编译完成"

# 11、筛选纯httpd rpm并打包
info "【步骤11】筛选并打包所有 httpd RPM"
TMP_RPM_DIR=$(mktemp -d)
find "${RPMBUILD_ROOT}/RPMS" -name "httpd-*.rpm" -type f -exec cp {} "${TMP_RPM_DIR}/" \;

cd "${TMP_RPM_DIR}"
tar -czf "${CURR_DIR}/${OUTPUT_TAR}" *.rpm
rm -rf "${TMP_RPM_DIR}"

# 最终校验压缩包
if [ ! -f "${CURR_DIR}/${OUTPUT_TAR}" ]; then
    err "压缩包生成失败！"
fi

info "==================== 编译打包全部完成 ===================="
info "输出压缩包: ${CURR_DIR}/${OUTPUT_TAR}"
ls -lh "${CURR_DIR}/${OUTPUT_TAR}"
info "=========================================================="
