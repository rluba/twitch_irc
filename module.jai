Status :: enum_flags {
    DISCONNECTED    :: 0;
    CONNECTING      :: 1;
    CONNECTED       :: 2;
    AUTHENTICATING  :: 4;
    AUTHENTICATED   :: 8;
}

Error :: enum {
    NONE           ::   0;
    OUT_OF_MEMORY  ::  -2;
    SOCKET_CREATE  ::  -3;
    SOCKET_CONNECT ::  -4;
    SOCKET_SEND    ::  -5;
    SOCKET_RECV    ::  -6;
    SOCKET_CLOSE   ::  -7;
    EPOLL_CREATE   ::  -8;
    EPOLL_CTL      ::  -9;
    EPOLL_WAIT     :: -10; // epoll_pwait() error
    CONN_CLOSED    :: -11; // Connection lost: peer closed it
    CONN_HANGUP    :: -12; // Connection lost: unexpectedly
    CONN_SOCKET    :: -13; // Connection lost: socket error
    EPOLL_SIG      :: -14; // epoll_pwait() caught a signal
}

TWITCH_BUFFER_SIZE :: 2048;

Twitch_Chat :: struct (Data_Type: Type) {
	status:           Status = .DISCONNECTED;
	buffer:           [] u8;                      // IRC message buffer
    unconsumed_bytes: int;
	login:            Twitch_Login;
	error:            Error;                         // Last error that occured
    event_callback:   (event: Twitch_Event, data: *Data_Type);
    event_callback_data: *Data_Type;
    verbose:          bool;

	socket:           s32 = -1;
    #if OS == .LINUX {
        epoll_handle: s32 = -1;
    }
    #if OS == .MACOS {
        kevent_queue: s32 = -1;
    }
}

Twitch_Login :: struct {
    nickname: string;
    password: string;
	display_name: string;
	id:   string;
}

Twitch_Tag :: struct {
	key: string;
	value: string;
}

Twitch_Event :: struct {
	raw:          string;           // The raw message as received

    // Split, but not interpreted
	prefix:       string;           // IRC message prefix
	command:      string;           // IRC message command
	command_args: [] string;           // IRC message command args
    parameter:    string;
    tags:         [] Twitch_Tag;
	ctcp:         string;           // CTCP commmand, if any

    // Interpreted from the split fields above
    type:         Command_Type;     // Parsed command type
	origin:       string;           // Nick as extracted from prefix
	channel:      string;           // Channel as extracted from params
	target:       string;           // Target user of hosts, bans, etc.
	message:      string;           // Message as extracted from params
}

Command_Type :: enum {
    UNKNOWN;

    CAP;
    AUTHENTICATED;
    GLOBALUSERSTATE;

    JOIN;
    PART;
    CLEARCHAT;
    ROOMSTATE;
    USERSTATE;
    MODERATOR;

    HOSTTARGET;

    PRIVMSG;
    CLEARMSG;
    NOTICE;
    USERNOTICE;
    WHISPER;

    PING;

    NAMES;
    END_OF_NAMES;

    RECONNECT;

    INVALID_COMMAND;

    CTCP_ACTION;
}

init :: (s: *Twitch_Chat($T), callback: (event: Twitch_Event, data: *T), callback_data: *T, verbose := false) {
    s.buffer = NewArray(TWITCH_BUFFER_SIZE, u8, initialized = false);
    s.event_callback = callback;
    s.event_callback_data = callback_data;
    s.verbose = verbose;
}

deinit :: (s: *$T/Twitch_Chat) {
    disconnect(s);
	array_free(s.buffer);
}

