// Sends the PASS command to the server, with the pass appended as parameter.
// This is the first part of the authentication process (next part is NICK).
cmd_pass :: (state: *Twitch_Chat, pass: string) -> bool {
    msg := tprint("PASS %\r\n", pass);
	return send_message(state, msg);
}

// Sends the NICK command to the server, with the nick appended as parameter.
// This is the second part of the authentication process (first is PASS).
cmd_nick :: (state: *Twitch_Chat, nick: string) -> bool {
	msg := tprint("NICK %\r\n", nick);
	return send_message(state, msg);
}

// Request to join the specified channel.
cmd_join :: (state: *Twitch_Chat, chan: string) -> bool {
	msg := tprint("JOIN %\r\n", chan);
	return send_message(state, msg);
}

// Leave (part) the specified channel.
cmd_leave :: cmd_part;
cmd_part :: (state: *Twitch_Chat, chan: string) -> bool {
	msg := tprint("PART %\r\n", chan);
	return send_message(state, msg);
}

// Sends the PONG command to the IRC server.
// If param is given, it will be appended. To make Twitch happy (this is not 
// part of the IRC specification) the param will be prefixed with a colon (":")
// unless it is prefixed with one already.
cmd_pong :: (state: *Twitch_Chat, param: string) -> bool {
    builder: String_Builder;
    append(*builder, "PONG");
    if param {
        if param[0] != #char ":" then append(*builder, #char ":");
        append(*builder, param);
    }
    append(*builder, "\r\n");
    msg := builder_to_string(*builder,, temp);
	return send_message(state, msg);
}

// Sends the PING command to the IRC server. 
// If param is given, it will be appended.
cmd_ping :: (state: *Twitch_Chat, param: string) -> bool {
    builder: String_Builder;
    append(*builder, "PING");
    if param then append(*builder, param);
    append(*builder, "\r\n");
    msg := builder_to_string(*builder, temp);
	return send_message(state, msg);
}

// Sends the QUIT command to the IRC server.
cmd_quit :: (state: *Twitch_Chat) -> bool {
	return send_message(state, "QUIT\r\n");
}

// Send a message (msg) to the specified channel.
cmd_privmsg :: (state: *Twitch_Chat, chan: string, message: string) -> bool {
	msg := tprint("PRIVMSG % :%\r\n", chan, message);
	return send_message(state, msg);
}

// Send a CTCP ACTION message (aka "/me") to the specified channel.
cmd_action :: (state: *Twitch_Chat, chan: string, message: string) -> bool {
	// "PRIVMSG #<chan> :\x01ACTION <msg>\x01"
	msg := tprint("PRIVMSG % :%2ACTION %0%2\r\n", chan, 1, message);
	return send_message(state, msg);
}

// Send a whisper message to the specified user.
cmd_whisper :: (state: *Twitch_Chat, nick: string, message: string) -> bool {
	// Usage: "/w <login> <message>"
	msg := tprint("PRIVMSG #% :/w % %\r\n", state.login.nickname, nick, message);
	return send_message(state, msg);
}

// Requests a list of the channel's moderators, both offline and online.
// The answer will be in the form of a NOTICE with the msg-id tag set to 
// "room_mods" and a message like "The moderators of this channel are: <list>",
// where list is a comma-and-space separated list of the moderators nicks.
// If the channel has no moderators, the msg-id tag will be "no_mods" instead.
cmd_mods :: (state: *Twitch_Chat, chan: string) -> bool {
	msg := tprint("PRIVMSG % :/mods\r\n", chan);
	return send_message(state, msg);
}

// Requests a list of the channel's VIPs, both offline and online.
// The answer will be in the form of a NOTICE with the msg-id tag set to either
// "room_vips" or "no_vips" if the room doesn't have any VIPs
cmd_vips :: (state: *Twitch_Chat, chan: string) -> bool {
	msg := tprint("PRIVMSG % :/vips\r\n", chan);
	return send_message(state, msg);
}

