#!/bin/sh
# 崩溃时抓调用栈。
#
# 用途:dbus-testing run 只能报「被测进程在就绪前退出(退出码 -11)」,
# 看不到崩在哪一帧。这个脚本在私有总线上用 gdb 直接拉起 dsm-host 加载
# 同一个插件,复现崩溃并打印所有线程的 backtrace —— 只用于 CI 排障,
# 正常路径不经过它。
#
# 用法: ./tests/dbus/debug-stack.sh <build-dir>
# 前置: dbus-daemon、dbus-testing-dsm-host、gdb 均在 PATH 中。
set -e

build_dir="${1:-build}"
plugin="$build_dir/src/service/libplugin-dde-appearance.so"
service="org.deepin.dde.Appearance1"

if [ ! -f "$plugin" ]; then
    echo "找不到插件: $plugin(先构建再运行本脚本)" >&2
    exit 1
fi
for tool in dbus-daemon gdb dbus-testing-dsm-host; do
    command -v "$tool" >/dev/null 2>&1 || { echo "缺 $tool" >&2; exit 1; }
done

# 私有会话总线。框架 core/bus.py 也是这么起:unix:path=<dir>/bus.socket,
# 默认策略放开 send_destination / own,否则 dsm-host 抢不到服务名。
bus_dir=$(mktemp -d /tmp/dbus-testing-debug-XXXXXX)
cat > "$bus_dir/bus.conf" <<EOF
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>session</type>
  <listen>unix:path=$bus_dir/bus.socket</listen>
  <policy context="default">
    <allow send_destination="*"/>
    <allow own="*"/>
  </policy>
</busconfig>
EOF
dbus-daemon --config-file="$bus_dir/bus.conf" --fork

# 沙箱 HOME:插件启动时会在 $HOME/.config/deepin/dde-daemon/appearance 下
# 建目录,写到真实 HOME 会污染 runner。XDG_DATA_DIRS 保持继承(插件要读
# 系统图标主题与 dsg schema)。
home_dir=$(mktemp -d /tmp/dbus-testing-debug-home-XXXXXX)
echo "sandbox HOME: $home_dir"
echo "bus socket : $bus_dir/bus.socket"
echo "--- gdb backtrace ---"

# 关键:必须限时。若插件本就不崩(比如资源已补齐),dsm-host 会一直挂在
# 总线上等请求,gdb -ex run 永不返回 —— 不加 timeout 会把 CI job 拖到
# 默认 6 小时上限。20s 足够走到 init 阶段并暴露崩溃。
# -k 5:超时后若 gdb 不退,5s 后补 SIGKILL。
# 退出码 124 表示超时(即"没崩"),不是失败。
set +e
timeout -k 5 20 \
env HOME="$home_dir" \
    XDG_DATA_HOME="$home_dir/data" \
    XDG_CONFIG_HOME="$home_dir/config" \
    XDG_CACHE_HOME="$home_dir/cache" \
    XDG_RUNTIME_DIR="$home_dir/run" \
    QT_QPA_PLATFORM=offscreen \
gdb -batch -q \
    -ex 'set pagination off' \
    -ex 'set confirm off' \
    -ex run \
    -ex 'thread apply all bt full' \
    --args dbus-testing-dsm-host \
        --plugin "$(realpath "$plugin")" \
        --name "$service" \
        --bus "unix:path=$bus_dir/bus.socket"
rc=$?
set -e
if [ "$rc" -eq 124 ]; then
    echo "--- 20s 内未崩溃(退出码 124):dsm-host 正常驻留,插件启动没问题 ---"
elif [ "$rc" -eq 0 ]; then
    echo "--- 进程自行退出了,但 gdb 未捕获到信号(下面 bt 为空属正常) ---"
else
    echo "--- gdb 退出码 $rc(通常 134=SIGABRT / 139=SIGSEGV,上面的栈即根因) ---"
fi
exit "$rc"
