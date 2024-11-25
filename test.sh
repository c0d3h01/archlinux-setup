#!/usr/bin/env bash
set -e

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

declare -A CONFIG

# Configuration function
init_config() {

    while true; do
        read -s -p "Enter a single password for root and user: " PASSWORD
        echo
        read -s -p "Confirm the password: " CONFIRM_PASSWORD
        echo
        if [ "$PASSWORD" = "$CONFIRM_PASSWORD" ]; then
            break
        else
            echo "Passwords do not match. Try again."
        fi
    done

    CONFIG=(
        [DRIVE]="/dev/nvme0n1"
        [HOSTNAME]="archlinux"
        [USERNAME]="c0d3h01"
        [PASSWORD]="$PASSWORD"
        [TIMEZONE]="Asia/Kolkata"
        [LOCALE]="en_US.UTF-8"
        [CPU_VENDOR]="amd"
        [BTRFS_OPTS]="defaults,noatime,compress=zstd:1,compress-force=zstd,space_cache=v2,commit=120,discard=async,autodefrag,clear_cache,ssd,nodiratime"
    )

    CONFIG[EFI_PART]="${CONFIG[DRIVE]}p1"
    CONFIG[ROOT_PART]="${CONFIG[DRIVE]}p2"
}

# Logging functions
info() { echo -e "${BLUE}INFO:${NC} $*"; }
warn() { echo -e "${YELLOW}WARN:${NC} $*"; }
error() {
    echo -e "${RED}ERROR:${NC} $*" >&2
    exit 1
}
success() { echo -e "${GREEN}SUCCESS:${NC} $*"; }

# Disk preparation function
setup_disk() {
    info "Preparing disk partitions..."

    # Safety check
    read -p "WARNING: This will erase ${CONFIG[DRIVE]}. Continue? (y/N)" -n 1 -r
    echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && error "Operation cancelled by user"

    # Partition the disk
    sgdisk --zap-all "${CONFIG[DRIVE]}"
    sgdisk --clear "${CONFIG[DRIVE]}"
    sgdisk --set-alignment=8 "${CONFIG[DRIVE]}"

    # Create partitions
    sgdisk --new=1:0:+1G \
        --typecode=1:ef00 \
        --change-name=1:"EFI" \
        --new=2:0:0 \
        --typecode=2:8300 \
        --change-name=2:"ROOT" \
        --attributes=2:set:2 \
        "${CONFIG[DRIVE]}"

    # Verify and update partition table
    sgdisk --verify "${CONFIG[DRIVE]}" || error "Partition verification failed"
    partprobe "${CONFIG[DRIVE]}"
}

# Filesystem setup function
setup_filesystems() {
    info "Setting up filesystems..."

    # Format partitions
    mkfs.fat -F32 -n EFI "${CONFIG[EFI_PART]}"
    mkfs.btrfs -f -L ROOT -n 32k -m dup "${CONFIG[ROOT_PART]}"

    # Create BTRFS subvolumes
    mount "${CONFIG[ROOT_PART]}" /mnt
    pushd /mnt >/dev/null

    local subvolumes=("@" "@home" "@cache" "@srv" "@tmp" "@log" "@pkg" "@.snapshots")
    for subvol in "${subvolumes[@]}"; do
        btrfs subvolume create "$subvol"
    done

    popd >/dev/null
    umount /mnt

    # Mount subvolumes
    mount -o "${CONFIG[BTRFS_OPTS]},subvol=@" "${CONFIG[ROOT_PART]}" /mnt

    # Create mount points
    mkdir -p /mnt/{home,var/log,var/cache/pacman/pkg,.snapshots,boot/efi,tmp,srv}

    # Mount other subvolumes
    mount -o "${CONFIG[BTRFS_OPTS]},subvol=@home" "${CONFIG[ROOT_PART]}" /mnt/home
    mount -o "${CONFIG[BTRFS_OPTS]},subvol=@log" "${CONFIG[ROOT_PART]}" /mnt/var/log
    mount -o "${CONFIG[BTRFS_OPTS]},subvol=@pkg" "${CONFIG[ROOT_PART]}" /mnt/var/cache/pacman/pkg
    mount -o "${CONFIG[BTRFS_OPTS]},subvol=@.snapshots" "${CONFIG[ROOT_PART]}" /mnt/.snapshots
    mount -o "${CONFIG[BTRFS_OPTS]},subvol=@tmp" "${CONFIG[ROOT_PART]}" /mnt/tmp
    mount -o "${CONFIG[BTRFS_OPTS]},subvol=@srv" "${CONFIG[ROOT_PART]}" /mnt/srv
    mount "${CONFIG[EFI_PART]}" /mnt/boot/efi
}

