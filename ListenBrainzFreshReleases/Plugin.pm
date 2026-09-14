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
use Digest::MD5 qw(md5_hex);
use POSIX ();

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

use constant WARM_DELAY      => 180;         # seconds after startup, before the CATCH-UP
                                            # warm. Raised from 60 in the fixed-clock
                                            # build: the 0.9.195 diagnosis is direct
                                            # evidence that 60s post-boot is the worst
                                            # moment on the machine — the cold pass ran
                                            # while the box was saturated by its own boot
                                            # and pinned 8 false no-matches. Under the
                                            # startup gate the catch-up fires far less
                                            # often, which makes waiting longer cheap.
use constant WARM_MERGE      => 3600;        # a tick due this close BEFORE a scheduled
                                            # warm folds into it — see _catchUpFold.
use constant WARM_INTERVAL   => 24 * 3600;   # daily — the documented CEILING and the
                                            # fallback if _secsUntilNextWarm ever answers
                                            # something non-sensical. NOT the re-arm.
use constant WARM_HOUR       => 5;          # LOCAL hour to start the overnight warm
use constant WARM_JITTER_MAX => 1800;       # per-install spread, 0..1799s
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

    my $buildChanged = _buildChanged();

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
    # Through the GATE, not unconditionally — see _armWarm. The answer to "did the
    # build change?" is PASSED IN because _buildChanged consumed it above and
    # cannot be re-asked.
    _armWarm($buildChanged);

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
    # ANSWER THE QUESTION, do not just act on it. The startup warm gate has to know
    # whether this fired, and it CANNOT re-ask: the eval below sets `last_build` to
    # the running version as its last act, so a second call takes this very return.
    # Returning a bare `return` here (undef) and the eval's value below would make
    # the two paths indistinguishable, and the gate's build-changed branch would be
    # dead code — a clean-load test build restarting after its scheduled hour would
    # silently skip the refill it exists for.
    return 0 if $seen eq $version;

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

    # A DIFFERENT BUILD WAS SEEN, whether or not the wipe itself succeeded. The gate
    # wants "is this a new build?", not "did the wipe work" — a half-wiped store is
    # the case that most needs a catch-up warm, not least.
    return 1;
}

# ---------------------------------------------------------------------------
# THE MOST RECENT SCHEDULED WARM INSTANT.
#
# The mirror image of _secsUntilNextWarm, built by the SAME one-liner (_warmInstantOn)
# so the two can never disagree about where the boundary is: today's scheduled
# instant if it has already passed, otherwise yesterday's. At or before $now, and
# never more than a local day back (25 hours across the autumn change).
#
# NOT `$now + _secsUntilNextWarm($now) - 86400`, which is what this was. A local day
# is not 86400 seconds twice a year, so on those days that answer was an hour off
# the real instant — and on the autumn day it made a restart that had already
# warmed read as "no warm since the last scheduled hour" and run a needless
# catch-up.
sub _lastWarmInstant {
    my ($now) = @_;
    $now = time() unless defined $now;
    # FROM TOMORROW DOWN, not from today: the first candidate at or before $now is
    # then the LATEST one even if the local date were ever read one day off — a
    # loop starting at today would stop at yesterday's and skip today's.
    for my $d (1, 0, -1, -2) {
        my $at = _warmInstantOn($now, $d);
        return $at if $at <= $now;
    }
    return $now - 86400;   # unreachable: yesterday's instant is always in the past
}

# The scheduled instant on the local day $d days from $now's: WARM_HOUR plus the
# jitter, as a real LOCAL time. mktime normalises the day overflow (the 32nd, the
# 0th) and, with isdst = -1, works out whether that date is in summer time — which
# is the whole reason it exists. See _secsUntilNextWarm for why seconds-arithmetic
# cannot do this.
sub _warmInstantOn {
    my ($now, $d) = @_;
    my @t = localtime($now);
    return POSIX::mktime(_warmJitter(), 0, WARM_HOUR, $t[3] + $d, $t[4], $t[5], 0, 0, -1);
}

# One place that arms a warm timer, so the suite has a seam and the three kinds are
# named rather than told apart by their delay.
sub _armTimer {
    my ($in, $what) = @_;
    my %cb = (
        tick   => \&_warmTick,      # the catch-up, shortly after startup
        clock  => \&_warmTick,      # the next scheduled overnight run
        reseed => \&_warmReseed,    # skip path: rebuild the queue, fetch nothing
    );
    Slim::Utils::Timers::setTimer(undef, time() + $in, $cb{$what});
}

