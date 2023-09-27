#!/bin/bash

# Switch between ROS 1 / ROS 2 workspaces without messing with environment variables
# Helpers for colcon (colbuild) and network interfaces with ROS 2
# Olivier Kermorgant

# ROS 1 / 2 workspaces are defined in overlay ordering
# ex: ros1_workspaces="/opt/ros/noetic $HOME/ros_ws1 $HOME/ros_ws2"

# replace tilde by home dir in paths
# export ros1_workspaces="${ros1_workspaces//'~'/$HOME}"
# export ros2_workspaces="${ros2_workspaces//'~'/$HOME}"
export PS1_ori=$PS1

# store arguments to this script to be used in inner functions
ROS_MANAGEMENT_ARGS="$*"


# add a command for the next auto-init
ros_management_add()
{
    if [[ ! $ROS_MANAGEMENT_ARGS == *"-k"* ]]; then
        return
    fi

    if [[ ! -e ~/.ros_management_auto_init ]]; then
        echo "$*" > ~/.ros_management_auto_init
        return
    fi

    local ros_history=$(<~/.ros_management_auto_init)

    # only valid commands are ros1ws vs ros2ws and any ros_ (exclusive)
    if [[ "$*" == *"ws" ]]; then
        local updated=${ros_history/ros[12]ws/$*}
    else
        local updated=$(echo "$ros_history" | sed "s/ros_.*/$*/")
    fi

    if [[ $updated != $ros_history ]]; then
        echo "$updated" > ~/.ros_management_auto_init
    else
        if [[ "$updated" != *"$*"* ]]; then
            echo "$*" >> ~/.ros_management_auto_init
        fi
    fi
}

# Takes a path string separated with colons and a list of sub-paths
# Removes path elements containing sub-paths
ros_management_remove_paths() {
    if [ -n "$ZSH_VERSION" ]; then
        IFS=':' read -A PATHES <<< "$1"
    else
        IFS=':' read -ra PATHES <<< "$1"
    fi
    local THISPATH=""
    local path
    for path in "${PATHES[@]}"; do
        local to_remove=0
        for i in "${@:2}"; do
        if [[ $path = $i ]]; then
            to_remove=1
            break
            fi
        done
        if [ $to_remove -eq 0 ]; then
            THISPATH="$THISPATH:$path"
        fi
    done
    echo "$THISPATH[2,-1]"
}

# Takes a list of sub-paths
# Updates ROS-related system paths by removing all elements containing sub-paths
ros_management_remove_all_paths()
{
    export AMENT_PREFIX_PATH=$(ros_management_remove_paths "$AMENT_PREFIX_PATH" $@)
    export AMENT_CURRENT_PREFIX=$(ros_management_remove_paths "$AMENT_CURRENT_PREFIX" $@)
    export PYTHONPATH=$(ros_management_remove_paths "$PYTHONPATH" $@)
    export CMAKE_PREFIX_PATH=$(ros_management_remove_paths "$CMAKE_PREFIX_PATH" $@)
    export PATH=$(ros_management_remove_paths "$PATH" $@)
    export LD_LIBRARY_PATH=$(ros_management_remove_paths "$LD_LIBRARY_PATH" $@)
}

# Register a single ROS 1 / 2 workspace, try to source in order : ws > ws/install > ws/devel
ros_management_register_workspace()
{
    local ldir="$PWD"
    local subs=("/" "/install/" "/devel/")
    local sub
    for sub in $subs
    do
        if [ -f "$1${sub}local_setup.bash" ]; then
            cd "$1${sub}"
            source "$1${sub}local_setup.bash"
            cd "$ldir"
            return
        fi
        if [ -f "$1${sub}local_setup.sh" ]; then
            cd "$1${sub}"
            source "$1${sub}local_setup.sh"
            cd "$ldir"
            return
        fi
        if [ -f "$1${sub}setup.sh" ]; then
            cd "$1${sub}"
            source "$1${sub}setup.sh"
            cd "$ldir"
            return
        fi
    done
}

