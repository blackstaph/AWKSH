#!/usr/bin/awk -f
# Quick script to serve as a status notifier in i3wm. 


function str_matches(st_base, pt_base, ary_match_catch, st_old_rs, st_old_rl,
                        st_old_offset, st_offset, match_count, st_base_len ){
    #usage: str_matches(s, p[, a])
    #purpose: search string 's' for pattern 'p'. Return the total number of
    #         (non-nested) longest-matches of pattern 'p' in string 's'. 
    #         if optional array [a] is supplied it is populated as follows:
    #               a[n]            = value of match #n
    #               a[n,"START"]    = index of first char of match 1
    #               a[n,"LENGTH"]   = length of match #n
    #               here 'n' is a number less than or equal to the total number
    #               of matches.
    #example:
    #   str_matches( "cat dog fox", "[a-z]o[a-z]", matches )  -->   2  
    #       In the above example matches[1] would be set to "dog", 
    #       matches[1,"START"] will be set to 5 and matches[1,"LENGTH"] will
    #       be set to 3
    #   str_matches( "x a b c o", "[abc]" )                   -->   3
    #       In the above example there is not optional array to populate with
    #       with values, starting points, and lengths. 
    #   str_matches( "a b c d e f",/[abc]/)                   --> ERROR
    #       Invalid parameter (second argument should be "[abc]" instead of 
    #       /[abc]/
    #notes: your patterns should not be regex literals beginning and ending with 
    #       '/', instead they should be strings in double quotes. 

    if (RSTART)
        st_old_rs = RSTART
    if (RLENGTH)
        st_old_rl = RLENGTH
    st_base_len = length(st_base) 
    
    st_offset = 1
    #st_end = st_base_len
    while (match(substr(st_base, st_offset), pt_base)) {
        st_offset = RSTART + RLENGTH + st_old_offset
        ary_match_catch[++match_count] = substr(st_base, 
                                                st_old_offset + RSTART,
                                                RLENGTH)
        ary_match_catch[match_count,"START"] = RSTART + st_old_offset
        ary_match_catch[match_count,"LENGTH"] = RLENGTH
        st_old_offset = st_offset - 1
    }
    if (st_old_rs)
        RSTART = st_old_rs
    if (st_old_rl)
        RLENGTH = st_old_rl
    return match_count
}

function shc_cmnd_snag( cmnd_string, base_ary,  cmnd_out_counter ){
    #usage: shc_cmnd_snag(s, a)
    #purpose: capture the standard output of command 's' to array 'a' 
    #         return the number of lines of output
    #notes: I/O redirection is not handled directly buy this function. If you
    #       want to use file descriptors it's up to you include that in your
    #       command
    delete base_ary #start with a clean slate
    for ( cmnd_out_counter = 1 ;
            cmnd_string | getline base_ary[cmnd_out_counter] ;
            cmnd_out_counter += 1){
        #empty loop
    }
    close(cmnd_string)
    return cmnd_out_counter -  1
}

function sleep(time,   command){
    #command = sprintf("sleep %i", time)
    command = "sleep " time
    return system(command)
}

function stanza_out( name, instance, color, full_text,    stanza_val, element){
    stanza["name"] = name
    stanza["instance"] = instance
    stanza["color"] = color
    stanza["full_text"] = full_text
    stanza_val = "{"
    for (element in stanza){
        if (stanza[element]) {
            #current_count++
            stanza_val = stanza_val sprintf("\"%s\":\"%s\",",
                                        element, stanza[element])
        }
    }
    gsub(/[,]$/,"},",stanza_val) #replace the last comma with stanza close
    return stanza_val
}

function get_zfs( dataset,   i, a, name, instance, color, full_text, matches,
                    zpoolout, zpoolfields, cmd ){
    color = GREEN
    cmd = "zfs list -H " dataset 
    cmd | getline zpoolout
    close(cmd)
    split(zpoolout, zpoolfields)
    full_text = sprintf("%s:%s",zpoolfields[1], zpoolfields[3])
    return stanza_out(name, instance, color, full_text)
}

function get_fs( fsRE,   i, a, name, instance, color, full_text, matches, Name ){
    shc_cmnd_snag( "df -h", fs_out)
    for (i in fs_out){
        if ( str_matches(fs_out[i], fsRE, matches) > 0 ) {
            split(fs_out[i], a, FS)
            Name = "size check"
            instance = matches[1]
            full_text = sprintf("%s: %s/%s(%s)", instance, a[4], a[2], a[5]) 
            if ( int(a[5])  < 50) 
                color = GREEN
            if ( int(a[5])  > 50) 
                color = YELLOW
            if ( int(a[5])  > 80) 
                color = ORANGE
            if ( int(a[5])  > 90) 
                color = RED
            delete fs_out
            return stanza_out(name, instance, color, full_text)
        }
    }

}

