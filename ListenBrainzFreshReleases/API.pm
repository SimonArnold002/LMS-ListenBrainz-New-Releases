package Plugins::ListenBrainzFreshReleases::API;

use strict;
use warnings;

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Cache;
use Slim::Utils::PluginManager;
use JSON::XS::VersionOneAndTwo;

my $log   = logger('plugin.listenbrainzfreshreleases');
my $prefs = preferences('plugin.listenbrainzfreshreleases');
my $cache = Slim::Utils::Cache->new();

# A MusicBrainz tracklist never changes, so cache a found result for a long time;
# genres can be sparse on fresh releases, so recheck an empty result daily.
use constant MB_FOUND_TTL => 30 * 86400;
use constant MB_EMPTY_TTL =>  1 * 86400;

# Last.fm tags change slowly; cache a found result for a month and recheck an
# empty one weekly (a brand-new album may pick up tags over time).
use constant LFM_FOUND_TTL => 30 * 86400;
use constant LFM_EMPTY_TTL =>  7 * 86400;

# The fresh-releases feed only changes ~daily, but the Material home row reloads
# it constantly. Without caching, every home/menu view fired a fresh, slow (2-15s)
# ListenBrainz call — which flooded and rate-limited the API and hung the home
# page. Cache the parsed feed so repeat views are instant. The data is ~daily, so
# refresh once a day; a "Refresh" row in each list lets the user force one sooner
# (it removes the key below via clearFeedCache). All Releases also rolls over at
# local midnight via the date in its cache key.
use constant FEED_TTL => 24 * 3600;   # 1 day

# Network timeout for the feed fetches — kept short so a slow/unreachable
# ListenBrainz fails fast instead of leaving the menu/home spinning.
use constant FEED_TIMEOUT => 10;

# A separate, long-lived copy of the last successful feed. If a later fetch fails
# (ListenBrainz down/slow) we serve this so the menu/home still shows something.
use constant FEED_FALLBACK_TTL => 30 * 86400;

# The Created-for-You playlist LISTING only changes weekly (new Weekly Jams /
# Exploration generated each Monday; ListenBrainz keeps the current + previous
# week). Rather than a rolling 24h TTL (which expires relative to whenever the
# cache was first populated, so the new week is only picked up "within a day" of
# Monday and the exact moment drifts with install/browse time), the working copy
# is expired AT the Monday boundary by _secsUntilNextWeeklyRefresh — so the first
# browse after the rollover always re-pulls the fresh listing. The per-playlist
# tracks/resolved caches (keyed by last_modified) remain immutable per key.
#
# ListenBrainz regenerates the weekly playlists shortly after 00:00 UTC Monday
# (observed ~00:15–00:27 UTC); expire a few hours later to give it a buffer.
use constant PLAYLIST_REFRESH_HOUR => 3;   # UTC hour on Monday to expire the listing

# Fallback copy of the playlist listing (served only when a fetch fails). Unlike
# the feeds' 30d FEED_FALLBACK_TTL, this is bounded to ~8 days: a persistent
# createdfor outage then degrades to an empty/refresh state rather than confidently
# showing a >1-week-old listing that masks the new Monday playlists indefinitely.
use constant PLAYLIST_LIST_FALLBACK_TTL => 8 * 86400;

# Seconds from now until the next weekly refresh boundary (Monday
# PLAYLIST_REFRESH_HOUR:00 UTC). Strictly future: if this Monday's boundary has
# already passed (or it's later on Monday), the next one is a week out.
sub _secsUntilNextWeeklyRefresh {
    my @g = gmtime(time);                       # [0]=sec [1]=min [2]=hour [6]=wday(0=Sun)
    my $secsIntoDay = $g[2]*3600 + $g[1]*60 + $g[0];
    my $daysAhead   = (8 - $g[6]) % 7;          # Mon->0, Tue->6, …, Sun->1
    my $secs = $daysAhead*86400 - $secsIntoDay + PLAYLIST_REFRESH_HOUR*3600;
    $secs += 7*86400 if $secs <= 0;             # boundary already passed today
    return $secs;
}

use constant BASE_URL        => 'https://api.listenbrainz.org';
use constant LABS_URL        => 'https://labs.api.listenbrainz.org';
use constant CAA_BASE_URL    => 'https://coverartarchive.org/release/';
use constant MB_BASE_URL     => 'https://musicbrainz.org/ws/2/';
use constant LASTFM_BASE_URL => 'https://ws.audioscrobbler.com/2.0/';

# MusicBrainz requires a descriptive User-Agent identifying the application. The
# version is read from the plugin manifest (install.xml) at runtime rather than
# hardcoded here, so it can never drift from the actual release (it had silently
# lagged 17 versions behind before). Memoised after first use; the manifest is
# parsed during the plugin scan, long before any HTTP call, so it's always ready.
my $_userAgent;
sub USER_AGENT {
    return $_userAgent if defined $_userAgent;
    my $ver = eval {
        Slim::Utils::PluginManager->dataForPlugin('Plugins::ListenBrainzFreshReleases::Plugin')->{version};
    };
    $ver = 'dev' unless defined $ver && length $ver;   # impossible-case fallback
    return $_userAgent =
        "LMS-ListenBrainzFreshReleases/$ver ( https://github.com/SimonArnold002/LMS-ListenBrainz-New-Releases )";
}

# ---------------------------------------------------------------------------
# GET /1/user/<username>/fresh_releases  (personalised, auth required)
# ---------------------------------------------------------------------------
sub getFreshReleasesForUser {
    my ($class, %args) = @_;

    my $username = $prefs->get('username') // '';
    my $token    = $prefs->get('token')    // '';

    unless ($username && $token) {
        $args{onError}->("No ListenBrainz username/token configured");
        return;
    }

    my $sort   = $args{sort}   // 'release_date';
    my $days   = $args{days}   // 14;
    my $past   = $args{past}   ? 'true' : 'false';
    my $future = $args{future} ? 'true' : 'false';

    my $cacheKey = 'lbf:feed:user:'   . join('|', $username, $sort, $past, $future, $days);
    my $fbKey    = 'lbf:feed:userfb:' . join('|', $username, $sort, $past, $future, $days);
    if (my $cached = $cache->get($cacheKey)) {
        $log->info("For-you releases cache hit ($cacheKey)");
        $args{onDone}->($cached);
        return;
    }

    (my $safe_user = $username) =~ s/([^A-Za-z0-9\-_.~])/sprintf("%%%02X",ord($1))/ge;

    my $url = sprintf('%s/1/user/%s/fresh_releases?sort=%s&past=%s&future=%s&days=%d',
        BASE_URL, $safe_user, $sort, $past, $future, $days);

    $log->info("Fetching for-you releases: $url");

    my $http = Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $resp = shift;
            _handleResponse($resp,
                sub {
                    my $releases = shift;
                    _cacheFeed($cacheKey, $fbKey, $releases);
                    $args{onDone}->($releases);
                },
                # A 200 with an unparseable / unexpected body must NOT be cached as
                # an empty feed (it would blank the menu for FEED_TTL). Route it
                # through the same fallback path as a transport error so the last
                # good copy is served instead.
                sub { _feedError($resp, $fbKey, $args{onDone}, $args{onError}) },
            );
        },
        sub { _feedError(shift, $fbKey, $args{onDone}, $args{onError}) },
        { timeout => FEED_TIMEOUT }
    );

    $http->get($url,
        'Authorization' => "Token $token",
        'Accept'        => 'application/json',
    );
}

