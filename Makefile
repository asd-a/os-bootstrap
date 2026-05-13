DEBIAN_VERSION ?= trixie
HOSTID ?= 1
HOSTNAME ?= i

USE_DOCA ?= 1
USE_NVIDIA ?= 1
USE_AMD ?= 0

clean-all: clean clean-deb clean-key clean-rootfs

clean-deb: 
	rm -rf nvidia.deb doca.deb

clean-rootfs:
	rm -rf rootfs.tar.xz

clean-key:
	rm -rf id_ed25519 id_ed25519.pub

clean:
	rm -rf target
	${MAKE} util/unmount
	umount -R ./rootfs/* || true
	rm -rf rootfs
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
	apt install gdisk btrfs-progs parted dosfstools debootstrap qemu-system-x86 ovmf

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

nvidia.deb: nvidia-url.txt
	@echo "Downloading NVIDIA driver deb package"
	wget `cat nvidia-url.txt` -O - > $@

doca.deb: doca-url.txt
	@echo "Downloading DOCA driver deb package"
	wget `cat doca-url.txt` -O - > $@

amd.deb: amd-url.txt
	@echo "Downloading AMD driver deb package"
	wget `cat amd-url.txt` -O - > $@

id_ed25519:
	@echo "Generating SSH key pair"
	ssh-keygen -t ed25519 -f id_ed25519 -N ""

rootfs.tar.xz: requires-basic.txt requires-kernel.txt passwd.txt id_ed25519 ssh_keys.txt nfs.conf
	${MAKE} target/dependency
	
	mkdir -p rootfs

	@echo "Bootstrapping Debian ${DEBIAN_VERSION} into ./rootfs"
	debootstrap \
		--arch=amd64 \
		--variant=minbase \
		${DEBIAN_VERSION} ./rootfs

	@echo "Setting up APT sources"
	rm ./rootfs/etc/apt/sources.list
	cp ./rootfs/usr/share/doc/apt/examples/debian.sources ./rootfs/etc/apt/sources.list.d

	@echo "Installing necessary packages"
	./chroot ./rootfs apt update
	./chroot ./rootfs apt install -y --no-install-recommends --show-progress -V \
		`grep -vE "^\s*#" requires-basic.txt | tr "\n" " "`

	./chroot ./rootfs dpkg-reconfigure locales tzdata

	./chroot ./rootfs apt install -y --no-install-recommends --show-progress -V \
		`grep -vE "^\s*#" requires-kernel.txt | tr "\n" " "`
	
	@echo "Setting up networkd and resolved services"
	./chroot ./rootfs systemctl enable systemd-networkd systemd-resolved
	ln -sf ../run/systemd/resolve/stub-resolv.conf ./rootfs/etc/resolv.conf

	@echo "Cleaning up apt cache"
	./chroot -r ./rootfs apt clean
	./chroot -r ./rootfs apt autoclean

	@echo "Setting root password"
	cat passwd.txt | ./chroot -r ./rootfs chpasswd -e

	@echo "Setting root ssh authorized keys"
	mkdir -p -m 700 ./rootfs/root/.ssh
	cat ssh_keys.txt > ./rootfs/root/.ssh/authorized_keys
	cat id_ed25519.pub >> ./rootfs/root/.ssh/authorized_keys
	cp id_ed25519 ./rootfs/root/.ssh/
	cp id_ed25519.pub ./rootfs/root/.ssh/

	@echo "Setting up NFS configuration"
	cp nfs.conf ./rootfs/etc/nfs.conf

	@echo "Packing root filesystem into $@"
	tar -C rootfs -capf $@ .


target/bootstrap: rootfs.tar.xz target/subvolume
	@echo "Bootstrapping Debian into ./mnt"
	tar -xapf rootfs.tar.xz -C ./mnt

	@touch $@

update/passwd: passwd.txt target/bootstrap
	@echo "Updating password"
	cat passwd.txt | ./chroot -r ./mnt chpasswd -e

update/hostname: target/bootstrap
	@echo "Updating hostname"
	echo "${HOSTNAME}${HOSTID}" > ./mnt/etc/hostname

update/boot: cmdline target/bootstrap
	@echo "Updating kernel cmdline and boot configuration"
	./cmdline > ./mnt/etc/kernel/cmdline
	./chroot -r ./mnt dpkg-reconfigure systemd-boot
	./chroot -r ./mnt update-initramfs -u

update/fstab: genfstab target/bootstrap
	@echo "Updating fstab"
	./genfstab > ./mnt/etc/fstab
	mkdir ./mnt/mnt/niuniu || true

NETWORK_CONF := systemd/network/20-bond0.netdev systemd/network/20-bond0.network systemd/network/20-enp-bond0.network 
update/network: ${NETWORK_CONF} target/bootstrap
	@echo "Updating network configuration"
	cp systemd/network/20-bond0.netdev ./mnt/etc/systemd/network/
	sed 's/$${HOSTID}/${HOSTID}/g' systemd/network/20-bond0.network > ./mnt/etc/systemd/network/20-bond0.network
	cp systemd/network/20-enp-bond0.network ./mnt/etc/systemd/network/

SYSCTL_CONF := $(wildcard sysctl.d/*)
update/sysctl: ${SYSCTL_CONF} target/bootstrap
	@echo "Updating sysctl configuration"
	cp sysctl.d/* ./mnt/etc/sysctl.d/

NVIDIA_MODULE_CONF := modules-load.d/nvidia.conf
target/nvidia: nvidia.deb requires-nvidia.txt ${NVIDIA_MODULE_CONF} target/bootstrap
	@echo "Installing NVIDIA driver"

	dpkg --root=./mnt -i nvidia.deb
	cp ./mnt/var/nvidia-driver-local-repo-debian*/nvidia-driver-local-*-keyring.gpg ./mnt/usr/share/keyrings/

	./chroot -r ./mnt apt update
	./chroot -r ./mnt apt install -y --no-install-recommends --show-progress -V \
		`grep -vE "^\s*#" requires-nvidia.txt | tr "\n" " "`

	@echo "Setting up NVIDIA modules"
	cp modules-load.d/nvidia.conf ./mnt/etc/modules-load.d/
	
	@touch $@

