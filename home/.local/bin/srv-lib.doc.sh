#!/usr/bin/env bash

set -x

SRV_LIB_BASENAME="srv-lib.doc.sh" #TODO GAG can I use $0, given that I source this file?

srv_lib_add_line_to_file_if_not_present() {
    local line="$1"
    local file="$2"
    grep -qxF "$line" "$file" || echo "$line" >> "$file"
}

srv_lib_remove_line_from_file() {
    local line="$1"
    local file="$2"
    grep -vxF "$line" "$file" > temp_file && mv temp_file "$file"
}

# === USERS ===
#
# - Users 0-99 are reserved by Linux
# - I consider 100-999 to be reserved by distros (it is the case in Debian...?)
# - I use an offset of 1000 for normal users
# - I use the 'venv_id' of LXC containers as their linux uid, I use values between 2000 and 3000

srv_lib_add_group_and_user() {
    local id="$1"
    local name="$2"

    if ((id >= 1000 && id < 2000)); then
        groupadd -g ${id} ${name} && useradd -u ${id} -g ${id} ${name}
    elif ((id >= 2000 && id < 3000)); then
        groupadd -g ${id} ${name} && useradd -M -s /usr/sbin/nologin -u ${id} -g ${id} ${name}
    else
        echo "Invalid srv_lib_uid ${id}. Aborting."
        exit 1
    fi
}

srv_lib_remove_group_and_user() {
    local name="$1"
    userdel "${name}"
    groupdel "${name}"
}

srv_lib_add_normal_user() {
    local id=$1
    local name=$2
    srv_lib_add_group_and_user $((${id} + 10000)) "${name}"
}

# Example: `srv_lib_generate_mac_address "BC:24:11:64" $venv_id`
srv_lib_generate_mac_address() {
    local prefix=$1
    local last_two_bytes_decimal=$2

    local last_two_bytes_hex=$(printf '%04X\n' "$last_two_bytes_decimal")

    echo "${prefix}:${last_two_bytes_hex:0:2}:${last_two_bytes_hex:2:2}"
}


# The lxc.idmap configuration has a bit of a funky syntax.
# The most common and basic case is to express that:
# - uids starting from the guest uid 0,
# - will be mapped to host uids starting from 100000,
# - for a total of 65536
# That is the configuration mentioned in: https://wiki.archlinux.org/title/Linux_Containers
# Whose settings correspond to:
# lxc.idmap = u 0 100000 65536
# lxc.idmap = g 0 100000 65536
# Which is the output of `srv_lib_configure_lxc_idmaps 100000 65536`.
#
# In the context of this "srv-lib framework" the most common configuration is to map the guest
# uid 0 to the venv_id user in the host.
# Which is the output of `srv_lib_configure_lxc_idmaps $venv_id 100000 65536 0=$venv_id`.
srv_lib_configure_lxc_idmaps() {
    local venv_id=$1
    local host_ids_base=$2
    local host_ids_count=$3
    shift 3

    declare -A one_to_one_idmaps

    for one_to_one_idmap in "$@"
    do
        IFS='=' read -r guest_id host_id <<< "$one_to_one_idmap"
        one_to_one_idmaps[$guest_id]=$host_id

        srv_lib_add_line_to_file_if_not_present "root:${host_id}:1" "/etc/subuid"
        srv_lib_add_line_to_file_if_not_present "root:${host_id}:1" "/etc/subgid"
    done

    local current_guest_id=0

    while [ $current_guest_id -lt $host_ids_count ]; do
        local user_line=""
        local group_line=""

        if [[ ${one_to_one_idmaps[$current_guest_id]+_} ]]; then
            user_line="lxc.idmap: u $current_guest_id ${one_to_one_idmaps[$current_guest_id]} 1"
            group_line="lxc.idmap: g $current_guest_id ${one_to_one_idmaps[$current_guest_id]} 1"
            ((current_guest_id++))
        else
            local next_custom_guest_id=$host_ids_count
            for custom_mapping_guest_id in "${!one_to_one_idmaps[@]}"; do
                if [[ $custom_mapping_guest_id -gt $current_guest_id && $custom_mapping_guest_id -lt $next_custom_guest_id ]]; then
                    next_custom_guest_id=$custom_mapping_guest_id
                fi
            done

            local host_ids_start=$((host_ids_base + current_guest_id))
            local mapping_range=$((next_custom_guest_id - current_guest_id))

            user_line="lxc.idmap: u $current_guest_id $host_ids_start $mapping_range"
            group_line="lxc.idmap: g $current_guest_id $host_ids_start $mapping_range"

            current_guest_id=$next_custom_guest_id
        fi

        srv_lib_add_line_to_file_if_not_present "$user_line" "/etc/pve/lxc/${venv_id}.conf"
        srv_lib_add_line_to_file_if_not_present "$group_line" "/etc/pve/lxc/${venv_id}.conf"
    done
}

srv_lib_mount_rootfs_and_change_ownership_to_new_lxc_idmaps()
{
    local venv_id=$1
    local venv_user_name=$2


    pct mount ${venv_id}
    find "/var/lib/lxc/${venv_id}/rootfs" -user 100000 -exec chown ${venv_user_name} {} \;
    find "/var/lib/lxc/${venv_id}/rootfs" -group 100000 -exec chgrp ${venv_user_name} {} \;
    pct unmount ${venv_id}

    echo "LEAKED FILES START (should be empty):" # TODO GAG study/investigate this issue
    find / -user ${venv_id}
    find / -group ${venv_id}
    echo "Will now fix ownership..."
    find / -user ${venv_id} -exec chown root {} \;
    find / -group ${venv_id} -exec chgrp root {} \;
    echo "Print leaked files again"
    find / -user ${venv_id}
    find / -group ${venv_id}
    echo "LEAKED FILES END"
    # TODO GAG exclude mp to avoid fixing persmissions later
}

srv_lib_start_and_create_guest()
{
    local venv_id=$1
    local script_name=$2

    local script_basename="$(basename "${script_name}")"
    local srv_lib_name="$(dirname "${script_name}")/${SRV_LIB_BASENAME}"

    pct start ${venv_id}
    echo "Waiting 10 seconds for container to start and get an IP address..."
    sleep 10
    pct push ${venv_id} "${srv_lib_name}" "/tmp/${SRV_LIB_BASENAME}"
    pct push ${venv_id} "${script_name}" "/tmp/${script_basename}"
    pct exec ${venv_id} -- bash "/tmp/${script_basename}" guest-create
}

srv_lib_venv_mp_create()
{
    local venv_user_name=$1
    local host_mp_dir=$2

    mkdir -p "${host_mp_dir}"
    chown "${venv_user_name}:${venv_user_name}" "${host_mp_dir}"
}
#pveam list trinity-hdd-pve-isos # TODO GAG

# https://docs.docker.com/engine/install/ubuntu/#install-using-the-repository
srv_lib_install_docker_on_ubuntu()
{
    apt-get update
    apt-get install -y ca-certificates curl gnupg
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}