# ---------------------------------------------------------------------------
# GET /1/explore/fresh-releases/  (global, no auth needed)
# ---------------------------------------------------------------------------
sub getFreshReleasesAll {
    my ($class, %args) = @_;

    my $sort   = $args{sort}   // 'release_date';
    my $days   = $args{days}   // 14;
    my $past   = $args{past}   ? 'true' : 'false';
    my $future = $args{future} ? 'true' : 'false';

    my @t = localtime(time);
    my $today = sprintf('%04d-%02d-%02d', $t[5]+1900, $t[4]+1, $t[3]);

    my $cacheKey = 'lbf:feed:all:'   . join('|', $sort, $past, $future, $days, $today);
    my $fbKey    = 'lbf:feed:allfb:' . join('|', $sort, $past, $future, $days);
    if (my $cached = $cache->get($cacheKey)) {
        $log->info("All releases cache hit ($cacheKey)");
        $args{onDone}->($cached);
        return;
    }

    my $url = sprintf('%s/1/explore/fresh-releases/?sort=%s&past=%s&future=%s&days=%d&release_date=%s',
        BASE_URL, $sort, $past, $future, $days, $today);

    $log->info("Fetching all releases: $url");

    my $http = Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $resp = shift;
            _handleResponse($resp,
                sub {
                    my $releases = shift;
                    _cacheFeed($cacheKey, $fbKey, $releases);
                    $args{onDone}->($releases);
                },
                # See getFreshReleasesForUser: don't cache an unparseable 200 —
                # fall back to the last good copy instead.
                sub { _feedError($resp, $fbKey, $args{onDone}, $args{onError}) },
            );
        },
        sub { _feedError(shift, $fbKey, $args{onDone}, $args{onError}) },
        { timeout => FEED_TIMEOUT }
    );

    $http->get($url, 'Accept' => 'application/json');
}

# Store a fetched feed under both the short-TTL working key and the long-TTL
# fallback key (used when a later fetch fails). Guarded so a Storable hiccup
# can't break the response.
sub _cacheFeed {
    my ($cacheKey, $fbKey, $releases) = @_;
    eval { $cache->set($cacheKey, $releases, FEED_TTL);          1 } or $log->warn("feed cache set failed: $@");
    eval { $cache->set($fbKey,    $releases, FEED_FALLBACK_TTL); 1 } or $log->warn("feed fallback cache set failed: $@");
}

