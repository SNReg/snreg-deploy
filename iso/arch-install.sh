#!/bin/bash
# Unattended Arch install, run by the live ISO on tty1 (archiso's script= parameter). Arch has no
# installer config format, so this is the "archiso profile" of spec §6.2: wipe the first fixed
# disk, pacstrap a minimal system, then run the shared setup.sh inside it.
# snreg-iso fills in admin_hash below.
set -euxo pipefail
src=/run/archiso/bootmnt/snreg
admin_hash='@ADMIN_HASH@' # crypt(3) chars only: [./A-Za-z0-9$]
exec > >(tee /root/snreg-install.log) 2>&1 # stdout is already tty1

# The first non-removable, writable disk (the install stick is removable; the DVD is a rom).
disk=$(lsblk -dpno NAME,TYPE,RM,RO | awk '$2 == "disk" && $3 == 0 && $4 == 0 {print $1; exit}')
[[ -n $disk ]]
part() { if [[ $disk =~ [0-9]$ ]]; then echo "${disk}p$1"; else echo "$disk$1"; fi; }

for _ in $(seq 120); do curl -fsI https://archlinux.org >/dev/null && break; sleep 2; done
# pacman's keyring is set up by a boot-time one-shot service; pacstrap needs it. `start` waits
# for it whether it's still running, finished, or not started yet.
systemctl start pacman-init.service

wipefs -af "$disk"
if [[ -d /sys/firmware/efi ]]; then
  printf 'label: gpt\nsize=512M, type=U\ntype=L\n' | sfdisk -q "$disk"
  esp=$(part 1)
else # GPT on BIOS needs a BIOS boot partition for GRUB's core image
  printf 'label: gpt\nsize=1M, type=21686148-6205-4E54-A2BC-6578C2E15D2C\ntype=L\n' | sfdisk -q "$disk"
  esp=
fi
udevadm settle
root=$(part 2)
mkfs.ext4 -qF "$root"
mount "$root" /mnt
if [[ -n $esp ]]; then mkfs.fat -F32 "$esp"; mount --mkdir -t vfat "$esp" /mnt/boot; fi

# Mirrors stall now and then; a stalled pacstrap must not end a zero-touch install.
for try in 1 2 3; do
  pacstrap -K /mnt base linux grub ${esp:+efibootmgr} --disable-download-timeout && break
  [[ $try = 3 ]] && exit 1
  sleep 10
done
genfstab -U /mnt >>/mnt/etc/fstab
echo snreg-device >/mnt/etc/hostname
ln -sf /usr/share/zoneinfo/UTC /mnt/etc/localtime
printf '[Match]\nName=en* eth*\n\n[Network]\nDHCP=yes\n' >/mnt/etc/systemd/network/20-wired.network
arch-chroot /mnt usermod -p "$admin_hash" root
arch-chroot /mnt sh -ec '
  systemctl enable systemd-networkd systemd-resolved
  if [ -d /sys/firmware/efi ]; then
    grub-install --target=x86_64-efi --efi-directory=/boot --removable
  else
    grub-install --target=i386-pc '"$disk"'
  fi
  grub-mkconfig -o /boot/grub/grub.cfg'

cp -r "$src" /mnt/tmp/snreg
arch-chroot /mnt sh /tmp/snreg/setup.sh /tmp/snreg
rm -rf /mnt/tmp/snreg
# Last: arch-chroot gives the chroot the live system's resolver only while this is a plain file.
ln -sf /run/systemd/resolve/stub-resolv.conf /mnt/etc/resolv.conf
sync
umount -R /mnt
reboot