connect :: (s: *$T/Twitch_Chat, nickname: string, password: string, hostname := "irc.chat.twitch.tv", port := "6667") -> bool {
    if s.verbose then log("Connecting to %:% as %…", hostname, port, nickname);
	// Create socket
    s.socket = socket(AF_INET, SOCK_STREAM, 0);
    if s.socket == -1 {
        error_code, error_string := get_error_value_and_string();
        log_error("Could not create socket: % %", error_code, error_string);
        return false;
    }

	fl_value := fcntl(s.socket, F_GETFL);
	fl_value |= O_NONBLOCK;
    result := fcntl(s.socket, F_SETFL, fl_value);
    if result == -1 {
        error_code, error_string := get_error_value_and_string();
        log_error("Could not set socket to non-blocking: % %", error_code, error_string);
        close_and_reset(*s.socket);
        return false;
    }

    #if OS == .LINUX {
        s.epoll_handle = epoll_create(1);
        if s.epoll_handle < 0 {
            error_code, error_string := get_error_value_and_string();
            log_error("Could not create epoll instance: % %", error_code, error_string);
            disconnect(s);
            return false;
        }

        // Set up the epoll instance
        eev: epoll_event;
        eev.data.ptr = s;
        eev.events = EPOLLRDHUP | EPOLLOUT | EPOLLIN | EPOLLET;
        result = epoll_ctl(s.epoll_handle, EPOLL_CTL_ADD, s.socket, *eev);
        if result {
            error_code, error_string := get_error_value_and_string();
            log_error("Could not configure epoll instance: % %", error_code, error_string);
            disconnect(s);
            return -1;
        }

    } else {
        s.kevent_queue = kqueue();
        if s.kevent_queue == -1 {
            error_code, error_string := get_error_value_and_string();
            log_error("Could not create event queue: % %", error_code, error_string);
            disconnect(s);
            return false;
        }

        INTERESTING_EVENTS :: Kevent_Filter.[.READ, .WRITE];
        events: [INTERESTING_EVENTS.count] Kevent64;
        for INTERESTING_EVENTS {
            events[it_index].ident = cast(u64) s.socket;
            events[it_index].filter = it;
            events[it_index].flags = .ADD;
        }

        result = kevent64(s.kevent_queue, events.data, events.count, null, 0, 0, null);
        if result == -1 {
            error_code, error_string := get_error_value_and_string();
            log_error("Could not register events with the event queue: % %", error_code, error_string);
            disconnect(s);
            return false;
        }
    }

	// Connect the socket (and handle a possible connection error)
    hints: addrinfo;
	hints.ai_family   = AF_INET;
	hints.ai_socktype = SOCK_STREAM;
	hints.ai_protocol = IPPROTO_TCP;

    info: *addrinfo;
    defer {
        if info then freeaddrinfo(info);
    }
    c_hostname := temp_c_string(hostname);
    c_port := temp_c_string(port);
    result = getaddrinfo(c_hostname, c_port, *hints, *info);
    if result {
        error_code, error_string := get_error_value_and_string();
        log_error("Could not get addr info: % %", error_code, error_string);
        disconnect(s);
		return false;
	}

    con := connect(s.socket, info.ai_addr, info.ai_addrlen);

    if con == -1 {
        error_code := errno();
        if error_code != EINPROGRESS && error_code != EALREADY {
            error_string := get_error_string(error_code);
            log_error("Could not connect to host %:%: % %", hostname, port, error_code, error_string);
            disconnect(s);
            return false;
        }
    }

	s.status = .CONNECTING;
    s.login.nickname = copy_string(nickname);
    s.login.password = copy_string(password);
	return true;
}

quit_and_disconnect :: (s: *$T/Twitch_Chat) -> bool {
	if !cmd_quit(s) then return false; 
    disconnect(s);
    return true;
}