# Drop the working cache key for a feed so the next view re-fetches (used by the
# "Refresh" row). $which is 'user' or 'all'. The key here MUST match the one built
# in getFreshReleasesForUser / getFreshReleasesAll (same prefs, same format). The
# long-lived fallback copy is left intact — it's only consulted on a fetch error.
sub clearFeedCache {
    my ($class, $which) = @_;
    my $sort = $prefs->get('sort') // 'release_date';
    my $days = $prefs->get('days') // 14;

    if ($which eq 'all') {
        my $past   = ($prefs->get('all_past')   // 1) ? 'true' : 'false';
        my $future = ($prefs->get('all_future') // 0) ? 'true' : 'false';
        my @t = localtime(time);
        my $today = sprintf('%04d-%02d-%02d', $t[5]+1900, $t[4]+1, $t[3]);
        $cache->remove('lbf:feed:all:' . join('|', $sort, $past, $future, $days, $today));
    }
    else {
        my $username = $prefs->get('username') // '';
        my $past   = ($prefs->get('foryou_past')   // 1) ? 'true' : 'false';
        my $future = ($prefs->get('foryou_future') // 0) ? 'true' : 'false';
        $cache->remove('lbf:feed:user:' . join('|', $username, $sort, $past, $future, $days));
    }
    $log->info("cleared $which feed cache (forced refresh)");
}

# On a feed fetch failure, serve the last successfully cached copy if we have one
# (a ListenBrainz outage then degrades to slightly-stale data instead of an empty
# / error menu). Only when there's nothing cached do we surface the error.
sub _feedError {
    my ($resp, $fbKey, $onDone, $onError) = @_;
    if (my $stale = $cache->get($fbKey)) {
        my $msg = (ref $resp && $resp->can('error')) ? ($resp->error // '?') : 'error';
        $log->warn("ListenBrainz feed fetch failed ($msg) — serving last cached copy");
        $onDone->($stale);
        return;
    }
    _handleError($resp, $onError);
}

# ---------------------------------------------------------------------------
# GET /1/user/<username>/playlists/createdfor  — the algorithmic "Created for
# You" playlists (Weekly Jams, Weekly Exploration, Daily Jams, …). Readable
# without a token; we send the token too if present. The listing's per-playlist
# track array is always empty — the tracks come from getPlaylistTracks.
# ---------------------------------------------------------------------------
sub getCreatedForPlaylists {
    my ($class, %args) = @_;

    my $username = $prefs->get('username') // '';
    my $token    = $prefs->get('token')    // '';

    unless ($username) {
        $args{onError}->("No ListenBrainz username configured");
        return;
    }

    my $cacheKey = 'lbf:pl:list:'   . $username;
    my $fbKey    = 'lbf:pl:listfb:' . $username;
    # $args{force} skips the working-cache READ (used by the background warm) so a
    # still-valid-but-stale listing can't short-circuit discovery of a new week;
    # the fetched result is still written back to both keys below.
    if (!$args{force} && (my $cached = $cache->get($cacheKey))) {
        $log->info("Created-for playlists cache hit ($cacheKey)");
        $args{onDone}->($cached);
        return;
    }

    (my $safe_user = $username) =~ s/([^A-Za-z0-9\-_.~])/sprintf("%%%02X",ord($1))/ge;
    my $url = sprintf('%s/1/user/%s/playlists/createdfor?count=25', BASE_URL, $safe_user);

    $log->info("Fetching created-for playlists: $url");

    my @headers = ('Accept' => 'application/json');
    push @headers, ('Authorization' => "Token $token") if $token;

    my $http = Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $resp = shift;
            my $data = eval { from_json($resp->content) };
            if ($@) {
                $log->error("Created-for JSON parse error: $@");
                _feedError($resp, $fbKey, $args{onDone}, $args{onError});
                return;
            }
            my $playlists = _parsePlaylistList($data);
            # Use the feed-style dual cache so a later outage degrades to the
            # last good copy rather than an empty section.
            # Expire at the Monday boundary, but never hold longer than a day: if
            # ListenBrainz (re)enables Daily Jams for the account it regenerates
            # *daily*, and the listing carries it — the 24h cap keeps that fresh on
            # the lazy browse path (no dependence on the warm running), while the
            # boundary value still wins as Monday nears so the weekly rollover lands
            # exactly on Monday.
            my $listTtl = _secsUntilNextWeeklyRefresh();
            $listTtl = 24 * 3600 if $listTtl > 24 * 3600;
            eval { $cache->set($cacheKey, $playlists, $listTtl);                   1 } or $log->warn("pl list cache set failed: $@");
            eval { $cache->set($fbKey,    $playlists, PLAYLIST_LIST_FALLBACK_TTL); 1 } or $log->warn("pl list fallback set failed: $@");
            $args{onDone}->($playlists);
        },
        sub { _feedError(shift, $fbKey, $args{onDone}, $args{onError}) },
        { timeout => FEED_TIMEOUT }
    );

    $http->get($url, @headers);
}

# Normalise the createdfor response into a newest-first arrayref of
# { mbid, title, source_patch, last_modified }.
sub _parsePlaylistList {
    my ($data) = @_;
    return [] unless ref $data eq 'HASH' && ref $data->{playlists} eq 'ARRAY';

    my @out;
    for my $wrap (@{ $data->{playlists} }) {
        my $p = ref $wrap eq 'HASH' ? $wrap->{playlist} : undef;
        next unless ref $p eq 'HASH';

        my $ext = $p->{extension}
            && $p->{extension}{'https://musicbrainz.org/doc/jspf#playlist'};
        $ext = {} unless ref $ext eq 'HASH';
        my $meta = ref $ext->{additional_metadata} eq 'HASH' ? $ext->{additional_metadata} : {};
        my $algo = ref $meta->{algorithm_metadata} eq 'HASH' ? $meta->{algorithm_metadata} : {};

        my $mbid = '';
        if (defined $p->{identifier}) {
            my $id = ref $p->{identifier} eq 'ARRAY' ? $p->{identifier}[0] : $p->{identifier};
            ($mbid) = ($id // '') =~ m{/playlist/([0-9a-f-]{36})}i;
        }
        next unless $mbid;

        push @out, {
            mbid          => lc $mbid,
            title         => $p->{title} // 'Playlist',
            source_patch  => $algo->{source_patch} // '',
            last_modified => $ext->{last_modified_at} // $p->{date} // '',
        };
    }

    # Newest-first by last_modified (ISO-8601 sorts lexically).
    @out = sort { ($b->{last_modified} // '') cmp ($a->{last_modified} // '') } @out;
    return \@out;
}

# ---------------------------------------------------------------------------
# GET /1/playlist/<mbid>  — the full JSPF playlist with its tracks. A playlist's
# contents are immutable for a given last_modified, so cache long once found.
# ---------------------------------------------------------------------------
sub getPlaylistTracks {
    my ($class, $mbid, $lastModified, $onDone, $onError) = @_;

    unless ($mbid) {
        $onError->('No playlist MBID') if ref $onError eq 'CODE';
        return;
    }

    my $cacheKey = 'lbf:pl:tracks:' . join('|', $mbid, ($lastModified // ''));
    if (my $cached = $cache->get($cacheKey)) {
        $log->info("Playlist tracks cache hit: $mbid");
        $onDone->($cached);
        return;
    }

    (my $safe = $mbid) =~ s/([^A-Za-z0-9\-_.~])/sprintf("%%%02X",ord($1))/ge;
    my $url = BASE_URL . '/1/playlist/' . $safe;

    $log->info("Fetching playlist tracks: $url");

    my $http = Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $resp = shift;
            my $data = eval { from_json($resp->content) };
            if ($@) {
                $log->error("Playlist JSON parse error: $@");
                $onError->("JSON error: $@") if ref $onError eq 'CODE';
                return;
            }
            my $tracks = _parsePlaylistTracks($data);
            my $ttl    = @$tracks ? MB_FOUND_TTL : MB_EMPTY_TTL;
            eval { $cache->set($cacheKey, $tracks, $ttl); 1 }
                or $log->warn("playlist tracks cache set failed: $@");
            $onDone->($tracks);
        },
        sub { _handleError(shift, $onError) },
        { timeout => 15 }
    );

    $http->get($url, 'Accept' => 'application/json', 'User-Agent' => USER_AGENT);
}

# Normalise playlist.track[] into an arrayref of
# { title, artist, album, recording_mbid }. (Only these drive track resolution;
# duration / cover-art come from the matched streaming result, not the JSPF entry.)
sub _parsePlaylistTracks {
    my ($data) = @_;
    my $p = (ref $data eq 'HASH') ? $data->{playlist} : undef;
    return [] unless ref $p eq 'HASH' && ref $p->{track} eq 'ARRAY';

    my @out;
    for my $t (@{ $p->{track} }) {
        next unless ref $t eq 'HASH';

        my $recMbid = '';
        if (defined $t->{identifier}) {
            my $id = ref $t->{identifier} eq 'ARRAY' ? $t->{identifier}[0] : $t->{identifier};
            ($recMbid) = ($id // '') =~ m{/recording/([0-9a-f-]{36})}i;
        }

        push @out, {
            title          => $t->{title}   // '',
            artist         => $t->{creator} // '',
            album          => $t->{album}   // '',
            recording_mbid => lc($recMbid // ''),
        };
    }
    return \@out;
}

# ---------------------------------------------------------------------------
# GET /1/user/<username>/feed/events — the user's SOCIAL FEED: the timeline of
# events from the people they follow. We keep only the track-bearing events
# (recording_recommendation + recording_pin) and turn them into a de-duplicated,
# newest-first track list, so a "Recommended by People You Follow" playlist can be
# resolved from it. The feed is PRIVATE — it needs the user's token (unlike the
# public createdfor listing). Cadence: this timeline updates continuously, so —
# unlike the weekly createdfor listing (Monday-boundary key) — it's cached for a
# day (dual working/fallback, same shape as the fresh-releases feed) and refreshed
# by the daily warm. $args{force} skips the working-cache READ (the warm passes it)
# so a still-valid copy can't hide newly-arrived recommendations from a warm tick.
# ---------------------------------------------------------------------------
use constant FOLLOW_FEED_COUNT => 75;   # events fetched per call (feed is newest-first)

sub getFollowFeed {
    my ($class, %args) = @_;

    my $username = $prefs->get('username') // '';
    my $token    = $prefs->get('token')    // '';

    unless ($username && $token) {
        $args{onError}->("No ListenBrainz username/token configured") if ref $args{onError} eq 'CODE';
        return;
    }

    my $cacheKey = 'lbf:follow:feed:'   . $username;
    my $fbKey    = 'lbf:follow:feedfb:' . $username;
    if (!$args{force} && (my $cached = $cache->get($cacheKey))) {
        $log->info("Follow-feed cache hit ($cacheKey)");
        $args{onDone}->($cached);
        return;
    }

    (my $safe_user = $username) =~ s/([^A-Za-z0-9\-_.~])/sprintf("%%%02X",ord($1))/ge;
    my $url = sprintf('%s/1/user/%s/feed/events?count=%d', BASE_URL, $safe_user, FOLLOW_FEED_COUNT);

    $log->info("Fetching follow feed: $url");

    my $http = Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $resp = shift;
            my $data = eval { from_json($resp->content) };
            if ($@) {
                $log->error("Follow-feed JSON parse error: $@");
                _feedError($resp, $fbKey, $args{onDone}, $args{onError});
                return;
            }
            my $tracks = _parseFollowFeed($data);
            # Dual short/fallback cache (like the fresh-releases feed) so a later
            # outage degrades to the last good copy rather than an empty tile.
            eval { $cache->set($cacheKey, $tracks, FEED_TTL);          1 } or $log->warn("follow feed cache set failed: $@");
            eval { $cache->set($fbKey,    $tracks, FEED_FALLBACK_TTL); 1 } or $log->warn("follow feed fallback set failed: $@");
            $args{onDone}->($tracks);
        },
        sub { _feedError(shift, $fbKey, $args{onDone}, $args{onError}) },
        { timeout => FEED_TIMEOUT }
    );

    $http->get($url,
        'Authorization' => "Token $token",
        'Accept'        => 'application/json',
    );
}

# Track-bearing feed event types we turn into playlist tracks. Everything else in
# the feed (listens, follows, notifications, reviews) carries no single recording.
my %FOLLOW_TRACK_EVENT = ( recording_recommendation => 1, recording_pin => 1 );

# Normalise a feed/events payload into a de-duplicated, newest-first arrayref of
# { title, artist, album, recording_mbid, recommender, created }. The feed is returned
# reverse-chronological, so array order is preserved. The recording_mbid lives in
# additional_info OR the mbid_mapping (and a pin wraps the recording one level
# deeper), so several places are checked. Dedup by recording_mbid when present,
# else by lc "artist|title" — the same track is often recommended by several
# followed users, or re-recommended over time.
sub _parseFollowFeed {
    my ($data) = @_;
    my $payload = (ref $data eq 'HASH' && ref $data->{payload} eq 'HASH') ? $data->{payload} : $data;
    my $events  = (ref $payload eq 'HASH' && ref $payload->{events} eq 'ARRAY') ? $payload->{events} : [];

    my (@out, %seen);
    for my $ev (@$events) {
        next unless ref $ev eq 'HASH' && $FOLLOW_TRACK_EVENT{ $ev->{event_type} // '' };

        my $meta = ref $ev->{metadata} eq 'HASH' ? $ev->{metadata} : {};
        my $pin  = ref $meta->{pin} eq 'HASH' ? $meta->{pin} : {};
        my $tm   = ref $meta->{track_metadata} eq 'HASH' ? $meta->{track_metadata}
                 : ref $pin->{track_metadata}  eq 'HASH' ? $pin->{track_metadata}
                 : {};
        my $ai   = ref $tm->{additional_info} eq 'HASH' ? $tm->{additional_info} : {};
        my $map  = ref $tm->{mbid_mapping}    eq 'HASH' ? $tm->{mbid_mapping}    : {};

        my $artist = $tm->{artist_name} // '';
        my $title  = $tm->{track_name}  // '';
        next unless length $artist || length $title;

        my $rec = _firstRecMbid($ai->{recording_mbid}, $map->{recording_mbid},
                                $meta->{recording_mbid}, $pin->{recording_mbid});

        my $key = $rec ? "m:$rec" : 't:' . lc("$artist|$title");
        next if $seen{$key}++;

        push @out, {
            title          => $title,
            artist         => $artist,
            album          => $tm->{release_name} // '',
            recording_mbid => $rec,
            recommender    => $ev->{user_name} // '',
            # Unix epoch of the feed event, so the follow feature can bucket recs
            # into Monday-start weeks (the weekly-list view). 0 if absent.
            created        => ($ev->{created} // 0) + 0,
        };
    }
    return \@out;
}

# First argument that looks like a bare recording MBID (handles a scalar or the
# first element of an arrayref), lower-cased; '' if none qualify.
sub _firstRecMbid {
    for my $c (@_) {
        my $v = ref $c eq 'ARRAY' ? $c->[0] : $c;
        return lc $v if defined $v && !ref $v && $v =~ /^[0-9a-f-]{36}$/i;
    }
    return '';
}

# ---------------------------------------------------------------------------
# GET /1/cf/recommendation/user/<user>/recording — collaborative-filtering
# recommended recordings, used by BOTH Don't Stop The Music propagators
# (Recommended directly; Radio as its cold-start / error fallback). The endpoint
# accepts an artist_type (similar/raw/top), but the live API IGNORES it — all three
# return the identical payload, and omitting it entirely returns the same data too
# (verified against the API). So we send a fixed artist_type=similar rather than
# exposing a flavour the server doesn't honour. Returns an ordered (highest-score
# first) arrayref of recording MBID strings. A 204 (recs not yet generated for
# this account) or any non-list payload yields an empty list, not an error.
# ---------------------------------------------------------------------------
sub getRecommendations {
    my ($class, %args) = @_;

    my $username = $prefs->get('username') // '';
    my $token    = $prefs->get('token')    // '';
    my $count    = $args{count}   || 100;
    my $onDone   = $args{onDone}  || sub {};
    my $onError  = $args{onError} || sub { $onDone->([]) };

    unless ($username) {
        $onError->("No ListenBrainz username configured");
        return;
    }

    (my $safe_user = $username) =~ s/([^A-Za-z0-9\-_.~])/sprintf("%%%02X",ord($1))/ge;
    # artist_type is sent but ignored by the live API (see header note); fixed at
    # 'similar' to keep the request stable.
    my $url = sprintf('%s/1/cf/recommendation/user/%s/recording?artist_type=similar&count=%d',
        BASE_URL, $safe_user, $count);

    $log->info("Fetching recommendations: $url");

    my @headers = ('Accept' => 'application/json', 'User-Agent' => USER_AGENT);
    push @headers, ('Authorization' => "Token $token") if $token;

    my $http = Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $resp = shift;
            # 204 No Content (recs not generated yet) → empty content; treat as no recs.
            my $body = $resp->content;
            unless (defined $body && length $body) {
                $log->info("Recommendations: no content (code " . $resp->code . ")");
                $onDone->([]);
                return;
            }
            my $data = eval { from_json($body) };
            if ($@) {
                $log->error("Recommendations JSON parse error: $@");
                $onError->("JSON error: $@");
                return;
            }
            my $payload = (ref $data eq 'HASH') ? $data->{payload} : undef;
            my $mbids   = (ref $payload eq 'HASH' && ref $payload->{mbids} eq 'ARRAY')
                ? $payload->{mbids} : [];
            my @ids = grep { $_ } map { lc($_->{recording_mbid} // '') } @$mbids;
            $log->info("Recommendations: " . scalar(@ids) . " recording MBIDs");
            $onDone->(\@ids);
        },
        sub { _handleError(shift, $onError) },
        { timeout => 15 }
    );

    $http->get($url, @headers);
}

# ---------------------------------------------------------------------------
# GET /1/metadata/recording/?recording_mbids=<csv>&inc=artist — bulk-resolve a
# list of recording MBIDs to { artist, title } in one (or a few) call(s),
# avoiding MusicBrainz's 1 req/sec throttle. Calls $onDone with a hashref keyed
# by lower-case recording MBID: { mbid => { artist, title } }. Chunks to
# METADATA_CHUNK MBIDs per request and merges.
# ---------------------------------------------------------------------------
use constant METADATA_CHUNK => 50;

sub getRecordingMetadata {
    my ($class, $mbids, $onDone, $onError) = @_;
    $onDone  ||= sub {};
    $onError ||= sub { $onDone->({}) };

    my @all = grep { $_ } @{ $mbids || [] };
    unless (@all) { $onDone->({}); return; }

    my %meta;
    my @chunks;
    push @chunks, [ splice(@all, 0, METADATA_CHUNK) ] while @all;

    my $next;
    $next = sub {
        my $chunk = shift @chunks;
        unless ($chunk) { $onDone->(\%meta); return; }

        my $csv = join(',', @$chunk);
        (my $safe = $csv) =~ s/([^A-Za-z0-9\-_.~,])/sprintf("%%%02X",ord($1))/ge;
        my $url = BASE_URL . '/1/metadata/recording/?inc=artist&recording_mbids=' . $safe;

        my $http = Slim::Networking::SimpleAsyncHTTP->new(
            sub {
                my $resp = shift;
                my $data = eval { from_json($resp->content) };
                if ($@) {
                    $log->error("Recording metadata JSON parse error: $@");
                } else {
                    _mergeRecordingMetadata(\%meta, $data);
                }
                $next->();
            },
            # A failed chunk shouldn't sink the rest — log and continue with what we have.
            sub {
                my $resp = shift;
                $log->warn("Recording metadata chunk failed: " . ($resp->error // '?'));
                $next->();
            },
            { timeout => 15 }
        );

        $http->get($url, 'Accept' => 'application/json', 'User-Agent' => USER_AGENT);
    };
    $next->();
}

# Merge a /metadata/recording response (object keyed by recording MBID) into
# %$meta as { mbid => { artist, title } }. Tolerates the two artist shapes:
# a flat artist.name credit string, or an artist.artists[] credit array.
sub _mergeRecordingMetadata {
    my ($meta, $data) = @_;
    return unless ref $data eq 'HASH';

    while (my ($mbid, $entry) = each %$data) {
        next unless ref $entry eq 'HASH';
        my $rec    = ref $entry->{recording} eq 'HASH' ? $entry->{recording} : {};
        my $artObj = ref $entry->{artist}    eq 'HASH' ? $entry->{artist}    : {};

        my $title = $rec->{name} // '';
        my $artist = $artObj->{name} // '';
        if (!length $artist && ref $artObj->{artists} eq 'ARRAY') {
            $artist = join('', map {
                ($_->{artist_credit_name} // $_->{name} // '') . ($_->{join_phrase} // '')
            } @{ $artObj->{artists} });
        }

        $meta->{ lc $mbid } = { artist => $artist, title => $title }
            if length $title;
    }
}

# ---------------------------------------------------------------------------
# Resolve an artist NAME to a MusicBrainz artist MBID. Needed for the radio when
# the seed track came from a streaming service (Qobuz/Tidal/etc.) and carries no
# MusicBrainz ID — without this the radio can't fetch similar artists and falls
# back to generic recommendations. One cached lookup per artist; requires a
# strong (score>=90) match to avoid seeding off the wrong artist. Calls $onDone
# with a lower-case MBID or undef.
# ---------------------------------------------------------------------------
sub getArtistMbidByName {
    my ($class, $name, $onDone, $onError) = @_;
    $onDone  ||= sub {};
    $onError ||= sub { $onDone->(undef) };

    $name = defined $name ? $name : '';
    $name =~ s/^\s+|\s+$//g;
    unless (length $name) { $onDone->(undef); return; }

    my $cacheKey = 'lbf:artistmbid:' . lc $name;
    utf8::encode($cacheKey) if utf8::is_utf8($cacheKey);
    if (defined(my $c = $cache->get($cacheKey))) {
        $onDone->($c || undef);   # '' is the cached "not found" sentinel
        return;
    }

    my $q = 'artist:"' . $name . '"';
    utf8::encode($q) if utf8::is_utf8($q);
    (my $safe = $q) =~ s/([^A-Za-z0-9])/sprintf("%%%02X",ord($1))/ge;
    my $url = MB_BASE_URL . 'artist?query=' . $safe . '&fmt=json&limit=1';

    $log->info("Resolving artist name to MBID: $name");

    my $http = Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $resp = shift;
            my $data = eval { from_json($resp->content) };
            my $mbid = '';
            if (!$@ && ref $data eq 'HASH' && ref $data->{artists} eq 'ARRAY' && @{ $data->{artists} }) {
                my $a = $data->{artists}[0];
                $mbid = lc $a->{id} if $a->{id} && ($a->{score} // 0) >= 90;
            }
            eval { $cache->set($cacheKey, $mbid, $mbid ? MB_FOUND_TTL : MB_EMPTY_TTL); 1 }
                or $log->warn("artist-mbid cache set failed: $@");
            $log->info("Artist '$name' => " . ($mbid || 'no match'));
            $onDone->($mbid || undef);
        },
        sub { _handleError(shift, $onError) },
        { timeout => 12 }
    );

    $http->get($url, 'Accept' => 'application/json', 'User-Agent' => USER_AGENT);
}

# ---------------------------------------------------------------------------
# Similar artists (labs dataset) — GET labs/similar-artists/json?artist_mbids=<m>
# Powers the "ListenBrainz Radio" propagator: given the last-played artist, find
# artists similar listeners gravitate to. Returns an arrayref of
# { artist_mbid, name, score }, score-desc. Cached SIMILAR_TTL (the dataset is
# stable). Empty/odd response → empty list, never an error.
# ---------------------------------------------------------------------------
use constant SIMILAR_TTL    => 7 * 86400;
use constant SIMILAR_ALGO   => 'session_based_days_7500_session_300_contribution_5_threshold_10_limit_100_filter_True_skip_30';

sub getSimilarArtists {
    my ($class, $artistMbid, $onDone, $onError) = @_;
    $onDone  ||= sub {};
    $onError ||= sub { $onDone->([]) };

    unless ($artistMbid) { $onDone->([]); return; }

    my $cacheKey = 'lbf:similar:artist:' . lc $artistMbid;
    if (my $cached = $cache->get($cacheKey)) {
        $log->info("Similar-artists cache hit: $artistMbid");
        $onDone->($cached);
        return;
    }

    (my $safe = $artistMbid) =~ s/([^A-Za-z0-9\-_.~])/sprintf("%%%02X",ord($1))/ge;
    my $url = LABS_URL . '/similar-artists/json?artist_mbids=' . $safe
        . '&algorithm=' . SIMILAR_ALGO;

    $log->info("Fetching similar artists: $url");

    my $http = Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $resp = shift;
            my $data = eval { from_json($resp->content) };
            if ($@) {
                $log->error("Similar-artists JSON parse error: $@");
                $onError->("JSON error: $@");
                return;
            }
            # Response is a top-level array (or { data => [...] } on some deploys).
            my $rows = (ref $data eq 'ARRAY') ? $data
                     : (ref $data eq 'HASH' && ref $data->{data} eq 'ARRAY') ? $data->{data} : [];
            my @out;
            for my $r (@$rows) {
                next unless ref $r eq 'HASH' && $r->{artist_mbid};
                push @out, {
                    artist_mbid => lc $r->{artist_mbid},
                    name        => $r->{name} // $r->{artist_name} // '',
                    score       => $r->{score} // 0,
                };
            }
            eval { $cache->set($cacheKey, \@out, SIMILAR_TTL); 1 }
                or $log->warn("similar-artists cache set failed: $@");
            $log->info("Similar artists for $artistMbid: " . scalar(@out));
            $onDone->(\@out);
        },
        sub { _handleError(shift, $onError) },
        { timeout => 15 }
    );

    $http->get($url, 'Accept' => 'application/json', 'User-Agent' => USER_AGENT);
}

# ---------------------------------------------------------------------------
# Top recordings for an artist — GET /1/popularity/top-recordings-for-artist/<m>
# Turns a (similar) artist into concrete, resolvable tracks. Returns an arrayref
# of { recording_mbid, title, artist }, most-popular first. Cached SIMILAR_TTL.
# ---------------------------------------------------------------------------
sub getTopRecordingsForArtist {
    my ($class, $artistMbid, $onDone, $onError) = @_;
    $onDone  ||= sub {};
    $onError ||= sub { $onDone->([]) };

    unless ($artistMbid) { $onDone->([]); return; }

    my $cacheKey = 'lbf:toprec:artist:' . lc $artistMbid;
    if (my $cached = $cache->get($cacheKey)) {
        $onDone->($cached);
        return;
    }

    (my $safe = $artistMbid) =~ s/([^A-Za-z0-9\-_.~])/sprintf("%%%02X",ord($1))/ge;
    my $url = BASE_URL . '/1/popularity/top-recordings-for-artist/' . $safe;

    my $http = Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $resp = shift;
            my $data = eval { from_json($resp->content) };
            if ($@) {
                $log->error("Top-recordings JSON parse error: $@");
                $onError->("JSON error: $@");
                return;
            }
            my $rows = (ref $data eq 'ARRAY') ? $data
                     : (ref $data eq 'HASH' && ref $data->{data} eq 'ARRAY') ? $data->{data} : [];
            my @out;
            for my $r (@$rows) {
                next unless ref $r eq 'HASH' && $r->{recording_mbid};
                push @out, {
                    recording_mbid => lc $r->{recording_mbid},
                    title          => $r->{recording_name} // '',
                    artist         => $r->{artist_name}    // '',
                };
            }
            eval { $cache->set($cacheKey, \@out, SIMILAR_TTL); 1 }
                or $log->warn("top-recordings cache set failed: $@");
            $onDone->(\@out);
        },
        sub { _handleError(shift, $onError) },
        { timeout => 15 }
    );

    $http->get($url, 'Accept' => 'application/json', 'User-Agent' => USER_AGENT);
}

# ---------------------------------------------------------------------------
# GET /1/validate-token  (used by Settings on save)
# ---------------------------------------------------------------------------
sub validateToken {
    my ($class, $token, $onDone, $onError) = @_;

    (my $safe = $token) =~ s/([^A-Za-z0-9\-_.~])/sprintf("%%%02X",ord($1))/ge;
    my $url = BASE_URL . '/1/validate-token?token=' . $safe;

    my $http = Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $resp = shift;
            my $data = eval { from_json($resp->content) };
            if ($@) { $onError->("JSON error: $@"); return; }
            $onDone->($data);
        },
        sub { _handleError(shift, $onError) },
        { timeout => 10 }
    );

    $http->get($url, 'Accept' => 'application/json');
}

# ---------------------------------------------------------------------------
# GET /ws/2/release/<mbid> from MusicBrainz — tracklist + genres for the
# release detail page. On-demand (one release at a time), so the anonymous
# 1 req/sec MusicBrainz rate limit is not a concern.
# ---------------------------------------------------------------------------
sub getReleaseDetails {
    my ($class, $mbid, $onDone, $onError) = @_;

    unless ($mbid) {
        $onError->('No release MBID') if ref $onError eq 'CODE';
        return;
    }

    # Cache hit → return the parsed tracklist/genres without re-fetching.
    my $cacheKey = 'lbf:mb:' . $mbid;
    if (my $cached = $cache->get($cacheKey)) {
        $log->info("MusicBrainz release cache hit: $mbid");
        $onDone->($cached);
        return;
    }

    (my $safe = $mbid) =~ s/([^A-Za-z0-9\-_.~])/sprintf("%%%02X",ord($1))/ge;
    # recordings = tracklist. Genres come from the release-GROUP
    # (getReleaseGroupGenres) — release-level genres are almost always empty.
    my $url = MB_BASE_URL . 'release/' . $safe . '?inc=recordings&fmt=json';

    $log->info("Fetching MusicBrainz release details: $url");

    my $http = Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $resp = shift;
            my $data = eval { from_json($resp->content) };
            if ($@) {
                $log->error("MusicBrainz JSON parse error: $@");
                $onError->("JSON error: $@") if ref $onError eq 'CODE';
                return;
            }
            my $parsed = _parseReleaseDetails($data);
            # This request only asks for recordings (the tracklist); genres come
            # from the release-GROUP (getReleaseGroupGenres), so the TTL is driven
            # purely by whether we got a tracklist.
            my $ttl    = @{ $parsed->{media} } ? MB_FOUND_TTL : MB_EMPTY_TTL;
            eval { $cache->set($cacheKey, $parsed, $ttl); 1 }
                or $log->warn("release detail cache set failed: $@");
            $onDone->($parsed);
        },
        sub { _handleError(shift, $onError) },
        { timeout => 15 }
    );

    $http->get($url,
        'Accept'     => 'application/json',
        'User-Agent' => USER_AGENT,
    );
}

# ---------------------------------------------------------------------------
# GET /ws/2/release-group/<mbid> genres. Genres live on the release-group, not
# the release, so this is what actually populates the detail page. Keyed by
# release-group MBID so releases sharing a group reuse the cache.
# ---------------------------------------------------------------------------
sub getReleaseGroupGenres {
    my ($class, $rgMbid, $onDone, $onError) = @_;

    unless ($rgMbid) {
        $onError->('No release-group MBID') if ref $onError eq 'CODE';
        return;
    }

    my $cacheKey = 'lbf:rggenres:' . $rgMbid;
    if (my $cached = $cache->get($cacheKey)) {
        $onDone->($cached);
        return;
    }

    (my $safe = $rgMbid) =~ s/([^A-Za-z0-9\-_.~])/sprintf("%%%02X",ord($1))/ge;
    my $url = MB_BASE_URL . 'release-group/' . $safe . '?inc=genres&fmt=json';

    $log->info("Fetching MusicBrainz release-group genres: $url");

    my $http = Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $resp = shift;
            my $data = eval { from_json($resp->content) };
            if ($@) {
                $log->error("MusicBrainz RG JSON parse error: $@");
                $onError->("JSON error: $@") if ref $onError eq 'CODE';
                return;
            }
            my $genres = _parseGenres($data);
            my $ttl    = @$genres ? MB_FOUND_TTL : MB_EMPTY_TTL;
            eval { $cache->set($cacheKey, $genres, $ttl); 1 }
                or $log->warn("RG genre cache set failed: $@");
            $onDone->($genres);
        },
        sub { _handleError(shift, $onError) },
        { timeout => 15 }
    );

    $http->get($url,
        'Accept'     => 'application/json',
        'User-Agent' => USER_AGENT,
    );
}

