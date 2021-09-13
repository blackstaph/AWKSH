#!/usr/bin/env ksh93 
#shell settings
ulimit -v $(( 1024 * 128 )) 
ulimit -m $(( 1024 * 64 ))
umask 077 #Let's make things r/w by user only (by defaul)
#set -o x
set +o bgnice #turn off background-nice to allow for parallel execution
#Constants
typeset -a modules=() #list of all modules 
typeset -a active_modules=() #List active modules
typeset -a serial_modules=() # list of modules run serially
typeset -a concurrent_inputs=()
typeset -a concurrent_outputs=()
typeset -i output_virginity=1
typeset -i interval=0.01
typeset -i missed_signals=0
typeset -i master_pid=$$
typeset config_path="${HOME}/.config/k9status"
typeset config_file="${config_path}/config"
FPATH="${config_path}/lib"
typeset config_action=true
typeset -SA results=()
typeset -a ids=()
typeset -A stanzas=()

usage(){
    print "
    Usage: ${0} [config_file]
    "
    exit 0
}

splat(){
    #Similar to cat but different
    typeset in_line
    while ( read in_line ) ; do 
        print ${in_line}
        unset in_line
    done
}

check_config(){
    typeset config=${1} #no I do not mean "typest -n" here
    if [[ -n ${config} ]]  ; then
        config_action='. ${config_file}'
        if [[ -f "${config}" ]] ; then
            config_file="${config_path}/config_${config}"
        elif [[ -f "${config_path}/config_${config}" ]] ; then
            config_file="${config_path}/config_${config}"
        elif [[ -n ${config} ]] && [[ -f "${config_path}/${config}" ]] ; then
            config_file="${config_path}/${config}"
        fi
    elif [[ -d ${config_path} ]] ; then
        if [[ -f ${config_file} ]] ; then
            config_action='. ${config_file}'
        else
            config_action='drop_config'
        fi
    else 
        mkdir -p ${config_path}
        config_action='drop_config'
    fi 
}

drop_config(){
    [[ -d ${config_path} ]] || mkdir -p ${config_path}
    splat > ${config_file} <<-EOF
        #K9status is a ksh93 script. It is not compatible with BASH, DASH,
        #ZSH, FISH, or any other shell. To run it you'll need at least ksh
        #version u+ (2012-08-01)

        #your config file is sourced like a regular shell file (. /<filename>)
        #That means you can configure it in whatever way you want.

        #We have a user defined type (think Object Class) called status_module
        #You instanciate it like so

        status_module time_module

        #You now have a module called 'time_module'. Modules can have any name
        #that is valid for varialbles in the POSIX shell command language
        #Your module has a parameter list that you can set like so:

        time_module=( 
            disabled=0      # if set to 1 Then the module doesn't run
            interval=1      # How frequently do you want this module to update
            concurrent=0    # 1 == run in a co-process; 0 == run in main proces
        )

        #NOTE: Intervals are simple but you need to know how they work.
        #   K9status has an internal "interval" which defaults to 1 second
        #   every \$interval k9status launches each non-concurrentmodule in
        #   succession. If your module's interval is set to 1, then it will
        #   run everytime k9status calls modules. If you set it to 2 then it
        #   run every other time (every 2 seconds) and 3 would make it run
        #   every 3rd time (every 3 seconds).
        #
        #   Concurrent modules use the interval setting to determins how long
        #   to sleep before updating themselves. 1 means sleep 1 seconds before
        #   updating. 2 means sleep 2 seconds before updating.


        #STANZA:
        #Your stanza is what get's processed into the values sent out to your
        #bar program. 

        time_module+=(
            stanza[name]=time
            stanza[instance]=local_time
        )

        time_module.update(){
            _.setkey color ${_.COLORS[CYAN]}
            _.setkey full_text $(printf "%T" now)
            _.setkey short_text $(printf "%(%m/%d-%H%M.%S)T" now)

        }
EOF
}

append_values(){
    #This function searches 
    typeset head=${1%%\|*}
    typeset tail=${1#*\|}
    results[${head}]="${tail}"

    case ${ids[*]} in
        !(*${head}*))
            ids+=( ${head} )
            ;;
    esac
    #For the uninitiated, the above case statement is a common(?) trick used
    #to avoid making a shell call to the grep command. Using the id's
    #array as the 'word' argument to case we can leverage the regex
    #features of POSIX shell in the 'pattern' portion to act if our
    #current id isn't already in the list of known id's.
}