update :: (s: *$T/Twitch_Chat, timeout_ms := -1) -> bool {
    #if OS == .LINUX {
        epev: epoll_event;
        
        // epoll_wait()/epoll_pwait() will return -1 if a signal is caught.
        // User code might catch "harmless" signals, like SIGWINCH, that are
        // ignored by default. This would then cause epoll_wait() to return
        // with -1, hence our main loop to come to a halt. This is not what
        // a user would expect; we should only come to a halt on "serious"
        // signals that would cause program termination/halt by default.
        // In order to achieve this, we tell epoll_pwait() to block all of
        // the signals that are ignored by default. For a list of signals:
        // https://en.wikipedia.org/wiki/Signal_(IPC)
        
        sigset: sigset_t;
        sigemptyset(*sigset);
        sigaddset(*sigset, SIGCHLD);  // default: ignore
        sigaddset(*sigset, SIGCONT);  // default: continue execution
        sigaddset(*sigset, SIGURG);   // default: ignore
        sigaddset(*sigset, SIGWINCH); // default: ignore

        num_events = epoll_pwait(s.epoll_handle, *epev, 1, timeout_ms, *sigset);

        // An error has occured
        if num_events == -1 {
            // The exact reason why epoll_wait failed can be queried through
            // errno; the possibilities include wrong/faulty parameters and,
            // more interesting, that a signal has interrupted epoll_wait().
            // Wrong parameters will either happen on the very first call or
            // not at all, but a signal could come in anytime. Either way, 
            // epoll_wait() failing doesn't necessarily mean that we lost 
            // the connection with the server. Some signals, like SIGSTOP 
            // can mean that we're simply supposed to stop execution until 
            // a SIGCONT is received. Hence, it seems like a good idea to 
            // leave it up to the user what to do, which means that we are
            // not going to quit/disconnect from IRC; we're simply going to
            // return -1 to indicate an issue. The user can then check the 
            // connection status and decide if they want to explicitly end 
            // the connection or keep it alive. One exception: if we can 
            // actually determine, right here, that the connection seems to
            // be down, then we'll set off the disconnect event handlers.
            // For this, we'll use tcpsock_status().

            // Set the error accordingly:
            error_code := errno();
            if error_code == EINTR {
                s.error = .EPOLL_SIG;
            } else {
                s.error = .EPOLL_WAIT;
            }
            
            // Were we connected previously but now seem to be disconnected?
            if is_connected(s) && tcpsock_status(s.socket) == -1 {
                disconnect(s);
            }
            return false;
        }
        
        if num_events == 0 {
            return true;
        }

        // We've got data coming in
        if epev.events & EPOLLIN {
            success := read_and_process_data(s);
            if !success then return false;
        }
        
        // We're ready to send data
        if epev.events & EPOLLOUT {
            // If we weren't connected yet, we seem to be now!
            if s.status & .CONNECTING {		
                status = .CONNECTED;
                capreq(s);
                auth(s);
            }
        }
        
        // Server closed the connection
        if epev.events & EPOLLRDHUP {
            s.error = .CONN_CLOSED;
            disconnect(s);
            return false;
        }
        
        // Unexpected hangup on socket 
        if epev.events & EPOLLHUP {
            s.error = .CONN_HANGUP;
            disconnect(s);
            return false;
        }

        // Socket error
        if epev.events & EPOLLERR {
            s.error = .CONN_SOCKET;
            disconnect(s);
            return false;
        }
    }
    #if OS == .MACOS {
        timeout_spec_pointer: *timespec = null;
        timeout_spec: timespec;
        if timeout_ms >= 0 {
            timeout_spec.tv_sec = timeout_ms / 1000;
            timeout_spec.tv_nsec = (timeout_ms % 1000) * 1000 * 1000;
            timeout_spec_pointer = *timeout_spec;
        }

        events: [2] Kevent64;
        num_events := kevent64(s.kevent_queue, null, 0, events.data, events.count, 0, timeout_spec_pointer);
        if num_events == -1 {
            error_code, error_string := get_error_value_and_string();
            log_error("Could not read events from the event queue: % %\n", error_code, error_string);
            return false;
        }

        for i: 0..num_events-1 {
            event := events[i];

            if event.filter == {
                case .READ;
                    success := read_and_process_data(s);
                    if !success then return false;

                    if event.flags & .EOF {
                        if s.verbose then log("Connection got closed");
                        s.error = .CONN_CLOSED;
                        disconnect(s);
                        return false;
                    }
                case .WRITE;
                    // If we weren't connected yet, we seem to be now!
                    if s.status & .CONNECTING {		
                        s.status = .CONNECTED;

                        // Remove the write event from the kevent queue, because we only used it to know when we are connected.
                        events: [1] Kevent64;
                        events[0].ident = cast(u64) s.socket;
                        events[0].filter = .WRITE;
                        events[0].flags = .DELETE;
                        result := kevent64(s.kevent_queue, events.data, events.count, null, 0, 0, null);
                        if result == -1 {
                            error_code, error_string := get_error_value_and_string();
                            log_error("Could not remove WRITE event from the event queue: % %", error_code, error_string);
                            disconnect(s);
                            return false;
                        }

                        capreq(s);
                        auth(s);
                    }
                case;
                    log_error("Unexpected event: %", event);
            }
        }
    }
	
	return true;
}

