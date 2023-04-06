#!/bin/bash

# 更新配置文件中指定参数的值
function updateParam() {
    key=$1
    value=$2
    conf_file=$3

    if [ "" != "$(grep "^\s*$key\s*=.*" $conf_file)" ]; then
        # value中可能包含特殊字符，所以需要转义，\\表示的是\，&表示的是匹配到的内容
        value=$(echo $value | sed -e 's/[]\/$*.^[]/\\&/g')
        sed -i "s/^\s*$key\s*=.*/$key=$value/g" $conf_file
    else
        # 如果不存在，则新增
        echo "$key=$value" >>$conf_file
    fi
}

# 获取配置文件中指定参数的值
function getParam() {
    key=$1
    conf_file=$2
    value=$(grep "^\s*$key\s*=.*" $conf_file | awk -F '=' '{ print $2 }')
    echo $value
}

