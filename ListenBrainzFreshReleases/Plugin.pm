package Plugins::ListenBrainzFreshReleases::Plugin;

use strict;
use base qw(Slim::Plugin::OPMLBased);

use Slim::Control::Request;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::PluginManager;
use Slim::Utils::Strings qw(string cstring);
use Slim::Utils::Timers;
use Slim::Music::Import;
use Slim::Utils::OSDetect;
use File::Spec;
use Time::HiRes ();

# Background cache-warm timing: first run shortly after startup (so it doesn't
# compete with boot), then once a day. Daily is cheap because the playlist
# caches are keyed by last_modified — real work happens only when a new week's
# playlist appears.
# THE RUNNING BUILD'S OWN VERSION — read from the LOADED plugin, never restated.
#
# A REPO-INSTALLED COPY SHADOWS A MANUAL INSTALL, and nothing else in this plugin
# could tell you that had happened. The settings page proves only what is on DISK,
# and a `.pm` loads once at startup, so a stale copy under `cache/InstalledPlugins`
# answers every question a fresh manual install was meant to answer — a whole
# verification round can be run against the wrong build without one wrong-looking
# line anywhere. `["lbf","cachestats"]` already reported a `version`, but that is the
# STORE SCHEMA version, which does not move on most builds and therefore proves
# nothing about which package is running.
#
# `dataForPlugin` reads the install.xml of the copy that was actually loaded, so it
# cannot drift the way a hand-maintained constant does. The sibling HQPlayer Bridge
# carries the same accessor for the same reason, after a constant there sat at 0.2.3
# while the repo was at 0.2.7. Cached: the answer cannot change without a restart.
my $VERSION;

sub version {
    return $VERSION if defined $VERSION;
    $VERSION = eval {
        Slim::Utils::PluginManager->dataForPlugin(__PACKAGE__)->{version};
    } || 'unknown';
    return $VERSION;
}

use constant WARM_DELAY      => 60;          # seconds after startup
use constant WARM_INTERVAL   => 24 * 3600;   # daily
# While a library scan is running the local-library tier is incomplete, so a warm
# that ran then would miss every owned track and cache that all-streaming result
# for the resolved-playlist TTL (days) — and later warms skip an already-cached
# playlist, so it would stay wrong until the weekly mbid change. So defer the warm
# while scanning and re-check on this interval.
use constant WARM_SCAN_RETRY => 120;         # seconds between scan re-checks
# Installed != ready: a service plugin's API handler lands after LMS has loaded it
# (account read, token refresh, Spotty's helper starting), and the playlist resolve
# runs ~60s into a boot. A search against a service that cannot answer is cached as
# a confirmed no-match for a WEEK, so wait for the services rather than pin misses.
# Capped: a service that never becomes ready (signed out, broken) must not hold the
# warm for ever — past the cap we warm anyway and say so.
use constant WARM_SVC_RETRY    => 30;        # seconds between readiness re-checks
use constant WARM_SVC_MAX_WAIT => 300;       # give up waiting, warm anyway

# ---------------------------------------------------------------------------
# WARM STAGE TIMING — instrumentation only, no behaviour change.
#
# The question this exists to answer is NOT "how long did the warm take" but
# "WHAT WAS RUNNING AT THE SAME TIME AS WHAT". `_warmTick` calls `warmFeeds` and
# `warmCache` back to back without waiting, `warmFeeds` fires three feed fetches
# concurrently, and `warmCache` starts the genre ladder alongside the playlist
# resolves — so a table of durations alone cannot distinguish "the genre ladder is
# slow" from "the genre ladder is starving the feeds". Absolute start/end marks
# can, which is why both are recorded rather than an elapsed time.
#
# Held in a package lexical rather than `kv` because it describes this process,
# not durable cached data. A stage table from before a restart would describe a
# different run.
#
# Every entry is eval-guarded at the call site's expense, never this module's: a
# recorder that can die turns an instrument into an outage.
# ---------------------------------------------------------------------------
my %WARM_STAGE;     # name => { start, end, outcome, note }
my @WARM_ORDER;     # names in the order they STARTED — the overlap is the point
my $WARM_TICK_AT;   # epoch the current tick began
my $WARM_TICK_N = 0;

# Mark a stage as started. Re-starting a name that is already open (a stage that
# runs once per feed, say) overwrites it rather than accumulating — the tick is
# the unit of measurement, not the call.
sub stageStart {
    my ($name) = @_;
    return unless defined $name && length $name;
    push @WARM_ORDER, $name unless exists $WARM_STAGE{$name};
    $WARM_STAGE{$name} = { start => Time::HiRes::time(), end => 0, outcome => 'running', note => '' };
    return;
}

# Mark a stage as finished. $outcome is one word — done / skipped / failed /
# cache-hit — and $note is free text for whatever the stage counted.
#
# A stage that was never started still records, with a zero start: that is the
# shape of "this stage was skipped before it began" (no username, no token,
# section switched off), and it is worth seeing in the report rather than being
# silently absent.
sub stageEnd {
    my ($name, $outcome, $note) = @_;
    return unless defined $name && length $name;
    my $e = $WARM_STAGE{$name};
    unless ($e) {
        push @WARM_ORDER, $name;
        $e = $WARM_STAGE{$name} = { start => 0, end => 0, outcome => '', note => '' };
    }
    $e->{end}     = Time::HiRes::time();
    $e->{outcome} = $outcome // 'done';
    $e->{note}    = $note    // '';
    return;
}

