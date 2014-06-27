# This is a Varnish 4.x VCL file
vcl 4.0;

backend default {
    .host = "127.0.0.1";
    .port = "81";
    .probe = {
        .url = "/ping";
        .timeout   = 1s;
        .interval  = 10s;
        .window    = 5;
        .threshold = 2;
    }
    .first_byte_timeout     = 300s;   # How long to wait before we receive a first byte from our backend?
    .connect_timeout        = 5s;     # How long to wait for a backend connection?
    .between_bytes_timeout  = 2s;     # How long to wait between bytes received from our backend?
}

backend web1 {
    .host = "127.0.0.1";
    .port = "81";
}

backend web2 {
    .host = "127.0.0.1";
    .port = "81";
}

# Below is an example redirector based on round-robin requests
import directors;
sub vcl_init {
    new cluster1 = directors.round_robin();
    cluster1.add_backend(web1);    # Backend web1 defined above
    cluster1.add_backend(web2);    # Backend web2 defined above
}

# Below is an example redirector based on the client IP (sticky sessions)
#sub vcl_init {
#    new cluster2 = directors.hash();
#    cluster2.add_backend(web1);    # Backend web1 defined above
#    cluster2.add_backend(web2);    # Backend web2 defined above
#}

acl purge {
    # For now, I'll only allow purges coming from localhost
    "127.0.0.1";
    "localhost";
}

