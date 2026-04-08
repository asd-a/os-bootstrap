DEBIAN_VERSION ?= trixie
HOSTID ?= 1
HOSTNAME ?= i

clean-deb: 
	rm -rf nvidia.deb doca.deb

clean:
	rm -rf target
	${MAKE} util/unmount
	rm -rf mnt 
	rm -rf qemu-run

util/mount:
	@test "${DISK}" != "" || (echo "Specify DISK=/dev/..."; exit 1)

	mount --mkdir `lsblk -nlo PATH ${DISK} | awk 'NR==3 {print}'` ./mnt
	mount --mkdir -o fmask=027,umask=027 `lsblk -nlo PATH ${DISK} | awk 'NR==2 {print}'` ./mnt/boot

util/unmount:
	umount ./mnt/boot 	|| true
	umount ./mnt 		|| true

target/dependency:
	apt install gdisk btrfs-progs parted dosfstools debootstrap qemu-system-x86 ovmf arch-install-scripts

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
	btrfs su create mnt/opt
	chattr +C mnt/var/cache

	@touch $@

nvidia.deb:
	@echo "Downloading NVIDIA driver deb package"
	wget https://developer.download.nvidia.com/compute/nvidia-driver/590.48.01/local_installers/nvidia-driver-local-repo-debian13-590.48.01_1.0-1_amd64.deb -O $@

doca.deb:
	@echo "Downloading DOCA driver deb package"
	wget https://www.mellanox.com/downloads/DOCA/DOCA_v3.3.0/host/doca-host_3.3.0-088000-26.01-debian13_amd64.deb -O $@

target/bootstrap: target/subvolume nvidia.deb doca.deb
	@echo "Bootstrapping Debian ${DEBIAN_VERSION} into ./mnt"
	debootstrap \
		--arch=amd64 \
		--variant=minbase \
		${DEBIAN_VERSION} ./mnt
	
	# install nivida gpu driver and ofed driver package source lists and keyrings into the chroot environment
	dpkg --root=./mnt -i doca.deb nvidia.deb
	cp ./mnt/var/nvidia-driver-local-repo-debian*/nvidia-driver-local-*-keyring.gpg ./mnt/usr/share/keyrings/

	@echo "Setting kernel cmdline"
	echo "root=UUID=`findmnt -no UUID ./mnt` rw console=tty0 console=ttyS0,115200n8 iommu=pt" > ./mnt/etc/kernel/cmdline
	
	@echo "Generating fstab"
	./genfstab > ./mnt/etc/fstab

	@echo "Setting up APT sources"
	rm ./mnt/etc/apt/sources.list
	cp ./mnt/usr/share/doc/apt/examples/debian.sources ./mnt/etc/apt/sources.list.d

	@echo "Installing necessary packages"
	arch-chroot ./mnt apt update
	arch-chroot ./mnt apt install -y --no-install-recommends --show-progress -V \
		`grep -vE "^\s*#" requires-basic.txt | tr "\n" " "`

	arch-chroot ./mnt dpkg-reconfigure locales tzdata

	arch-chroot ./mnt apt install -y --no-install-recommends --show-progress -V \
		`grep -vE "^\s*#" requires-kernel.txt | tr "\n" " "`

	@touch $@

target/driver: target/bootstrap
	@echo "Installing NVIDIA and DOCA drivers"

	arch-chroot ./mnt apt update
	arch-chroot ./mnt apt install -y --no-install-recommends --show-progress -V \
		`grep -vE "^\s*#" requires-driver.txt | tr "\n" " "`

	@touch $@

target/configure: target/driver
	@echo "Setting root password"
	cat passwd.txt | arch-chroot ./mnt chpasswd -e
	
	@echo "Setting hostname"
	echo "${HOSTNAME}${HOSTID}" > ./mnt/etc/hostname

	@echo "Setting root ssh authorized keys"
	mkdir -p ./mnt/root/.ssh
	cat ssh_keys.txt > ./mnt/root/.ssh/authorized_keys

	@echo "Setting up OpenSM and InfiniBand modules"
	cp modules-load.d/ib.conf ./mnt/etc/modules-load.d/ib.conf
	sed 's/$${HOSTID}/${HOSTID}/g' systemd/system/opensm.service > ./mnt/etc/systemd/system/opensm.service
	arch-chroot ./mnt systemctl enable opensm

	@echo "Setting up networkd and resolved services"
	arch-chroot ./mnt systemctl enable systemd-networkd systemd-resolved
	ln -sf ../run/systemd/resolve/stub-resolv.conf ./mnt/etc/resolv.conf
	cp systemd/network/20-bond0.netdev ./mnt/etc/systemd/network/20-bond0.netdev
	sed 's/$${HOSTID}/${HOSTID}/g' systemd/network/20-bond0.network > ./mnt/etc/systemd/network/20-bond0.network
	cp systemd/network/20-enp-bond0.network ./mnt/etc/systemd/network/20-enp-bond0.network
	
	@echo "Setting up IP over IB"
	cp systemd/network/20-bond1.netdev ./mnt/etc/systemd/network/20-bond1.netdev
	sed 's/$${HOSTID}/${HOSTID}/g' systemd/network/20-bond1.network > ./mnt/etc/systemd/network/20-bond1.network
	cp systemd/network/20-ib-bond1.network ./mnt/etc/systemd/network/20-ib-bond1.network

	@touch $@

target/all: target/configure

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
	arch-chroot ./mnt

test/scrub:
	btrfs scrub start -B mnt