// Change your color to the specified one. If you're a turbo user, this can be
// any hex color (for example, "#FFFFFF" for white), otherwise it should be a 
// named color from the following list (might change in the future):
//   Blue, BlueViolet, CadetBlue, Chocolate, Coral, DodgerBlue, Firebrick, 
//   GoldenRod, Green, HotPink, OrangeRed, Red, SeaGreen, SpringGreen,
//   YellowGreen.
cmd_color :: (state: *Twitch_Chat, color: string) -> bool {
	msg := tprint("PRIVMSG #% :/color %\r\n", state.login.nickname, color);
	return send_message(state, msg);
}

// Broadcasters and Moderators only:
// Delete the message with the specified id in the given channel.
// TODO This has yet to be tested, the usage is still unclear to me.
cmd_delete :: (state: *Twitch_Chat, chan: string, id: string) -> bool {
	// @msg-id=usage_delete :tmi.twitch.tv NOTICE #domsson :%!(EXTRA string=delete)
	msg := tprint("PRIVMSG % :/delete %\r\n", chan, id);
	return send_message(state, msg);
}

// Broadcasters and Moderators only:
// Timeout the user with the given nick name in the specified channel for 
// `secs` amount of seconds. If `secs` is 0, the Twitch default will be used, 
// which is 600 seconds (10 minutes) at the time of writing. `reason` will be 
// shown to the affected user and other moderators and is optional.
cmd_timeout :: (state: *Twitch_Chat, chan: string, nick: string, secs := 0, reason := "") -> bool {
	// Usage: "/timeout <username> [duration][time unit] [reason]"
	// Temporarily prevent a user from chatting. Duration (optional, 
	// default=10 minutes) must be a positive integer; time unit (optional, 
	// default=s) must be one of s, m, h, d, w; maximum duration is 2 weeks.
	// Combinations like 1d2h are also allowed. Reason is optional and will 
	// be shown to the target user and other moderators. Use "untimeout" to 
	// remove a timeout.
	msg := tprint("PRIVMSG % :/timeout % %s %\r\n", chan, nick, secs, reason);
	return send_message(state, msg);
}

// Broadcasters and Moderators only:
// Un-timeout the given user in the given channel. You could use unban as well.
cmd_untimeout :: (state: *Twitch_Chat, chan: string, nick: string) -> bool {
	// Usage: "/untimeout <username>" - Removes a timeout on a user.
	msg := tprint("PRIVMSG % :/untimeout %\r\n", chan, nick);
	return send_message(state, msg);
}

// Broadcasters and Moderators only:
// Permanently ban the specified user from the specified channel. Optionally, a
// reason can be given, which will be shown to the affected user and other 
// moderators.
cmd_ban :: (state: *Twitch_Chat, chan: string, nick: string, reason := "") -> bool {
	// Usage: "/ban <username> [reason]" - Permanently prevent a user from
	// chatting. Reason is optional and will be shown to the target user 
	// and other moderators. Use "unban" to remove a ban.
	msg := tprint("PRIVMSG % :/ban % %\r\n", chan, nick, reason);
	return send_message(state, msg);
}

// Broadcasters and Moderators only:
// Unban the specified user from the specified channel. Also removes timeouts.
cmd_unban :: (state: *Twitch_Chat, chan: string, nick: string) -> bool {
	// Usage: "/unban <username>" - Removes a ban on a user.
	msg := tprint("PRIVMSG % :/unban %\r\n", chan, nick);
	return send_message(state, msg);
}

// Broadcasters and Moderators only:
// Enable slow mode in the specified channel. This means users can only send 
// messages every `secs` seconds. If seconds is 0, the Twitch default, which at 
// the time of writing is 120 seconds, will be used.
cmd_slow :: (state: *Twitch_Chat, chan: string, secs := 0) -> bool {
	// Usage: "/slow [duration]" - Enables slow mode (limit how often users
	// may send messages). Duration (optional, default=120) must be a 
	// positive number of seconds. Use "slowoff" to disable.
	msg := tprint("PRIVMSG % :/slow %\r\n", chan, secs);
	return send_message(state, msg);
}

