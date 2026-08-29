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
use constant WARM_DELAY      => 60;          # seconds after startup
use constant WARM_INTERVAL   => 24 * 3600;   # daily
# While a library scan is running the local-library tier is incomplete, so a warm
# that ran then would miss every owned track and cache that all-streaming result
# for the resolved-playlist TTL (days) — and later warms skip an already-cached
# playlist, so it would stay wrong until the weekly mbid change. So defer the warm
# while scanning and re-check on this interval.
use constant WARM_SCAN_RETRY => 120;         # seconds between scan re-checks

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
# Held in a package lexical rather than `kv`: the dev-build wipe is one
# unconditional `DELETE FROM kv`, and a measurement only has to survive until it
# is read. It is deliberately NOT persisted — a stage table from before a restart
# describes a different process.
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

# ARE WE A DEV BUILD? 1 on `dev`, 0 on `main`, and it is the ONLY thing in the
# plugin that knows the difference — the `(dev)` version-tag convention is retired
# and `repo.xml` (whose <url> is the real dev↔main diff) is not inside the zip.
#
# It gates ONE thing: whether _buildChanged throws the user's genres away. In dev
# every build clears everything, because a stale cache has repeatedly made a working
# fix look broken. A RELEASED build must not — genres are the most expensive thing
# this plugin collects (66 rate-limited ListenBrainz batches and a deliberately paced
# one-request-per-second Last.fm pass; the per-artist hosted pass that used to sit
# between them was removed in 0.9.173), so a release
# clears them only when GENRE_FACT_VERSION says the parser that wrote them changed.
#
# SET THIS TO 0 AT MERGE-TO-MAIN, with the `repo.xml` <url> line — the two are the
# same one-line reconciliation, and leaving this at 1 in a release re-inflicts the
# 0.9.166/0.9.167 wipe on every user who upgrades.
use constant DEV_BUILD       => 1;

my $log = Slim::Utils::Log->addLogCategory({
    'category'     => 'plugin.listenbrainzfreshreleases',
    # WARN in production keeps server.log quiet (the INFO lines log every API
    # response code/length/URL and cache hit). Raise to INFO via Settings →
    # Logging when diagnosing.
    'defaultLevel' => 'WARN',
    'description'  => 'PLUGIN_LISTENBRAINZ_FRESH_RELEASES',
});

my $prefs = preferences('plugin.listenbrainzfreshreleases');

