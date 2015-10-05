# Copyright (C) 2013-2015 GRNET S.A.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
# 02110-1301, USA.

assign_disk_devices_to() {
    local varname
    varname="$1"

    eval $varname=\(\)

    set -- c d e f g h e j k l m n o p q r

    for ((i = 0; i < DISK_COUNT; i++)); do
        eval $varname+=\(\"/dev/xvd$1\"\); shift
    done
}

launch_helper() {
    local name helperid rc floppy disks disk_path xen_dev ftype

    floppy="$1"

    name="snf-image-helper-$instance-$RANDOM"

    report_info "Starting customization VM..."
    echo "$($DATE +%Y:%m:%d-%H:%M:%S.%N) VM START" >&2

    set -- c d e f g h i j k l m n o p q r
    for ((i = 0; i < DISK_COUNT; i++)); do
        eval disk_path=\"\$DISK_${i}_PATH\"
        case $(stat -L -c %F "$disk_path") in
        "regular file")
            ftype=file
            ;;
        "block special file")
            ftype=phy
            ;;
        *)
            log_error "Disk: $disk_path is not a block device or a regular file"
            report_error "Disk: $disk_path is not a block device or a regular file"
            exit 1
        esac

        xen_dev="xvd$1"; shift

        disks+=" disk=$ftype:$disk_path,$xen_dev,w"
    done

    xm create /dev/null \
      kernel="$HELPER_DIR/kernel" ramdisk="$HELPER_DIR/initrd" \
      root="/dev/xvda" memory="$HELPER_MEMORY" boot="c" vcpus=1 name="$name" \
      extra="console=hvc0 hypervisor=$HYPERVISOR snf_image_activate_helper \
	  ipv6.disable=1 rules_dev=/dev/xvdb ro boot=local helper_ip=10.0.0.1 \
          monitor_port=48888 init=/usr/bin/snf-image-helper" \
      disk="file:$HELPER_DIR/image,xvda,r" disk="file:$floppy,xvdb,r" $disks \
      vif="script=${XEN_SCRIPTS_DIR}/vif-snf-image"
    add_cleanup suppress_errors xm destroy "$name"

    if ! xenstore-exists snf-image-helper; then
        xenstore-write snf-image-helper ""
	#add_cleanup xenstore-rm snf-image-helper
    fi

    helperid=$(xm domid "$name")
    xenstore-write snf-image-helper/${helperid} ""
    add_cleanup xenstore-rm snf-image-helper/${helperid}
    xenstore-chmod snf-image-helper/${helperid} r0 w${helperid}

    filter='udp and dst port 48888 and dst host 10.0.0.255 and src host 10.0.0.1'
    $TIMEOUT -k $HELPER_HARD_TIMEOUT $HELPER_SOFT_TIMEOUT \
      ./helper-monitor.py -i "vif${helperid}.0" -f "$filter" ${MONITOR_FD} &
    monitor_pid=$!

    set +e
    $TIMEOUT -k $HELPER_HARD_TIMEOUT $HELPER_SOFT_TIMEOUT \
      socat EXEC:"xm console $name",pty STDOUT | sed -u 's|^|HELPER: |g'
    rc=$?
    set -e

    echo "$($DATE +%Y:%m:%d-%H:%M:%S.%N) VM STOP" >&2

    check_helper_rc "$rc"

    set +e
    wait "$monitor_pid"
    monitor_rc=$?
    set -e

    if [ $monitor_rc -ne 0 ]; then
       log_error "Helper VM monitoring failed"
       report_error "Helper VM monitoring failed"
       exit 1
    fi

    report_info "Checking customization status..."
    result=$(xenstore-read snf-image-helper/$helperid)
    report_info "Customization status is: $result"

    check_helper_result "$result"
}

# vim: set sta sts=4 shiftwidth=4 sw=4 et ai :