read_and_process_data :: (s: *$T/Twitch_Chat) -> bool {
    // Fetch and process all available data from the socket
    while true {
        bytes_received := read(s.socket, s.buffer.data + s.unconsumed_bytes, cast(u64) (s.buffer.count - s.unconsumed_bytes));
        if bytes_received == -1 {
            error_code := errno();
            if error_code == EAGAIN || error_code == EWOULDBLOCK {
                // Nothing to read
                break;
            }

            error_string := get_error_string(error_code);
            log_error("Could not read from socket: % %", error_code, error_string);
            s.error = .SOCKET_RECV;
            
            // We were connected but now seem to be disconnected?
            if is_connected(s) && !socket_is_connected(s.socket) {
                disconnect(s);
            }

            return false;
        }

        // if s.verbose then log("Read % bytes", bytes_received);

        if bytes_received == 0 then break;

        s.unconsumed_bytes += bytes_received;

        success, bytes_consumed := process_data(s, array_view(s.buffer, 0, s.unconsumed_bytes));
        s.unconsumed_bytes -= bytes_consumed;

        // @ToDo: should be a memmove! But we don't have that yet?
        for i: 0..s.unconsumed_bytes-1 {
            s.buffer[i] = s.buffer[bytes_consumed + i];
        }

        if !success then return false;
    }

    return true;
}

process_data :: (s: *$T/Twitch_Chat, buf: [] u8) -> bool, bytes_consumed: int {
    bytes_consumed: int;
    remaining := cast (string) buf;
    // if s.verbose then log("Trying to process: %", remaining);
    found: bool;
    message: string;
    while true {
        found, message, remaining = split_from_left(remaining, "\r\n");
        if !found then break;

        bytes_consumed += message.count + 2;

        success := process_msg(s, message);
        if !success then return false, bytes_consumed;
    }

    return true, bytes_consumed;
}

process_msg :: (s: *$T/Twitch_Chat, message: string) -> bool {
    if s.verbose then log("Message: %", message);
    event: Twitch_Event;
    event.raw = message;

    success, tags, remainder := parse_tags(message);
    if !success     return false;

    defer array_free(tags);

    event.tags = tags;

    success, event.prefix, remainder = parse_prefix(remainder);
    if !success     return false;

    event.command, event.command_args, event.parameter = parse_command(remainder);

	// Check for CTCP and possibly modify the event accordingly
    success = parse_ctcp(*event);
    if !success     return false;

	// Extract the nick from the prefix, maybe
	event.origin = parse_nick(event.prefix);
	
    interpret_and_emit_event(s, *event);

    return true;
}