// Broadcasters and Moderators only:
// Disables slow mode in the specified channel.
cmd_slowoff :: (state: *Twitch_Chat, chan: string) -> bool {
	// Usage: "/slowoff" - Disables slow mode.
	msg := tprint("PRIVMSG % :/slowoff\r\n", chan);
	return send_message(state, msg);
}

// Broadcasters and Moderators only:
// Enables followers-only mode for the specified channel.
// This means that only followers can still send messages. If `time` is set, 
// only followers who have been following for at least the specified time will 
// be allowed to chat. Allowed values range from 0 minutes (all followers) to 
// 3 months. `time` should be NULL or a string as in the following examples: 
// "7m" or "7 minutes", "2h" or "2 hours", "5d" or "5 days", "1w" or "1 week", 
// "3mo" or "3 months".
cmd_followers :: (state: *Twitch_Chat, chan: string, time := "") -> bool {
	// Usage: "/followers [duration]" - Enables followers-only mode (only 
	// users who have followed for 'duration' may chat). Examples: "30m", 
	// "1 week", "5 days 12 hours". Must be less than 3 months.
	msg := tprint("PRIVMSG % :/followers %\r\n", chan, time);
	return send_message(state, msg);
}

// Broadcasters and Moderators only:
// Disable followers-only mode for the specified channel.
cmd_followersoff :: (state: *Twitch_Chat, chan: string) -> bool {
	// Usage: "/followersoff - Disables followers-only mode.
	msg := tprint("PRIVMSG % :/followersoff\r\n", chan);
	return send_message(state, msg);
}

// Broadcasters and Moderators only:
// Enable subscriber-only mode for the specified channel.
cmd_subscribers :: (state: *Twitch_Chat, chan: string) -> bool {
	// Usage: "/subscribers" - Enables subscribers-only mode (only subs 
	// may chat in this channel). Use "subscribersoff" to disable.
	msg := tprint("PRIVMSG % :/subscribers\r\n", chan);
	return send_message(state, msg);
}

// Broadcasters and Moderators only:
// Disable subscriber-only mode for the specified channel.
cmd_subscribersoff :: (state: *Twitch_Chat, chan: string) -> bool {
	// Usage: "/subscribersoff" - Disables subscribers-only mode.
	msg := tprint("PRIVMSG % :/subscribersoff\r\n", chan);
	return send_message(state, msg);
}

// Broadcasters and Moderators only:
// Completely wipe the previous chat history. Note: clients can ignore this.
cmd_clear :: (state: *Twitch_Chat, chan: string) -> bool {
	// Usage: "/clear" - Clear chat history for all users in this room.
	msg := tprint("PRIVMSG % :/clear\r\n", chan);
	return send_message(state, msg);
}

// Broadcasters and Moderators only:
// Enables R9K mode for the specified channel.
// Check the Twitch docs for further information about R9K mode.
cmd_r9k :: (state: *Twitch_Chat, chan: string) -> bool {
	// Usage: "/r9kbeta" - Enables r9k mode. Use "r9kbetaoff" to disable.
	msg := tprint("PRIVMSG % :/r9kbeta\r\n", chan);
	return send_message(state, msg);
}

// Broadcasters and Moderators only:
// Disables R9K mode for the specified channel.
cmd_r9koff :: (state: *Twitch_Chat, chan: string) -> bool {
	// Usage: "/r9kbetaoff" - Disables r9k mode.
	msg := tprint("PRIVMSG % :/r9kbetaoff\r\n", chan);
	return send_message(state, msg);
}

// Broadcasters and Moderators only:
// Enables emote-only mode for the specified channel.
// This means that only messages that are 100% emotes are allowed.
cmd_emoteonly :: (state: *Twitch_Chat, chan: string) -> bool {
	// Usage: "/emoteonly" - Enables emote-only mode (only emoticons may 
	// be used in chat). Use "emoteonlyoff" to disable.
	msg := tprint("PRIVMSG % :/emoteonly\r\n", chan);
	return send_message(state, msg);
}