# Clear the table for a new tick. Called at the top of _warmTick ONLY — a stage
# from the previous day's tick is not evidence about this one.
sub stageReset {
    %WARM_STAGE   = ();
    @WARM_ORDER   = ();
    $WARM_TICK_AT = Time::HiRes::time();
    $WARM_TICK_N++;
    return;
}

# The recorded table, oldest-start first. Returns plain data so the CLI (and any
# test) can read it without touching the lexicals.
sub warmStages {
    my @rows;
    for my $name (@WARM_ORDER) {
        my $e = $WARM_STAGE{$name} or next;
        push @rows, {
            name    => $name,
            start   => $e->{start},
            end     => $e->{end},
            # Elapsed is only meaningful once both ends are known. A running stage
            # reports the time SO FAR, which is what you want when the report is
            # read mid-tick; a never-started one reports 0 rather than a negative.
            elapsed => ( $e->{start}
                            ? ( $e->{end} ? $e->{end} - $e->{start}
                                          : Time::HiRes::time() - $e->{start} )
                            : 0 ),
            outcome => $e->{outcome},
            note    => $e->{note},
        };
    }
    return {
        tick_at => $WARM_TICK_AT // 0,
        ticks   => $WARM_TICK_N,
        stages  => \@rows,
    };
}

# ARE WE A DEV BUILD? 1 on `dev`, 0 on `main`. This is telemetry only: ordinary
# version changes preserve every cache on both branches. Cache families invalidate
# themselves with their own key/schema/parser versions; a plugin version is not a
# reason to download the same upstream data again.
use constant DEV_BUILD => 1;

# Set to 1 only for a deliberately built clean-load test. The next version change
# then clears both derived rows and genre answers, reproducing the populated-store
# side of a fresh install without making every routine dev install one. Return it
# to 0 before building anything intended to preserve an existing installation.
use constant RESET_CACHE_ON_BUILD => 0;

my $log = Slim::Utils::Log->addLogCategory({
    'category'     => 'plugin.listenbrainzfreshreleases',
    # WARN in production keeps server.log quiet (the INFO lines log every API
    # response code/length/URL and cache hit). Raise to INFO via Settings →
    # Logging when diagnosing.
    'defaultLevel' => 'WARN',
    'description'  => 'PLUGIN_LISTENBRAINZ_FRESH_RELEASES',
});

my $prefs = preferences('plugin.listenbrainzfreshreleases');

# The manual Last.fm key field was REMOVED 2026-09-14 — the built-in key
# (API::lastfmKey) is the only one used. Drop any stored value so a user's old key
# does not sit unused in prefs.yaml. Idempotent; a no-op once it is gone.
eval { $prefs->remove('lastfm_api_key') if defined $prefs->get('lastfm_api_key'); 1 };

