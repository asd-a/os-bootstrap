HOSTID ?= 1
HOSTNAME ?= i

.DEFAULT: clean

clean-all: clean clean-deb clean-rootfs

clean-deb:
	rm -rf nvidia.deb doca.deb

clean-rootfs:
	rm -rf rootfs.tar.xz
	rm -rf ubuntu-base.tar.gz

clean:
	rm -rf target
	${MAKE} util/unmount
	rm -rf mnt 
	umount -R rootfs/* || true
	rm -rf rootfs
	rm -rf qemu-run

util/mount:
	@test "${DISK}" != "" || (echo "Specify DISK=/dev/..."; exit 1)

	mount --mkdir `lsblk -nlo PATH ${DISK} | awk 'NR==3 {print}'` ./mnt
	mount --mkdir -o fmask=027,umask=027 `lsblk -nlo PATH ${DISK} | awk 'NR==2 {print}'` ./mnt/boot

util/unmount:
	umount ./mnt/boot 	|| true
	umount ./mnt 		|| true

nvidia.deb:
	@echo "Downloading NVIDIA driver deb package"
	wget https://developer.download.nvidia.com/compute/nvidia-driver/590.48.01/local_installers/nvidia-driver-local-repo-debian13-590.48.01_1.0-1_amd64.deb -O $@

doca.deb:
	@echo "Downloading DOCA driver deb package"
	wget https://www.mellanox.com/downloads/DOCA/DOCA_v3.3.0/host/doca-host_3.3.0-088000-26.01-debian13_amd64.deb -O $@

ubuntu-base.tar.gz:
	@echo "Downloading Ubuntu base tarball"
	wget https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/ubuntu-base-24.04.4-base-amd64.tar.gz -O $@

rootfs.tar.gz: ubuntu-base.tar.gz
	@echo "Create Ubuntu rootfs"

	mkdir -p rootfs
	tar -xapf ubuntu-base.tar.gz -C ./rootfs
	echo "nameserver 8.8.8.8" > ./rootfs/etc/resolv.conf
	./chroot -r ./rootfs apt update
	./chroot -r ./rootfs apt upgrade -y --no-install-recommends --show-progress -V --purge

	./chroot -r ./rootfs apt install -y --no-install-recommends --show-progress -V --purge \
		`grep -vE "^\s*#" requires-basic.txt | tr "\n" " "`

	./chroot -r ./rootfs dpkg-reconfigure locales

	@echo "Cleaning up apt cache"
	./chroot -r ./rootfs apt clean
	./chroot -r ./rootfs apt autoclean

	@echo "Setting root password"
	cat passwd.txt | ./chroot -r ./rootfs chpasswd -e
	
	@echo "Setting root ssh authorized keys"
	mkdir -p ./rootfs/root/.ssh
	cat ssh_keys.txt > ./rootfs/root/.ssh/authorized_keys

	tar -capf $@ -C ./rootfs .

target/dependency:
	apt install gdisk btrfs-progs parted dosfstools qemu-system-x86 ovmf

	mkdir -p target
	@touch $@

target/partition-disk: target/dependency
	@test "${DISK}" != "" || (echo "Specify DISK=/dev/..."; exit 1)
	@read -p "Partition ${DISK}? (y/N): " c && [ "$$c" = y ] || { echo "Canceled"; exit 1; }

	# 1. 清空磁盘分区表
	sgdisk -Z "${DISK}"
	# 2. 创建 GPT (Clear)
	sgdisk -o "${DISK}"
	# 3. 创建 EFI 分区（FAT32）1G
	sgdisk -n 1:0:+1G -t 1:EF00 -c 1:"EFI System" "${DISK}"
	# 4. 创建 Btrfs 根分区（剩余全部）
	sgdisk -n 2:0:0 -t 2:8304 -c 2:"Linux root (btrfs)" "${DISK}"
	# 重新加载分区表
	partprobe "${DISK}"

	@touch $@

target/format-efi:
	@test "${PART_EFI}" != "" || (echo "Specify PART_EFI"; exit 1)

	@echo format ${PART_EFI} as FAT
	mkfs.fat -F32 ${PART_EFI}

	@touch $@

target/format-root:
	@test "${PART_ROOT}" != "" || (echo "Specify PART_ROOT"; exit 1)

	@echo format ${PART_ROOT} as btrfs
	mkfs.btrfs -f ${PART_ROOT}

	@touch $@

target/format: target/partition-disk
	@test "${DISK}" != "" || (echo "Specify DISK=/dev/..."; exit 1)

	mkdir -p ./mnt

	${MAKE} target/format-root "PART_ROOT=`lsblk -nlo PATH ${DISK} | awk 'NR==3 {print}'`"
	${MAKE} target/format-efi  "PART_EFI=`lsblk -nlo PATH ${DISK} | awk 'NR==2 {print}'`"
	
	@touch $@

target/subvolume: target/format
	${MAKE} util/mount

	btrfs su create mnt/var
	btrfs su create mnt/var/cache
	chattr +C mnt/var/cache

	@touch $@

target/bootstrap: target/subvolume rootfs.tar.gz
	@echo "Bootstrapping Ubuntu into ./mnt"
	tar -xapf rootfs.tar.gz -C ./mnt

	@echo "Setting kernel cmdline"
	echo "root=UUID=`findmnt -no UUID ./mnt` rw console=tty0 console=ttyS0,115200n8 iommu=pt" > ./mnt/etc/kernel/cmdline
	
	@echo "Generating fstab"
	./genfstab > ./mnt/etc/fstab
	mkdir ./mnt/mnt/niuniu

	@echo "Installing necessary packages"
	./chroot -r ./mnt apt update

	./chroot -r ./mnt apt install -y --no-install-recommends --show-progress -V --purge \
		`grep -vE "^\s*#" requires-kernel.txt | tr "\n" " "`

	@touch $@

target/ib: target/bootstrap doca.deb
	@echo "Installing DOCA drivers"

# 	todo

	@touch $@

target/nvidia: target/bootstrap nvidia.deb
	@echo "Installing NVIDIA drivers"

# 	todo

	@touch $@

target/configure: target/bootstrap
	
	@echo "Setting hostname"
	echo "${HOSTNAME}${HOSTID}" > ./mnt/etc/hostname
	
	@echo "Setting up networkd and resolved services"
	cp systemd/network/20-bond0.netdev ./mnt/etc/systemd/network/20-bond0.netdev
	sed 's/$${HOSTID}/${HOSTID}/g' systemd/network/20-bond0.network > ./mnt/etc/systemd/network/20-bond0.network
	cp systemd/network/20-enp-bond0.network ./mnt/etc/systemd/network/20-enp-bond0.network
	./chroot -r ./mnt systemctl enable systemd-networkd systemd-resolved

	@touch $@

target/configure-ib: target/configure target/ib
	@echo "Configuring InfiniBand"
	
# 	todo

	@touch $@


target/configure-nvidia: target/configure target/nvidia
	@echo "Configuring NVIDIA"
	
# 	todo

	@touch $@


target/all: target/configure target/configure-ib target/configure-nvidia

test/boot:
	@test "${DISK}" != "" || (echo "Specify DISK=/dev/..."; exit 1)

	${MAKE} util/unmount

	mkdir -p qemu-run
	cp /usr/share/OVMF/OVMF_VARS_4M.fd ./qemu-run/OVMF_VARS_4M.fd
	qemu-system-x86_64 -m 4g -smp 8 -nographic \
		  -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
		  -drive if=pflash,format=raw,file=./qemu-run/OVMF_VARS_4M.fd \
		  -drive file=${DISK},format=raw,if=none,id=disk0,cache=directsync \
		  -netdev user,id=net0,net=10.1.0.0/22,host=10.1.0.1,dns=10.1.0.2 \
		  -device virtio-net-pci,netdev=net0 \
		  -device virtio-blk-pci,drive=disk0,bootindex=0

test/chroot:
	./chroot -r ./mnt

test/scrub:
	btrfs scrub start -B mnt