# ---------------------------------------------------------------------------
# THE STARTUP GATE — "have you had today's warm?", asked once, at startup.
#
# WHAT THIS FIXES. Every restart used to run a complete warm 60 seconds later,
# unconditionally: three forced feed fetches, the genre ladder up to its 400-artist
# Last.fm cap at one request a second, the playlist listing forced, the follower
# builds. Restart five times over an evening — a build test, a settings change, a
# crash — and that is five complete warms, of which only the first could have found
# anything.
#
# WHAT IT MUST NOT BREAK, and this is the regression the whole change could
# plausibly introduce. The startup tick is NOT redundant and is not being removed:
#
#   - THE SCHEDULE HAS NO EXISTENCE OUTSIDE THE PROCESS. The timer lives in
#     Slim::Utils::Timers, in memory. Nothing on disk remembers that a tick is due.
#     A machine powered down at 05:00, or restarted more often than the interval,
#     would NEVER warm at all if the startup tick were simply deleted — and a fixed
#     clock makes that worse, not better: 24h-from-startup at least fires on any
#     machine with 24h of uptime, whereas a fixed 05:00 never fires on a server its
#     owner switches off overnight. The startup tick is the catch-up, and the fixed
#     clock makes it load-bearing.
#   - kvSweep AND feedSweep RUN FROM _warmTick AND NOWHERE ELSE. No tick means the
#     kv table grows without bound.
#
# So the gate is "has a tick run since the most recent scheduled instant?", derived
# from the same clock helper as the schedule itself — there is no second number to
# tune and no way for the two to disagree. A threshold in hours would have been a
# second source of truth.
#
# THE SKIP BRANCH IS NOT A BARE RETURN. It arms the clock (a gate that skipped the
# catch-up AND forgot the schedule would stop the plugin warming at all, and would
# pass a test that only checked "no tick ran"), and it re-seeds the in-memory detail
# queue from the store, because warmFeeds is that queue's only seeder — see
# Browse::reseedFromStore.
#
# THE CATCH-UP BRANCH ARMS UNCONDITIONALLY, AND THAT IS CORRECT. Whether it should
# fold into an imminent scheduled warm is decided when it FIRES, in _warmTick, not
# here — a boot-time scan can move it arbitrarily close to the instant after this
# sub has answered. See _catchUpFold.
sub _armWarm {
    my ($buildChanged, $now) = @_;
    $now = time() unless defined $now;

    my $lastTick = $prefs->get('warm_last_at') || 0;
    my $due      = _lastWarmInstant($now);

    my $why;
    if    ($buildChanged)    { $why = 'build changed' }
    elsif (!$lastTick)       { $why = 'no warm on record' }
    elsif ($lastTick < $due) { $why = 'no warm since the last scheduled hour' }

    if ($why) {
        dbg("warm: catch-up armed in " . WARM_DELAY . "s ($why)");
        _armTimer(WARM_DELAY, 'tick');
        return;
    }

    my $clockIn = _secsUntilNextWarm($now);
    _armTimer($clockIn, 'clock');

    # NO RE-SEED WHEN THE CLOCK BEATS IT. A restart in the WARM_DELAY before the
    # scheduled instant would otherwise fire the clock tick first — warmFeeds sets
    # $detailMainReady to 0 for its phase ordering — and then the re-seed, which
    # releases that flag outright. Detail work would start in the gap between the
    # feed chain releasing its Last.fm hold and _warmGenres taking its own (the
    # streaming-readiness wait, up to WARM_SVC_MAX_WAIT, likeliest right after a
    # boot): the 0.9.204 phase inversion for that one warm. Not arming it is exact
    # rather than a guard: the tick seeds the same queue itself, from a forced fetch.
    # The reverse order (re-seed, then a later tick) is safe and stays — the tick
    # re-zeroes the flag for its own phase.
    if ($clockIn <= WARM_DELAY) {
        dbg("warm: today's warm already ran — catch-up skipped; clock due in ${clockIn}s, "
          . "so it seeds the queue itself (no re-seed)");
        return;
    }
    dbg("warm: today's warm already ran — catch-up skipped; clock armed, queue re-seeding");
    _armTimer(WARM_DELAY, 'reseed');
}

# The skip path's only work: rebuild the in-memory detail queue from what the store
# already holds. Issues no feed fetch — see Browse::reseedFromStore.
sub _warmReseed {
    eval {
        require Plugins::ListenBrainzFreshReleases::Browse;
        Plugins::ListenBrainzFreshReleases::Browse::reseedFromStore();
        1;
    } or $log->error("Detail queue re-seed failed: $@");
}