# Handle the HTTP request received by the client
sub vcl_recv {
    # Choose the round-robin backend
    set req.backend_hint = cluster1.backend();

    # Or chose the client-IP backend (sticky sessions)
    #set req.backend_hint = cluster2.backend();

    # shortcut for DFind requests
    if (req.url ~ "^/w00tw00t") {
        return (synth(404, "Not Found"));
    }

    if (req.restarts == 0) {
        if (req.http.X-Forwarded-For) {
            set req.http.X-Forwarded-For = req.http.X-Forwarded-For + ", " + client.ip;
        } else {
            set req.http.X-Forwarded-For = client.ip;
        }
    }

    # Normalize the header, remove the port (in case you're testing this on various TCP ports)
    set req.http.Host = regsub(req.http.Host, ":[0-9]+", "");

    # Allow purging
    if (req.method == "PURGE") {
        if (!client.ip ~ purge) {
            # Not from an allowed IP? Then die with an error.
            return (synth(405, "This IP is not allowed to send PURGE requests."));
        }

        # If you got this stage (and didn't error out above), purge the cached result
        return (purge);
    }

    # Only deal with "normal" types
    if (req.method != "GET" &&
            req.method != "HEAD" &&
            req.method != "PUT" &&
            req.method != "POST" &&
            req.method != "TRACE" &&
            req.method != "OPTIONS" &&
            req.method != "PATCH" &&
            req.method != "DELETE") {
        /* Non-RFC2616 or CONNECT which is weird. */
        return (pipe);
    }

    # Only cache GET or HEAD requests. This makes sure the POST requests are always passed.
    if (req.method != "GET" && req.method != "HEAD") {
        return (pass);
    }

    # Configure grace period, in case the backend goes down. This allows otherwise "outdated"
    # cache entries to still be served to the user, because the backend is unavailable to refresh them.
    # This may not be desireable for you, but showing a Varnish Guru Meditation error probably isn't either.
    #set req.grace = 15s;
    #if (std.healthy(req.backend)) {
    #    set req.grace = 30s;
    #} else {
    #    unset req.http.Cookie;
    #    set req.grace = 6h;
    #}

    # Some generic URL manipulation, useful for all templates that follow
    # First remove the Google Analytics added parameters, useless for our backend
    if (req.url ~ "(\?|&)(utm_source|utm_medium|utm_campaign|gclid|cx|ie|cof|siteurl)=") {
        set req.url = regsuball(req.url, "&(utm_source|utm_medium|utm_campaign|gclid|cx|ie|cof|siteurl)=([A-z0-9_\-\.%25]+)", "");
        set req.url = regsuball(req.url, "\?(utm_source|utm_medium|utm_campaign|gclid|cx|ie|cof|siteurl)=([A-z0-9_\-\.%25]+)", "?");
        set req.url = regsub(req.url, "\?&", "?");
        set req.url = regsub(req.url, "\?$", "");
    }

    # Strip hash, server doesn't need it.
    if (req.url ~ "\#") {
        set req.url = regsub(req.url, "\#.*$", "");
    }

    # Strip a trailing ? if it exists
    if (req.url ~ "\?$") {
        set req.url = regsub(req.url, "\?$", "");
    }

    # Some generic cookie manipulation, useful for all templates that follow
    # Remove the "has_js" cookie
    set req.http.Cookie = regsuball(req.http.Cookie, "has_js=[^;]+(; )?", "");

    # Remove any Google Analytics based cookies
    set req.http.Cookie = regsuball(req.http.Cookie, "__utm.=[^;]+(; )?", "");
    set req.http.Cookie = regsuball(req.http.Cookie, "_ga=[^;]+(; )?", "");
    set req.http.Cookie = regsuball(req.http.Cookie, "utmctr=[^;]+(; )?", "");
    set req.http.Cookie = regsuball(req.http.Cookie, "utmcmd.=[^;]+(; )?", "");
    set req.http.Cookie = regsuball(req.http.Cookie, "utmccn.=[^;]+(; )?", "");

    # Remove the Quant Capital cookies (added by some plugin, all __qca)
    set req.http.Cookie = regsuball(req.http.Cookie, "__qc.=[^;]+(; )?", "");

    # Remove the AddThis cookies
    set req.http.Cookie = regsuball(req.http.Cookie, "__atuvc=[^;]+(; )?", "");

    # Remove a ";" prefix in the cookie if present
    set req.http.Cookie = regsuball(req.http.Cookie, "^;\s*", "");

    # Are there cookies left with only spaces or that are empty?
    if (req.http.cookie ~ "^\s*$") {
        unset req.http.cookie;
    }

    # Normalize Accept-Encoding header
    # straight from the manual: https://www.varnish-cache.org/docs/3.0/tutorial/vary.html
    if (req.http.Accept-Encoding) {
        if (req.url ~ "\.(jpg|png|gif|gz|tgz|bz2|tbz|mp3|ogg)$") {
            # No point in compressing these
            unset req.http.Accept-Encoding;
        } elsif (req.http.Accept-Encoding ~ "gzip") {
            set req.http.Accept-Encoding = "gzip";
        } elsif (req.http.Accept-Encoding ~ "deflate") {
            set req.http.Accept-Encoding = "deflate";
        } else {
            # unkown algorithm
            unset req.http.Accept-Encoding;
        }
    }

    # Large static files should be piped, so they are delivered directly to the end-user without
    # waiting for Varnish to fully read the file first.
    # TODO: once the Varnish Streaming branch merges with the master branch, use streaming here to avoid locking.
    if (req.url ~ "^[^?]*\.(mp[34]|rar|tar|tgz|gz|wav|zip)(\?.*)?$") {
        unset req.http.Cookie;
        return (pipe);
    }

    # Remove all cookies for static files
    # A valid discussion could be held on this line: do you really need to cache static files that don't cause load? Only if you have memory left.
    # Sure, there's disk I/O, but chances are your OS will already have these files in their buffers (thus memory).
    # Before you blindly enable this, have a read here: http://mattiasgeniar.be/2012/11/28/stop-caching-static-files/
    if (req.url ~ "^[^?]*\.(bmp|bz2|css|doc|eot|flv|gif|gz|ico|jpeg|jpg|js|less|pdf|png|rtf|swf|txt|woff|xml)(\?.*)?$") {
        unset req.http.Cookie;
        return (hash);
    }

    # Send Surrogate-Capability headers to announce ESI support to backend
    set req.http.Surrogate-Capability = "key=ESI/1.0";

    if (req.http.Authorization) {
        # Not cacheable by default
        return (pass);
    }

    return (hash);
}