$prefs->init({
    # General
    username             => '',
    token                => '',
    muspy_userid         => '',
    # THE RELEASE WINDOW IS WHOLE MONDAY-TO-SUNDAY WEEKS, set PER SECTION as
    # <section>_weeks (total, this week = 1, max 4) + <section>_upcoming (how many
    # of those are ahead) — see the For You / All Releases blocks below and
    # API::sectionWeeks, the only reader. MuSpy has no window of its own; it rides
    # For You's. The retired `days`, `muspy_future_months`, `muspy_future`,
    # `weeks_past`/`weeks_future` and the four `*_past`/`*_future` gates are
    # deliberately NOT migrated or deleted: they simply stop being read.
    # Per-view content sort (release_date / artist / album), flipped in place by
    # the "Sorted by …" toggle in each view's Options section — not on the settings
    # page. Both are DURABLE, so the choice sticks across visits and restarts.
    # `foryou_sort` = New Releases for You; `all_sort` = All Releases (shared across
    # every week view). Replaced the old global `sort` pref in 0.9.97.
    foryou_sort          => 'release_date',
    all_sort             => 'release_date',
    # Per-view release-family filter, flipped in place by the "Showing …" toggle in
    # each view's Options section (NOT on the settings page — like the sort toggles).
    # Two states: 'albums' (everything that ISN'T a single/EP) or 'singles_eps'
    # (primary type Single or EP). Applied AFTER the settings type-checkbox filter,
    # so it only narrows within the types the user has ticked (nothing ticked is
    # lost — Broadcast/Other/compilations fall into the 'albums' bucket). Default
    # 'albums' so the feeds look as before out of the box. `foryou_view` = New
    # Releases for You; `all_view` = All Releases (shared across every week view).
    foryou_view          => 'albums',
    all_view             => 'albums',
    # Genre filter: arrayref of selected top-level FAMILY names, set only via the
    # in-view Genres picker (not the settings page — like the sort/view prefs).
    # EMPTY means "show everything", the same convention as the release-type
    # checkboxes.
    foryou_genres        => [],
    all_genres           => [],
    # Where the genre labels on list rows are allowed to come from.
    #   'auto'   — use a local MusicBrainz mirror when there is one (per artist,
    #              6 at a time), else the ListenBrainz bulk path. THE DEFAULT.
    #   'always' — force the ListenBrainz bulk path even when a mirror exists.
    #   'off'    — never look genres up. Rows then show only what arrives FREE
    #              with the feed (its own release_tags) plus anything Last.fm has
    #              already cached.
    #
    # 'auto' USED TO MEAN 'off' WITHOUT A MIRROR, and that was the parked state of
    # this whole feature: ListenBrainz's metadata endpoint answered a 50-mbid batch
    # in 0.25s–24s and took 125s to fill one feed, so a plugin could not turn it on
    # by default for a cosmetic label. ListenBrainz has since fixed that endpoint —
    # re-benchmarked 2026-08-12 on the live 556-release week at 2.8s for the WHOLE
    # feed — so the bulk path is now fast enough to be the default for everyone,
    # and the mirror is an optimisation rather than a prerequisite.
    # See Browse::_genreLookupMode.
    genre_lookup         => 'auto',
    play_via             => 1,
    # Master on/off for the whole "People You Follow" browse section (trending
    # tracks + both trending-albums lists + the Recommended list). Default ON
    # (preserves existing behaviour — the pref is new, so this default applies to
    # every install on update). When OFF the section, its warm pre-build and its
    # unmatched-debug entry are ALL skipped — no following/stats/feed calls, no
    # caching, no warming for it at all.
    people_follow        => 1,
    # People You Follow list ordering: 'date' (day dividers, newest first) or
    # 'recommender' (grouped by the follower who recommended each track). Flipped
    # in place by the inline toggle at the top of that list.
    follow_sort          => 'date',
    prefer_library       => 1,
    # MusicBrainz web-service base. Default is BLANK on purpose: blank lets
    # postinitPlugin auto-detect a same-host musicbrainz-docker mirror (and
    # _mbBase falls back to the public API when none is found). A non-blank
    # default would suppress both — autodetectMirror skips a configured base and
    # _mbBase never consults the auto-detected mirror. Point it at a local mirror
    # (e.g. http://your-server:5000/ws/2/) for fast, un-throttled lookups; a
    # mirror speaks the identical ws/2 API, so it's a pure host swap. (Cover art
    # still comes from the public Cover Art Archive.)
    mb_base_url          => '',
    # Opt-in dedicated warm/resolve debug log (lbf-debug.log beside server.log).
    # Off by default — turn on to track a match/caching issue, off again after.
    debug_log            => 0,
    # Pre-warm the image proxy for the feeds' cover art (Browse::_warmCovers).
    # ON by default: without it the FIRST device to open a feed pays ~1.5-2s per
    # cover to Cover Art Archive, and so does every OTHER device, because the
    # proxy's cache key includes the size spec and each device/view asks for a
    # different one. Off = no background image traffic at all; covers then fill
    # in as they are looked at, exactly as they did before.
    warm_covers          => 1,

    # The plugin version the store was last seen by. It is diagnostic in ordinary
    # builds and is also the once-only marker for an explicit clean-load test (see
    # RESET_CACHE_ON_BUILD and _buildChanged).
    last_build           => '',
    # The genre-parser version the store was last cleared for. Separate from
    # last_build ON PURPOSE: genres are expensive upstream fact, not a decision,
    # so they survive an ordinary build and clear only when the parser changes.
    last_genre_fact      => '',

    # Artists the user has blocked: an arrayref of { mbid => <artist MBID or ''>,
    # name => <display name> }. Releases by any of these are hidden from every
    # feed (For You / All Releases + the home shelves) by Browse::_filterSection.
    # Built from the release detail page's "Block this artist" action; managed
    # (unblocked) on the settings page. There is no ListenBrainz API for this —
    # it is a purely local filter applied at render time.
    blocked_artists      => [],

    # Streaming-service search priority. Services are searched in ascending order
    # and the search stops at the first one with a match; 0 = never search it.
    svc_priority_qobuz    => 1,
    svc_priority_bandcamp => 2,
    svc_priority_tidal    => 3,
    svc_priority_deezer   => 4,
    svc_priority_spotify  => 5,

    # Don't Stop The Music propagators (Similar / Raw / Top). dstm_count = how many
    # recommended recordings to pull from ListenBrainz into the pool; dstm_batch =
    # how many resolved tracks to append per queue top-up. Track resolution reuses
    # prefer_library + svc_priority_* (library first, then streaming).
    dstm_count => 100,
    dstm_batch => 15,

    # For You section
    foryou_weeks            => 4,   # this week counts as 1; total, max 4 (API::WEEKS_MAX)
    foryou_upcoming         => 2,   # of those, how many are ahead — 1 back + this + 2 ahead
    foryou_artwork_only     => 1,
    foryou_various          => 1,
    foryou_type_album       => 1,
    foryou_type_single      => 0,
    foryou_type_ep          => 0,
    foryou_type_broadcast   => 0,
    foryou_type_other       => 0,
    foryou_type_compilation => 1,
    foryou_type_soundtrack  => 0,
    foryou_type_live        => 0,
    foryou_type_remix       => 0,
    foryou_type_demo        => 0,

    # All Releases section
    all_weeks            => 2,   # last week + this week
    all_upcoming         => 0,
    all_artwork_only     => 1,
    all_various          => 1,
    all_type_album       => 1,
    all_type_single      => 0,
    all_type_ep          => 0,
    all_type_broadcast   => 0,
    all_type_other       => 0,
    all_type_compilation => 1,
    all_type_soundtrack  => 0,
    all_type_live        => 0,
    all_type_remix       => 0,
    all_type_demo        => 0,
});