$prefs->init({
    # General
    username             => '',
    token                => '',
    lastfm_api_key       => '',
    muspy_userid         => '',
    muspy_future         => 1,
    # THE RELEASE WINDOW IS WHOLE MONDAY-TO-SUNDAY WEEKS (0.9.185), replacing the
    # rolling `days` count (1-90, default 14) and MuSpy's `muspy_future_months`.
    # The current week is ALWAYS included in full — these are the whole weeks
    # EITHER SIDE of it, and 1 + past + future is capped at four. See
    # API::sectionWeeks, which is the only place they are read.
    # `days` and `muspy_future_months` are deliberately NOT migrated or deleted:
    # they simply stop being read, and everyone lands on 1 back / 2 ahead.
    weeks_past           => 1,
    weeks_future         => 2,
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

    # The plugin version the store was last seen by, which is how a build change
    # is detected (see _buildChanged). It lives in a PREF and not in the store for
    # the obvious reason: the thing it triggers is `DELETE FROM kv`, so a marker
    # kept in kv would delete itself and every build would look like a new one.
    # Same lesson as the follow feed's `follow_last_seen` (0.9.75).
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

    # Don't Stop The Music propagators (Similar / Raw / Top). dstm_count = how many
    # recommended recordings to pull from ListenBrainz into the pool; dstm_batch =
    # how many resolved tracks to append per queue top-up. Track resolution reuses
    # prefer_library + svc_priority_* (library first, then streaming).
    dstm_count => 100,
    dstm_batch => 15,

    # For You section
    foryou_past             => 1,
    foryou_future           => 1,   # upcoming releases on by default (0.9.79) — new installs only; existing prefs win
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
    all_past             => 1,
    all_future           => 0,
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
                    # getRightSize returns the value of the SMALLEST key >= the
                    # requested dimension, and UNDEF when nothing in the table is
                    # big enough (verified in Slim/Web/ImageProxy.pm — the loop
                    # simply falls off the end). So a `|| '<smallest>'` fallback
                    # fires on exactly the BIGGEST requests and serves the
                    # SMALLEST file. Material asks for `_<n>x<n>_f` where n is
                    # IS_HIGH_DPI ? 600 : 300 for a grid tile, ? 300 : 150 for a
                    # list row and ? 2048 : 1024 for now-playing — so with the
                    # table topping out at 500, every hi-dpi grid tile was a
                    # 250px thumbnail upscaled 2.4x, on the one surface that
                    # shows artwork biggest. Measured live: a `_600x600_f` came
                    # back SMALLER (38KB) than the `_400x400_f` beside it (72KB).
                    # The table now reaches 1200 (CAA serves front-250 8.8KB /
                    # front-500 18KB / front-1200 77KB) and the fallback is the
                    # LARGEST option, never the smallest.
                    my $size = Slim::Web::ImageProxy->getRightSize($spec, {
                        50   => '250',
                        100  => '250',
                        250  => '250',
                        500  => '500',
                        1200 => '1200',
                    }) || '1200';
                    $url =~ s|/front-\d+$|/front-$size|;
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

    $request->addResult('ticks',   $rep->{ticks}   // 0);
    $request->addResult('tick_at', int($rep->{tick_at} // 0));
    $request->addResult('dev_build', DEV_BUILD ? 1 : 0);

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
            $request->addResult('count', scalar @$rows);
            $request->addResult('failed', scalar grep { $_->{status} eq 'fail' } @$rows);
            $request->addResult('warned', scalar grep { $_->{status} eq 'warn' } @$rows);

            # Presence only for credentials — see Diag::_context. This output is
            # meant to be pasted into a support thread.
            $request->addResult('username', $ctx->{username});
            $request->addResult('token',    $ctx->{token});
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
# THE DEV-BUILD WIPE.
#
# The fleet rule is that every dev build invalidates all plugin caches, because
# stale caches have repeatedly made a working fix look broken. What makes it safe
# to do UNCONDITIONALLY here — one `DELETE FROM kv`, no allowlist to get wrong —
# is that anything which must survive now has a TABLE. Do not add exceptions to
# this; move the data instead.
#
# WHAT DELIBERATELY SURVIVES, and each one is a decision from §2.1 rather than an
# oversight:
#   * the durable BASE — stored releases, feed coverage, Bandcamp pins, the
#     follow store. ListenBrainz only re-serves releases inside the window it is
#     asked for, so wiping the base would LOSE older rows outright, not
#     re-download them.
#   * the FACTS except genres — years, types, MBIDs and above all SORT-NAMES, which
#     are re-derivable only at 100 artists per pass, serially, with a courtesy gap.
#     A genre change must never re-inflict a multi-day artist-sort reconvergence.
#
# The marker is a PREF, not a store row: the wipe is `DELETE FROM kv`, so a marker
# in kv would delete itself and every start would look like a new build.
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

        my $kv = Plugins::ListenBrainzFreshReleases::DB::wipeDerived();

        # WHILE IN DEV, EVERY BUILD CLEARS EVERY CACHE. That is the standing rule
        # and it exists for a reason no amount of reasoning replaces: a stale cache
        # has repeatedly made a working fix look broken, and there is otherwise NO
        # way to test first-run behaviour, or what a user sees when they widen the
        # window and a swathe of releases arrives that the store has never held.
        #
        # 0.9.168 gated this on GENRE_FACT_VERSION after a wipe left the store empty
        # for days — but the wipe was never the defect. `wipeGenres` cleared the
        # answers and left their TIMESTAMPS running, so nothing could be re-asked for
        # ninety days; the store was not slow to refill, it was LOCKED. That is fixed
        # at its source (per-answer stamps, cleared with the answer), so a wipe is
        # recoverable again and the rule goes back.
        #
        # GENRE_FACT_VERSION is still the PRODUCTION trigger — a released build must
        # not throw a user's genres away for nothing — and it is still recorded here
        # so the two cannot disagree about which parser wrote what.
        #
        # TWO TRIGGERS, AND UNTIL 0.9.175 ONLY ONE OF THEM EXISTED. `last_genre_fact`
        # was written on every build and READ BY NOTHING, so the "production trigger"
        # the comment above describes never ran: a released upgrade that changed no
        # genre code still cleared all four artist tiers, the release-group genres and
        # the whole `lastfm_tags` table. That is precisely what the 0.9.169 changelog
        # promises users does not happen ("a released build still only clears genres
        # when the code that parses them changes"), and it is the harm 0.9.168 was
        # over-reacting to. DEV_BUILD is the dev rule; the pref is the release gate.
        my $gv    = Plugins::ListenBrainzFreshReleases::DB->GENRE_FACT_VERSION;
        my $gseen = $prefs->get('last_genre_fact') // '';
        my $g;
        if (DEV_BUILD || $gseen ne $gv) {
            $g = Plugins::ListenBrainzFreshReleases::DB::wipeGenres();
            # Recorded only when they were actually cleared, so the pref keeps meaning
            # "the parser version the store was last cleared FOR" rather than "the
            # version that happened to be running last time we booted".
            $prefs->set('last_genre_fact', $gv);
        }

        my $why = DEV_BUILD ? 'dev build' : "parser v$gseen -> v$gv";
        $log->warn("Build changed ($seen -> $version): cleared $kv derived rows"
                 . (defined $g
                     ? "; cleared $g genre answers ($why) — they refill from the"
                       . " ladder, oldest stamp first"
                     : "; genres KEPT (parser v$gv unchanged)")
                 . "; releases, feed coverage, pins, follow items, dates and"
                 . " sort-names kept");

        # INSIDE THE EVAL, and that is the whole point: this pref is what makes the
        # sub return early next start, so setting it after the eval records the
        # build as handled whether or not it WAS. A wipe that died half way — say
        # wipeDerived hit a locked DB during startup — then left a partly-wiped
        # store marked done and never ran again for that version, which is the one
        # path by which a dev build can silently NOT clear its caches.
        #
        # `last_genre_fact` beside it has always been set inside, for the same
        # reason: the pref means "the version the store was last cleared FOR", not
        # "the version that happened to be running". This one was the odd one out.
        #
        # A permanent failure now retries once per server start and logs each time.
        # That is the right trade: the retry is idempotent (`DELETE FROM kv`) and
        # one error line per start is a symptom you can act on, where a half-wiped
        # store marked complete is exactly the state the rule exists to prevent.
        $prefs->set('last_build', $version);
        1;
    } or $log->error("Dev-build wipe failed: $@");
}

# Run the warm, then re-arm for the next day. Deferred while a library scan is in
# progress (see WARM_SCAN_RETRY) so it never resolves against a half-scanned
# library and caches an all-streaming result for owned tracks.
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
            eval {
                Plugins::ListenBrainzFreshReleases::Browse::warmCache();
                1;
            } or $log->error("Playlist warm failed: $@");
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
