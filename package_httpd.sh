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
elif [[ "${ID}" == "ctyunos" ]]; then
    OS_TAG="ctyunos"
    PKG_MGR="dnf"
else
    err "当前发行版不支持，仅兼容：
1. CentOS 7.x 全系列
2. BCLinux 8.x 全系列
3. Rocky Linux 8.x / 9.x
4. CTyunOS 2.0.1 / 23.01"
fi

info "发行版ID: ${ID} | 完整版本: ${VERSION_ID} | 主版本: ${MAJOR_VER}"
info "系统标识: ${OS_TAG} | 包管理器: ${PKG_MGR}"
info "待编译 httpd 版本: ${HTTPD_VERSION}"

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
    info "【执行】yum 安装编译依赖（CentOS7）"
    ${PKG_MGR} install -y gcc gcc-c++ make autoconf libtool apr-devel apr-util-devel pcre-devel openssl-devel zlib-devel lua-devel perl-devel libxml2-devel rpm-build wget tar curl
elif [[ "${ID}" == "bclinux" ]]; then
    info "【执行】dnf 安装编译依赖（BC-Linux8 适配）"
    ${PKG_MGR} install -y gcc gcc-c++ make autoconf libtool apr-devel apr-util-devel pcre-devel openssl-devel zlib-devel lua-devel perl-devel libxml2-devel rpm-build wget tar curl
else
    info "【执行】dnf 安装编译依赖（Rocky/CtyunOS）"
    ${PKG_MGR} install -y gcc gcc-c++ make autoconf libtool apr-devel apr-util-devel pcre-devel openssl-devel zlib-devel lua-devel perl-devel libxml2-devel rpm-build wget tar curl
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

info "【执行】wget 下载源码包 ${TARBALL}"
if ! wget -q --no-check-certificate --timeout=${NETWORK_TIMEOUT} "${SRC_URL}"; then
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

    # 修复spec文件中缺失的模块文件（如mod_brotli.so）
    # 检查是否有未打包的模块文件，追加到files段
    if ! grep -q 'mod_brotli' "${SPEC_PATH}"; then
        info "【执行】修复spec：添加mod_brotli.so到%files段"
        sed -i '/^%files/a %attr(0755,root,root) %{_libdir}/httpd/modules/mod_brotli.so' "${SPEC_PATH}"
    fi
else
    # 若源码包中无spec文件，生成一个简单的spec
    info "【执行】源码包无内置spec文件，生成默认spec"
    cat > "${SPEC_PATH}" << EOF
%define _buildhost %(hostname)
%define httpd_version ${HTTPD_VERSION}

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
        ${PKG_MGR} install -y ${SPEC_DEPS} 2>/dev/null || true
    fi
fi

# 10、仅构建二进制包 -bb
info "【步骤10】切换rpmbuild根目录，仅构建二进制rpm（rpmbuild -bb）"
cd "${RPMBUILD_ROOT}"
rpmbuild -bb SPECS/httpd.spec

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