sub initPlugin {
    my $class = shift;

    if (main::WEBUI) {
        require Plugins::ListenBrainzFreshReleases::Settings;
        Plugins::ListenBrainzFreshReleases::Settings->new();
    }

    require Plugins::ListenBrainzFreshReleases::Browse;
    require Plugins::ListenBrainzFreshReleases::API;

    eval {
        require Slim::Web::ImageProxy;
        if ( UNIVERSAL::can('Slim::Web::ImageProxy', 'getRightSize') ) {
            Slim::Web::ImageProxy->registerHandler(
                match => qr/coverartarchive\.org/,
                func  => sub {
                    my ($url, $spec) = @_;
                    # ONE SOURCE URL FOR EVERY SPEC, and that is the whole point.
                    #
                    # Slim::Web::ImageProxy::getImage queues by the REWRITTEN SOURCE
                    # URL ($queue{$url}), and _resizeFromFile then walks that queue
                    # resizing EACH waiting entry to its own spec, caching each under
                    # its own cachekey. So N concurrent requests for different specs
                    # of one source URL cost ONE download and N local resizes.
                    #
                    # The old ladder mapped each spec to a DIFFERENT CAA size, so the
                    # three specs Material asks for were three different source URLs
                    # and could never share a download: a 2,000-release pass issued
                    # ~6,000 upstream fetches where it needed 2,000. There is no
                    # alternative fix — the proxy calls SimpleAsyncHTTP with
                    # {cache=>1} but no `expires`, and SimpleHTTP::Base caches only a
                    # response carrying Cache-Control: max-age or Expires, which
                    # archive.org sends neither of (Last-Modified + ETag only). The
                    # downloaded original is genuinely never cached, so CONCURRENCY
                    # IS THE ONLY WAY TO SHARE ONE DOWNLOAD. Browse::_warmCovers
                    # therefore launches a release's three specs in one turn.
                    #
                    # WHY 1200 AND NOT 500: Material's largest ask on a row is
                    # _600x600_f (LMS_IMAGE_SZ = IS_HIGH_DPI ? 600 : 300) and CAA
                    # offers 250 / 500 / 1200 only, so 1200 is the ONLY source that
                    # never upscales. It is also the fewest bytes overall — one
                    # 339 KB fetch beats the 73 KB + 339 KB pair a two-size ladder
                    # would still pull — because the cost here is latency, not size:
                    # 20 covers 8-way measured 5.35s at _thumb250 against 6.33s at
                    # _thumb1200. Now-playing artwork comes from the streaming
                    # service, never from this path, so nothing above 600 is needed.
                    #
                    # PROBED 2026-09-02 before this landed: the newest 24 releases on
                    # the live feed, all three sizes each — 22 answered 200 at every
                    # size, 2 answered 404 at every size, and NONE disagreed. IA
                    # derives the thumbnails as one task, so asking only for 1200
                    # cannot lose a cover that 250 would have found. (Those two 404s
                    # are the "IA holds only the original" case; they fail on every
                    # route and size alike.)
                    #
                    # DO NOT REINSTATE getRightSize HERE. Kept as a warning because
                    # it cost a release: it returns the value of the SMALLEST key >=
                    # the request and UNDEF when nothing is big enough, so a
                    # `|| '<smallest>'` fallback fires on exactly the BIGGEST
                    # requests and serves the SMALLEST file — measured live, a
                    # _600x600_f came back 38,248 bytes against the _400x400_f beside
                    # it at 72,764. With one source there is no table to get wrong.
                    # $spec is deliberately unused: every spec resolves alike, and
                    # the proxy still caches each rendition under its own path.
                    #
                    # ANCHORED SO IT TOLERATES THE EXTENSION, and that is not
                    # cosmetic. `coverArtUrl` emits `/front-250.jpg` so the proxied
                    # path — and therefore the cached rendition — is JPEG rather than
                    # PNG (a 600px PNG measured 648,081 B against 101,100 B of JPEG,
                    # and the PNG was larger than the 1200px source it came from).
                    # This pattern used to be anchored straight at end-of-string, so
                    # the moment the URL carried an extension it stopped matching and
                    # the whole ladder silently stopped firing. The extension is
                    # captured and put back, so an extensionless URL still behaves
                    # exactly as it always did.
                    $url =~ s{/front-\d+(\.\w+)?$}{'/front-1200' . ($1 // '')}e;
                    return $url;
                },
            );
            $log->info("Registered Cover Art Archive image proxy handler");
        }
    } if preferences('server')->get('useLocalImageproxy');

    # NB: OPMLBased ignores an icon => arg; the app/menu icon always comes from
    # install.xml <icon> (OPMLBased.pm uses _pluginDataFor('icon')). We point it
    # at ...Icon_svg.png: Material's "_svg.png" convention makes it load the
    # sibling ...Icon.svg and recolour it per theme (white on dark, black on
    # light). The SVG MUST use #000 (not #000000) — Material string-replaces
    # "#000", so #000000 would corrupt to an invalid colour and render blank.
    # Non-Material skins fall back to the real transparent PNG.
    $class->SUPER::initPlugin(
        tag    => 'listenbrainzfreshreleases',
        feed   => \&Plugins::ListenBrainzFreshReleases::Browse::topLevel,
        is_app => 1,
        menu   => 'radios',
        weight => 10,
    );

    # Connectivity diagnostic. Two jobs, and the second is why it is a CLI
    # command rather than a private handler for the settings page: it is the only
    # surface a remote user (or a headless verification run) can reach —
    #     ["lbf","diag"]
    # over jsonrpc.js returns the whole report as data, so "paste this" replaces
    # "send me log.txt". Flags [0,1,1]: no player needed, it is a query, and it
    # runs async.
    Slim::Control::Request::addDispatch(
        ['lbf', 'diag'], [0, 1, 1, \&_cliDiag]);

    # Store report —
    #     ["lbf","cachestats"]
    # A SILENTLY FAILING WRITE IS INDISTINGUISHABLE FROM A FIX THAT WAS NEVER
    # INSTALLED. That is not hypothetical here: it is exactly what the 90-day TTLs
    # did for the whole life of the genre feature. The only way to tell the two
    # apart is to read the store from outside the process that wrote it, and again
    # after a restart — so this is a CLI command (remote-reachable, headless-
    # verifiable) rather than anything the settings page owns. Synchronous: it
    # counts rows. Flags [0,1,0]: no player, a query, not async.
    Slim::Control::Request::addDispatch(
        ['lbf', 'cachestats'], [0, 1, 0, \&_cliCacheStats]);

    # Warm timing report —
    #     ["lbf","warmstats"]
    # Same argument as cachestats, one layer up: the settings pages are LAN-only,
    # so a timing question asked from off-network has no other answer, and the
    # overlap between stages is not visible in server.log without reconstructing
    # it by hand from interleaved lines. Synchronous: it reads a package lexical.
    # Flags [0,1,0]: no player, a query, not async.
    Slim::Control::Request::addDispatch(
        ['lbf', 'warmstats'], [0, 1, 0, \&_cliWarmStats]);

    return;
}

# CLI: the warm stage table. Times are reported BOTH as an absolute epoch and as
# an offset from the tick's own start, because the two answer different questions
# — the epoch lines the table up against server.log, the offset makes the overlap
# readable without arithmetic.
#
# `ticks => 0` (no warm has run yet) is reported as data with an empty loop, not
# as an error: "the tick has not fired" is a real and common answer, and it is the
# one worth distinguishing from "the tick fired and recorded nothing".
sub _cliWarmStats {
    my $request = shift;

    my $rep = eval { warmStages() } || { tick_at => 0, ticks => 0, stages => [] };

    # FIRST, so a report pasted into a thread names the build it came from.
    $request->addResult('plugin_version', version());
    $request->addResult('ticks',   $rep->{ticks}   // 0);
    $request->addResult('tick_at', int($rep->{tick_at} // 0));
    $request->addResult('dev_build', DEV_BUILD ? 1 : 0);
    # Whether the warm has the built-in Last.fm key, and whether it has been stopped. The
    # SOURCE only — this report is meant to be pasted, so never the value.
    $request->addResult('lastfm_key',
        eval { Plugins::ListenBrainzFreshReleases::API->lastfmKeySource } // '');
    $request->addResult('lastfm_keys',
        eval { Plugins::ListenBrainzFreshReleases::API->lastfmLatchState } // '');
    my $details = Plugins::ListenBrainzFreshReleases::Browse::detailWarmStats();
    $request->addResult('detail_' . $_, $details->{$_}) for sort keys %$details;

    my $t0 = $rep->{tick_at} || 0;
    my $i  = 0;
    for my $s (@{ $rep->{stages} || [] }) {
        $request->addResultLoop('stages_loop', $i, 'name',    $s->{name});
        $request->addResultLoop('stages_loop', $i, 'outcome', $s->{outcome});
        # Offsets, to 2dp — the whole point is comparing them to each other.
        $request->addResultLoop('stages_loop', $i, 'at',
            $s->{start} && $t0 ? sprintf('%.2f', $s->{start} - $t0) : '');
        $request->addResultLoop('stages_loop', $i, 'until',
            $s->{end}   && $t0 ? sprintf('%.2f', $s->{end}   - $t0) : '');
        $request->addResultLoop('stages_loop', $i, 'elapsed', sprintf('%.2f', $s->{elapsed} // 0));
        $request->addResultLoop('stages_loop', $i, 'note',    $s->{note} // '');
        $i++;
    }
    $request->addResult('count', $i);

    $request->setStatusDone();
}

# CLI: flatten DB::stats into loops. `ok => 0` (an unopenable store) is reported
# as data rather than as an error — degrading to re-fetching is a supported state,
# and a report that refused to answer in it would hide the one case worth seeing.
sub _cliCacheStats {
    my $request = shift;

    my $stats = eval {
        require Plugins::ListenBrainzFreshReleases::DB;
        Plugins::ListenBrainzFreshReleases::DB::stats();
    } || { ok => 0, tables => {}, error => ($@ || 'unknown error') };

    # `plugin_version` is the RUNNING PACKAGE; `version` is the STORE SCHEMA. They
    # are different questions and the second cannot answer the first.
    $request->addResult('plugin_version', version());
    $request->addResult('ok',      $stats->{ok}      ? 1 : 0);
    $request->addResult('path',    $stats->{path}    // '');
    $request->addResult('version', $stats->{version} // 0);
    $request->addResult('bytes',   $stats->{bytes}   // 0);
    $request->addResult('error',   $stats->{error}) if $stats->{error};

    my $i = 0;
    for my $tbl (sort keys %{ $stats->{tables} || {} }) {
        $request->addResultLoop('tables_loop', $i, 'name',  $tbl);
        $request->addResultLoop('tables_loop', $i, 'rows',  $stats->{tables}{$tbl});
        $i++;
    }
    $request->addResult('count', $i);

    my $j = 0;
    for my $k (sort keys %{ $stats->{detail} || {} }) {
        $request->addResultLoop('detail_loop', $j, 'name',  $k);
        $request->addResultLoop('detail_loop', $j, 'value', $stats->{detail}{$k});
        $j++;
    }

    # Per-family kv counts. A bare total says nothing about WHICH family failed to
    # fill, and "which tier is empty" has been the actual question behind every
    # genre diagnosis this year — so the report answers it directly rather than
    # leaving it to be inferred from behaviour.
    my $f = 0;
    for my $k (sort keys %{ $stats->{families} || {} }) {
        $request->addResultLoop('families_loop', $f, 'family', $k);
        $request->addResultLoop('families_loop', $f, 'rows',   $stats->{families}{$k});
        $f++;
    }

    # Per-FEED rows, covered days and the age of the last ANSWERING fetch. This is
    # what a stage-5/6 verification actually reads: a bare `release` count cannot
    # say whether All Releases is stored and For You is not, and `age` is what
    # distinguishes "serving stored rows because the store is fresh" from "serving
    # stored rows because every fetch since has failed" — which look identical from
    # the browse and are the whole reason a dead feed needed the sweep.
    my $d = 0;
    for my $feed (@{ $stats->{feeds} || [] }) {
        $request->addResultLoop('feeds_loop', $d, $_, $feed->{$_}) for qw(feed rows days generation age);
        $d++;
    }

    $request->setStatusDone();
    return;
}

# CLI: run the probes and flatten the report into one loop plus scalar context.
#
# The `status` field carries ok/warn/fail/skip rather than a boolean, because a
# host that answers with the wrong answer (rejected token, empty search index) is
# neither reachable-and-fine nor unreachable, and flattening that distinction is
# the reporting bug this whole feature replaces.
sub _cliDiag {
    my $request = shift;

    $request->setStatusProcessing();

    # Set by the callback, so a run that answers synchronously and THEN dies cannot
    # be answered a second time by the failure branch below.
    my $answered = 0;

    # GUARDED, BECAUSE THE REQUEST IS ALREADY MARKED PROCESSING. If the require
    # fails, or run dies before it schedules any HTTP, nothing would ever call
    # setStatusDone — the ["lbf","diag"] request stays processing and the caller
    # (the settings page, or a remote user's jsonrpc.js call) hangs with no error.
    # Diag::run is well guarded ONCE STARTED: its deadline timer and pre-filled
    # rows mean a probe that never calls back still completes. This covers only the
    # window before that timer is set.
    my $ok = eval {
        require Plugins::ListenBrainzFreshReleases::Diag;
        Plugins::ListenBrainzFreshReleases::Diag->run(sub {
            my ($rows, $ctx) = @_;

            my $i = 0;
            for my $r (@$rows) {
                $request->addResultLoop('targets_loop', $i, $_, $r->{$_})
                    for qw(key name url status http ms note);
                $i++;
            }
            # The diag report exists to be PASTED into a support thread; a report
            # that does not name its own build is the one that wastes the thread.
            $request->addResult('plugin_version', version());
            $request->addResult('count', scalar @$rows);
            $request->addResult('failed', scalar grep { $_->{status} eq 'fail' } @$rows);
            $request->addResult('warned', scalar grep { $_->{status} eq 'warn' } @$rows);

            # Presence only for credentials — see Diag::_context. This output is
            # meant to be pasted into a support thread.
            $request->addResult('username', $ctx->{username});
            $request->addResult('token',    $ctx->{token});
            $request->addResult('lastfm',   $ctx->{lastfm});
            $request->addResult('proxy',    $ctx->{proxy});

            my $j = 0;
            for my $s (@{ $ctx->{services} || [] }) {
                $request->addResultLoop('services_loop', $j, $_, $s->{$_})
                    for qw(name installed priority);
                $j++;
            }

            $answered = 1;
            $request->setStatusDone();
        });
        1;
    };

    unless ($ok || $answered) {
        my $err = $@ || 'unknown error';
        $log->error("lbf diag failed to start: $err");
        # Answer in the shape of a real report, so a caller parsing the response
        # does not have to special-case this.
        $request->addResult('count',  0);
        $request->addResult('failed', 0);
        $request->addResult('warned', 0);
        $request->addResult('error',  $err);
        $request->setStatusDone();
    }

    return;
}

# Runs after all plugins have initialised, so Material Skin is available to
# check. Registers a home-page scrollable row for the For You feed, mirroring
# how Qobuz/Bandcamp do it.
sub postinitPlugin {
    my $class = shift;

    # Retire every store row left behind by a key-version bump, once, at startup.
    #
    # WHY THIS IS NOT MERELY TIDINESS: before the store, a bumped family sat in
    # the shared LMS cache until each row's own TTL ran out — up to 30 days of
    # space held by entries nothing could ever read again, and no way to see them.
    # The versions now live in ONE place (DB::KEY_VERSIONS), so a bump can reclaim
    # its own space the moment it ships, and `cachestats` reports per family.
    # `->KEY_VERSIONS`, A METHOD CALL, NEVER THE BAREWORD FORM. Written as
    # `Plugins::…::DB::KEY_VERSIONS` it is resolved at COMPILE time, and a constant
    # in another package is not declared then unless that package was already
    # loaded — the runtime `require` below is far too late. Under `use strict subs`
    # that is a fatal "Bareword not allowed", and because it happens while
    # Plugin.pm itself is compiling, the ENTIRE PLUGIN FAILS TO LOAD: no menu, no
    # feeds, no settings, and a log line that names a constant rather than anything
    # a user would recognise. It shipped in 0.9.166 and emptied every feed.
    eval {
        require Plugins::ListenBrainzFreshReleases::DB;
        # retirePrefixes stays a FUNCTION call — it takes a plain hashref, so the
        # method form would hand it the class name instead. `KEY_VERSIONS` is the
        # one that must be a method call; being a constant, it ignores the invocant.
        my $n = Plugins::ListenBrainzFreshReleases::DB::retirePrefixes(
                    Plugins::ListenBrainzFreshReleases::DB->KEY_VERSIONS);
        $log->info("Retired $n store rows left by a key-version bump") if $n;
        1;
    } or $log->error("Store prefix retirement failed: $@");

    _buildChanged();

    if ( Slim::Utils::PluginManager->isEnabled('Plugins::MaterialSkin::Plugin')
      && Plugins::MaterialSkin::Plugin->can('registerHomeExtra') ) {
        eval {
            require Plugins::ListenBrainzFreshReleases::HomeExtras;
            Plugins::ListenBrainzFreshReleases::HomeExtras->initPlugin();
            $log->info("Registered Material Skin home extra (For You)");
            1;
        } or $log->error("Failed to register Material home extra: $@");
    }

    # Register the Don't Stop The Music propagators (Similar / Raw / Top). DSTM is
    # a core plugin (normally enabled); DSTM->register guards on registerHandler so
    # a disabled DSTM is a quiet no-op.
    eval {
        require Plugins::ListenBrainzFreshReleases::DSTM;
        Plugins::ListenBrainzFreshReleases::DSTM->register();
        1;
    } or $log->error("Failed to register DSTM propagators: $@");

    # Warm the Created-for-You caches (playlist list, per-track matches, grid
    # covers) shortly after startup, then daily — so the Playlists view and each
    # playlist open instantly and the tile artwork is pre-rendered. A daily tick
    # is cheap (caches keyed by last_modified; real work only when a new week's
    # playlist lands). First run is delayed so it doesn't compete with boot.
    Slim::Utils::Timers::setTimer(undef, time() + WARM_DELAY, \&_warmTick);

    # If no MusicBrainz base is configured, probe for a same-host mirror once so a
    # musicbrainz-docker instance on this machine is used with zero config. Async,
    # no-op when a base is set or a recent probe result is cached (see API).
    eval { Plugins::ListenBrainzFreshReleases::API->autodetectMirror(); 1 }
        or $log->error("Failed to auto-detect MusicBrainz mirror: $@");
}

# ---------------------------------------------------------------------------
# BUILD-CHANGE CACHE POLICY.
#
# An ordinary build preserves the whole store. Each derived cache family owns an
# explicit key version, schema-backed data owns its migration/fact version, and
# GENRE_FACT_VERSION remains the one legitimate automatic trigger for clearing
# genre answers. A plugin version alone says nothing about stored-data validity.
#
# RESET_CACHE_ON_BUILD is the deliberate fresh-load test switch. With it enabled,
# a version change clears the disposable kv tier and every genre answer once; the
# durable base and non-genre facts still survive because deleting those would lose
# history that upstream windowed APIs cannot necessarily serve again.
# ---------------------------------------------------------------------------
sub _buildChanged {
    my $version = eval {
        Slim::Utils::PluginManager->dataForPlugin(__PACKAGE__)->{version}
    } // '';
    return unless length $version;

    my $seen = $prefs->get('last_build') // '';
    return if $seen eq $version;

    eval {
        require Plugins::ListenBrainzFreshReleases::DB;

        my $reset = RESET_CACHE_ON_BUILD ? 1 : 0;
        my $kv = $reset
            ? Plugins::ListenBrainzFreshReleases::DB::wipeDerived()
            : undef;

        my $gv    = Plugins::ListenBrainzFreshReleases::DB->GENRE_FACT_VERSION;
        my $gseen = $prefs->get('last_genre_fact') // '';
        my $g;
        if ($reset || $gseen ne $gv) {
            $g = Plugins::ListenBrainzFreshReleases::DB::wipeGenres();
            # Recorded only when they were actually cleared, so the pref keeps meaning
            # "the parser version the store was last cleared FOR" rather than "the
            # version that happened to be running last time we booted".
            $prefs->set('last_genre_fact', $gv);
        }

        my $why = $reset ? 'explicit clean-load test' : "parser v$gseen -> v$gv";
        $log->warn("Build changed ($seen -> $version): "
                 . (defined $kv
                     ? "cleared $kv derived rows"
                     : "derived cache KEPT")
                 . (defined $g
                     ? "; cleared $g genre answers ($why) — they refill from the"
                       . " ladder, oldest stamp first"
                     : "; genre cache KEPT (parser v$gv unchanged)")
                 . "; durable base and non-genre facts kept");

        # INSIDE THE EVAL, and that is the whole point: this pref is what makes the
        # sub return early next start, so setting it after the eval records the
        # build as handled whether or not it WAS. An explicit reset that died half
        # way — say wipeDerived hit a locked DB during startup — must retry next
        # start rather than record a partly-wiped store as complete.
        #
        # `last_genre_fact` beside it has always been set inside, for the same
        # reason: the pref means "the version the store was last cleared FOR", not
        # "the version that happened to be running". This one was the odd one out.
        #
        # A permanent failure retries once per server start and logs each time.
        $prefs->set('last_build', $version);
        1;
    } or $log->error("Build-change cache handling failed: $@");
}

# Run the warm, then re-arm for the next day. Deferred while a library scan is in
# progress (see WARM_SCAN_RETRY) so it never resolves against a half-scanned
# library and caches an all-streaming result for owned tracks.

# The playlist/follow/trending stage of the warm — the ONLY part that resolves
# tracks against the streaming services — held until those services can actually
# answer, then run.
#
# DELIBERATELY NOT IN _warmTick's DEFER. Waiting there would also hold the feeds
# and the genre ladder, which touch no streaming API and are the two things a view
# needs to render at all; the scan defer can hold everything because a half-scanned
# library poisons the library tier the same way. This one waits for the stage that
# is actually at risk, so a slow Spotty costs the playlists a few minutes and costs
# All Releases nothing.
#
# $waited is threaded rather than kept in a file-scoped counter so the daily tick
# starts from zero without anything having to reset it.
sub _warmPlaylistsWhenReady {
    my ($waited) = @_;
    $waited ||= 0;

    my @notReady = eval { Plugins::ListenBrainzFreshReleases::Browse::streamingNotReady() };
    if (@notReady && $waited < WARM_SVC_MAX_WAIT) {
        dbg("warm: streaming not ready (" . join(', ', @notReady) . ") — deferring " . WARM_SVC_RETRY . "s");
        # setTimer hands the $obj back as the callback's first argument; the closure
        # takes none, so the count is carried in the closure instead.
        Slim::Utils::Timers::setTimer(undef, time() + WARM_SVC_RETRY,
            sub { _warmPlaylistsWhenReady($waited + WARM_SVC_RETRY) });
        return;
    }
    $log->warn("warm: streaming still not ready (" . join(', ', @notReady)
             . ") after " . WARM_SVC_MAX_WAIT . "s — warming anyway") if @notReady;

    eval {
        Plugins::ListenBrainzFreshReleases::Browse::warmCache();
        1;
    } or $log->error("Playlist warm failed: $@");
}
sub _warmTick {
    if ( Slim::Music::Import->stillScanning() ) {
        dbg("warm: library scan in progress — deferring " . WARM_SCAN_RETRY . "s");
        Slim::Utils::Timers::setTimer(undef, time() + WARM_SCAN_RETRY, \&_warmTick);
        return;
    }

    # Start a fresh stage table. Deliberately AFTER the scan-defer check — a
    # deferred tick has not begun, and resetting here would show an empty table
    # for however long the scan runs, which reads as "the warm did nothing".
    stageReset();

    # THE FEED WARM RUNS AHEAD OF warmCache, AND THAT ORDER IS THE POINT.
    # `warmCache` returns early without a username (Browse.pm), so All Releases —
    # which needs no account at all — HAS NEVER BEEN WARMED FOR ANYONE. Now that a
    # feed fetch fills a durable store rather than a cache key that expires at
    # midnight, warming it is what makes the first browse of the day instant
    # instead of a 2-15s ListenBrainz round trip.
    # ORDERED, NOT MERELY SEQUENCED. warmFeeds now CHAINS its three feeds
    # (For You -> All Releases -> MuSpy) and calls back when the last one lands;
    # warmCache — playlists, then the follower builds — starts from that callback
    # rather than being fired in the same turn. Previously both were fire-and-forget,
    # so "feeds first" meant only "issued first", and on a cold store the playlist
    # and follower work raced the feeds it should have been queued behind.
    #
    # The callback is what carries the ordering, so warmCache must run even if the
    # chain fails: warmFeeds guards it with its own WARM_FEED_CHAIN_MAX watchdog,
    # and the eval below cannot swallow a failure INSIDE an async callback (that
    # dies in LMS's event loop, outside this scope) — hence the watchdog rather
    # than relying on this eval to notice.
    eval {
        require Plugins::ListenBrainzFreshReleases::Browse;
        Plugins::ListenBrainzFreshReleases::Browse::warmFeeds(sub {
            _warmPlaylistsWhenReady(0);
        });
        1;
    } or $log->error("Feed warm failed: $@");

    # Collect expired kv rows. This has to run on a TIMER, not from the store's
    # open path: the rows that need collecting are precisely the ones nothing will
    # ever read again, so the per-read cleanup cannot reach them, and an open-time
    # sweep fires once per server start. Without this the table grows with UPTIME
    # — a defect that is invisible on any machine that happens to reboot nightly.
    eval {
        require Plugins::ListenBrainzFreshReleases::DB;
        my $n = Plugins::ListenBrainzFreshReleases::DB::kvSweep();
        dbg("warm: swept $n expired store rows") if $n;

        # Stored releases do not expire, so the one behaviour that genuinely
        # changes with the store is that a permanently dead feed would otherwise
        # show months-old releases for ever. This bounds it at 120 days —
        # comfortably beyond the four-week window's reach, so it can never
        # reach a row the window still wants.
        my $f = Plugins::ListenBrainzFreshReleases::DB::feedSweep();
        dbg("warm: swept $f stale feed rows") if $f;
        1;
    } or $log->error("Store sweep failed: $@");

    Slim::Utils::Timers::setTimer(undef, time() + WARM_INTERVAL, \&_warmTick);
}

# ---------------------------------------------------------------------------
# Dedicated, opt-in debug log for warm/resolve tracking. Always mirrors to
# server.log at info; when the debug_log pref is on, ALSO appends a timestamped
# line to lbf-debug.log (beside server.log) so the warm/match timeline is easy
# to follow without wading through the rest of server.log. Size-capped (~1 MB,
# one .old rotation) so it can't grow unbounded. Fully eval-guarded — a logging
# failure never disrupts the caller.
# ---------------------------------------------------------------------------
my $DBG_FILE;   # memoised path

sub _dbgFile {
    return $DBG_FILE if defined $DBG_FILE;
    my $dir = eval { scalar Slim::Utils::OSDetect::dirsFor('log') };
    $dir = preferences('server')->get('cachedir') if !$dir || !-d $dir;
    $DBG_FILE = File::Spec->catfile($dir // '.', 'lbf-debug.log');
    return $DBG_FILE;
}

sub dbg {
    my $msg = shift;
    $log->info($msg);
    return unless $prefs->get('debug_log');
    eval {
        my $file = _dbgFile();
        rename($file, "$file.old") if (-s $file // 0) > 1_000_000;   # ~1 MB cap, keep one rotation
        open(my $fh, '>>:encoding(UTF-8)', $file) or die "open $file: $!";
        my @t = localtime(time);
        printf $fh "%04d-%02d-%02d %02d:%02d:%02d  %s\n",
            $t[5]+1900, $t[4]+1, $t[3], $t[2], $t[1], $t[0], $msg;
        close $fh;
        1;
    } or $log->warn("debug-log write failed: $@");
}

sub getDisplayName { 'PLUGIN_LISTENBRAINZ_FRESH_RELEASES' }

sub playerMenu { undef }

1;