get_values(){
    typeset output=''
    typeset line_id=''

    if (( ${#ids[*]} > 0 )) ; then
        output+="["
        for line_id in ${ids[*]}; do
            if [[ "${line_id}" != "${ids[0]}" ]]; then
                output+=","
            fi
            output+="${results[${line_id}]}"
        done
        output+="],"
    fi
    print "${output}"
}

lexit(){
    shift 
    print "$(date): ${@:? 'an error occurred'}" >&2
    exit $1
}

launcher(){
    integer total_calls=0
    typeset module
    typeset temp_val
    integer in
    integer out
    ignore_trap #don't switch until we're launched all background procs
    for module in ${modules[@]} ; do 
        typeset -n mymodule=${module}
        if (( mymodule.disabled == 0 )) ; then
            active_modules+=( ${module} )
            #mymodule.init
            if (( mymodule.concurrent == 1 )) ; then
                mymodule.run |&
                exec {in}<&p
                concurrent_inputs+=( ${in} )
                exec {out}>&p
                concurrent_outputs+=( ${out} )
            else
                serial_modules+=( ${module} )
            fi
        fi
    done
    set_trap
    while true ; do #perpetual loop ; when this loops closes main() ends
        for module in ${serial_modules[@]} ; do
            typeset -n mymodule=${module}
            mymodule.run
            append_values "$(mymodule.mapout)"
        done
        spout
        set_trap
        sleep ${interval}
    done
}

typeset -T status_module=(
    #This is a KSH93 type definition 
    integer disabled=0 # 0 == active // 1 == deactivated
    integer concurrent=0
    integer interval=1
    integer noop=0
    typeset -a stanza_scrub=( instance full_text short_text color background urgent )
    typeset -A COLORS=(
                [GREEN]='#00AF00'
                [YELLOW]='#FFFF00'
                [ORANGE]='#FF8000'
                [RED]='#FF0000'
                [CYAN]='#07DBDB'
                )
    typeset -A stanza=(
        [name]=""
        [instance]=""
        [full_text]=""
        [short_text]=""
        [color]=""
        [background]=""
        [border]=""
        [min_width]=""
        [align]=""
        [urgent]=""
        [seperator]=""
        [separator_block_width]=""
        [markup]=""
    )


    create(){
        modules+=( ${!_} )
        #typeset -A stanzas[${!_}]=()
        #eval typeset -n _.stanza='${stanzas[' ${!_} ']}'
    }

    setkey(){
        #unfortunately namerefs (typeset -n) have inconsistent behavior
        #when being invoked from inside a discipline function on positional
        #parameters. For this reason we simply snag the values and stick them
        #in local variables
        typeset key=${1}
        typeset value=${2}
        unset _.stanza[${key}]
        if [[ -n ${value} ]] ; then
           _.stanza[${key}]="${value}"
        fi
    }

    run(){
        if (( _.disabled == 1 )) ; then
            return 0
        elif (( _.concurrent == 1 ))  ; then 
            while :; do
                #unset _.stanza
                _.update && _.mapout && _.signal
                sleep ${_.interval:=1}
            done
        elif (( ++_.noop >= _.interval )) ; then
            #unset _.stanza
            _.noop=0
            _.update
        fi
    }

    signal(){
        if (( _.concurrent != 1 )) ; then
            return 0
        fi
        kill -USR1 ${master_pid} || exit
    }

    update(){
        #"update logic goes here"
        #_.stanza[full_text]="You need to define an update function"
        _.stanza[full_text]="You need to define an update function"
    }

    mapout(){ 
        #This is the method (Discipline Function) that formats output.
        typeset output="{"
        integer virgin=1
        typeset key

        for key in ${!_.stanza[@]} ; do
            if [[ -z ${_.stanza[${key}]} ]] ; then
                continue
            elif (( virgin == 1 )) ; then
                virgin=0
            else
                output+=","
            fi
            output+="\"${key}\":\"${_.stanza[${key}]}\""
        done
        #unset _.stanza
        output+="}"
        print "${!_}|${output}"
    }
)

###############################################################################
###############################################################################
#instanciate your modules here. Order is preserved in execution/presentation.
###############################################################################
###############################################################################

status_module time_module=( disabled=0 interval=1 concurrent=0 stanza[name]="time" stanza[instance]="time" )
status_module zfs_tank_module=( disabled=1 concurrent=1 stanza[name]="tank\/" stanza[instance]="tank" interval=20 ) 
status_module em0_module=( disabled=0 concurrent=1 stanza[name]="nic:em0" interval=5 )
status_module wlan0_module=( disabled=0 concurrent=1 interval=1 stanza[color]=${_.COLORS[RED]} stanza[name]="wlan0" )
status_module brightness_module=( disabled=0 concurrent=0 interval=1 stanza[name]="brightness" stanza[instance]="brightness" )
status_module power_module=( disabled=0 concurrent=0 interval=2 stanza[name]="power" stanza[instance]="power" )
status_module test_module=( disabled=0 concurrent=0 interval=2 stanza[name]="test00" stanza[instance]="test00 0x00")



###############################################################################
###############################################################################
#You need to (re)define your .update() methods here.
###############################################################################
###############################################################################
#function test_module.update {

test_module.update(){
    #unset _.stanza[full_text]
    #unset _.stanza
    _.setkey full_text "1234567890abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
    #_.setkey full_text "1234567890abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
}

function zfs_tank_module.update {
    typeset temp_val
    typeset zfs_used
    typeset zfs_avail
    zfs list -H -o used,avail tank  | read zfs_used zfs_avail
    _.stanza[full_text]="tank/:${zfs_avail}:${zfs_used}" 
    _.stanza[color]=${_.COLORS[GREEN]}
}

function time_module.update {
    _.stanza[color]=${_.COLORS[CYAN]}
    _.stanza[full_text]=$(printf "%T" now)
    _.stanza[short_text]=${_.stanza[full_text]:9:10}
}

power_module.update(){
    #Redefine update method for power_module
    integer stat_value=$(sysctl -n hw.acpi.acline)
    integer life_value=$(sysctl -n hw.acpi.battery.life)
    #typeset battery_glyph=$'\uD83D\uDD0B'
    #typeset plug_glyph=$'\ud83d\udd0b'
    typeset battery_glyph=$'\x1f50B'
    typeset plug_glyph=$'\x1f50C'
    typeset glyph
    (( stat_value == 1 )) && glyph=${plug_glyph} || glyph=${battery_glyph}

    _.setkey color ${_.COLORS[RED]}
    (( life_value > 30 )) && _.setkey color ${_.COLORS[ORANGE]}
    (( life_value > 50 )) && _.setkey color ${_.COLORS[YELLOW]}
    (( life_value > 80 )) && _.setkey color ${_.COLORS[GREEN]}

    _.setkey full_text "${glyph}${life_value}"
}

brightness_module.update(){
    #typeset glyph="🔆"
    typeset glyph=$'\x1f505'
    #typeset glyph="\ud83d\udd06" #high brightness glyph
    typeset current_brightness=$(sysctl -n hw.acpi.video.lcd0.brightness)
    (( current_brightness > 0 )) &&  _.setkey color ${_.COLORS[GREEN]}
    (( current_brightness > 60 )) &&  _.setkey color ${_.COLORS[YELLOW]}
    (( current_brightness > 70 )) &&  _.setkey color ${_.COLORS[ORANGE]}
    (( current_brightness > 80 )) &&  _.setkey color ${_.COLORS[RED]}
    #Redefine update method for brightness_module
    _.setkey full_text "${glyph}${current_brightness}"
}

wlan0_module.update(){
    typeset -a addresses=()
    typeset temp_val
    _.stanza[color]=${_.COLORS[RED]}
    ifconfig -f inet:cidr wlan0 |\
    while read temp_val; do
        case $temp_val in
            *inet*broadcast*)
                temp_val=${temp_val//*inet /}
                temp_val=${temp_val// broadcast*/}
                addresses+=( ${temp_val} )
                ;;
        esac
    done

    _.setkey full_text "wlan0:no IP"
    if (( ${#addresses} > 0 )); then
        _.setkey color ${_.COLORS[$GREEN]}
        _.stanza[full_text]="wlan0:${addresses[0]}"
    fi

}

em0_module.update(){
    typeset -a addresses=()
    typeset temp_val
    typeset -i last_count
    ifconfig -f inet:cidr em0 |\
    while read  temp_val; do
        case $temp_val in
            *inet*\ broadcast*)
                temp_val=${temp_val//*inet /}
                temp_val=${temp_val// broadcast*/}
                addresses+=( ${temp_val} )
                ;;
        esac
    done
    if (( ${#addresses[@]} == 0 )) ; then
        _.stanza[full_text]="em0:no IP"
        _.stanza[color]=${_.COLORS[RED]}
    elif (( ${#addresses[@]} == 1 )) ; then
        _.stanza[full_text]="em0:${addresses[0]}"
        _.stanza[color]=${_.COLORS[RED]}
    elif (( ${#addresses[@]} > 1 )) ; then
        _.stanza[full_text]="em0:[1/${#addresses[@]}]${addresses[0]}"
        _.stanza[color]=${_.COLORS[RED]}
    else
        if (( last_count >= ${#addresses[@]} )) ; then
            last_count=0
        fi
        _.stanza[full_text]="em0:[$((last_count+1))/${#addresses[@]}]${addresses[${last_count}]}"
        _.stanza[color]=${_.COLORS[GREEN]}
        (( last_count++ ))
    fi
}


ignore_trap(){
    trap missed_signals+=1 USR1
}

set_trap(){
    if (( missed_signals > 0 )); then
        missed_signals=0
        job_poller
    fi
    trap job_poller USR1
}

spout(){
    #This is the output handler. This is the only place output on STDOUT should
    #come from.
    if (( output_virginity == 1 )) ; then
        print '{"version":1} \n[\n'
        unset output_virginity
    fi
    ignore_trap
    print "$(get_values)"
    set_trap
}

job_poller(){
    ignore_trap
    typeset input
    for input in ${concurrent_inputs[@]} ; do
        unset input_line
        read -t0.01 -u${input} input_line
        if [[ -n ${input_line} ]] ; then
            append_values "${input_line}"
            spout
        fi
    done
    set_trap
}

process_cleanup(){
    print "cleaning up"
    for job in $(jobs -p) ; do
        kill ${job}
    done
    exit
}


###############################################################################
###############################################################################
#Start with main()
###############################################################################
###############################################################################
trap process_cleanup INT KILL STOP QUIT
main(){
    typeset input_line
    launcher
    process_cleanup
}

case $@ in 
    -h|--h|-help|--help|-?|--?)
        usage
        ;;
esac

check_config
#eval ${config_action}

main
