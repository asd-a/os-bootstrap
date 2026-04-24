# OS Bootstrap

用于制作 Ubuntu 基本系统。

## 快速开始

⚠️ **警告：以下操作会删除目标磁盘上的所有数据！**

如果没有空闲磁盘可以创建一个 loop dev
```bash
dd if=/dev/zero of=test.img bs=1G count=8
losetup /dev/loop0 test.img
```
最后 `losetup -d /dev/loop0` 弹出设备

### 完整安装（推荐）

自动安装依赖、分区、格式化、引导系统：

```bash
# 完成所有安装步骤（会提示确认分区操作和root PASSWD）
make target/all DISK=/dev/sdX HOSTID=?

# 使用 QEMU 测试启动
make test/boot DISK=/dev/sdX
```