// Broadcasters and Moderators only:
// Disables emote-only mode for the specified channel.
cmd_emoteonlyoff :: (state: *Twitch_Chat, chan: string) -> bool {
	// Usage: "/emoteonlyoff" - Disables emote-only mode.
	msg := tprint("PRIVMSG % :/emoteonlyoff\r\n", chan);
	return send_message(state, msg);
}

// Partner only:
// Run a commercial for all viewers for `secs` seconds. `secs` can be 0, in 
// which case the Twitch default (30 secs at time of writing) will be used;
// otherwise the following values are allowed: 30, 60, 90, 120, 150, 180.
cmd_commercial :: (state: *Twitch_Chat, chan: string, secs := 0) -> bool {
	msg := tprint("PRIVMSG % :/commercial %\r\n", chan, secs);
	return send_message(state, msg);
}

// Broadcaster and channel editor only:
// Host the channel of the user given via `target`.
// Note: target channel has to be given without the pound sign ("#").
cmd_host :: (state: *Twitch_Chat, chan: string, target: string) -> bool {
	msg := tprint("PRIVMSG % :/host %\r\n", chan, target);
	return send_message(state, msg);
}

// Broadcaster and channel editor only:
// Stop hosting a channel and return to the normal state.
cmd_unhost :: (state: *Twitch_Chat, chan: string) -> bool {
	msg := tprint("PRIVMSG % :/unhost\r\n", chan);
	return send_message(state, msg);
}

// Broadcaster only:
// Promote the user with the given nick to channel moderator.
cmd_mod :: (state: *Twitch_Chat, chan: string, nick: string) -> bool {
	msg := tprint("PRIVMSG % :/mod %\r\n", chan, nick);
	return send_message(state, msg);
}

// Broadcaster only:
// Demote the moderator with the given nick back to a regular viewer.
cmd_unmod :: (state: *Twitch_Chat, chan: string, nick: string) -> bool {
	msg := tprint("PRIVMSG % :/unmod %\r\n", chan, nick);
	return send_message(state, msg);
}

// Broadcaster only:
// Give VIP status to the given user in the given channel.
cmd_vip :: (state: *Twitch_Chat, chan: string, nick: string) -> bool {
	msg := tprint("PRIVMSG % :/vip %\r\n", chan, nick);
	return send_message(state, msg);
}

// Broadcaster only:
// Remove VIP status from the user with the given nick in the given channel.
cmd_unvip :: (state: *Twitch_Chat, chan: string, nick: string) -> bool {
	msg := tprint("PRIVMSG % :/unvip %\r\n", chan, nick);
	return send_message(state, msg);
}

// Adds a stream marker at the current timestamp. Comment is optional and should not exceed 140 characters.
cmd_marker :: (state: *Twitch_Chat, chan: string, comment: string) -> bool {
	// Usage: "/marker" - Adds a stream marker (with an optional comment, 
	// max 140 characters) at the current timestamp. You can use markers 
	// in the Highlighter for easier editing.
	msg := tprint("PRIVMSG % :/marker %\r\n", chan, comment);
	return send_message(state, msg);
}

// Requests the tags capability from the Twitch server.
cmd_req_tags :: (state: *Twitch_Chat) -> bool {
	return send_message(state, "CAP REQ :twitch.tv/tags\r\n");
}

// Requests the membership capability from the Twitch server.
cmd_req_membership :: (state: *Twitch_Chat) -> bool {
	return send_message(state, "CAP REQ :twitch.tv/membership\r\n");
}

// Requests the commands capability from the Twitch server.
cmd_req_commands :: (state: *Twitch_Chat) -> bool {
	return send_message(state, "CAP REQ :twitch.tv/commands\r\n");
}

// Requests the chatrooms capability from the Twitch server.
cmd_req_chatrooms :: (state: *Twitch_Chat) -> bool {
	return send_message(state, "CAP REQ :twitch.tv/tags twitch.tv/commands\r\n");
}

// Requests the tags, membership, commands and chatrooms capabilities.
cmd_req_all :: (state: *Twitch_Chat) -> bool {
	return send_message(state, 
	    "CAP REQ :twitch.tv/tags twitch.tv/commands twitch.tv/membership\r\n");
}