function get_ip( interface,    i, a, instance, color, full_text, name){
    shc_cmnd_snag( "ifconfig " interface, fs_out)
    color = RED
    full_text = interface ": no IP"
    instance = interface
    name = "interface"
    if (fs_out[1] ~ interface ) { #snag the first line to see if we're good
        name = "interface"
        instance = interface
    } else { #bail because we don't have a valid interface
    	name = "interface"
    	instance = interface
	color = RED
	full_text = instance " doesn't exist"
    	return stanza_out(name, instance, color, full_text)
    }
    for (i=1; i in fs_out ; i++){
        if ( ( instance ) && (fs_out[i] ~ /inet[ ,\t]+/) ) {
            split(fs_out[i], a, FS)
            if ( ! a[2] ) {
                full_text = "DOWN"
                color = RED
            } else {
		        sub(/addr:/,"",a[2]) #remove 'addr:' from GNU ifconfig
                full_text = interface ": " a[2]
                color = GREEN
            }
            return stanza_out(name, instance, color, full_text)
        }
    }
    return stanza_out(name, instance, color, full_text)

}

function check_xscreensaver(    i, ps_out, full_text, color, instance, name){
    name = "XSS"
    instance = name
    color = RED
    full_text = name ": DOWN"
    shc_cmnd_snag( "ps uxww", ps_out)
    for (i in ps_out){
        if ( str_matches(ps_out[i], "xscreensaver -nosplash") ) {
            color = GREEN
            #full_text = name ": RUNNING"
            full_text = name  #I don't need to see "RUNNING"
        }
    }
    delete ary_match_catch  
    return stanza_out(name, instance, color, full_text)
}

function check_mate(    i, ps_out, full_text, color, instance, name){
    name = "mate"
    instance = name
    color = YELLOW
    full_text = name ": DOWN"
    shc_cmnd_snag( "ps uxww", ps_out)
    for (i in ps_out){
        if ( str_matches(ps_out[i], "awk -f .*mate.awk") ) {
            color = ORANGE
            #full_text = name ": RUNNING"
            full_text = name  #I don't need to see "RUNNING"
        }
    }
    delete ary_match_catch
    return stanza_out(name, instance, color, full_text)
}

function check_brightness(   bright_unicode, bright_stat,
		       	cmd, name, instance, color, full_text){
    #bright_unicode = "🌞 " #Sun_with_face (&#127774)
    #bright_unicode = "🌣 " #white_sun 
    #bright_unicode = "☀" #black_sun_with_rays (&#127774)
    bright_unicode = "🔆" #high_brightness (&#127774)
    name = "brightness"
    instance = name    
    color = GREEN
    cmd = "sysctl -n hw.acpi.video.lcd0.brightness" #for FreeBSD
    cmd | getline bright_stat
    close(cmd)
    if ( bright_stat >= 50 )
        color = YELLOW
    if ( bright_stat >= 60 )
        color = ORANGE
    if ( bright_stat >= 80 )
        color = RED
    full_text = bright_unicode bright_stat
    return stanza_out(name, instance, color, full_text)
}

function check_power(   plug_unicode, ac_stat, battery_unicode, batt_stat,
		       	cmd, name, instance, color, full_text){
    plug_unicode = "🔌"
    battery_unicode = "🔋"
    name = "battery"
    instance = name    
    color = GREEN
    cmd = "sysctl -n hw.acpi.battery.life" #for FreeBSD
    cmd | getline batt_stat
    close(cmd)
    if ( batt_stat < 60 )
        color = YELLOW
    if ( batt_stat < 40 )
        color = ORANGE
    if ( batt_stat < 20 )
        color = RED
    cmd = "sysctl -n hw.acpi.acline" #for FreeBSD
    cmd | getline ac_stat
    close(cmd)
    if (ac_stat == 1)
        full_text = plug_unicode batt_stat "%"
    else
        full_text = battery_unicode batt_stat "%"
    return stanza_out(name, instance, color, full_text)
}

function clock(format,   name, instance, color, full_text){
    name = "clock"
    instance = name
    color = CYAN
    if (format)
        shc_cmnd_snag("date +" format, clock_out)
    else
        shc_cmnd_snag("date", clock_out)

    full_text = clock_out[1]
    return stanza_out(name, instance, color, full_text)
}

BEGIN {
    interval = 10
    interval = 1
    #GREEN = "#00FF00"
    GREEN = "#00AF00"
    YELLOW = "#FFFF00"
    ORANGE = "#FF8000"
    RED = "#FF0000"
    CYAN = "#07DBDB"
    printf("{\"version\":1}\n[\n")
    do {
        stanza_line = "["
        value =  get_fs("/$")
        #sub(/$/,check_xscreensaver(),stanza_line)   #append return value
        #sub(/$/,check_mate(),stanza_line)           #append return value
        #sub(/$/,get_fs("/$"),stanza_line)           #append return value
        #sub(/$/,get_zfs("zroot"),stanza_line)           #append return value
        #sub(/$/,get_ip("lagg0"),stanza_line)        #append return value
        #sub(/$/,check_brightness(),stanza_line)        #append return value   
        #sub(/$/,check_power(),stanza_line)        #append return value   
        sub(/$/,clock(),stanza_line)                #append return value   
        sub(/[,]$/,"],",stanza_line) #remove trailing comma before entry end
        print stanza_line
        #runs++
        delete stanza
        delete fs_out
    } while ( sleep(interval) == 0 )
}