# ---------------------------------------------------------------------------
# THE OVERNIGHT CLOCK — a fixed LOCAL hour, not 24 hours after startup.
#
# Modelled on API::_secsUntilNextWeeklyRefresh but deliberately NOT placed beside
# it. That one lives in API.pm because its consumer — the created-for listing TTL
# — is in API.pm; this one's only consumer is _warmTick, so putting it there would
# mean Plugin.pm reaching across for a private sub it alone uses. Same style, same
# arithmetic-only discipline: no Time::Local, nothing to get wrong.
#
# WHY A FIXED CLOCK AT ALL. WARM_INTERVAL re-armed 24 hours from STARTUP, so the
# daily tick landed at whatever o'clock the server was last restarted at — on the
# live rig 08:58, the middle of the day, competing with listening and ~6 hours
# adrift of ListenBrainz's own 03:00 UTC job purely by coincidence.
#
# WHY LOCAL AND NOT UTC. The release-window arithmetic is local throughout
# (API::_today, DB::_weekStart), so a UTC schedule would roll the warm and the
# window on different clocks. And the requirement is about the USER's night, not
# ListenBrainz's: a fixed UTC hour would put the warm at 16:00 in Sydney.
#
# WHY 05:00. Two constraints. It must be after ListenBrainz's 03:00 UTC job has
# actually LANDED (the job is only *requested* at 03:00; the Spark cluster then
# takes its time), and it must sit outside 00:00-03:00 so a daylight-saving
# transition can never make the target hour ambiguous or non-existent. 05:00 local
# satisfies both from UTC-12 to UTC+2. East of that the tick lands before that
# day's job and picks up the previous run — the same freshness any fixed schedule
# gives, and stale-while-revalidate still corrects it on the first browse.
#
# DST IS HANDLED BY ASKING FOR A LOCAL TIME, NOT BY ADDING SECONDS — and the first
# version of this sub got that exactly backwards. It computed "target minus
# seconds-into-day, plus 86400 if past", on the stated theory that the transition
# day would land an hour off and the next tick would be back on target. That is
# true of the SPRING change only. On the AUTUMN change (a 25-hour day) the tick at
# 05:10 BST re-armed for 86400s later = 04:10 GMT, and THAT tick, being before
# 05:10, re-armed for an hour later: TWO complete warms on one morning, the second
# resetting the first's detail phase. Measured with TZ=Europe/London, 2026-10-25.
# t_warmclock.pl section 3 missed it because it never followed the re-arm CHAIN.
#
# So the target is built as a real local time on a real local date (_warmInstantOn,
# POSIX::mktime with isdst = -1), and every run lands on WARM_HOUR + jitter local,
# the transition days included — section 3 now demands exactness and one run per
# local date. POSIX is core and LMS loads it; WARM_HOUR sits outside 00:00-03:00,
# so the target is never the hour a transition makes ambiguous or non-existent.
#
# $now is an argument ONLY so the suite can ask about a chosen instant. Nothing in
# the plugin passes it.
sub _secsUntilNextWarm {
    my ($now) = @_;
    $now = time() unless defined $now;

    # STRICTLY FUTURE, AND THE `>` IS LOAD-BEARING. _warmTick re-arms from this at
    # the bottom of the sub, so an answer of 0 at the moment the tick fires would
    # re-arm for NOW — firing again immediately, and again, for ever. Asked AT
    # today's instant, today's does not qualify and tomorrow's is returned.
    # From YESTERDAY up, for the reason _lastWarmInstant walks down from tomorrow:
    # the first candidate after $now is the EARLIEST one either way.
    for my $d (-1, 0, 1, 2) {
        my $at = _warmInstantOn($now, $d);
        return $at - $now if $at > $now;
    }
    return 86400;          # unreachable: tomorrow's instant is always in the future
}