# Base system installation function
install_base_system() {
    info "Installing base system..."
    
    # Pacman configure for arch-iso
    sed -i 's/^#ParallelDownloads/ParallelDownloads/' /etc/pacman.conf
    sed -i 's/^#Color/Color/' /etc/pacman.conf
    sed -i '/^# Misc options/a DisableDownloadTimeout\nILoveCandy' /etc/pacman.conf

    pacman-key --recv-keys F3B607488DB35A47 --keyserver keyserver.ubuntu.com
    pacman-key --lsign-key F3B607488DB35A47

    pacman -U 'https://mirror.cachyos.org/repo/x86_64/cachyos/cachyos-keyring-20240331-1-any.pkg.tar.zst' \
                'https://mirror.cachyos.org/repo/x86_64/cachyos/cachyos-mirrorlist-18-1-any.pkg.tar.zst' \
                'https://mirror.cachyos.org/repo/x86_64/cachyos/cachyos-v3-mirrorlist-18-1-any.pkg.tar.zst' \
                'https://mirror.cachyos.org/repo/x86_64/cachyos/pacman-7.0.0.r3.gf3211df-3.1-x86_64.pkg.tar.zst'
    sed -i '/\[cachyos\]/,/^$/d' /etc/pacman.conf && 
    sed -i '/\[cachyos-v3\]/,/^$/d' /etc/pacman.conf && 
    echo -e "\n[cachyos]\nInclude = /etc/pacman.d/cachyos-mirrorlist\n\n[cachyos-v3]\nInclude = /etc/pacman.d/cachyos-v3-mirrorlist" | sudo tee -a /etc/pacman.conf && 

    # Update the mirrorlist with the 20 latest HTTPS mirrors sorted by rate
    info "Updating mirrorlist with the latest 20 mirrors..."
    reflector --latest 20 --protocol https --sort rate --save /etc/pacman.d/mirrorlist

    # Refresh package databases
    pacman -Syy
    
    local base_packages=(
        # Core System
        base base-devel
        linux linux-firmware
        linux-cachyos-autofdo linux-cachyos-autofdo-headers

        # CachyOS Kernel
        cachyos-linux cachyos-linux-headers

        # Essential System Utilities
        networkmanager grub efibootmgr
        btrfs-progs reflector sudo git nano

        # CPU & GPU Drivers
        amd-ucode xf86-video-amdgpu
    )

    pacstrap /mnt "${base_packages[@]}" || error "Failed to install base packages"
}

# System configuration function
configure_system() {
    info "Configuring system..."

    # Generate fstab
    genfstab -U /mnt >>/mnt/etc/fstab

    # Chroot and configure
    arch-chroot /mnt /bin/bash <<EOF    
    # Set timezone and clock
    ln -sf /usr/share/zoneinfo/${CONFIG[TIMEZONE]} /etc/localtime
    hwclock --systohc

    # Set locale
    echo "${CONFIG[LOCALE]} UTF-8" >> /etc/locale.gen
    locale-gen
    echo "LANG=${CONFIG[LOCALE]}" > /etc/locale.conf

    # Set hostname
    echo "${CONFIG[HOSTNAME]}" > /etc/hostname

    # Configure hosts
    tee > /etc/hosts <<-END
# Standard host addresses
127.0.0.1  localhost
::1        localhost ip6-localhost ip6-loopback
ff02::1    ip6-allnodes
ff02::2    ip6-allrouters
# This host address
127.0.1.1  ${CONFIG[HOSTNAME]}
END

    # Set root password
    echo "root:${CONFIG[PASSWORD]}" | chpasswd

    # Create user
    useradd -m -G wheel -s /bin/bash ${CONFIG[USERNAME]}
    echo "${CONFIG[USERNAME]}:${CONFIG[PASSWORD]}" | chpasswd
    
    # Configure sudo
    sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

    # Configure bootloader
    sed -i 's|GRUB_CMDLINE_LINUX_DEFAULT=".*"|GRUB_CMDLINE_LINUX_DEFAULT="nowatchdog nvme_load=YES zswap.enabled=0 splash loglevel=3"|' /etc/default/grub
    sed -i 's|GRUB_TIMEOUT=.*|GRUB_TIMEOUT=2|' /etc/default/grub

    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ARCH
    grub-mkconfig -o /boot/grub/grub.cfg
    mkinitcpio -P
EOF
}