// Extracts tags from the beginning of an IRC message, if any, and returns them
// as a pointer to a dynamically allocated array of tag structs, where 
// each struct contains two members, key and value, representing the key and 
// value of a tag, respectively. The value member of a tag can be empty string 
// for key-only tags. The last element of the array will be a NULL pointer, so 
// you can loop over all tags until you hit NULL. The number of extracted tags
// is returned in len. If no tags have been found at the beginning of msg, tags
// will be NULL, len will be 0 and this function will return a pointer to msg.
// Otherwise, a pointer to the part of msg after the tags will be returned. 
//
// https://ircv3.net/specs/core/message-tags-3.2.html
parse_tags :: (message: string) -> success: bool, [] Twitch_Tag, remainder: string {
	// If msg doesn't start with "@", then there are no tags
    if !message.count || message[0] != #char "@"    return true, .[], message;

    found, tags_string, remaining_message := split_from_left(message, " ");
    if !found   return false, .[], message;

    advance(*tags_string); // trim the @

    // @Speed: We could determine the number of tags up-front with a pre-pass.
    tags: [..] Twitch_Tag;
    remainder := tags_string;
    while remainder {
        found, tag_string, right := split_from_left(remainder, ";");
        if !found {
            tag_string = remainder;
        }

        tag := parse_tag(tag_string);
        array_add(*tags, tag);

        remainder = right;
    }

    return true, tags, remaining_message;
}

parse_tag :: (tag_string: string) -> Twitch_Tag {
    tag: Twitch_Tag;
    found, key, value := split_from_left(tag_string, "=");
    tag.key = key;
    if found {
        tag.value = value;
        unescape(*tag.value);
    }

    return tag;
}

parse_prefix :: (message: string) -> success: bool, prefix: string, remainder: string {
    if !message.count || message[0] != #char ":"    return true, "", message;

    found, prefix, remainder := split_from_left(message, " ");
    if !found   return false, "", message;

    return true, prefix, remainder;
}

parse_command :: (message: string) -> command: string, command_args: [] string, remainder: string {
    found, command_string, after_command := split_from_left(message, ":");

    command: string;
    remainder: string;
    found, command, remainder = split_from_left(command_string, " ");

    remainder = trim(remainder);
    return command, split(remainder, " "), after_command;
}

// Checks if the event is a CTCP event. If so, strips the CTCP markers (0x01)
// as well as the CTCP command from the trailing parameter and fills the ctcp
// member of event with the CTCP command instead. If it isn't a CTCP command, 
// this function does nothing.
parse_ctcp :: (event: *Twitch_Event) -> success: bool {
    parameter := event.parameter;
    if !parameter    return true;

	// First or last char not 0x01? Not CTCP!
    if parameter[0] != 0x01  return true;
    if parameter[parameter.count - 1] != 0x01  return true;

    found, ctcp, remainder := split_from_left(parameter, " ");

    if !found   return false;
    event.ctcp = ctcp;
    event.parameter = remainder;

    return true;
}

// Extracts the nickname from an IRC message's prefix, if any. Done this way:
// Searches prefix for an exclamation mark ('!'). If there is one, everything 
// before it will be returned as a pointer to an allocated string (malloc), so
// the caller has to free() it at some point. If there is no exclamation mark 
// in prefix or prefix is NULL or we're out of memory, NULL will be returned.
parse_nick :: (prefix: string) -> string {
    found, nick, remainder := split_from_left(prefix, "!");
    if !found   return "";
    return nick;
}

// Requests all supported capabilities from the Twitch servers.
capreq :: (s: *$T/Twitch_Chat) -> bool {
    return cmd_req_all(s);
}

// Authenticates with the Twitch Server using the NICK and PASS commands.
// Login is not automatically completed upon return of this function, one has 
// to wait for the server to reply. If the tags capability has been requested 
// beforehand, the server will confirm login with the GLOBALUSERSTATE command,
// otherwise just look out for the MOTD (starting with numeric command 001).
auth :: (s: *$T/Twitch_Chat) -> bool {
	if !cmd_pass(s, s.login.password)   return false;
	if !cmd_nick(s, s.login.nickname)   return false;

	s.status |= .AUTHENTICATING;
	return true;
}