# Top genre names (most-voted first, max 5) from a MusicBrainz entity response.
sub _parseGenres {
    my ($data) = @_;
    return [] unless ref $data->{genres} eq 'ARRAY';
    my @g = sort { ($b->{count} // 0) <=> ($a->{count} // 0) } @{ $data->{genres} };
    @g = @g[0 .. 4] if @g > 5;
    return [ grep { defined && length } map { $_->{name} } @g ];
}

# ---------------------------------------------------------------------------
# Artist biography from Last.fm (artist.getinfo) — the FALLBACK bio source for
# the detail page's Artist section when the MAI plugin isn't installed. Requires
# lastfm_api_key (graceful no-op otherwise). Calls $onDone with the cleaned, FULL
# bio string (content, not the short summary), or undef. Cached lbf:bio:2:* (30d/7d).
# ---------------------------------------------------------------------------
use constant BIO_MAX => 20000;   # pure DoS guard; never trims a real bio (no visible cap)

sub getArtistBio {
    my ($class, $artist, $onDone, $onError) = @_;
    $onDone  ||= sub {};
    $onError ||= sub { $onDone->(undef) };

    my $key = $prefs->get('lastfm_api_key');
    unless ($key && length($artist // '')) { $onDone->(undef); return; }

    # Octets, so the md5 cache key and per-byte URL encoding are safe for CJK/emoji.
    utf8::encode($artist) if utf8::is_utf8($artist);

    my $cacheKey = 'lbf:bio:2:' . lc $artist;   # :2: = full-content bio (was the short summary)
    if (defined(my $c = $cache->get($cacheKey))) {
        $onDone->($c || undef);   # '' = cached "no bio"
        return;
    }

    my %p = (method => 'artist.getinfo', artist => $artist, autocorrect => 1,
             api_key => $key, format => 'json');
    my $qs = join('&', map {
        (my $v = defined $p{$_} ? $p{$_} : '')
            =~ s/([^A-Za-z0-9\-_.~])/sprintf("%%%02X", ord($1))/ge;
        "$_=$v";
    } sort keys %p);
    my $url = LASTFM_BASE_URL . '?' . $qs;

    my $http = Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $resp = shift;
            my $data = eval { from_json($resp->content) };
            my $bio  = '';
            if (!$@ && ref $data eq 'HASH' && ref $data->{artist} eq 'HASH'
                   && ref $data->{artist}{bio} eq 'HASH') {
                # Prefer the FULL bio (content); summary is only Last.fm's short teaser.
                $bio = _cleanBio($data->{artist}{bio}{content} // $data->{artist}{bio}{summary} // '');
            }
            eval { $cache->set($cacheKey, $bio, $bio ? LFM_FOUND_TTL : LFM_EMPTY_TTL); 1 }
                or $log->warn("bio cache set failed: $@");
            $onDone->($bio || undef);
        },
        sub { $onError->('Last.fm bio fetch failed') },
        { timeout => 12 }
    );
    $http->get($url, 'User-Agent' => USER_AGENT);
}

# Strip Last.fm's trailing "Read more on Last.fm" link + any HTML and decode the
# common entities, but KEEP the full text (and paragraph breaks) so Material's
# "more" expander reveals the whole biography. Only caps at BIO_MAX as a safety net.
sub _cleanBio {
    my ($s) = @_;
    return '' unless defined $s && length $s;
    $s =~ s{<a\b[^>]*>.*?</a>}{}gis;   # drop the "Read more on Last.fm" link
    $s =~ s/\s*\.?\s*User-contributed text is available.*$//is;  # Last.fm CC licence boilerplate
    $s =~ s{</p>\s*<p[^>]*>}{\n\n}gis; # paragraph breaks -> blank lines
    $s =~ s{<br\s*/?>}{\n}gis;
    $s =~ s/<[^>]+>/ /g;               # any other tags
    $s =~ s/&amp;/&/gi;
    $s =~ s/&lt;/</gi;
    $s =~ s/&gt;/>/gi;
    $s =~ s/&quot;/"/gi;
    $s =~ s/&#0?39;|&apos;/'/gi;
    $s =~ s/&[a-z]+;/ /gi;             # any remaining named entity
    $s =~ s/[ \t]+/ /g;                # collapse spaces/tabs, but keep newlines
    $s =~ s/ *\n */\n/g;
    $s =~ s/\n{3,}/\n\n/g;             # at most one blank line between paragraphs
    $s =~ s/^\s+|\s+$//g;
    if (length $s > BIO_MAX) {
        $s = substr($s, 0, BIO_MAX);
        $s =~ s/\s+\S*$//;             # back off to a word boundary
        $s .= "\x{2026}";
    }
    return $s;
}

# ---------------------------------------------------------------------------
# Last.fm genre/style tags — fallback for when MusicBrainz genres AND the
# payload's release_tags are both empty (common for brand-new releases). Tries
# the album's top tags, then the artist's (the artist almost always has tags
# even when a new album doesn't yet). Requires a free Last.fm API key in the
# lastfm_api_key pref; with no key this is a graceful no-op. Detail page only.
# ---------------------------------------------------------------------------
sub getLastfmTags {
    my ($class, $artist, $album, $onDone, $onError) = @_;

    my $key = $prefs->get('lastfm_api_key');
    unless ($key && length($artist // '')) {
        $onDone->([]);
        return;
    }

    # Work in UTF-8 octets. Titles from the JSON API are wide strings (utf8 flag
    # set); a CJK/emoji title crashes Digest::MD5 — used to build the cache key
    # below — with "Wide character in subroutine entry", which aborts the whole
    # detail request. Downgrading to octets fixes that (and the URL encoding in
    # _lastfmCall, which percent-encodes per byte). Only encode flagged strings
    # so we never double-encode plain Latin-1 octets.
    utf8::encode($artist)               if utf8::is_utf8($artist);
    utf8::encode($album) if defined $album && utf8::is_utf8($album);

    my $cacheKey = 'lbf:lfm:' . lc("$artist|" . ($album // ''));
    if (my $cached = $cache->get($cacheKey)) {
        $onDone->($cached);
        return;
    }

    my $finish = sub {
        my $tags = shift || [];
        my $ttl  = @$tags ? LFM_FOUND_TTL : LFM_EMPTY_TTL;
        eval { $cache->set($cacheKey, $tags, $ttl); 1 }
            or $log->warn("Last.fm tag cache set failed: $@");
        $onDone->($tags);
    };

    # Fallback step: artist-level tags.
    my $tryArtist = sub {
        $class->_lastfmCall('artist.gettoptags',
            { artist => $artist, api_key => $key },
            sub { $finish->(shift) },
            sub { $finish->([]) },   # any failure -> empty; never break the page
        );
    };

    # Preferred step: album tags; fall back to the artist if empty/failed.
    if (length $album) {
        $class->_lastfmCall('album.gettoptags',
            { artist => $artist, album => $album, api_key => $key },
            sub {
                my $tags = shift || [];
                @$tags ? $finish->($tags) : $tryArtist->();
            },
            sub { $tryArtist->() },
        );
    }
    else {
        $tryArtist->();
    }
}

# One Last.fm getTopTags call -> cleaned tag-name arrayref via $onDone.
sub _lastfmCall {
    my ($class, $method, $args, $onDone, $onError) = @_;

    my %p = (method => $method, format => 'json', autocorrect => 1, %$args);
    my $qs = join('&', map {
        (my $v = defined $p{$_} ? $p{$_} : '')
            =~ s/([^A-Za-z0-9\-_.~])/sprintf("%%%02X", ord($1))/ge;
        "$_=$v";
    } sort keys %p);
    my $url = LASTFM_BASE_URL . '?' . $qs;

    my $http = Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $resp = shift;
            my $data = eval { from_json($resp->content) };
            if ($@) {
                $onError->("JSON error: $@") if ref $onError eq 'CODE';
                return;
            }
            $onDone->(_parseLastfmTags($data));
        },
        sub { _handleError(shift, $onError) },
        { timeout => 15 }
    );
    $http->get($url, 'User-Agent' => USER_AGENT);
}

# Top tag names (weight-sorted, max 5) from a Last.fm getTopTags response.
# Last.fm returns a single tag as a hash (not an array); drop blanks/long junk
# and the very-low-weight tail once we already have a few solid tags.
sub _parseLastfmTags {
    my ($data) = @_;
    my $t = $data->{toptags}{tag};
    return [] unless $t;
    my @tags = ref $t eq 'ARRAY' ? @$t : ($t);
    # A tag entry is normally a { name, count, url } hash, but Last.fm can also
    # send a bare string; guard the count deref so a string entry can't trip a
    # strict-refs die (the sort and the low-weight filter below both read count).
    my $count = sub { ref $_[0] eq 'HASH' ? ($_[0]{count} // 0) : 0 };
    @tags = sort { $count->($b) <=> $count->($a) } @tags;

    my @out;
    for my $tag (@tags) {
        my $name = ref $tag eq 'HASH' ? $tag->{name} : $tag;
        next unless defined $name;
        $name =~ s/^\s+//; $name =~ s/\s+$//;
        next if $name eq '' || length($name) > 30;
        next if $count->($tag) < 10 && @out >= 3;
        push @out, $name;
        last if @out >= 5;
    }
    return \@out;
}

# ---------------------------------------------------------------------------
# Similar artists from Last.fm (artist.getsimilar) — the FALLBACK for the radio
# propagator when ListenBrainz's similar-artists dataset has nothing for the seed.
# Needs lastfm_api_key (graceful empty list otherwise). Returns an arrayref of
# { name, artist_mbid (may be ''), score }, match-desc. Last.fm gives artist NAMES
# (its mbids are spotty), so the caller resolves names to MBIDs before fanning out.
# Cached lbf:lfmsimilar:* (found = SIMILAR_TTL, empty = LFM_EMPTY_TTL).
# ---------------------------------------------------------------------------
use constant LFM_SIMILAR_LIMIT => 30;

sub getSimilarArtistsLastfm {
    my ($class, $artist, $onDone, $onError) = @_;
    $onDone  ||= sub {};
    $onError ||= sub { $onDone->([]) };

    my $key = $prefs->get('lastfm_api_key');
    unless ($key && length($artist // '')) { $onDone->([]); return; }

    # Octets — safe md5 cache key and per-byte URL encoding for CJK/emoji names.
    utf8::encode($artist) if utf8::is_utf8($artist);

    my $cacheKey = 'lbf:lfmsimilar:' . lc $artist;
    if (my $cached = $cache->get($cacheKey)) { $onDone->($cached); return; }

    my %p = (method => 'artist.getsimilar', artist => $artist, autocorrect => 1,
             limit => LFM_SIMILAR_LIMIT, api_key => $key, format => 'json');
    my $qs = join('&', map {
        (my $v = defined $p{$_} ? $p{$_} : '')
            =~ s/([^A-Za-z0-9\-_.~])/sprintf("%%%02X", ord($1))/ge;
        "$_=$v";
    } sort keys %p);
    my $url = LASTFM_BASE_URL . '?' . $qs;

    my $http = Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $resp = shift;
            my $data = eval { from_json($resp->content) };
            my @out;
            if (!$@ && ref $data eq 'HASH' && ref $data->{similarartists} eq 'HASH') {
                my $a = $data->{similarartists}{artist};
                my @arts = ref $a eq 'ARRAY' ? @$a : ($a ? ($a) : ());
                for my $r (@arts) {
                    next unless ref $r eq 'HASH';
                    my $name = $r->{name};
                    next unless defined $name && length $name;
                    push @out, {
                        name        => $name,
                        artist_mbid => ($r->{mbid} && $r->{mbid} =~ /^[0-9a-f-]{36}$/i) ? lc $r->{mbid} : '',
                        score       => $r->{match} // 0,
                    };
                }
            }
            eval { $cache->set($cacheKey, \@out, @out ? SIMILAR_TTL : LFM_EMPTY_TTL); 1 }
                or $log->warn("lfm-similar cache set failed: $@");
            $log->info("Last.fm similar artists for '$artist': " . scalar(@out));
            $onDone->(\@out);
        },
        sub { _handleError(shift, $onError) },
        { timeout => 15 }
    );
    $http->get($url, 'User-Agent' => USER_AGENT);
}

# Normalise a MusicBrainz release lookup into { media => [...] }. Genres are NOT
# read here — they live on the release-group (getReleaseGroupGenres); the release
# request only includes recordings.
sub _parseReleaseDetails {
    my ($data) = @_;

    my %out = (media => []);

    # Tracks are grouped by medium (disc); preserve that grouping
    if (ref $data->{media} eq 'ARRAY') {
        for my $m (@{ $data->{media} }) {
            my @tracks;
            if (ref $m->{tracks} eq 'ARRAY') {
                for my $t (@{ $m->{tracks} }) {
                    my $rec = ref $t->{recording} eq 'HASH' ? $t->{recording} : {};
                    push @tracks, {
                        position => $t->{number} // $t->{position},
                        title    => $t->{title} // $rec->{title} // '',
                        length   => $t->{length} // $rec->{length},
                    };
                }
            }
            push @{ $out{media} }, {
                position => $m->{position},
                format   => $m->{format} // '',
                tracks   => \@tracks,
            };
        }
    }

    return \%out;
}

# ---------------------------------------------------------------------------
# Build Cover Art Archive thumbnail URL
# ---------------------------------------------------------------------------
sub coverArtUrl {
    my ($class, $rel) = @_;
    # caa_release_mbid (with caa_id) is the authoritative "has cover art" signal
    # in the fresh_releases payload. release_mbid is always present, so falling
    # back to it returned a URL even when no art exists (404s + broke the
    # artwork-only filter). Require caa_release_mbid so absence == no artwork.
    # Accept either a release hashref or a bare caa_release_mbid string so
    # playlist tracks (which carry the mbid directly) can reuse this.
    my $mbid = (ref $rel eq 'HASH') ? $rel->{caa_release_mbid} : $rel;
    return undef unless $mbid;
    return CAA_BASE_URL . $mbid . '/front-250';
}

# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------
# Parse a fresh-releases response. On success calls $onDone with the releases
# arrayref (which may legitimately be empty). On an unparseable body or an
# unrecognised structure calls $onError instead, so the caller can fall back to
# the last good cached copy rather than caching the failure as an empty feed.
# $onError defaults to the old behaviour (an empty list) for any caller that
# doesn't pass one.
sub _handleResponse {
    my ($resp, $onDone, $onError) = @_;
    $onError ||= sub { $onDone->([]) };

    $log->info("ListenBrainz API response code: " . $resp->code);
    $log->info("ListenBrainz API response length: " . length($resp->content));

    my $data = eval { from_json($resp->content) };
    if ($@) {
        $log->error("JSON parse error: $@");
        $onError->("JSON parse error: $@");
        return;
    }

    if (ref $data eq 'HASH') {
        my $payload = $data->{payload};
        if (ref $payload eq 'HASH' && ref $payload->{fresh_releases} eq 'ARRAY') {
            $log->info("Found " . scalar(@{ $payload->{fresh_releases} }) . " releases in payload.fresh_releases");
            $onDone->($payload->{fresh_releases});
        } elsif (ref $payload eq 'HASH' && ref $payload->{releases} eq 'ARRAY') {
            $log->info("Found " . scalar(@{ $payload->{releases} }) . " releases in payload.releases");
            $onDone->($payload->{releases});
        } elsif (ref $payload eq 'ARRAY') {
            $log->info("Found " . scalar(@$payload) . " releases in payload array");
            $onDone->($payload);
        } elsif (ref $data->{fresh_releases} eq 'ARRAY') {
            $log->info("Found " . scalar(@{ $data->{fresh_releases} }) . " releases in fresh_releases");
            $onDone->($data->{fresh_releases});
        } else {
            $log->warn("Unexpected response structure, keys: " . join(', ', keys %$data));
            $log->warn("Payload keys: " . join(', ', keys %$payload)) if ref $payload eq 'HASH';
            $onError->("unexpected response structure");
        }
    } elsif (ref $data eq 'ARRAY') {
        $log->info("Found " . scalar(@$data) . " releases in root array");
        $onDone->($data);
    } else {
        $log->error("Unexpected data type: " . ref($data));
        $onError->("unexpected data type");
    }
}

sub _handleError {
    my ($resp, $onError) = @_;
    my $msg = $resp->error // 'Unknown HTTP error';
    $log->error("API error: $msg");
    $onError->($msg) if ref $onError eq 'CODE';
}

1;
