#!/bin/bash
set -euo pipefail

# 使用说明
usage() {
    echo "用法: $0 <openssh版本号>"
    echo "示例: $0 10.3p1"
    exit 1
}

# 校验入参
if [ $# -ne 1 ]; then
    usage
fi
OPENSSH_VERSION="$1"

########################### 全局配置 ###########################
SRC_DOMAIN="cdn.openbsd.org"
SRC_URL="https://${SRC_DOMAIN}/pub/OpenBSD/OpenSSH/portable/openssh-${OPENSSH_VERSION}.tar.gz"
TARBALL="openssh-${OPENSSH_VERSION}.tar.gz"
# rpmbuild标准目录
RPMBUILD_ROOT="${HOME}/rpmbuild"
SOURCES_DIR="${RPMBUILD_ROOT}/SOURCES"
SPEC_PATH="${RPMBUILD_ROOT}/SPECS/openssh.spec"
NETWORK_TIMEOUT=30
YUM_TIMEOUT=60
# CtyunOS源替换规则
OLD_DOMAIN="ctyunos.ctyun.cn/ctyun/ctyunos/ctyunos-2/2.0.1"
NEW_DOMAIN="repo.ctyun.cn/hostos/ctyunos-2.0.1"
REPO_DIR="/etc/yum.repos.d"
# 输出压缩包名称
OUTPUT_TAR="openssh-${OPENSSH_VERSION}-rpms.tar.gz"
# 保存脚本执行原始目录
CURR_DIR=$(pwd)
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
info "待编译 OpenSSH 版本: ${OPENSSH_VERSION}"

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
# CentOS/Rocky/CtyunOS保留libedit-devel；BC-Linux无该依赖直接剔除
# Rocky9补充perl依赖，解决builddep报错
info "【步骤5】安装OpenSSH全套编译依赖包"
if [[ "${OS_TAG}" == "el7" ]]; then
    info "【执行】yum 安装编译依赖（CentOS7）"
    ${PKG_MGR} install -y gcc gcc-c++ make automake autoconf libtool zlib-devel openssl-devel pam-devel libselinux-devel krb5-devel libedit-devel rpm-build wget tar curl
elif [[ "${ID}" == "bclinux" ]]; then
    info "【执行】dnf 安装编译依赖（BC-Linux8 适配，剔除不存在的依赖）"
    ${PKG_MGR} install -y gcc gcc-c++ make automake autoconf libtool zlib-devel openssl-devel pam-devel libselinux-devel krb5-devel rpm-build wget tar curl perl-generators perl
else
    info "【执行】dnf 安装编译依赖（Rocky/CtyunOS，补充perl）"
    ${PKG_MGR} install -y gcc gcc-c++ make automake autoconf libtool zlib-devel openssl-devel pam-devel libselinux-devel krb5-devel libedit-devel rpm-build wget tar curl perl-generators perl
fi

# 6、初始化标准rpmbuild目录
info "【步骤6】初始化标准rpmbuild打包目录"
info "【执行】删除旧rpmbuild目录 ${RPMBUILD_ROOT}"
rm -rf "${RPMBUILD_ROOT}"

info "【执行】创建rpmbuild分层目录"
mkdir -p ${RPMBUILD_ROOT}/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}

# 7、下载OpenSSH源码
info "【步骤7】下载OpenSSH源码包：${SRC_URL}"
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

# 8、处理spec，关闭x11/gnome askpass编译
info "【步骤8】解压源码，拷贝并修复openssh.spec编译开关"
TMP_EXTRACT=$(mktemp -d)
tar -xf "${TARBALL}" -C "${TMP_EXTRACT}"

cp "${TMP_EXTRACT}/openssh-${OPENSSH_VERSION}/contrib/redhat/openssh.spec" "${SPEC_PATH}"
rm -rf "${TMP_EXTRACT}"

# 关闭图形依赖，杜绝编译报错
sed -i 's/^%global no_x11_askpass 0/%global no_x11_askpass 1/g' "${SPEC_PATH}"
sed -i 's/^%global no_gnome_askpass 0/%global no_gnome_askpass 1/g' "${SPEC_PATH}"

# 9、仅构建二进制包 -bb
info "【步骤9】切换rpmbuild根目录，仅构建二进制rpm（rpmbuild -bb）"
cd "${RPMBUILD_ROOT}"
rpmbuild -bb SPECS/openssh.spec

# 10、筛选纯openssh rpm并打包
info "【步骤10】筛选并打包所有 OpenSSH RPM"
TMP_RPM_DIR=$(mktemp -d)
find "${RPMBUILD_ROOT}/RPMS" -name "openssh-*.rpm" -type f -exec cp {} "${TMP_RPM_DIR}/" \;

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