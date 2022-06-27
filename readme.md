# Twitch IRC library in jai

Loosely based on [libtwirc](https://github.com/domsson/libtwirc) and pretty much untested for now.

## Usage
```
twitch: Twitch_Chat;
init(*twitch, event_callback, verbose = true);
success = connect(*twitch, username, password);
if !success then exit(1);

while true {
    log("Updating…");
    success = update(*twitch);
    if !success then break; // Or reconnect or whatever
}

deinit(*twitch);

event_callback :: (event: Twitch_Event) {
    if event.type == {
        case;
            log("Got event: %", event);
    }
}
```


