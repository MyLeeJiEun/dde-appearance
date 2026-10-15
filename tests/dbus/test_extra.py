"""可选逃生舱:有外部副作用、无法用六原语声明的行为放这里。

示例:
    def test_set_wallpaper_produces_file(dbus_service):
        dbus_service.call("Set", "background", "file:///tmp/x.png")
        # 断言外部副作用(文件/进程/窗口)
"""