# Performance optimization function
apply_optimizations() {
    info "Applying system optimizations..."
    arch-chroot /mnt /bin/bash <<EOF

    pacman-key --recv-keys F3B607488DB35A47 --keyserver keyserver.ubuntu.com
    pacman-key --lsign-key F3B607488DB35A47

    pacman -U 'https://mirror.cachyos.org/repo/x86_64/cachyos/cachyos-keyring-20240331-1-any.pkg.tar.zst' \
                'https://mirror.cachyos.org/repo/x86_64/cachyos/cachyos-mirrorlist-18-1-any.pkg.tar.zst' \
                'https://mirror.cachyos.org/repo/x86_64/cachyos/cachyos-v3-mirrorlist-18-1-any.pkg.tar.zst' \
                'https://mirror.cachyos.org/repo/x86_64/cachyos/pacman-7.0.0.r3.gf3211df-3.1-x86_64.pkg.tar.zst'
    sed -i '/\[cachyos\]/,/^$/d' /etc/pacman.conf && 
    sed -i '/\[cachyos-v3\]/,/^$/d' /etc/pacman.conf && 
    echo -e "\n[cachyos]\nInclude = /etc/pacman.d/cachyos-mirrorlist\n\n[cachyos-v3]\nInclude = /etc/pacman.d/cachyos-v3-mirrorlist" | sudo tee -a /etc/pacman.conf && 

    # Update the mirrorlist with the 20 latest HTTPS mirrors sorted by rate
    info "Updating mirrorlist with the latest 20 mirrors..."
    reflector --latest 20 --protocol https --sort rate --save /etc/pacman.d/mirrorlist

    # Refresh package databases
    pacman -Syy
    
    sed -i 's/^#ParallelDownloads/ParallelDownloads/' /etc/pacman.conf
    sed -i 's/^#Color/Color/' /etc/pacman.conf
    sed -i '/^# Misc options/a DisableDownloadTimeout\nILoveCandy' /etc/pacman.conf

# ZRAM configuration
tee > "/etc/systemd/zram-generator.conf" <<'ZRAMCONF'
[zram0]
zram-size = ram
compression-algorithm = zstd
max-comp-streams = auto
swap-priority = 100
fs-type = swap
ZRAMCONF

EOF
}

archinstall() {
    info "Starting Arch Linux installation script..."
    init_config

    # Main installation steps
    setup_disk
    setup_filesystems
    install_base_system
    configure_system
    apply_optimizations
    umount -R /mnt
    success "Installation completed! You can now reboot your system."
}

# Main execution function
main() {
    case "$1" in
    "--install" | "-i")
        archinstall
        ;;
    "--setup" | "-s")
        usrsetup
        ;;
    "--help" | "-h")
        show_help
        ;;
    "")
        echo "Error: No arguments provided"
        show_help
        exit 1
        ;;
    *)
        echo "Error: Unknown option: $1"
        show_help
        exit 1
        ;;
    esac

}

show_help() {
    tee <<EOF
Usage: $(basename "$0") [OPTION]

Options:
    -i, --install    Run Arch Linux installation
    -s, --setup      Setup user configuration
    -h, --help       Display this help message
EOF
}

# Execute main function
main "$@"