# A per-install offset of 0..WARM_JITTER_MAX-1 seconds, STABLE for the life of the
# install.
#
# WHY SPREAD. Without it every copy of this plugin in a given timezone hits
# api.listenbrainz.org in the same second. MetaBrainz is publicly asking for relief
# from exactly that kind of surge (their 2026-08-19 status post reports the Spark
# cluster failing every other week), and half an hour of spread costs us nothing.
#
# WHY STABLE. Derived from a fixed local value rather than rand(), so it survives a
# restart and does not move between ticks. A wandering jitter would make the
# `next_tick_at` this build adds unverifiable — which is the whole point of
# reporting it.
#
# `our`, not `my`, for the reason %REVALIDATING and %FEED_MEMO are: the suite has
# to clear the memo to drive several seeds through the real sub, and a lexical
# would make the "not a constant zero for every install" assertion untestable.
#
# md5_hex DIES on any codepoint above 255 and the username is free text a user
# typed, so the seed is encoded to octets first — the 0.6.15 / 0.9.66 wide-character
# trap arriving at a third site.
our $warmJitter;
sub _warmJitter {
    return $warmJitter if defined $warmJitter;

    my $seed = eval { preferences('server')->get('server_uuid') } // '';
    $seed = $prefs->get('username') // '' unless length $seed;
    $seed = 'listenbrainzfreshreleases' unless length $seed;   # deterministic last resort

    utf8::encode($seed) if utf8::is_utf8($seed);
    $warmJitter = hex(substr(md5_hex($seed), 0, 8)) % WARM_JITTER_MAX;
    return $warmJitter;
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
# ---------------------------------------------------------------------------
# A TICK DUE SHORTLY BEFORE A SCHEDULED WARM FOLDS INTO IT.
#
# The catch-up is armed WARM_DELAY after startup, and every tick re-arms for the
# next scheduled instant when it finishes. So a catch-up that lands just before
# 05:0x — LMS started at 05:01 on a 05:04:30 install — re-arms for 29 seconds later
# and TWO complete warms run over each other: three forced feed fetches twice, and
# the second warmFeeds zeroing $detailMainReady while the first warm's genre tail
# is about to set it back to 1, releasing detail work mid-feed-chain — the 0.9.204
# phase inversion, reached through the catch-up branch this time. Found by the
# 2026-09-14 review of 0.9.217.
#
# WHY HERE AND NOT IN _armWarm. A gate-time check sees only the boot instant, and
# the scan defer below moves a tick in 120s steps after that: a boot-time library
# scan carries the catch-up right up to the instant however far away it started.
# Simulated: a gate-only fix still left warms 160s apart after a 1h scan and 40s
# after a 2h one. Asked at the moment the tick is about to warm, one rule covers
# both paths.
#
# WHY IT CAN NEVER SWALLOW A SCHEDULED TICK. The clock tick fires AT or after its
# instant, and _secsUntilNextWarm is strictly future, so from there the next
# instant is 23-25 hours away — never inside WARM_MERGE. t_warmclock.pl §6b pins
# that across both DST weeks, and pins a tick firing ten minutes late.
#
# WHAT IT COSTS, stated: a catch-up due within an hour of the instant now warms AT
# the instant, up to WARM_DELAY + WARM_MERGE after boot, with no re-seed in the
# wait (the store is stale on that path, so a non-forced re-seed would revalidate in
# the background and duplicate the forced fetch minutes later). And an hour keeps
# two warms apart only while a warm's main phase finishes inside it — measured ~22s
# warm and ~10 minutes cold, so a wide margin, not a bound.
sub _catchUpFold {
    my ($now) = @_;
    $now = time() unless defined $now;
    my $in = _secsUntilNextWarm($now);
    return $in <= WARM_MERGE ? $in : 0;
}

sub _warmTick {
    if ( Slim::Music::Import->stillScanning() ) {
        dbg("warm: library scan in progress — deferring " . WARM_SCAN_RETRY . "s");
        Slim::Utils::Timers::setTimer(undef, time() + WARM_SCAN_RETRY, \&_warmTick);
        return;
    }

    # AFTER the scan defer, so a scan-blocked tick keeps retrying on its own clock;
    # BEFORE stageReset and the warm_last_at stamp, because a folded tick is not a
    # warm and must not read as one. See _catchUpFold.
    if ( my $fold = _catchUpFold() ) {
        dbg("warm: scheduled warm due in ${fold}s — folding this tick into it");
        Slim::Utils::Timers::setTimer(undef, time() + $fold, \&_warmTick);
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

    # STAMP THE SCHEDULE MARKER, on the synchronous path, beside the re-arm.
    #
    # It records "the warm ran at this hour", NOT "the warm succeeded" — written
    # here rather than from an async callback deliberately, so a tick whose chain
    # later fails still counts. The alternative makes a run of feed failures turn
    # every restart back into a full warm, which is the behaviour being fixed.
    # warmstats remains the record of what actually succeeded.
    $prefs->set('warm_last_at', time());

    # RE-ARM ON THE CLOCK, not on an interval measured from this tick. Computed
    # fresh every time, which is what makes the schedule self-correcting across a
    # DST transition and what stops the drift an interval accumulates.
    Slim::Utils::Timers::setTimer(undef, time() + _secsUntilNextWarm(), \&_warmTick);
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