DOCA_MODULE_CONF := modules-load.d/ib.conf modules-load.d/rdma.conf 
DOCA_NETWORK_CONF := systemd/network/20-bond1.netdev systemd/network/20-bond1.network systemd/network/20-ib-bond1.network
target/doca: doca.deb requires-doca.txt ${DOCA_MODULE_CONF} ${DOCA_NETWORK_CONF} target/bootstrap 
	@echo "Installing DOCA driver"

	dpkg --root=./mnt -i doca.deb

	./chroot -r ./mnt apt update
	./chroot -r ./mnt apt install -y --no-install-recommends --show-progress -V \
		`grep -vE "^\s*#" requires-doca.txt | tr "\n" " "`

	@echo "Setting up OpenSM and InfiniBand modules"
	cp modules-load.d/ib.conf ./mnt/etc/modules-load.d/
	cp modules-load.d/rdma.conf ./mnt/etc/modules-load.d/

	@echo "Setting up OpenSM and InfiniBand network configuration"
	cp systemd/network/20-bond1.netdev ./mnt/etc/systemd/network/
	sed 's/$${HOSTID}/${HOSTID}/g' systemd/network/20-bond1.network > ./mnt/etc/systemd/network/20-bond1.network
	cp systemd/network/20-ib-bond1.network ./mnt/etc/systemd/network/

	@touch $@

target/amd: amd.deb requires-amd.txt target/bootstrap
	@echo "Installing AMD GPU drivers"

	dpkg --root=./mnt -i amd.deb

	./chroot -r ./mnt apt update
	./chroot -r ./mnt apt install -y --no-install-recommends --show-progress -V \
		`grep -vE "^\s*#" requires-amd.txt | tr "\n" " "`

	echo "/opt/rocm/lib" >> ./mnt/etc/ld.so.conf.d/rocm.conf
	echo "/opt/rocm/lib64" >> ./mnt/etc/ld.so.conf.d/rocm.conf
	./chroot -r ./mnt ldconfig

	@touch $@

target/drivers: target/bootstrap
ifeq ($(USE_NVIDIA), 1)
	${MAKE} target/nvidia
endif
ifeq ($(USE_DOCA), 1)
	${MAKE} target/doca
endif
ifeq ($(USE_AMD), 1)
	${MAKE} target/amd
endif

update/configure: target/drivers
	@echo "Configuring the system"

	@echo "Setting up fstab"
	${MAKE} update/fstab

	@echo "Setting boot configuration and kernel cmdline"
	${MAKE} update/boot

	@echo "Setting root password"
	${MAKE} update/passwd

	@echo "Setting hostname"
	${MAKE} update/hostname

	@echo "Setting up network configuration"
	${MAKE} update/network
	
	@echo "Setting up sysctl configuration"
	${MAKE} update/sysctl

all: update/configure

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

test/chroot: target/bootstrap
	./chroot -r ./mnt

test/scrub:
	btrfs scrub start -B mnt