# Equivalent of roscd but jumps to the source
ros2cd()
{
    local ws=$ros2_workspaces
    local dest=$(ros2 pkg prefix $1 --share)
    if [[ $dest == *"not found" ]]; then
        echo "Could not find package $1"
        return
    fi

    if [[ $dest == *"/install/"* ]]; then
    for ws in $ros2_workspaces
        do
            # identify if we are here
            if [[ "$dest" != "$ws"* ]]; then
                continue
            fi
            # Make it to the source directory if possible
            if [[ ! -d "${ws}/src" ]]; then
                continue
            fi

            # Find the source with sym link if possible
            local abs_pkg=$(readlink ${dest}/package.xml)
            if [[ $abs_pkg != "" ]]; then
                dest=$(dirname $abs_pkg)
                break
            fi
        done
    fi
    cd $dest
}

# do a Bloom release for a given distro
bloom-auto()
{
    bloom-release --ros-distro $1 --track $1 $(basename $PWD) $2
}

# Activate ROS 1 ws
ros1ws()
{
    export ROS_VERSION=1
    #export ROS_DISTRO="<unknown>"
    # Clean ROS 2 paths
    ros_management_remove_all_paths $ros2_workspaces
    unset ROS_DISTRO

    # register ROS 1 workspaces
    local ws
    for ws in $ros1_workspaces
    do
        ros_management_register_workspace $ws
    done
    for ws in $ros1_workspaces
    do
        ros_management_register_workspace $ws
    done

    if [ -f /usr/share/gazebo/setup.sh ]; then
        source /usr/share/gazebo/setup.sh
    fi

    # change prompt if you like (actually not by default)
    if [[ $# -eq 0 ]]; then
        ros_management_add ros1ws
    fi
}

# Activate ROS 2 ws
ros2ws()
{
    # Clean ROS 1 paths
    ros_management_remove_all_paths $ros1_workspaces
    unset ROS_DISTRO

    # register ROS 2 workspaces
    local ws
    for ws in "${ros2_workspaces[@]}"; do
        ros_management_register_workspace $ws
    done

    # add base ROS 1 libs in case some ROS 2 pkg need them
    export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/opt/ros/noetic/lib


    if [ -f /usr/share/gazebo/setup.sh ]; then
        source /usr/share/gazebo/setup.sh
    fi


    # update ROS prompt
    if [[ $# -eq 0 ]]; then
        ros_management_add ros2ws
    fi
}

# some shortcuts
colbuild()
{
    # Clean ROS 1 paths
    ros_management_remove_all_paths $ros1_workspaces
    unset ROS_DISTRO

    # source ROS 2 workspaces up to this one (not including)
    unset AMENT_PREFIX_PATH
    unset AMENT_CURRENT_PREFIX
    unset COLCON_PREFIX_PATH

    local ws
    local PWD="$(pwd)/"
    for ws in $ros2_workspaces; do

        # if in this workspace, run colcon
        if [[ "$PWD" = "$ws/"* ]]; then
            local cmd="colcon build --symlink-install --continue-on-error"
            # add all args, change -p to --packages-select and -pu to --packages-up-to
            # also add -t / --this to compile the package we are in
            for arg in $@; do
                case "$arg" in
                    ("-p") cmd="$cmd --packages-select" ;;
                    ("-pu") cmd="$cmd --packages-up-to" ;;
                    ("-t");&
                    ("--this")
                    # identify this package
                    local this_dir=$PWD
                    while [[ ! -e "$this_dir/package.xml" ]]
                    do
                        this_dir=$(dirname $this_dir)
                        if [[ "$this_dir" = "$ws" ]]; then
                            # we went up to the workspace root: could not identify package
                            break
                        fi
                    done
                    if [[ -e "$this_dir/package.xml" ]]; then
                        local pkg=$(grep -oP '(?<=<name>).*?(?=</name>)' $this_dir/package.xml)
                        cmd="$cmd --packages-select $pkg"
                    fi
                    ;;
                    (*) cmd="$cmd $arg" ;;
                esac
            done

            if [ -d "$ws/src/ros1_bridge" ]; then
                cmd="$cmd  --packages-skip ros1_bridge"
            fi
              (cd $ws;eval $cmd)
        fi
        # source anyway
        ros_management_register_workspace $ws
    done
}

# some shortcuts
catbuild() {
    # Clean ROS 1 paths
    ros_management_remove_all_paths $ros2_workspaces
    unset ROS_DISTRO

    # source ROS 2 workspaces up to this one (not including)
    unset AMENT_PREFIX_PATH
    unset AMENT_CURRENT_PREFIX
    unset COLCON_PREFIX_PATH

    local ws
    local PWD="$(pwd)/"
    for ws in $ros1_workspaces; do
        # if in this workspace, run colcon
        if [[ "$PWD" = "$ws/"* ]]; then
            local cmd="catkin_make -DCMAKE_INSTALL_PREFIX=/opt/ecn/ROS1/install install"
            # add all args, change -p to --packages-select and -pu to --packages-up-to
            # also add -t / --this to compile the package we are in
            for arg in $@; do
                case "$arg" in
                    ("-p") cmd="$cmd --pkg" ;;
                    ("-pu") cmd="$cmd --only-pkg-with-deps" ;;
                esac
            done
            (
                cd $ws
                eval $cmd
            )
        fi
        # source anyway
        ros_management_register_workspace $ws
    done
}

# restrict FastRTPS / Cyclone DDS to this network interface
ros_restrict()
{
    if [[ $# -eq 0 ]]; then
        echo "ros_restrict: give a network interface"
        return
    fi
    
    # slight change in Cyclone syntax since Humble / 22.04
    if [[ $(lsb_release -sr) < 22.00 ]]; then
        local legacy_cyclonedds=1
    fi

    # auto-detect if basic name
    local interface=$1
    if [[ $1 == "WIFI" ]]; then
        local interface=$(for dev in /sys/class/net/*; do [ -e "$dev"/wireless ] && echo ${dev##*/}; done)
    fi
    if [[ $1 == "ETH" ]]; then
        local interface=$(ip link | awk -F: '$0 !~ "lo|vbox|vir|wl|^[^0-9]"{print $2;getline}')
        local interface=$(for dev in $ethernet_interface; do [[ ! -e /sys/class/net/"$dev"/wireless && $(grep 1 /sys/class/net/"$dev"/carrier) ]] && echo ${dev##*/}; done)
    fi
    if [[ $1 == "lo" ]]; then
        export ROS_LOCALHOST_ONLY=1
        unset ROS_DOMAIN_ID
        unset FASTRTPS_DEFAULT_PROFILES_FILE
        # https://answers.ros.org/question/365051/using-ros2-offline-ros_localhost_only1/
        
        if [[ -n $legacy_cyclonedds ]]; then
        export CYCLONEDDS_URI='<General>
            <NetworkInterfaceAddress>lo</NetworkInterfaceAddress>
            <AllowMulticast>false</AllowMulticast>
        </General>
        <Discovery>
            <ParticipantIndex>auto</ParticipantIndex>
            <MaxAutoParticipantIndex>100</MaxAutoParticipantIndex>
            <Peers>
                <Peer address="localhost"/>
            </Peers>
        </Discovery>'
        else
        export CYCLONEDDS_URI='<General>
             <Interfaces>
                <NetworkInterface name="lo"/>
            </Interfaces>
            <AllowMulticast>false</AllowMulticast>
        </General>
        <Discovery>
            <ParticipantIndex>auto</ParticipantIndex>
            <MaxAutoParticipantIndex>100</MaxAutoParticipantIndex>
            <Peers>
                <Peer address="localhost"/>
            </Peers>
        </Discovery>'
        fi

        # only update history and prompt if raw call
        if [[ $# -eq 1 ]]; then
            ros_management_add ros_restrict $interface
            #ros_management_prompt __CLEAN
        fi
        return
    fi

    # Fast-DDS https://fast-dds.docs.eprosima.com/en/latest/fastdds/transport/whitelist.html
    # needs actual ip for this interface
    ipinet="$(ip a s $interface | egrep -o 'inet [0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}')"
    echo "<?xml version=\"1.0\" encoding=\"UTF-8\" ?>
    <profiles xmlns=\"http://www.eprosima.com/XMLSchemas/fastRTPS_Profiles\">
        <transport_descriptors>
            <transport_descriptor>
                <transport_id>CustomUDPTransport</transport_id>
                <type>UDPv4</type>
                <interfaceWhiteList>
                    <address>${ipinet##inet }</address>
                </interfaceWhiteList>
            </transport_descriptor>

            <transport_descriptor>
                <transport_id>CustomTcpTransport</transport_id>
                <type>TCPv4</type>
                <interfaceWhiteList>
                    <address>${ipinet##inet }</address>
                </interfaceWhiteList>
            </transport_descriptor>

        </transport_descriptors>

        <participant profile_name=\"CustomUDPTransportParticipant\">
            <rtps>
                <userTransports>
                    <transport_id>CustomUDPTransport</transport_id>
                </userTransports>
            </rtps>
        </participant>

        <participant profile_name=\"CustomTcpTransportParticipant\">
            <rtps>
                <userTransports>
                    <transport_id>CustomTcpTransport</transport_id>
                </userTransports>
            </rtps>
        </participant>
    </profiles>" > /tmp/fastrtps_interface_restriction_$USER.xml
    # tell where to look
    export FASTRTPS_DEFAULT_PROFILES_FILE=/tmp/fastrtps_interface_restriction_$USER.xml

    # Cyclone DDS https://dds-demonstrators.readthedocs.io/en/latest/Teams/1.Hurricane/setupCycloneDDS.html
    if [[ -n $legacy_cyclonedds ]]; then
        export CYCLONEDDS_URI="<General><NetworkInterfaceAddress>$interface"
    else
        export CYCLONEDDS_URI='<General><Interfaces><NetworkInterface name="$interface"/>'
    fi                

    # we probably do not want to limit to localhost
    unset ROS_LOCALHOST_ONLY

    # only update history and prompt if raw call
    if [[ $# -eq 1 ]]; then
        ros_management_add ros_restrict $interface
        #ros_management_prompt $interface 15
    fi
}


# restart daemon
ros2restart()
{
ros2 daemon stop
ros2 daemon start
}

# special functions for network setup on Centrale Nantes's robots
# show several usages of ros_restrict

# configure ROS_IP and ROS_MASTER_URI
# give a network interface and the ROS_MASTER_URI to be used, if not the localhost
ros_master()
{

if [[ $# -eq 0 ]]; then
    unset ROS_MASTER_URI
    unset ROS_IP
    ros_management_add ros_master
    return
fi

export ROS_IP=$(ip addr show $1 | grep "inet\b" | awk '{print $2}' | cut -d/ -f1)

if [[ $# -eq 2 ]]; then
    export ROS_MASTER_URI="http://$2:11311"
else
    export ROS_MASTER_URI="http://$ROS_IP:11311"
fi

ros_management_add ros_master $1 $2
}

ros_reset()
{
    # reset to standard network settings
    unset ROS_IP
    unset ROS_MASTER_URI

    # ROS_LOCALHOST_ONLY with cyclonedds URI
    ros_restrict lo --nohistory

    ros_management_add ros_reset
}

setopt BASH_REMATCH

# deal with auto init
if [[ $ROS_MANAGEMENT_ARGS == *"-k"* ]] && [[ -e ~/.ros_management_auto_init ]]; then
    # requested + file here
    source ~/.ros_management_auto_init
else

    # check imposed ROS version
    if [[ $ROS_MANAGEMENT_ARGS =~ (.*)(-ros)([12])(.*) ]]; then
        eval "ros${BASH_REMATCH[4]}ws"
    fi
    
    # check localhost only
    if [[ $ROS_MANAGEMENT_ARGS == *"-lo"* ]]; then
        ros_restrict lo
    fi
fi

if [[ $ROS_VERSION -eq 2 ]]; then
    complete -W "$(ros2 pkg list)" ros2cd
fi