interpret_and_emit_event :: (s: *$T/Twitch_Chat, event: *Twitch_Event) {
    if event.ctcp {
        if event.ctcp == {
            case "ACTION";
                channel_command(event, .CTCP_ACTION);
                if event.parameter {
                    event.message = event.parameter;
                }
            case;
                event.type = .UNKNOWN;
        }
    } else {
        if event.command == {
            case "CAP";
                // On "CAP * ACK" command, which confirms a requested capability.
                event.type = .CAP;
            case "001";
                event.type = .AUTHENTICATED;
                s.status |= .AUTHENTICATED;
            case "GLOBALUSERSTATE";
                event.type = .GLOBALUSERSTATE;
                s.status |= .AUTHENTICATED;
                // Save the display-name and user-id in our login struct
                s.login.display_name = copy_string(get_tag_value(event.tags, "display-name"));
                s.login.id = copy_string(get_tag_value(event.tags, "user-id"));

            case "JOIN";
                channel_command(event, .JOIN);
            case "PART";
                channel_command(event, .PART);
            case "CLEARCHAT";
                channel_command(event, .CLEARCHAT);
            case "ROOMSTATE";
                channel_command(event, .ROOMSTATE);
            case "USERSTATE";
                channel_command(event, .USERSTATE);
            case "MODE";
                channel_command(event, .MODERATOR);

            case "HOSTTARGET";
                channel_command(event, .HOSTTARGET);
                // @ToDo: Eat spaces?
                found, name, count := split_from_left(event.parameter, #char " ");
                if found {
                    event.target = name;
                }

            case "PRIVMSG";
                channel_command(event, .PRIVMSG);
                if event.parameter {
                    event.message = event.parameter;
                }
            case "CLEARMSG";
                channel_command(event, .CLEARMSG);
                if event.parameter {
                    event.message = event.parameter;
                }
            case "NOTICE";
                channel_command(event, .NOTICE);
                if event.parameter {
                    event.message = event.parameter;
                }
            case "USERNOTICE";
                channel_command(event, .USERNOTICE);
                if event.parameter {
                    event.message = event.parameter;
                }
            case "WHISPER";
                channel_command(event, .WHISPER);
                if event.parameter {
                    event.message = event.parameter;
                }

            case "PING";
                event.type = .PING;
                cmd_pong(s, ifx event.command_args.count then event.command_args[0] else "");
            case "353";
                // > :<user>.tmi.twitch.tv 353 <user> = #<channel> :<user> <user2> <user3>
                // > :<user>.tmi.twitch.tv 353 <user> = #<channel> :<user4> <user5> ... <userN>
                event.type = .NAMES;
                if event.command_args.count > 2 {
                    event.channel = event.command_args[2];
                }
            case "366";
                // > :<user>.tmi.twitch.tv 366 <user> #<channel> :End of /NAMES list
                event.type = .END_OF_NAMES;
                if event.command_args.count > 1 {
                    event.channel = event.command_args[1];
                }
            case "421";
                event.type = .INVALID_COMMAND;
            case "RECONNECT";
                event.type = .RECONNECT;
            case;
                event.type = .UNKNOWN;
        }
    }

    s.event_callback(event, s.event_callback_data);
}

channel_command :: (event: *Twitch_Event, type: Command_Type) {
    event.type = type;
    if event.command_args.count {
        event.channel = event.command_args[0];
    }
}

send_message :: (s: *$T/Twitch_Chat, message: string) -> success: bool {
    assert(ends_with(message, "\r\n"));

    if s.verbose then log("Sending message: %", get_message_safe_for_logging(s, message));

    remainder := message;
    while remainder {
        // Actually send the message
        result := send(s.socket, message.data, cast(u64) message.count, 0);
        if result == -1 {
            error_code, error_string := get_error_value_and_string();
            // Let’s not doxx ourselves
            safe_message := get_message_safe_for_logging(s, message);
            safe_remainder := slice(safe_message, message.count - remainder.count, remainder.count);
            log_error("Could not send message: % %\n\tRemaining message was: %", error_code, error_string, safe_remainder);
            return false;
        }
        remainder = slice(remainder, result, remainder.count - result);
    }

    return true;
}

get_message_safe_for_logging :: (s: *$T/Twitch_Chat, message: string) -> string {
    password_index := find_index_from_left(message, s.login.password);
    if !password_index return message;

    safe_message := copy_temporary_string(message);
    while password_index != -1 {
        for i: 0..s.login.password.count-1 {
            safe_message[password_index + i] = #char "*";
        }
        password_index = find_index_from_left(safe_message, s.login.password);
    }

    return safe_message;
}

disconnect :: (s: *$T/Twitch_Chat) {
    if s.verbose then log("Disconnecting…");
    s.status = .DISCONNECTED;
    #if OS == .LINUX {
        close_and_reset(*s.epoll_handle);
    }
    #if OS == .MACOS {
        close_and_reset(*s.kevent_queue);
    }
    close_and_reset(*s.socket);
    deinit(*s.login);
}

