# redis-sentinel

## 简介

一键安装redis哨兵模式的Shell脚本

## 支持列表

目前仅支持CentOS系统，后续将支持Debian、Ubuntu系统

## 使用方法

安装curl

```
apt update -y  && apt install -y curl
```

或者

```
apt update -y  && apt install -y wget
```

或者手动下载本脚本至服务器

### 下载并执行

用curl下载

```
curl -sS -O https://raw.githubusercontent.com/easy-lau/redis-sentinel/main/redis-sentinel-install-cn.sh && chmod +x redis-sentinel-install-cn.sh && ./redis-sentinel-install-cn.sh
```

用wget下载

```
wget -q https://raw.githubusercontent.com/easy-lau/redis-sentinel/main/redis-sentinel-install-cn.sh && chmod +x redis-sentinel-install-cn.sh && ./redis-sentinel-install-cn.sh
```