sub vcl_pipe {
    # Note that only the first request to the backend will have
    # X-Forwarded-For set.  If you use X-Forwarded-For and want to
    # have it set for all requests, make sure to have:
    # set bereq.http.connection = "close";
    # here.  It is not set by default as it might break some broken web
    # applications, like IIS with NTLM authentication.

    #set bereq.http.Connection = "Close";
    return (pipe);
}

sub vcl_pass {
#    return (pass);
}

# The data on which the hashing will take place
sub vcl_hash {
    hash_data(req.url);

    if (req.http.host) {
        hash_data(req.http.host);
    } else {
        hash_data(server.ip);
    }

    # hash cookies for requests that have them
    if (req.http.Cookie) {
        hash_data(req.http.Cookie);
    }
}

sub vcl_hit {

    return (deliver);
}

sub vcl_miss {

    return (fetch);
}

# Handle the HTTP request coming from our backend
sub vcl_backend_response {
    # Pause ESI request and remove Surrogate-Control header
    if (beresp.http.Surrogate-Control ~ "ESI/1.0") {
        unset beresp.http.Surrogate-Control;
        set beresp.do_esi = true;
    }

    # Enable cache for all static files
    # The same argument as the static caches from above: monitor your cache size, if you get data nuked out of it, consider giving up the static file cache.
    # Before you blindly enable this, have a read here: http://mattiasgeniar.be/2012/11/28/stop-caching-static-files/
    if (bereq.url ~ "^[^?]*\.(bmp|bz2|css|doc|eot|flv|gif|gz|ico|jpeg|jpg|js|less|mp[34]|pdf|png|rar|rtf|swf|tar|tgz|txt|wav|woff|xml|zip)(\?.*)?$") {
        unset beresp.http.set-cookie;
    }

    # Sometimes, a 301 or 302 redirect formed via Apache's mod_rewrite can mess with the HTTP port that is being passed along.
    # This often happens with simple rewrite rules in a scenario where Varnish runs on :80 and Apache on :8080 on the same box.
    # A redirect can then often redirect the end-user to a URL on :8080, where it should be :80.
    # This may need finetuning on your setup.
    #
    # To prevent accidental replace, we only filter the 301/302 redirects for now.
    if (beresp.status == 301 || beresp.status == 302) {
        set beresp.http.Location = regsub(beresp.http.Location, ":[0-9]+", "");
    }

    # Set 2min cache if unset for static files
    if (beresp.ttl <= 0s || beresp.http.Set-Cookie || beresp.http.Vary == "*") {
        set beresp.ttl = 120s;
        set beresp.uncacheable = true;
        return (deliver);
    }

    # Allow stale content, in case the backend goes down.
    set beresp.grace = 6h;

    return (deliver);
}

# The routine when we deliver the HTTP request to the user
# Last chance to modify headers that are sent to the client
sub vcl_deliver {
    if (obj.hits > 0) {
        set resp.http.X-Cache = "cached";
    } else {
        set resp.http.x-Cache = "uncached";
    }

    # Remove some headers: PHP version
    unset resp.http.X-Powered-By;

    # Remove some headers: Apache version & OS
    unset resp.http.Server;
    unset resp.http.X-Drupal-Cache;
    unset resp.http.X-Varnish;
    unset resp.http.Via;
    unset resp.http.Link;

    return (deliver);
}

sub vcl_synth {
    if (resp.status == 720) {
        # We use this special error status 720 to force redirects with 301 (permanent) redirects
        # To use this, call the following from anywhere in vcl_recv: error 720 "http://host/new.html"
        set resp.status = 301;
        set resp.http.Location = resp.reason;
        return (deliver);
    } elseif (resp.status == 721) {
        # And we use error status 721 to force redirects with a 302 (temporary) redirect
        # To use this, call the following from anywhere in vcl_recv: error 720 "http://host/new.html"
        set resp.status = 302;
        set resp.http.Location = resp.reason;
        return (deliver);
    }

    return (deliver);
}

sub vcl_init {
    return (ok);
}

sub vcl_fini {
    return (ok);
}