deinit :: (login: *Twitch_Login) {
    free(login.nickname);     login.nickname = "";
    free(login.password);     login.password = "";
    free(login.display_name); login.display_name = "";
    free(login.id);           login.id = "";
}

is_connecting :: (state: *$T/Twitch_Chat) -> bool {
	return (state.status & .CONNECTING) != 0;
}

is_connected :: (state: *$T/Twitch_Chat) -> bool {
	return (state.status & .CONNECTED) != 0;
}

is_logging_in :: (state: *$T/Twitch_Chat) -> bool {
	return (state.status & .AUTHENTICATING) != 0;
}

is_logged_in :: (state: *$T/Twitch_Chat) -> bool {
	return (state.status & .AUTHENTICATED) != 0;
}

get_tag :: (tags: [] Twitch_Tag, key: string) -> found: bool, Twitch_Tag {
     for tags {
         if it.key == key  return true, it;
     }
     return false, .{};
}

get_tag_value :: (tags: [] Twitch_Tag, key: string) -> string {
     for tags {
         if it.key == key then return it.value;
     }

     return "";
}

#scope_file 

close_and_reset :: (handle: *s32) {
    result := close(<<handle);
    if !result {
        error_code := errno();
        if error_code != EINPROGRESS && error_code != EWOULDBLOCK { // Closing is also non-blocking on non-blocking sockets. Sigh… Maybe we should change it to blocking before we close it? Maybe it doesn't matter…
            error_string := get_error_string(error_code);
            log_error("Could not close handle %: % %", <<handle, error_code, error_string);
        }
    }
    <<handle = -1;
}


socket_is_connected :: (socket: s32) -> bool {
    err: s32;
    len := cast(u32) size_of(type_of(err));
    result := getsockopt(socket, SOL_SOCKET, SO_ERROR, *err, *len);
    if result != 0 {
		// Could not get the socket's status, invalid file descriptor?
        return false;
	}

    return err == 0;
}

unescape :: (value_pointer: *string) {
    value := <<value_pointer;
    dest := 0;
    for i: 0..value.count - 1 {
        if value[i] == #char "\\" && i != value.count - 1 {
            i += 1;
            if value[i] == {
                case #char ":";  value[dest] = #char ";";
                case #char "s";  value[dest] = #char " ";
                case #char "\\"; value[dest] = #char "\\";
                case #char "r";  value[dest] = #char "\r";
                case #char "n";  value[dest] = #char "\n";
                case;            value[dest] = value[i];
            }
        } else {
            value[dest] = value[i];
        }
        dest += 1;
    }
    value_pointer.count = dest;
}

// Command :: struct {
//     type: Command_Type;
// }

// Command_Channel :: struct {
//     using base: Command;
//     channel: string;
// }

// Command_Message :: struct {
//     using base: Command_Channel;
//     message: string;
// }

// Command_Cap :: struct {
//     using base: Command;
//     enabled: bool;
// }

// Command_Unknown :: struct {
//     using base: Command; type = .UNKNOWN;
// }

#load "commands.jai";

#import "Basic";
#import "POSIX";
#import "Process";
#import "String";
#import "System";
#if OS == .MACOS {
    #import "macos";
}
