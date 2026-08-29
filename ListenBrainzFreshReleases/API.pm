package Plugins::ListenBrainzFreshReleases::API;

use strict;
use warnings;

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::PluginManager;
use Slim::Utils::Timers;
use Time::HiRes ();
use JSON::XS::VersionOneAndTwo;

use Plugins::ListenBrainzFreshReleases::DB;

my $log   = logger('plugin.listenbrainzfreshreleases');
my $prefs = preferences('plugin.listenbrainzfreshreleases');

# THE STORE, NOT THE LMS CACHE. Same three methods, same three signatures, so
# every call site below reads as it always did — but `$ttl` now means seconds
# from now at any magnitude, the key is used verbatim rather than md5'd, and a
# bare string round-trips with its utf8 flag. See DB::Store for why the call
# sites were deliberately left alone. The genre bug was never in them.
my $cache = Plugins::ListenBrainzFreshReleases::DB::store();

# Various Artists MBID — skip the (pointless) sort-name lookup for VA credits.
use constant VA_MBID => '89ad4ac3-39f7-470e-963a-56509c546377';

# A MusicBrainz tracklist never changes, so cache a found result for a long time;
# genres can be sparse on fresh releases, so recheck an empty result daily.
use constant MB_FOUND_TTL => 30 * 86400;
use constant MB_EMPTY_TTL =>  1 * 86400;

# Last.fm tags change slowly; cache a found result for a month and recheck an
# empty one TOMORROW. See the age policy in docs/feed-findings-2026-08-14.md §2:
# an empty is the answer most likely to be wrong tomorrow, because it is the one
# an upstream dataset fills in. Seven days here meant a brand-new album that
# picked up tags on day two did not show them until day eight.
use constant LFM_FOUND_TTL => 30 * 86400;
use constant LFM_EMPTY_TTL =>  1 * 86400;

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
#
# STILL USED BY THE FOLLOW FEED, NO LONGER BY THE RELEASE FEEDS. The `…fb:` twins
# for All Releases / For You / MuSpy are GONE as storage: stored rows do not
# expire, so the last good copy is simply what is in the store, and its AGE is
# reportable (feed_meta.ok_at) rather than being an invisible second key that
# happened to be written at the same moment. See _feedWindow below.
use constant FEED_FALLBACK_TTL => 30 * 86400;

# ---------------------------------------------------------------------------
# THE RELEASE FEEDS ARE STORED, NOT CACHED (0.9.166)
#
# What was wrong: the whole feed went into ONE blob under a key containing
# today's date, so the entire ~3,255-release structure was re-fetched and
# re-frozen at every local midnight, and again on any change to the window or the
# past/future prefs — although almost none of those releases had moved in weeks.
#
# What happens now, per open:
#
#   nothing stored          -> fetch, and BLOCK on it (as before — there is
#                              genuinely nothing to show)
#   stored and fresh        -> serve from the store. NO HTTP AT ALL.
#   stored and stale, OR
#   stored with a gap       -> SERVE IMMEDIATELY, revalidate behind the render.
#
# The last line is the whole user-visible win and it is safe because every feed
# callback is already `cachetime => 0`, so the next walk picks up whatever the
# revalidation stored. Narrowing the window (3 weeks back -> 1) now costs NOTHING;
# widening it costs one fetch; midnight costs nothing whenever the shifted window
# is already covered — and with a week-aligned window most midnights do not shift
# it at all, only Monday's does.
#
# WHY A COVERAGE GAP DOES NOT FETCH ONLY THE MISSING DAYS, correcting §2.2 of
# docs/caching-rework.md: ListenBrainz's fresh_releases routes take
# `days=N&past=&future=` and answer with the WHOLE window. Neither the user route
# nor the explore route has a day-range parameter, so "fetch the uncovered days"
# is not expressible. A gap is repaired by the one full fetch; what the coverage
# query buys is the decision of whether that fetch has to block, which it does not.
use constant FEED_STALE_AFTER => FEED_TTL;

# Only ONE revalidation per feed may be in flight. Without this, the three or more
# XMLBrowser walks a single tap produces would each see the same stale coverage and
# each launch its own fetch — turning a background refresh into a self-inflicted
# burst against the rate limit the 429 work exists to respect.
my %REVALIDATING;

# ...and the SAME argument applies to the OPEN path, which %REVALIDATING does not
# cover: its guard is `if ($bg)`, and an open-path fetch carries onDone so $bg is
# false. On a WARM store that is harmless — the extra walks read the store and never
# fetch. On a COLD store (first open after install, or after the store is wiped)
# there is nothing to read, so each of those three-plus walks fires its own
# ListenBrainz fetch for the identical URL. %FEED_MEMO cannot help: it caches
# COMPLETED results, and none of them completes until 2-10s later.
#
# So the second and subsequent callers WAIT on the first instead of racing it. Keyed
# on the MEMO key, not the feed name, because sort and the week window both change
# what comes back and are all in that key — fanning one result out to a caller that
# asked a different question would be worse than the duplicate fetch.
my %INFLIGHT;   # memo key => [ { onDone, onError }, ... ] waiting on the in-flight fetch

# A CLAIMED KEY THAT IS NEVER RELEASED IS WORSE THAN NO SINGLE-FLIGHT AT ALL: every
# later cold open of that feed parks itself onto a list nothing will ever drain and
# returns WITHOUT RENDERING, for the life of the process — the registry is
# in-process by design, so no TTL and no cache expiry can clear it. Every exit
# releases its own claim through $fanout; this timer is the braces to that belt,
# for the case no release path can cover (a callback that never arrives at all).
# Same shape, and the same reasoning, as Browse's BUILDING_MAX.
#
# Comfortably clear of a legitimate run: SimpleAsyncHTTP guarantees a callback by
# FEED_TIMEOUT, and the ingest behind it hands back its refusal verdict
# synchronously, so claim-to-fanout cannot exceed one timeout plus one turn.
my %INFLIGHT_TIMER;
use constant INFLIGHT_MAX => 3 * FEED_TIMEOUT;

# ---------------------------------------------------------------------------
# THE WINDOW IS WHOLE MONDAY-TO-SUNDAY WEEKS (0.9.185)
#
# It used to be a rolling DAY count (`days`, 1-90) measured from today, and that
# cut the current week in half. The UI renders in whole weeks — the `W/C <Monday>`
# rows Browse::_weekStart builds — but the window's edges landed on arbitrary
# days, so with "include earlier weeks" off the current week's row held only
# today onwards and FRIDAY'S RELEASES (the week's main drop) were gone by
# Saturday. Turning the past side on was the only workaround, and it dragged in a
# ragged 14 days of history rather than whole weeks.
#
# So the window is now expressed in weeks anchored to Monday, with a hard budget
# of four weeks in total:
#
#     weeks_past   (0-3)   whole weeks BEFORE the current one
#     [current week]       ALWAYS included, Monday to Sunday, IN FULL
#     weeks_future (0-3)   whole weeks AFTER the current one
#
# The current week always being whole is the entire point: a Friday release stays
# visible until the WEEK rolls out of scope, not until midnight.
#
# This is cheap because of the 0.9.166 store rework — releases are stored
# permanently and the window is only a filter on the READ (DB::feedReleases), so
# narrowing it costs nothing and invalidates nothing. No BASE_VERSION bump (see
# DB.pm's header: one loses every older row for good, because ListenBrainz only
# re-serves releases inside the window it is asked for).
# ---------------------------------------------------------------------------
use constant WEEKS_MAX_SIDE => 3;   # current week + 3 = the four-week budget

# Pref defaults and per-section checkbox gates for the week window. The four
# per-section boxes survive the move from days to weeks as pure ON/OFF GATES —
# unticked means ZERO weeks on that side, for that section only — which is what
# keeps For You and All Releases on their independent defaults (foryou_future on,
# all_future off) without a second window pref each.
#
# 'muspy' is the For You window with a different FUTURE gate: MuSpy is a small,
# user-curated follow list whose whole value is upcoming releases, so its future
# side has always had its own toggle. It is just measured in the same weeks now
# (muspy_future_months is retired).
use constant WEEKS_PAST_DEFAULT   => 1;
use constant WEEKS_FUTURE_DEFAULT => 2;
my %WEEK_GATES = (
    foryou => [ 'foryou_past', 1, 'foryou_future', 1 ],
    all    => [ 'all_past',    1, 'all_future',    0 ],
    muspy  => [ 'foryou_past', 1, 'muspy_future',  1 ],
);

# THE ONE PLACE THE WEEK PREFS ARE READ. It replaces ~12 duplicated
# `$prefs->get('days') // 14` + past/future read sites across Browse.pm and the
# second copy inside clearFeedCache — sites that DISAGREED: foryou_future fell
# back to `// 0` in four of them and `// 1` in warmFeeds, so a warm and a browse
# asked ListenBrainz two different questions and stored two different windows.
#
# It lives in API.pm rather than Browse.pm because clearFeedCache has to rebuild
# the identical memo key, and a memo key that disagrees with the fetcher's is the
# 0.9.141 Refresh bug arriving from a new direction.
#
# Returns the GATED, CLAMPED week counts for $prefix ('foryou' | 'all' | 'muspy').
sub sectionWeeks {
    my ($class, $prefix) = @_;
    ($class, $prefix) = (undef, $class) unless defined $prefix;   # callable either way
    my $g = $WEEK_GATES{ $prefix // '' } or return (0, 0);

    my ($wp, $wf) = _clampWeeks($prefs->get('weeks_past'), $prefs->get('weeks_future'));
    $wp = 0 unless ($prefs->get($g->[0]) // $g->[1]);
    $wf = 0 unless ($prefs->get($g->[2]) // $g->[3]);
    return ($wp, $wf);
}

# THE FEED MEMO KEY, BUILT IN EXACTLY ONE PLACE. The fetcher mints it and
# clearFeedCache drops it, and when those two disagree Refresh drops a key nobody
# holds and then serves the very copy it was meant to replace — the 0.9.141 bug,
# which survived the move to the store unchanged because it was never about the
# store. Two call sites spelling out the same join is how that happens, so they
# do not: they call this.
#
# The date STAYS in the All Releases key and is GONE from storage. That is the
# 0.9.166 fix: the memo is a five-second thing whose key may name today, the store
# is not, and it was the store keying on today that re-minted the feed every
# midnight.
sub _feedMemoKey {
    my ($which, $sort, $wp, $wf) = @_;
    $sort ||= 'release_date';
    return 'lbf:feed:all:' . join('|', $sort, $wp, $wf, _today()) if $which eq 'all';
    return 'lbf:feed:user:' . join('|', ($prefs->get('username') // ''), $sort, $wp, $wf);
}

# The same window as ('YYYY-MM-DD','YYYY-MM-DD') — what _windowSpan and the MuSpy
# merge want, since they filter dates rather than issuing a fetch.
sub sectionWindow {
    my ($class, $prefix) = @_;
    ($class, $prefix) = (undef, $class) unless defined $prefix;
    return _feedWindow(sectionWeeks($prefix));
}

# 0-3 a side, and 1 + past + future <= 4 overall. A pref can be hand-edited in
# prefs.yaml or arrive as garbage, and it is multiplied out into a date range, so
# this clamps at READ time as well as on save. Over budget, THE PAST SIDE IS
# HONOURED FIRST and the future takes what is left (3/3 -> 3 back, 0 ahead):
# earlier weeks are releases that exist, upcoming ones are announcements.
sub _clampWeeks {
    my ($wp, $wf) = @_;
    $wp = WEEKS_PAST_DEFAULT   unless defined $wp && $wp =~ /^\d+$/;
    $wf = WEEKS_FUTURE_DEFAULT unless defined $wf && $wf =~ /^\d+$/;
    $wp = WEEKS_MAX_SIDE if $wp > WEEKS_MAX_SIDE;
    $wf = WEEKS_MAX_SIDE if $wf > WEEKS_MAX_SIDE;
    $wf = WEEKS_MAX_SIDE - $wp if $wp + $wf > WEEKS_MAX_SIDE;
    return ($wp, $wf);
}

# The window a feed is asked to cover, as ('YYYY-MM-DD','YYYY-MM-DD'): $wp whole
# weeks back from THIS Monday, through the Sunday that ends the $wf'th week ahead.
#
# It reuses DB::_weekStart — arithmetic-only, Monday-based, already documented as
# matching Browse::_weekStart. There is no third week-start implementation.
#
# The window is then WIDENED to the span the response actually carried before
# anything is recorded — see _ingestFeed. Widening is safe in a way that narrowing
# is not: the recorded window always CONTAINS the requested one, so every
# requested day still gets a feed_day row and still falls inside the rotation
# scope, which is the property §2.2 is protecting.
sub _feedWindow {
    my ($wp, $wf) = @_;
    ($wp, $wf) = _clampWeeks($wp, $wf);
    my $D   = 'Plugins::ListenBrainzFreshReleases::DB';
    my $mon = $D->can('_weekStart')->(_today());
    return ( _shiftDay($mon, -7 * $wp), _shiftDay($mon, 7 * $wf + 6) );
}

# THE LB `days=` PARAMETER IS DERIVED FROM THE WINDOW, NEVER CONFIGURED.
#
# ListenBrainz has no date-range parameter: both fresh-releases routes take
# `days=N&past=&future=` and answer SYMMETRICALLY about today (the same constraint
# that stops a coverage gap being repaired with a partial fetch — see above). So a
# week-aligned window asks for the WIDER of its two sides and lets feedReleases
# trim the rest on read. Worst case is 3 whole weeks + 6 days = 27, against the
# old pref's 90 ceiling; the over-fetched rows on the narrower side are simply
# stored, and nothing shows them.
#
# `future` comes back TRUE even when the user's "later weeks" box is off, because
# the current week runs to Sunday. That is intended, and it is the mechanism
# behind whole weeks.
sub _feedRequestDays {
    my ($from, $to) = @_;
    my $today = _today();
    my $back  = _spanDays($from, $today);
    my $fwd   = _spanDays($today, $to);
    $back = 0 if $back < 0;
    $fwd  = 0 if $fwd  < 0;
    my $days = $back > $fwd ? $back : $fwd;
    return ( ($days > 0 ? $days : 1), ($back > 0 ? 1 : 0), ($fwd > 0 ? 1 : 0) );
}

sub _today {
    my @t = localtime(time);
    return sprintf('%04d-%02d-%02d', $t[5]+1900, $t[4]+1, $t[3]);
}

sub _shiftDay {
    my ($date, $n) = @_;
    return $date unless $n;
    my $D = 'Plugins::ListenBrainzFreshReleases::DB';
    return $D->can('_fromDays')->( $D->can('_toDays')->(split /-/, $date) + $n );
}

# Whole days from $from to $to, or 0 for anything unparseable.
sub _spanDays {
    my ($from, $to) = @_;
    return 0 unless $from && $to
                 && $from =~ /^\d{4}-\d{2}-\d{2}$/ && $to =~ /^\d{4}-\d{2}-\d{2}$/;
    my $D = 'Plugins::ListenBrainzFreshReleases::DB';
    return $D->can('_toDays')->(split /-/, $to) - $D->can('_toDays')->(split /-/, $from);
}

# How far beyond the REQUESTED window a payload date is allowed to push the
# recorded one. The explore route answers a little wider than it was asked, which
# is the whole reason widening exists; six months either side covers that with
# room to spare while leaving a garbage date no purchase at all.
use constant WINDOW_SLACK_DAYS => 180;

# Store what a fetch returned. The window handed to the store is the union of the
# REQUESTED window and the span the response actually covered, so a route that
# answers a little wider than it was asked (which the explore route does) still
# gets those days recorded rather than leaving them permanently "uncovered" and
# re-fetching for ever.
#
# $rotate is passed 0 for any source whose response is a TOP-N SLICE rather than a
# window — MuSpy's `?limit=100` is exactly that. See DB::ingestFeed.
sub _ingestFeed {
    my ($feed, $releases, $from, $to, $rotate) = @_;

    # THE WIDENING IS DRIVEN BY UNVALIDATED PAYLOAD DATES, so it must be bounded.
    # `release_date` is whatever the upstream feed said; the format check below
    # passes 2099-01-01 and 1970-01-01 just as happily as a real one. One such row
    # pushed the recorded window past DB::WINDOW_MAX_DAYS, and _dayRange REFUSES a
    # window that wide by returning an empty list — silently. No feed_day row is
    # then written for any day, so coverage can never complete, every open sees a
    # gap and revalidates, and the "serve from the store, no HTTP at all" case this
    # rework exists for never happens again for that feed. The same widened window
    # is also the rotation scope, so an outlier widens what RULE 2 may delete.
    #
    # So a date only gets a vote if it is plausibly part of this window. Outliers
    # are still STORED — they are simply not allowed to define the day range.
    my ($reqFrom, $reqTo) = ($from, $to);
    my $lo = _shiftDay($reqFrom || _today(), -WINDOW_SLACK_DAYS);
    my $hi = _shiftDay($reqTo   || _today(),  WINDOW_SLACK_DAYS);

    for my $r (@{ $releases || [] }) {
        my $d = ref $r eq 'HASH' ? ($r->{release_date} // '') : '';
        next unless $d =~ /^\d{4}-\d{2}-\d{2}$/;
        next if $d lt $lo || $d gt $hi;
        $from = $d if !$from || $d lt $from;
        $to   = $d if !$to   || $d gt $to;
    }

    # BELT AND BRACES. The requested window is pref-derived, so a wide enough one
    # could carry it over the bound on its own, slack or no slack. (Far less likely
    # now the ceiling is four weeks rather than the old `days` pref's 90 a side —
    # kept because MuSpy and a widened response still arrive through here.)
    # Recording the
    # requested window is worse than recording the widened one and far better than
    # recording nothing, which is what _dayRange's silent refusal amounts to.
    my $maxSpan = Plugins::ListenBrainzFreshReleases::DB->WINDOW_MAX_DAYS;
    if (_spanDays($from, $to) > $maxSpan) {
        $log->warn("feed '$feed': window $from..$to is wider than the store records "
            . "(${maxSpan}d) — falling back to the requested window");
        ($from, $to) = ($reqFrom, $reqTo);
    }

    # chunk => N makes the row work yield between transactions instead of running
    # as one ~16,000-statement block inside this HTTP callback. That block was
    # measured at ~1.85s on the target Pi and is what drops players and stalls the
    # lazily-loaded artwork (the image proxy shares the event loop). The REFUSAL
    # verdict — the only field either call site reads — is still decided
    # synchronously before any row work, so nothing here has to wait.
    # `DB->INGEST_CHUNK`, never `DB::INGEST_CHUNK`: a bareword cross-package
    # constant is resolved at COMPILE time and killed the whole module in 0.9.166.
    my $res = eval {
        Plugins::ListenBrainzFreshReleases::DB::ingestFeed(
            $feed, $releases, from => $from, to => $to,
            chunk  => Plugins::ListenBrainzFreshReleases::DB->INGEST_CHUNK,
            rotate => (defined $rotate ? $rotate : 1));
    } || {};
    $log->warn("feed ingest for '$feed' raised: $@") if $@;
    return $res;
}

# Serve a feed out of the store if there is anything to serve, and say whether it
# needs revalidating. Returns ($releases, $stale) or () when the store is cold.
#
# `$byDay` is off for a top-N source: MuSpy's day coverage would be a LIE (a day
# inside the range can hold releases that simply fell outside the 100-item limit),
# so its freshness is decided by the age of the last answering fetch alone.
sub _feedFromStore {
    my ($feed, $from, $to, $byDay) = @_;

    my $cov = eval { Plugins::ListenBrainzFreshReleases::DB::feedCoverage($feed, $from, $to) } || {};
    return () unless $cov->{any};

    my $rels = eval { Plugins::ListenBrainzFreshReleases::DB::feedReleases($feed, $from, $to) } || [];
    return () unless ref $rels eq 'ARRAY' && @$rels;

    my $age   = $cov->{ok_at} ? (time() - $cov->{ok_at}) : (FEED_STALE_AFTER + 1);
    my $stale = ($age > FEED_STALE_AFTER) ? 1 : 0;
    $stale = 1 if $byDay && !$cov->{complete};

    $log->info(sprintf("feed '%s' served from the store: %d releases, %d/%d days, %ds old%s",
        $feed, scalar @$rels, ($cov->{covered} // 0), ($cov->{days} // 0), $age,
        $stale ? ' (revalidating)' : ''));

    return ($rels, $stale);
}

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
# Cover Art Archive also serves art keyed by a release-GROUP MBID at a different
# path. MuSpy only gives release-group MBIDs (no release-level MBID / caa_id), so
# their cover art comes from here rather than CAA_BASE_URL.
use constant CAA_RG_BASE_URL => 'https://coverartarchive.org/release-group/';
use constant MB_DEFAULT_BASE_URL => 'https://musicbrainz.org/ws/2/';
use constant LASTFM_BASE_URL => 'https://ws.audioscrobbler.com/2.0/';

# ---------------------------------------------------------------------------
# The hosted LMS-community metadata API ("mai-api", the LMS core dev's service).
# Cloudflare-cached (max-age 30d), ~57ms warm, unthrottled — so it front-runs the
# public MusicBrainz API's ~1 req/s for the majority of users who run no mirror.
#
# NOTE THE `/music` PREFIX. docs/hosted-lms-community-api.md §1 documents the
# resolver route as `/artist/<name>/mbid`; the LIVE route is
# `/music/artist/<name>/mbid` and the doc is simply wrong (that error cost a
# planning cycle). Every path passed to _hostedGet is relative to the constant
# below, so it is stated in exactly one place.
#
# WHAT THIS SERVICE IS NOT, verified live 2026-08-12 against the dev's own route
# doc (~/Downloads/mai-api.md) — do NOT "add" either of these:
#   * There is NO artist-genre route. `/music/artist/<n>/genres` answers HTTP 200
#     with the PICTURE payload, as do /tags, /genre, /info and any other
#     unrecognised path under /artist/<n>/ — it never 404s. Code written against
#     a guessed route would parse valid JSON, find no `genres` key, and yield
#     nothing forever while looking like poor coverage.
#     THE SAME IS TRUE UNDER /album/<title>/<artist>/, verified 2026-08-22:
#     /tracks, /tracklist, /recordings, /tracklisting and /songs ALL answer 200
#     with the picture payload. So the rule is the service's, not one route's —
#     never infer that an endpoint exists from a 200. Check the KEYS.
#   * There is NO TRACKLIST anywhere on this API (the probe above). The detail
#     page's tracklist source is MusicBrainz `release/<mbid>?inc=recordings`, and
#     the only alternative is ListenBrainz
#     `/1/metadata/release_group/?inc=recording` -> recording.mediums[].tracks[],
#     which is MBID-keyed and live rather than name-keyed and weekly.
#   * There is NO prose biography. /biography is a link directory, and the dev has
#     decided it stays that way. The MAI / Last.fm bio path stands.
use constant HOSTED_BASE_URL => 'https://api.lms-community.org/music/';

# The plugin package name, for the mandatory X-LMS-Plugin-ID header. Derived from
# THIS package rather than hardcoded so it can't drift: s/API$/Plugin/.
use constant PLUGIN_PACKAGE => __PACKAGE__ =~ s/\b(?:\w+)$/Plugin/r;

# Hosted-API timeout. Deliberately short: every hosted call has an unconditional
# MusicBrainz fallback behind it, so waiting is strictly worse than failing over.
use constant HOSTED_TIMEOUT => 4;

# A whole artist discography, folded to title -> { mbid, date, year, type }, cached
# per ARTIST. 7 days, NOT the 30 of MB_FOUND_TTL: the hosted service is rebuilt on
# a WEEKLY snapshot (with daily incrementals in progress), so a week is the longest
# a cached map can be held without being able to lag the source by more than one
# rebuild. Well inside the 30-day absolute-epoch ceiling that bit PFR and LBF.
use constant HOSTED_DISCO_TTL => 7 * 86400;

# The map is built from a payload that reaches ~104KB for a prolific artist (580
# entries for Radiohead, measured). Only the four fields above are kept — caching
# the raw JSON would put a six-figure string through Storable on every read.
use constant HOSTED_DISCO_MAX => 2000;

# Auto-detect: when the user sets NO mb_base_url, a same-host musicbrainz-docker
# mirror is probed once at startup (autodetectMirror) and its base cached under
# this key so the SYNCHRONOUS _mbBase can pick it up. Value: a URL (mirror found),
# '' (probed, none found), or absent (never probed). Re-probed daily.
use constant MB_AUTO_KEY => 'lbf:mbmirror:v1';
use constant MB_AUTO_TTL => 86400;

# The MusicBrainz web-service base is a PREF (default = the public API) so the
# plugin can be pointed at a local mirror — e.g. a musicbrainz-docker instance
# at http://your-server:5000/ws/2/ — for fast, un-throttled lookups without touching
# code. A mirror speaks the identical ws/2 API, so only the host changes. When
# the pref is blank, a same-host mirror auto-detected at startup is used if one
# was found; otherwise the public API. (Cover art still comes from the public
# Cover Art Archive — musicbrainz-docker does not mirror it.)
sub _mbBase {
    my $u = $prefs->get('mb_base_url');
    unless (defined $u && $u =~ /\S/) {
        my $auto = $cache->get(MB_AUTO_KEY);
        $u = (defined $auto && length $auto) ? $auto : MB_DEFAULT_BASE_URL;
    }
    $u =~ s/\s+//g;
    $u .= '/' unless $u =~ m{/$};
    return $u;
}

# True only when the configured base IS the public MusicBrainz host (incl.
# beta./test. subdomains); any other host is a local mirror. Used to decide
# whether an artist name-search may fall back to the public API (a mirror whose
# Solr search index is unbuilt returns 0 for everything while browses work).
sub _mbThrottled {
    return _mbBase() =~ m{^https?://([^/]*\.)?musicbrainz\.org/}i ? 1 : 0;
}

# ---------------------------------------------------------------------------
# THE one and only hosted-API request helper. Every call to api.lms-community.org
# goes through here — do not scatter the base URL, and do not build a hosted URL
# anywhere else. Two reasons, both from the dev:
#
#   1. X-LMS-Plugin-ID is MANDATORY on every call (it is how he sees who is
#      calling and handles abuse). One funnel = one place it can be forgotten.
#   2. AUTH MAY BE ADDED LATER. When it is, a token pref + an Authorization
#      header + a graceful 401/403 degrade all land in this sub and nowhere else.
#      The slot is marked below.
#
# $path is relative to HOSTED_BASE_URL and must already be percent-encoded by the
# caller (use _hostedSeg per segment — the segments are free text like artist and
# album names, and a '/' inside one would otherwise invent a route).
#
# EVERYTHING is a miss, never an exception: HTTP error, unparseable body, or a
# non-HASH payload all call $onMiss. Callers rely on that — each one has a
# MusicBrainz fallback behind it, so an outage degrades to today's behaviour
# rather than breaking. $onFound gets the decoded hashref.
# ---------------------------------------------------------------------------
# 429 BACKOFF FOR THE COMMUNITY API — modelled on what MusicArtistInfo does
# against this same service, because MAI is the precedent for doing this job at
# library scale and it is the reason an uncapped run is safe.
#
# MAI (`Common.pm`, scanner path): ONE request in flight, and on a 429
#   $delay = $delay ? min($delay*2, MAX_DELAY) : 5;  sleep $delay;
# resetting to 0 on any success. 5 seconds, doubling, capped at 30.
#
# We had NO 429 handling here at all while running four requests concurrently —
# four times more aggressive than the precedent AND deaf to the server asking us
# to stop. The per-pass cap was standing in for both, which is why it had to be
# set so low that the feed could never be prepared.
#
# The deadline is SHARED, like the ListenBrainz one (_lbWait): concurrent callers
# must back off TOGETHER, or the ones that did not personally see the 429 keep
# hammering and hold the limit open.
use constant HOSTED_BACKOFF_START => 5;
use constant HOSTED_BACKOFF_MAX   => 30;

# A RETRY THAT NEVER GIVES UP IS A HANG, NOT A RETRY. The ListenBrainz side has
# capped its 429 retries at LB_RETRY_MAX since it was written; this side did not,
# so a sustained 429 rescheduled _hostedGet for ever and $onMiss was never called.
# That is not merely a slow lookup: getArtistMbidByName's miss branch IS the
# MusicBrainz fallback, and DSTM::_resolveArtistMbids pumps one artist at a time
# waiting on the callback — so one wedged lookup stalls the whole radio seed
# rather than degrading to the slower source.
#
# TWO counters, because there are two ways back into this sub and only one of them
# is this caller's fault. `tries` counts requests THIS caller made that came back
# 429; `waits` counts times it found somebody else's deadline already in force and
# stood down. Sharing one counter would spend a caller's whole budget on other
# callers' rate limiting under ordinary concurrency and miss to MusicBrainz for no
# reason, so the wait budget is the looser of the two.
use constant HOSTED_RETRY_MAX => 3;
use constant HOSTED_WAIT_MAX  => 6;
my $hostedBusyUntil = 0;
my $hostedDelay     = 0;

sub _hostedWait {
    my $now = time();
    return $hostedBusyUntil > $now ? $hostedBusyUntil - $now : 0;
}

sub _hostedIsRateLimited {
    my ($resp) = @_;
    return 1 if ref $resp && $resp->can('code') && ($resp->code // 0) == 429;
    # A 429 sometimes only ever appears in the error STRING — the same shape the
    # ListenBrainz side handles, and MAI matches on the text too.
    my $err = ref $resp && $resp->can('error') ? ($resp->error // '') : '';
    return $err =~ /rate limit|\b429\b/i ? 1 : 0;
}

sub _hostedNoteLimit {
    $hostedDelay = $hostedDelay ? $hostedDelay * 2 : HOSTED_BACKOFF_START;
    $hostedDelay = HOSTED_BACKOFF_MAX if $hostedDelay > HOSTED_BACKOFF_MAX;
    # A DEADLINE ONLY EVER MOVES OUT, NEVER IN — the same guard _lbNoteLimit has.
    # The deadline is shared but the curve is reset by ANY success, so a plain
    # assignment lets a later 429 shorten a window still in force: A is limited at
    # the 30s cap (busy until T+30), B succeeds at T+1 and zeroes the curve, C is
    # limited at T+2 and restarts at 5 — parking the shared deadline at T+7 and
    # releasing all four concurrent callers 23 seconds early, straight back into
    # the live limit. Backing off TOGETHER is the whole point of sharing it.
    my $until = time() + $hostedDelay;
    $hostedBusyUntil = $until if $until > $hostedBusyUntil;
    $log->warn("Hosted API rate limit — backing off ${hostedDelay}s");
    return $hostedDelay;
}

sub _hostedNoteOk { $hostedDelay = 0; return }

sub _hostedGet {
    my ($path, $onFound, $onMiss, $st) = @_;
    $onFound ||= sub {};
    $onMiss  ||= sub {};
    # $st is INTERNAL — the retry budget, threaded through the reschedules. No
    # caller passes it, so every entry from outside starts with a full budget.
    $st ||= { tries => 0, waits => 0 };

    # BACK OFF TOGETHER. If another caller has already been rate-limited, wait out
    # the shared deadline rather than joining the queue that caused it.
    if ((my $wait = _hostedWait()) > 0) {
        if ($st->{waits}++ >= HOSTED_WAIT_MAX) {
            $log->info("Hosted API: still rate-limited after " . HOSTED_WAIT_MAX
                . " waits for $path — falling back");
            $onMiss->();
            return;
        }
        Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + $wait,
                                      sub { _hostedGet($path, $onFound, $onMiss, $st) });
        return;
    }

    # The apiHeaders helper is NEW in Slim::Utils::Misc and is absent on older
    # LMS, so it must be probed rather than called — a bare call would die at
    # runtime on exactly the servers we most want to degrade gracefully on.
    my %headers = Slim::Utils::Misc->can('apiHeaders')
        ? Slim::Utils::Misc::apiHeaders(PLUGIN_PACKAGE)
        : ('X-LMS-Plugin-ID' => PLUGIN_PACKAGE);

    # AUTH SLOT: when the dev publishes a scheme, read the token pref here and
    # add $headers{Authorization}. Treat 401/403 in the error handler below as a
    # MISS (fall back to MusicBrainz), never as a hard failure.

    my $url = HOSTED_BASE_URL . $path;
    $log->info("Hosted API: $url");

    my $http = Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $resp = shift;
            _hostedNoteOk();                     # a success clears the backoff
            my $data = eval { from_json($resp->content) };
            if ($@ || ref $data ne 'HASH') {
                $log->info("Hosted API: unparseable response for $path");
                $onMiss->();
                return;
            }
            $onFound->($data);
        },
        sub {
            my $resp = shift;
            # A 429 IS NOT A MISS — it is a request that has not been made yet.
            # Treating it as "this artist has no genres" would be a cached lie, and
            # (worse) would let the caller march straight on to the next artist at
            # full speed. Retried once the shared deadline passes — but a BOUNDED
            # number of times: past HOSTED_RETRY_MAX this stops being "not tried
            # yet" and becomes a service that is not answering, which is a miss,
            # and a miss is what releases the caller to MusicBrainz.
            if (_hostedIsRateLimited($resp)) {
                _hostedNoteLimit();
                if ($st->{tries}++ >= HOSTED_RETRY_MAX) {
                    $log->info("Hosted API: rate-limited " . HOSTED_RETRY_MAX
                        . " times for $path — falling back");
                    $onMiss->();
                    return;
                }
                # Retry against the deadline IN FORCE, not against this caller's own
                # backoff — another caller may hold a longer one, and waking before it
                # expires only spends a wait slot rediscovering that.
                my $wait = _hostedWait();
                Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + $wait,
                                              sub { _hostedGet($path, $onFound, $onMiss, $st) });
                return;
            }
            $log->info("Hosted API: request failed for $path: "
                . (ref $resp && $resp->can('error') ? ($resp->error // '?') : '?'));
            $onMiss->();
        },
        { timeout => HOSTED_TIMEOUT },
    );

    $http->get($url, %headers, 'Accept' => 'application/json');
}

# Percent-encode ONE path segment for the hosted API. Works in octets (the same
# chars-vs-octets rule as every other encoder in this file): artist and album
# names arrive as wide strings from the JSON APIs, and encoding per BYTE is what
# makes Motörhead / Sigur Rós / CJK resolve rather than 404.
sub _hostedSeg {
    my ($s) = @_;
    $s = defined $s ? $s : '';
    utf8::encode($s) if utf8::is_utf8($s);
    $s =~ s/([^A-Za-z0-9\-_.~])/sprintf("%%%02X", ord($1))/ge;
    return $s;
}

# Auto-detect a LOCAL MusicBrainz mirror on the SAME host — the common
# musicbrainz-docker-alongside-LMS setup — so it works with zero config. Only
# runs when the user has set NO mb_base_url: probe a small FIXED same-host list
# and, if one answers as a genuine ws/2 endpoint, cache its base for _mbBase.
# Validation is the point: a known artist MBID must come back with the expected
# name, which proves the responder is MusicBrainz and not some other service on
# :5000 (macOS AirPlay, a Flask app, ...) — so a false positive is effectively
# impossible. A manually-set base always wins and skips the probe; the LAN is
# NEVER scanned (localhost only — a mirror on another host is typed in by hand).
#
# THE PROBE MBID MUST BE A REAL ARTIST, AND IT WAS NOT. 0.9.94 shipped
# `a74b1b7f-06a0-4672-a641-eb3353aa608d` — a mangled copy of Radiohead's id that
# shares only the first block and 404s on the mirror AND on musicbrainz.org.
# Since a candidate is validated by fetching this artist and comparing the name,
# the probe could never validate, so NO MIRROR WAS EVER ADOPTED: every install
# with a blank mb_base_url and a same-host mirror has run against the public API
# at 1 req/s since 0.9.94, re-probing daily, forever.
#
# WHY IT SURVIVED, and why the fix is not just the constant: the failure is
# INVISIBLE BY CONSTRUCTION. A 404 on the probe artist is indistinguishable from
# "nothing is running on :5000", which is the correct and silent outcome for most
# users. No runtime log, no stubbed unit test and no amount of code reading can
# separate the two — only MusicBrainz can be asked. tools/t_diag.pl does exactly
# that (section 7, skipped when offline). Found by the connectivity diagnostic in
# 0.9.158, reporting a 404 against Simon's own working mirror; identical bug and
# fix to Discography 0.30.2.
use constant MB_PROBE_MBID => 'a74b1b7f-71a5-4011-9441-d0b5e4122711';   # Radiohead
use constant MB_PROBE_NAME => 'Radiohead';
my @MB_AUTO_CANDIDATES = (
    'http://localhost:5000/ws/2/',
    'http://127.0.0.1:5000/ws/2/',
);

sub autodetectMirror {
    my ($class, $cb) = @_;
    $cb ||= sub {};

    # Manual base set -> respect it, never probe.
    my $u = $prefs->get('mb_base_url');
    return $cb->() if defined $u && $u =~ /\S/;

    # Already probed within MB_AUTO_TTL (found a URL or confirmed none) -> done.
    return $cb->() if defined $cache->get(MB_AUTO_KEY);

    my $i = 0;
    my $try; $try = sub {
        if ($i >= @MB_AUTO_CANDIDATES) {
            eval { $cache->set(MB_AUTO_KEY, '', MB_AUTO_TTL); 1 };   # none; don't re-probe today
            return $cb->();
        }
        my $base = $MB_AUTO_CANDIDATES[$i++];
        Slim::Networking::SimpleAsyncHTTP->new(
            sub {
                my $data = eval { from_json(shift->content) };
                if (!$@ && ref $data eq 'HASH' && ($data->{name} // '') eq MB_PROBE_NAME) {
                    eval { $cache->set(MB_AUTO_KEY, $base, MB_AUTO_TTL); 1 };
                    $log->info("Auto-detected local MusicBrainz mirror: $base");
                    return $cb->();
                }
                $try->();   # answered but not MusicBrainz -> next candidate
            },
            sub { $try->() },   # unreachable / error -> next candidate
            { timeout => 3 }
        )->get($base . 'artist/' . MB_PROBE_MBID . '?fmt=json',
               'Accept' => 'application/json', 'User-Agent' => USER_AGENT());
    };
    $try->();
    return;
}

# MuSpy — an opt-in secondary source of "new releases" tailored to the artists a
# user deliberately follows there. The releases/<userid> endpoint is PUBLIC (no
# auth), so only the user's MuSpy user id is stored (muspy_userid pref) — never a
# password. The list changes ~daily like the LB feed, and since 0.9.166 it is
# STORED like one too — with rotation off, because `?limit=100` makes it a top-N
# slice rather than a window. See getMuSpyReleases.
use constant MUSPY_BASE_URL => 'https://muspy.com/api/1';
use constant MUSPY_TIMEOUT  => 10;

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
# GET /1/user/<username>/fresh_releases  (personalised, PUBLIC — username only)
#
# This endpoint needs NO token. Verified two ways (2026-08-12, and originally in
# docs/token-free-refactor.md): there is no validate_auth_header on the route in
# the ListenBrainz server source, and a live anonymous fetch of a real user's
# feed returns a payload BYTE-IDENTICAL to the same fetch with that user's token
# (same sha1 over payload.releases, same release count, same 13 fields each).
# Until 0.9.160 this was gated on `$username && $token`, so the plugin's flagship
# feed was unreachable without a credential it never needed. The token is still
# SENT when one happens to be set (same shape as getFollowing) — harmless, and it
# keeps the request identical for anyone who has one configured.
# ---------------------------------------------------------------------------
sub getFreshReleasesForUser {
    my ($class, %args) = @_;

    my $username = $prefs->get('username') // '';
    my $token    = $prefs->get('token')    // '';

    unless ($username) {
        $args{onError}->("No ListenBrainz username configured");
        return;
    }

    my $sort = $args{sort} // 'release_date';

    # The window is read HERE, from the one helper, rather than being passed in by
    # each caller — that is what stopped the browse paths and warmFeeds asking
    # ListenBrainz two different questions. `days`/`past`/`future` are derived
    # from it purely because the route has no date-range parameter.
    my ($wp, $wf)   = sectionWeeks('foryou');
    my ($from, $to) = _feedWindow($wp, $wf);
    my ($days, $p, $f) = _feedRequestDays($from, $to);
    my $past   = $p ? 'true' : 'false';
    my $future = $f ? 'true' : 'false';

    my $feed     = 'user:' . $username;
    my $memoKey  = _feedMemoKey('foryou', $sort, $wp, $wf);

    if (my $memo = _memoGet($memoKey)) {
        $args{onDone}->($memo);
        return;
    }

    (my $safe_user = $username) =~ s/([^A-Za-z0-9\-_.~])/sprintf("%%%02X",ord($1))/ge;

    my $url = sprintf('%s/1/user/%s/fresh_releases?sort=%s&past=%s&future=%s&days=%d',
        BASE_URL, $safe_user, $sort, $past, $future, $days);

    # Token is optional here — sent only when set, like getFollowing/getUserStats.
    my @headers = ('Accept' => 'application/json');
    push @headers, ('Authorization' => "Token $token") if $token;

    my ($stored, $stale) = _feedFromStore($feed, $from, $to, 1);
    if ($stored) {
        $args{onDone}->(_memoSet($memoKey, $stored));
        _fetchReleaseFeed(feed => $feed, url => $url, headers => \@headers, memoKey => $memoKey,
                          from => $from, to => $to, label => 'for-you') if $stale;
        return;
    }

    _fetchReleaseFeed(feed => $feed, url => $url, headers => \@headers, memoKey => $memoKey,
                      from => $from, to => $to, label => 'for-you',
                      onDone => $args{onDone}, onError => $args{onError});
}

# ---------------------------------------------------------------------------
# GET /1/explore/fresh-releases/  (global, no auth needed)
# ---------------------------------------------------------------------------
sub getFreshReleasesAll {
    my ($class, %args) = @_;

    my $sort = $args{sort} // 'release_date';

    my ($wp, $wf)   = sectionWeeks('all');
    my ($from, $to) = _feedWindow($wp, $wf);
    my ($days, $p, $f) = _feedRequestDays($from, $to);
    my $past   = $p ? 'true' : 'false';
    my $future = $f ? 'true' : 'false';

    my $today = _today();
    my $feed  = 'all';

    my $memoKey = _feedMemoKey('all', $sort, $wp, $wf);

    if (my $memo = _memoGet($memoKey)) {
        $args{onDone}->($memo);
        return;
    }

    my $url = sprintf('%s/1/explore/fresh-releases/?sort=%s&past=%s&future=%s&days=%d&release_date=%s',
        BASE_URL, $sort, $past, $future, $days, $today);

    my ($stored, $stale) = _feedFromStore($feed, $from, $to, 1);
    if ($stored) {
        $args{onDone}->(_memoSet($memoKey, $stored));
        _fetchReleaseFeed(feed => $feed, url => $url, memoKey => $memoKey,
                          from => $from, to => $to, label => 'all releases') if $stale;
        return;
    }

    _fetchReleaseFeed(feed => $feed, url => $url, memoKey => $memoKey,
                      from => $from, to => $to, label => 'all releases',
                      onDone => $args{onDone}, onError => $args{onError});
}

# ---------------------------------------------------------------------------
# The one fetch path for both release feeds, in either of its two roles.
#
#   WITH onDone/onError   the caller is waiting (the store was cold).
#   WITHOUT               a REVALIDATION behind an already-rendered page. It must
#                         never call back into a browse callback that has already
#                         answered, and it must never surface an error to anyone:
#                         the user is looking at stored releases and a failed
#                         refresh is not their problem.
#
# A FAILED FETCH DELETES NOTHING. It records the attempt (fetched_at, not ok_at)
# so the day stays uncovered and the next open tries again — the same branch a 429
# takes. An empty or unparseable 200 is a failed attempt too, not an empty feed:
# this repo has twice shipped the opposite (0.9.119, 0.9.149).
# ---------------------------------------------------------------------------
sub _fetchReleaseFeed {
    my (%p) = @_;
    my $feed = $p{feed};

    # One revalidation per feed at a time. A single tap produces three or more
    # XMLBrowser walks from the root, and without this each would see the same
    # stale coverage and launch its own fetch.
    my $bg = !$p{onDone};
    if ($bg) {
        return if $REVALIDATING{$feed};
        $REVALIDATING{$feed} = 1;
    }

    # SINGLE-FLIGHT the open path. See %INFLIGHT above for why %REVALIDATING does not
    # cover this. A caller that finds a fetch already running is parked and answered
    # from that fetch's result; only the first caller reaches the network.
    # THE KEY MUST DESCRIBE THE REQUEST THAT WILL ACTUALLY BE SENT, not just the
    # feed — the memo key covers the sort and the week window, and the HEADERS cover
    # the rest. Without them a caller holding a ListenBrainz token could be parked
    # behind an anonymous fetch and have their token silently never sent; harmless
    # for fresh_releases (the payloads are byte-identical either way, which is what
    # t_tokenfree exists to pin) but it would make the request LBF issues depend on
    # which browse walk happened to arrive first. Only identical requests share.
    my $ikey = ($p{memoKey} // $feed) . "\0" . join("\0", map { defined $_ ? $_ : '' } @{ $p{headers} || [] });
    unless ($bg) {
        if (my $waiters = $INFLIGHT{$ikey}) {
            push @$waiters, { onDone => $p{onDone}, onError => $p{onError} };
            $log->info("feed '$feed' already being fetched — waiting on it ("
                     . scalar(@$waiters) . " waiting)");
            return;
        }
        $INFLIGHT{$ikey} = [];
    }

    # Answer everyone parked behind this fetch, exactly once. EVAL'd per waiter: these
    # are XMLBrowser render callbacks, and one of them dying must not strand the rest
    # — they are unrelated browse sessions that merely asked the same question.
    my $fanout = sub {
        my ($which, @args) = @_;
        return if $bg;                            # a background refresh parks nobody
        eval { Slim::Utils::Timers::killSpecific(delete $INFLIGHT_TIMER{$ikey})
                   if $INFLIGHT_TIMER{$ikey}; 1 };
        my $waiters = delete $INFLIGHT{$ikey} or return;
        for my $w (@$waiters) {
            my $cb = $w->{$which};
            next unless ref $cb eq 'CODE';
            eval { $cb->(@args); 1 } or $log->error("feed waiter ($which) raised: $@");
        }
    };

    # Arm the leak watchdog now $fanout exists to do the releasing. It answers the
    # parked waiters rather than merely dropping the key — a waiter freed without a
    # callback is still a browse that never renders, which is the very thing being
    # prevented.
    unless ($bg) {
        eval {
            $INFLIGHT_TIMER{$ikey} = Slim::Utils::Timers::setTimer(
                undef, Time::HiRes::time() + INFLIGHT_MAX, sub {
                    return unless $INFLIGHT{$ikey};
                    $log->error("feed '$feed' single-flight claim expired after "
                              . INFLIGHT_MAX . "s without a result — releasing "
                              . scalar(@{ $INFLIGHT{$ikey} }) . " waiter(s)");
                    $fanout->('onError', 'ListenBrainz feed fetch did not complete');
                });
            1;
        };
    }

    my $done = sub {
        delete $REVALIDATING{$feed} if $bg;
        return unless $p{onDone};
        # EVAL'D FOR THE SAME REASON THE WAITERS ARE, and this is the asymmetry that
        # was the bug: $fanout — the ONLY place the claim is released — runs AFTER
        # the first caller's own callback. $p{onDone} is an XMLBrowser render
        # callback like any waiter's, so a die in it left $ikey claimed for ever and
        # every later cold open of this feed parked behind a fetch that had finished.
        eval { $p{onDone}->($_[0]); 1 } or $log->error("feed caller (onDone) raised: $@");
        $fanout->('onDone', $_[0]);
    };

    my $failed = sub {
        my ($resp) = @_;
        delete $REVALIDATING{$feed} if $bg;
        _ingestNoteFailure($feed, $p{from}, $p{to});
        return if $bg;

        # Nothing was rendered, so there is still a caller to answer. Serve stored
        # rows if there are any — a ListenBrainz outage degrades to slightly stale
        # data rather than to an empty menu — and only surface the error when the
        # store is genuinely empty too.
        my ($stored) = _feedFromStore($feed, $p{from}, $p{to}, 0);
        if ($stored) {
            my $msg = (ref $resp && $resp->can('error')) ? ($resp->error // '?') : 'error';
            $log->warn("ListenBrainz feed fetch failed ($msg) — serving the stored copy");
            # Eval'd for the reason $done's is: this is the OTHER path that runs the
            # first caller's own callback ahead of $fanout, so a die here strands the
            # claim identically. The error branch below is safe by construction —
            # _handleError runs no user code between it and $fanout.
            eval { $p{onDone}->(_memoSet($p{memoKey}, $stored)); 1 }
                or $log->error("feed caller (onDone, stored copy) raised: $@");
            $fanout->('onDone', $stored);
            return;
        }
        # A FAILURE MUST RELEASE THE WAITERS TOO. Parking them and then answering only
        # the first caller would turn a duplicate fetch into a hung browse — strictly
        # worse than the race this replaces.
        #
        # AND WITH THE SAME ARGUMENT SHAPE: _handleError hands onError a STRING, not
        # the response object, so the message is derived once and both get it. A
        # waiter handed $resp would receive a different type from the caller it was
        # multiplexed with — the kind of mismatch that only shows up in whichever
        # browse session happened to arrive second.
        my $msg = (ref $resp && $resp->can('error'))
                ? ($resp->error // 'Unknown HTTP error') : 'Unknown HTTP error';
        _handleError($resp, $p{onError});
        $fanout->('onError', $msg);
    };

    $log->info("Fetching $p{label}: $p{url}" . ($bg ? ' (revalidating behind the render)' : ''));

    my $http = Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $resp = shift;
            _handleResponse($resp,
                sub {
                    my $releases = shift;
                    my $res = _ingestFeed($feed, $releases, $p{from}, $p{to}, 1);
                    # A refused ingest (empty response, rows already stored) is a
                    # failure, not a feed that emptied — serve what is stored.
                    if ($res->{refused}) {
                        my ($stored) = _feedFromStore($feed, $p{from}, $p{to}, 0);
                        $releases = $stored if $stored;
                    }
                    _memoSet($p{memoKey}, $releases) if $p{memoKey};
                    $done->($releases);
                },
                sub { $failed->($resp) },
            );
        },
        sub { $failed->(shift) },
        { timeout => FEED_TIMEOUT }
    );

    $http->get($p{url}, @{ $p{headers} || ['Accept' => 'application/json'] });
}

sub _ingestNoteFailure {
    my ($feed, $from, $to) = @_;
    eval { Plugins::ListenBrainzFreshReleases::DB::feedNoteAttempt($feed, $from, $to); 1 }
        or $log->warn("recording a failed feed attempt raised: $@");
}

# ---------------------------------------------------------------------------
# GET https://muspy.com/api/1/releases/<userid>  (public — no auth)
# ---------------------------------------------------------------------------
# The user's followed-artist release groups, newest-first, mapped into the
# internal release-hash shape so they merge into the For You feed and dedupe
# against the ListenBrainz releases. Best-effort: ANY failure (no userid,
# transport error, unparseable body) resolves onDone with the last good copy or
# an empty list — it must never blank the LB feed. No onError path by design.
sub getMuSpyReleases {
    my ($class, %args) = @_;

    my $userid = $prefs->get('muspy_userid') // '';
    $userid =~ s/^\s+|\s+$//g;
    unless (length $userid) {
        $args{onDone}->([]);
        return;
    }

    my $feed    = 'muspy:' . $userid;
    my $memoKey = 'lbf:muspy:' . $userid;

    # Memoed like the LB feeds (0.9.139). Two reasons, and the second is the one
    # that matters: it saves the per-walk read, AND it makes the returned arrayref
    # STABLE across the re-walks of one interaction — which is what lets Browse's
    # derived-section memo recognise the For You inputs as unchanged (_mergeMuSpy
    # builds a fresh arrayref from them, so identity has to come from the sources).
    if (my $memo = _memoGet($memoKey)) {
        $args{onDone}->($memo);
        return;
    }

    # ------------------------------------------------------------------
    # MUSPY IS STORED WITH ROTATION OFF, AND THAT IS NOT A TUNING CHOICE.
    #
    # `?limit=100` returns a TOP-N SLICE, not a window. So:
    #   * day coverage would be a LIE — a day inside the range can hold releases
    #     that simply fell outside the 100, so $byDay is 0 and freshness is decided
    #     purely by the age of the last answering fetch;
    #   * window-scoped rotation would DELETE rows that are still perfectly valid,
    #     just pushed past the limit. That is "an empty result is never a fact"
    #     (0.9.119, 0.9.149) arriving from a new direction — a truncated list is
    #     not proof of absence either.
    # Rows therefore accumulate and age out on `seen_at` in DB::feedSweep instead.
    #
    # It earns its place in the store rather than staying in kv for two reasons:
    # it is read back UNWINDOWED and held far beyond what is displayed (see
    # Browse::_mergeMuSpy — a followed artist's album announced three months out is
    # fetched and stored today, and simply appears when the forward edge reaches
    # it), so it is the case where a window change most needs to be free; and MuSpy
    # rows are the only source of an inline artist_sort_name.
    # ------------------------------------------------------------------
    my ($stored, $stale) = _feedFromStore($feed, undef, undef, 0);
    if ($stored && !$stale) {
        $args{onDone}->(_memoSet($memoKey, $stored));
        return;
    }

    (my $safe = $userid) =~ s/([^A-Za-z0-9\-_.~])/sprintf("%%%02X",ord($1))/ge;
    my $url = sprintf('%s/releases/%s?limit=100', MUSPY_BASE_URL, $safe);
    $log->info("Fetching MuSpy releases: $url");

    # Best-effort throughout: ANY failure resolves onDone with the stored copy or
    # an empty list. It must never blank the LB feed it merges into, so there is
    # deliberately no onError path.
    my $serveStored = sub {
        my ($rels) = _feedFromStore($feed, undef, undef, 0);
        $args{onDone}->($rels && @$rels ? _memoSet($memoKey, $rels) : []);
    };

    my $http = Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $resp = shift;
            my $rels = _parseMuSpy($resp);
            if (defined $rels) {
                my $res = _ingestFeed($feed, $rels, undef, undef, 0);
                if ($res->{refused}) { $serveStored->(); return }
                $args{onDone}->(_memoSet($memoKey, $rels));
            }
            else {
                # A 200 with an unparseable body: serve the stored copy rather than
                # letting an empty MuSpy list stand as an answer.
                _ingestNoteFailure($feed, undef, undef);
                $serveStored->();
            }
        },
        sub {
            my $resp = shift;
            $log->warn("MuSpy fetch failed: " . ($resp->error // '?'));
            _ingestNoteFailure($feed, undef, undef);
            $serveStored->();
        },
        { timeout => MUSPY_TIMEOUT }
    );

    $http->get($url, 'Accept' => 'application/json');
}

# Parse a MuSpy releases response into the internal release-hash shape. Returns
# an arrayref (possibly empty) on success, or undef if the body isn't the
# expected JSON array (so the caller can fall back to the last good copy).
# MuSpy release object: { artist => { name, mbid, sort_name, disambiguation },
# mbid => <release-group-mbid>, name => <title>, type => <primary type>,
# date => 'YYYY' | 'YYYY-MM' | 'YYYY-MM-DD' }.
sub _parseMuSpy {
    my ($resp) = @_;

    my $data = eval { from_json($resp->content) };
    if ($@) {
        $log->error("MuSpy JSON parse error: $@");
        return undef;
    }
    # Tolerate either a bare array or a { releases => [...] } wrapper.
    $data = $data->{releases} if ref $data eq 'HASH' && ref $data->{releases} eq 'ARRAY';
    return undef unless ref $data eq 'ARRAY';

    my @out;
    for my $r (@$data) {
        next unless ref $r eq 'HASH';
        my $artist = $r->{artist};
        my $aname  = ref $artist eq 'HASH' ? ($artist->{name} // '') : (defined $artist ? $artist : '');
        my $asort  = ref $artist eq 'HASH' ? ($artist->{sort_name} // '') : '';
        my $ambid  = ref $artist eq 'HASH' ? $artist->{mbid} : undef;
        my $title  = $r->{name} // '';
        my $rgMbid = $r->{mbid} // '';
        next unless length $aname || length $title;
        push @out, {
            artist_credit_name         => $aname,
            # MusicBrainz sort-name ("White, Jack"; "Panda Bear" stays as-is for a
            # stage name). MuSpy supplies it; the LB feed does not (warmed from MB).
            artist_sort_name           => $asort,
            release_name               => $title,
            release_group_mbid         => $rgMbid,
            release_group_primary_type => $r->{type} // '',
            release_date               => _padDate($r->{date} // ''),
            artist_mbids               => ($ambid ? [ $ambid ] : []),
            # coverArtUrl builds a release-GROUP art URL from this (MuSpy has no
            # release-level MBID / caa_id, so this is the only art signal we have).
            caa_release_group_mbid     => $rgMbid,
            _source                    => 'muspy',
        };
    }
    $log->info("Parsed " . scalar(@out) . " MuSpy releases");
    return \@out;
}

# Pad a possibly-partial MuSpy date ('2026' / '2026-07') to a full 'YYYY-MM-DD',
# so the plugin's date sort, week dividers and windowing (which substr/regex the
# string) behave. Missing month/day default to 01. A non-date returns ''.
sub _padDate {
    my $d = shift // '';
    return '' unless $d =~ /^(\d{4})(?:-(\d{1,2}))?(?:-(\d{1,2}))?/;
    # Default a missing OR zero-filled component to 01. MusicBrainz (and so MuSpy)
    # represents an unknown month/day as an omitted part ('2026', '2026-07') OR as
    # a zero part ('2026-00-00', '2026-07-00'); a plain `$2 || 1` leaves '00' as-is
    # (Perl treats the string '00' as true), yielding an invalid date that then
    # corrupts the week-divider/window date maths downstream. Coerce numerically
    # up front — this also copies the captures into lexicals before any downstream
    # match can clobber $1/$2/$3.
    my ($y, $mon, $day) = ($1, ($2 // 0) + 0, ($3 // 0) + 0);
    return sprintf('%04d-%02d-%02d', $y, $mon || 1, $day || 1);
}

# `_cacheFeed` USED TO LIVE HERE and is gone. It wrote a feed to a short-TTL
# working key plus a long-TTL `…fb:` twin, and its only three callers were the two
# release feeds and MuSpy — all of which are now stored. The follow feed and the
# playlist listing keep `…fb:` twins but always wrote them inline, never through
# this helper, so nothing was left pointing at it.
#
# (An earlier revision of this comment claimed the follow feed still called it.
# It does not — it has its own `$cache->set` pair a few hundred lines below.)

# ---------------------------------------------------------------------------
# In-process feed memo (0.9.138)
# ---------------------------------------------------------------------------
# Slim::Utils::Cache is SQLite-backed, so every "cache hit" on a feed is a disk
# read plus a full deserialise of a structure holding hundreds to thousands of
# releases. XMLBrowser re-walks the whole feed from the ROOT on every drill-in,
# every in-place refresh and every paging tap, and the root builds both sections
# — so a single tap deep in the tree was decoding the same feeds three or more
# times, and any in-place toggle (sort, Albums/Singles) did it twice over. On a
# Pi that is the sluggishness, not the network: the requests were already cached.
#
# So hold the LAST decoded copy per key for a few seconds. That is far shorter
# than any feed TTL and covers exactly one user interaction's worth of re-walks;
# it can't mask a Refresh (clearFeedCache drops the memo too) and it can't survive
# a settings change (the prefs are all in the key).
our %FEED_MEMO;                         # key => [ expiry, $releases ]  (package-scoped so tests can age it)
use constant FEED_MEMO_TTL => 5;

sub _memoGet {
    my ($key) = @_;
    my $e = $FEED_MEMO{$key} or return undef;
    if ($e->[0] < time()) { delete $FEED_MEMO{$key}; return undef }
    return $e->[1];
}

sub _memoSet {
    my ($key, $data) = @_;
    # Drop anything expired while we're here — the plugin only ever holds a
    # handful of keys, so this is cheaper than a timer and can't grow unbounded.
    my $now = time();
    delete @FEED_MEMO{ grep { $FEED_MEMO{$_}[0] < $now } keys %FEED_MEMO };
    $FEED_MEMO{$key} = [ $now + FEED_MEMO_TTL, $data ];
    return $data;
}

sub _memoDrop { delete $FEED_MEMO{ $_[0] } }

# The "Refresh (force update now)" row. $which is 'user' or 'all'.
#
# WHAT CHANGED, AND IT IS A REAL IMPROVEMENT RATHER THAN A PORT: this used to
# REMOVE the feed's cache key, so between the tap and the fetch coming back the
# feed did not exist — a slow ListenBrainz meant an empty list. It now marks the
# stored feed's coverage stale (`ok_at = 0`) and deletes NOTHING, so the user keeps
# seeing releases while the re-fetch runs behind them, and a failed refresh leaves
# them with what they had rather than with nothing.
#
# THE MEMO STILL HAS TO BE DROPPED, BOTH LAYERS. getMuSpyReleases and both feeds
# check %FEED_MEMO BEFORE the store, and the rebuild this refresh triggers lands
# well inside FEED_MEMO_TTL — so invalidating only the store leaves Refresh serving
# the very copy it was meant to replace (the 0.9.141 review bug, and it survives
# the move to the store unchanged).
sub clearFeedCache {
    my ($class, $which) = @_;
    # The feeds are always fetched with sort=release_date now (client-side view
    # sorts replaced the global sort pref in 0.9.97), so the memo key is fixed.
    my $sort = 'release_date';

    my $invalidate = sub {
        eval { Plugins::ListenBrainzFreshReleases::DB::feedInvalidate($_[0]); 1 }
            or $log->warn("feed invalidate raised: $@");
    };

    # _feedMemoKey + sectionWeeks, never a second copy of either: the key dropped
    # here MUST be the key the fetcher minted (see _feedMemoKey).
    if ($which eq 'all') {
        _memoDrop(_feedMemoKey('all', $sort, sectionWeeks('all')));
        $invalidate->('all');
    }
    else {
        my $username = $prefs->get('username') // '';
        _memoDrop(_feedMemoKey('foryou', $sort, sectionWeeks('foryou')));
        $invalidate->('user:' . $username) if length $username;

        # The For You feed also folds in MuSpy releases, so a forced refresh must
        # invalidate MuSpy too — otherwise Refresh re-fetches LB fresh but keeps
        # serving a MuSpy copy up to FEED_TTL (24h) old, hiding a just-added artist
        # or newly-announced release.
        my $userid = $prefs->get('muspy_userid') // '';
        $userid =~ s/^\s+|\s+$//g;
        if (length $userid) {
            _memoDrop('lbf:muspy:' . $userid);
            $invalidate->('muspy:' . $userid);
        }
    }
    $log->info("marked the $which feed stale (forced refresh) — no rows deleted");
}

# On a fetch failure, serve the last successfully cached copy if we have one (an
# outage then degrades to slightly-stale data instead of an empty / error menu).
# Only when there's nothing cached do we surface the error.
#
# THE RELEASE FEEDS NO LONGER COME THROUGH HERE — _fetchReleaseFeed's own failure
# branch serves stored rows and reports their age. This remains for the follow
# feed and the playlist listing, which still keep `…fb:` twins.
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
# GET /1/metadata/recording/?recording_mbids=<csv>&inc=artist release — bulk-
# resolve a list of recording MBIDs in one (or a few) call(s), avoiding
# MusicBrainz's 1 req/sec throttle. Calls $onDone with a hashref keyed by
# lower-case recording MBID: { mbid => { artist, title, release_group_mbid,
# album } }. inc=release adds the recording's canonical release block, whose
# `release_group_mbid` maps the track back to its ALBUM (collapsing deluxe/
# remaster editions) — the join the People-You-Follow trending list needs to
# group per-track listens into per-album trends. Chunks to METADATA_CHUNK MBIDs
# per request and merges. (Older callers reading only { artist, title } are
# unaffected — the extra keys are additive.)
# ---------------------------------------------------------------------------
use constant METADATA_CHUNK => 50;

# recording→{artist,title,release_group_mbid,album,year} is IMMUTABLE, so each
# resolved mbid is cached long-term (per-mbid). Repeat builds (and the daily warm)
# then only HTTP the mbids they haven't seen — a big cut to the trending cold cost,
# which otherwise re-mapped every distinct recording across all followers each time.
#
# THIS IS AN AGE, NOT A TTL, AND THAT IS THE WHOLE FIX.
#
# It was `RECMETA_TTL => 90 * 86400`, handed to Slim::Utils::Cache, whose
# _canonicalize_expiration_time reads ANY value above 2,592,000 as an ABSOLUTE
# Unix epoch rather than a duration:
#
#     if ( $expiry <= 2592000 && $expiry > -1 ) { $expiry += time(); }
#
# So every entry written here was stored expiring 1 APRIL 1970 and every read
# returned undef. `set` returned 1, nothing died, nothing warned. And because the
# long branch was the DATED one, the entries worth keeping were precisely the ones
# discarded — which is why the ListenBrainz genre tiers had never once served a
# dated release and the background top-up re-fetched the same releases on every
# visit. Verified live on three rows (NCT 127, Davenki Pi Wiart, Jonathan Bree).
#
# 0.9.164 corrected the number to 30 days. A later build made the mistake
# INEXPRESSIBLE instead: the value is now compared against a stored `fetched_at`
# in Perl, so no duration is handed to anyone and no magnitude re-interprets
# itself. It then went back to 90 days because it safely could — and that is the
# error the age policy now closes. Safe to express is not the same as right.
#
# ONE CONSTANT, TWO CONSUMERS — and the second one is where the visible damage
# was. It applies to `getRecordingMetadata` AND to `getReleaseGroupMetadata`,
# which is the call the genre tiers ride on.
# 30 days, not 90 — the age policy in docs/feed-findings-2026-08-14.md §2 applies
# here too. Nothing forces it (this is a stored-fetched_at comparison, so the
# 2,592,000 ceiling above cannot bite), but a value that would be poison if it ever
# moved back to a cache TTL should not be sitting in the file waiting for someone
# to move it. A yearless row is refetched regardless — see the note below.
use constant RECMETA_AGE => 30 * 86400;
# A metadata entry WITHOUT a year is not immutable — LB backfills
# first_release_date, and MB release-group dates land after release — so a
# yearless row is a SOFT hit: kept as a fallback, but refetched. That is 0.9.113's
# rule, preserved exactly; it is expressed by the read side simply not calling
# such a row fresh, rather than by a second, shorter duration.

# Is a facts row still fresh? The ONE place staleness is decided for the metadata
# tables, so the dated/dateless rule cannot drift between the two callers.
sub _factFresh {
    my ($row, $age) = @_;
    return 0 unless ref $row eq 'HASH';
    return (time() - ($row->{fetched_at} || 0)) < $age;
}

# THE GENERAL FORM: is ONE answer on a row still good enough to serve?
#
# `$nCol` is the mirrored length (-1 never asked, 0 asked and the answer was
# none), `$atCol` is that answer's OWN timestamp. Reading both is what keeps a
# tier's freshness independent of everything else on the row — a sort-name write
# must not make the genres beside it look freshly fetched, which is what a shared
# `fetched_at` did until schema 3.
#
# Nothing is immutable: a populated answer is held for $foundAge, an empty one for
# a much shorter $emptyAge, so "asked, and there was nothing" is remembered without
# becoming permanent. Both ages come from DB.pm so this cannot drift from what
# `cachestats` reports as stale.
sub _answerFresh {
    my ($row, $nCol, $atCol, $foundAge, $emptyAge) = @_;
    return 0 unless ref $row eq 'HASH';
    my $n = $row->{$nCol};
    return 0 unless defined $n && $n >= 0;          # never asked
    my $age = time() - ($row->{$atCol} || 0);
    return $age < ($n > 0 ? $foundAge : $emptyAge) ? 1 : 0;
}

sub _genresFresh {
    my ($row) = @_;
    return _answerFresh($row, 'n_genres', 'genres_at',
                        Plugins::ListenBrainzFreshReleases::DB->RG_GENRE_FOUND_AGE,
                        Plugins::ListenBrainzFreshReleases::DB->RG_GENRE_EMPTY_AGE);
}

sub getRecordingMetadata {
    my ($class, $mbids, $onDone) = @_;
    $onDone ||= sub {};
    # Best-effort enrichment: onDone-ALWAYS. A failed/partial fetch resolves onDone with
    # whatever was gathered (cached soft-hit fallbacks included) rather than an error path —
    # a metadata gap must degrade to "no year yet", never stall the async chain. (No onError.)

    my @all = grep { $_ } @{ $mbids || [] };
    unless (@all) { $onDone->({}); return; }

    # Serve cached mbids from the file cache; only fetch the misses. A cached
    # entry with NO year is only a SOFT hit: "no first_release_date yet" is NOT
    # immutable — ListenBrainz backfills dates over time (especially for freshly
    # mapped recordings), and pinning a yearless entry for the full 90d TTL was
    # exactly how tracks stayed dateless through every fallback (the Stephen
    # Rennicks case: LB had the year, our cache had a poisoned '' from an earlier
    # lag window). Keep the stale entry as a fallback, but refetch the mbid; the
    # write side caches yearless results SHORT so they can't re-pin.
    my %meta;
    my @need;
    my $have = Plugins::ListenBrainzFreshReleases::DB::recGet([ map { lc } @all ]);
    for my $m (@all) {
        my $c = $have->{ lc $m };
        if (ref $c eq 'HASH' && length($c->{year} // '') && _factFresh($c, RECMETA_AGE)) {
            $meta{ lc $m } = $c;
        }
        else {
            $meta{ lc $m } = $c if ref $c eq 'HASH';   # fallback if the refetch fails
            push @need, $m;
        }
    }
    unless (@need) { $onDone->(\%meta); return; }

    my @chunks;
    push @chunks, [ splice(@need, 0, METADATA_CHUNK) ] while @need;

    my $next;
    $next = sub {
        my $chunk = shift @chunks;
        unless ($chunk) { $onDone->(\%meta); return; }

        my $csv = join(',', @$chunk);
        (my $safe = $csv) =~ s/([^A-Za-z0-9\-_.~,])/sprintf("%%%02X",ord($1))/ge;
        # inc=artist release: artist credit + the canonical release (for its
        # release_group_mbid). Space is %20-encoded in the query string.
        my $url = BASE_URL . '/1/metadata/recording/?inc=artist%20release&recording_mbids=' . $safe;

        my $http = Slim::Networking::SimpleAsyncHTTP->new(
            sub {
                my $resp = shift;
                my $data = eval { from_json($resp->content) };
                if ($@) {
                    $log->error("Recording metadata JSON parse error: $@");
                } else {
                    my %fresh;
                    _mergeRecordingMetadata(\%fresh, $data);
                    for my $mk (keys %fresh) {
                        $meta{$mk} = $fresh{$mk};
                        # NO TTL — a row plus `fetched_at`, and the age policy on
                        # the read side above decides. The dated/dateless soft-hit
                        # rule (0.9.113) is preserved exactly; what is gone is any
                        # chance of a duration meaning 1970.
                        Plugins::ListenBrainzFreshReleases::DB::recPut($mk, %{ $fresh{$mk} });
                    }
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
# %$meta as { mbid => { artist, title, release_group_mbid, album } }. Tolerates
# the two artist shapes: a flat artist.name credit string, or an
# artist.artists[] credit array. The release block (from inc=release) yields the
# recording's album (release_group_mbid + name); absent on a recording with no
# known release, in which case those keys are empty strings.
sub _mergeRecordingMetadata {
    my ($meta, $data) = @_;
    return unless ref $data eq 'HASH';

    while (my ($mbid, $entry) = each %$data) {
        next unless ref $entry eq 'HASH';
        my $rec    = ref $entry->{recording} eq 'HASH' ? $entry->{recording} : {};
        my $artObj = ref $entry->{artist}    eq 'HASH' ? $entry->{artist}    : {};
        my $rel    = ref $entry->{release}   eq 'HASH' ? $entry->{release}   : {};

        my $title = $rec->{name} // '';
        my $artist = $artObj->{name} // '';
        if (!length $artist && ref $artObj->{artists} eq 'ARRAY') {
            $artist = join('', map {
                ($_->{artist_credit_name} // $_->{name} // '') . ($_->{join_phrase} // '')
            } @{ $artObj->{artists} });
        }

        # Year source, in the order the data is actually reliable (verified live):
        # the `release` object is very often EMPTY in this payload (so $rel->{year}
        # and $rel->{release_group_mbid} are blank), but the RECORDING always carries
        # `first_release_date` — the same authoritative date NRFY reads from the feed's
        # release_date. Read that first; fall back to the release year if present. This
        # is what fixes fresh tracks showing no year (their release-group first-release-
        # date lags/None, so the RG-date fallback alone couldn't fill them).
        my $recDate = $rec->{first_release_date} // '';
        my $year    = ($rel->{year} && $rel->{year} =~ /^(\d{4})/) ? $1
                    : ($recDate =~ /^(\d{4})/)                     ? $1
                    :                                                '';
        $meta->{ lc $mbid } = {
            artist             => $artist,
            title              => $title,
            release_group_mbid => lc($rel->{release_group_mbid} // ''),
            album              => $rel->{name} // '',
            year               => $year,
        } if length $title;
    }
}

# Bulk-resolve release-group MBIDs to { year, name } via
# GET /1/metadata/release_group/?release_group_mbids=<csv>&inc=release_group tag
# — the album's first-release date (whose year the Trending Albums rows show, like
# the New Releases rows) AND its genres. Same chunked/merge shape as
# getRecordingMetadata; a failed chunk is logged and skipped.
# $onDone gets { rg_mbid => { year, date, type, name, genres, agenres } }.
#
# GENRES. `inc=tag` adds a `tag` block with TWO lists — `release_group` (this
# album's own tags) and `artist` (the credited artist's tags). Each tag carries a
# `genre_mbid` IFF it is a real MusicBrainz genre rather than a freeform tag,
# which is the quality gate: we keep only those, so "seen live"/"favourites" style
# noise never enters. Measured over 400 releases of a live All Releases feed
# (2026-07-26): release-group genres cover **5%**, artist genres **47%**, union
# **49%** — which is why the artist list is carried separately rather than merged
# here. The caller decides (see Browse::_genresFor: prefer the album's own, fall
# back to the artist's, because an artist genre is only a proxy — a jazz artist's
# ambient side project inherits "jazz").
#
# THIS IS THE WHOLE COST OF THE GENRE FEATURE, and it is why the feature could be
# unparked. `tag` rides the request the plugin ALREADY makes for years/dates, so
# genres for a feed cost no extra round trips. Re-benchmarked 2026-08-12 against
# the live 556-release All Releases week: **2.8s for the entire feed** (12 batches
# of 50, worst batch 0.52s, no 502s). The 2026-07-29 measurement that parked this
# work was 0.25s–24s per batch and **125s** for one feed — ListenBrainz fixed the
# endpoint upstream. Coverage reproduced exactly: 5% release-group, 47% artist.

# ---------------------------------------------------------------------------
# ListenBrainz RATE LIMITING — shared deadline + retry with backoff.
#
# MEASURED against the live API 2026-08-13: the metadata endpoint allows 30
# requests per ~10-second window, and every response states the budget in
# X-RateLimit-Remaining / X-RateLimit-Reset-In. Ten serial batches took it from 29
# remaining to 20.
#
# THAT BUDGET IS SHARED WITH EVERYTHING ELSE THE PLUGIN DOES — the feed fetches,
# the playlist fetches, the follow/stats fan-out. Before this, a 429 was logged
# ("RG metadata chunk failed: 429 TOO MANY REQUESTS") and the chunk was simply
# abandoned: no retry, no backoff, and the genre fill silently lost those
# releases. Observed five times in one boot window, because the genre warm fires
# GENRE_CONCURRENCY chunks into the same bucket the feed is already using.
#
# It matters far more now than it did: the daily warm covers the WHOLE feed (66
# batches, not 12), so an unpaced burst is guaranteed to exhaust the window rather
# than merely risking it.
#
# THE DEADLINE IS SHARED STATE, NOT PER-CALLER, and that is the point: concurrent
# callers must back off TOGETHER rather than each discovering the limit for
# itself. A caller that finds a deadline in force waits it out instead of adding
# to the queue that caused it.
# ---------------------------------------------------------------------------
use constant LB_RETRY_MAX     => 3;    # attempts per chunk, then give up as before
use constant LB_BACKOFF_MIN   => 2;    # floor when the server states no reset time
use constant LB_BACKOFF_CAP   => 30;   # never sit on a chunk longer than this
my $_lbBusyUntil = 0;

# Seconds to wait before the next ListenBrainz request may go out, 0 when clear.
sub _lbWait {
    my $now = Time::HiRes::time();
    return $_lbBusyUntil > $now ? ($_lbBusyUntil - $now) : 0;
}

# Record a rate-limit deadline from a 429. `X-RateLimit-Reset-In` is seconds until
# the window rolls; when it is missing or nonsense, fall back to the floor rather
# than retrying immediately into the same wall.
sub _lbNoteLimit {
    my ($resp, $attempt) = @_;
    my $in;
    if (ref $resp && $resp->can('headers')) {
        $in = eval { $resp->headers->header('X-RateLimit-Reset-In') };
    }
    $in = LB_BACKOFF_MIN unless defined $in && $in =~ /^\d+(?:\.\d+)?$/ && $in > 0;
    # Grow with the attempt, so a limit that outlasts one window is not hammered.
    $in *= $attempt if $attempt && $attempt > 1;
    $in = LB_BACKOFF_CAP if $in > LB_BACKOFF_CAP;
    my $until = Time::HiRes::time() + $in;
    $_lbBusyUntil = $until if $until > $_lbBusyUntil;
    return $in;
}

# True when an HTTP failure is a rate limit rather than a real error. The error
# string is used as well as the code because SimpleAsyncHTTP does not always
# populate ->code on a failure — the same reason Diag::_httpCode digs into it.
sub _lbIsRateLimited {
    my ($resp) = @_;
    return 0 unless ref $resp;
    my $code = eval { $resp->code } // '';
    return 1 if $code && $code == 429;
    my $err = eval { $resp->error } // '';
    return $err =~ /\b429\b|too many requests/i ? 1 : 0;
}

# Cache-only read of ONE release group's metadata. The bulk fetcher below has no
# cache-only mode, and the render path must never fetch — so a peek reads the
# same entries the bulk path writes, and simply has nothing to say for a release
# group nobody has fetched yet. Returns undef on a miss (NOT an empty hash, which
# would look like "fetched, no genres").
# NO SINGLE-KEY VARIANT, deliberately. There was one, and its only caller was the
# per-release loop below — which is the shape this whole rework exists to stop.
# Anyone who wants one release group can ask for a list of one.
#
# BULK peek — what the render path must use. `_withGenresLB`'s peek branch asks
# for a whole page (and, on the genre picker's whole-feed pass, ~2,900 release
# groups), and a read per release group there is the same synchronous-work-on-the-
# render-path hazard 0.9.130 exists for and that bench_walk.pl caught again in
# 0.9.165. Returns only the release groups actually known.
sub peekReleaseGroupMetadataBulk {
    my ($class, $mbids) = @_;
    my %want;
    for my $m (@{ $mbids || [] }) { next unless defined $m && length $m; $want{ lc $m } = 1 }
    return {} unless %want;
    return Plugins::ListenBrainzFreshReleases::DB::rgGet([ keys %want ]);
}

sub getReleaseGroupMetadata {
    my ($class, $mbids, $onDone) = @_;
    $onDone ||= sub {};
    # Best-effort enrichment: onDone-ALWAYS (see getRecordingMetadata). No onError.

    my @all = grep { $_ } @{ $mbids || [] };
    unless (@all) { $onDone->({}); return; }

    # Served from the file cache; only the misses are fetched. Dated entries are
    # immutable; a DATELESS entry is only a SOFT hit (MB release-group dates land
    # after release — same poisoned-cache class as the recording metadata): keep
    # it as a fallback but refetch, and the write side caches it short.
    #
    # THE GENRES ARE A SEPARATE ANSWER FROM THE DATE, and are judged separately.
    # This request carries `inc=release_group tag`, so one response answers TWO
    # questions with very different lifetimes, and freshness used to be judged on
    # the date alone. `wipeGenres` clears the genre columns and deliberately leaves
    # `fetched_at`/`year` (a genre parse change must not re-inflict a date refetch
    # across the whole feed) — so after a wipe every row still looked fresh and its
    # genres could not be re-asked for RECMETA_AGE: NINETY DAYS. That is precisely
    # what 0.9.166 did to the live store — 1033 of 1034 release groups holding no
    # genre, with no traffic attempting to repair it.
    #
    # `genres_at` is stamped only when the genres are actually written, and
    # `_genresFresh` gives an EMPTY answer a much shorter life than a populated one,
    # because MusicBrainz tagging routinely lands weeks after a release. So a
    # tagless release comes back round on its own instead of being locked out, and
    # because each row carries its own stamp the re-asking is spread over time
    # rather than arriving as one stampede.
    my %meta;
    my @need;
    my $have = Plugins::ListenBrainzFreshReleases::DB::rgGet([ map { lc } @all ]);
    for my $m (@all) {
        my $c = $have->{ lc $m };
        if (ref $c eq 'HASH' && length($c->{year} // '') && _factFresh($c, RECMETA_AGE)
            && _genresFresh($c)) {
            $meta{ lc $m } = $c;
        }
        else {
            $meta{ lc $m } = $c if ref $c eq 'HASH';   # fallback if the refetch fails
            push @need, $m;
        }
    }
    unless (@need) { $onDone->(\%meta); return; }

    my @chunks;
    push @chunks, [ splice(@need, 0, METADATA_CHUNK) ] while @need;

    # $self is passed in rather than captured: `my $s; $s = sub { … $s … }` is a
    # reference cycle Perl never collects (the leak fixed in 0.9.95). The chunk is
    # left AT THE HEAD of @chunks until it has actually been dealt with, so a
    # rate-limited attempt can retry the same one.
    my $next = sub {
        my ($self, $attempt) = @_;
        $attempt ||= 1;

        my $chunk = $chunks[0];
        unless ($chunk) { $onDone->(\%meta); return; }

        # BACK OFF TOGETHER. If another caller has already been rate-limited, wait
        # out the shared deadline rather than joining the queue that caused it.
        if ((my $wait = _lbWait()) > 0) {
            Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + $wait,
                                          sub { $self->($self, $attempt) });
            return;
        }

        my $csv = join(',', @$chunk);
        (my $safe = $csv) =~ s/([^A-Za-z0-9\-_.~,])/sprintf("%%%02X",ord($1))/ge;
        my $url = BASE_URL . '/1/metadata/release_group/?inc=release_group%20tag&release_group_mbids=' . $safe;

        my $http = Slim::Networking::SimpleAsyncHTTP->new(
            sub {
                my $resp = shift;
                shift @chunks;                     # this one is dealt with
                my $data = eval { from_json($resp->content) };
                if ($@) { $log->error("RG metadata JSON parse error: $@"); }
                else {
                    my %fresh;
                    _mergeReleaseGroupMetadata(\%fresh, $data);
                    for my $mk (keys %fresh) {
                        $meta{$mk} = $fresh{$mk};
                        # NO TTL — see getRecordingMetadata. THIS is the write that
                        # the 90-day constant destroyed: RECMETA_TTL was applied
                        # here as well as to the recording cache, so every DATED
                        # release group — the ones worth keeping — was stored
                        # expiring in 1970 and the genre tiers never served one.
                        Plugins::ListenBrainzFreshReleases::DB::rgPut($mk, %{ $fresh{$mk} });
                    }
                }
                $self->($self, 1);
            },
            sub {
                my $resp = shift;

                # A 429 IS NOT A FAILED CHUNK — it is a chunk that has not been
                # tried yet, and treating the two alike is what made the genre fill
                # silently lose every release after the window ran out. Retried
                # rather than dropped; the chunk is still at the head of the queue.
                if (_lbIsRateLimited($resp) && $attempt < LB_RETRY_MAX) {
                    my $in = _lbNoteLimit($resp, $attempt);
                    $log->info(sprintf('RG metadata rate-limited — backing off %.1fs (attempt %d)',
                                       $in, $attempt)) if $log->is_info;
                    Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + $in,
                                                  sub { $self->($self, $attempt + 1) });
                    return;
                }

                shift @chunks;                     # give up on this one, as before
                $log->warn("RG metadata chunk failed: " . ($resp->error // '?'));
                $self->($self, 1);
            },
            { timeout => 15 }
        );
        $http->get($url, 'Accept' => 'application/json', 'User-Agent' => USER_AGENT);
    };
    $next->($next, 1);
}

sub _mergeReleaseGroupMetadata {
    my ($meta, $data) = @_;
    return unless ref $data eq 'HASH';
    while (my ($mbid, $entry) = each %$data) {
        next unless ref $entry eq 'HASH';
        my $rg   = ref $entry->{release_group} eq 'HASH' ? $entry->{release_group} : {};
        my $date = $rg->{date} // '';
        my $tag  = ref $entry->{tag} eq 'HASH' ? $entry->{tag} : {};
        $meta->{ lc $mbid } = {
            year    => ($date =~ /^(\d{4})/) ? $1 : '',
            date    => $date,                    # full first-release date (for release_date)
            type    => ($rg->{type} // ''),      # primary type (Album/EP/…) — for the type filter
            name    => ($rg->{name} // ''),
            genres  => _genreTags($tag->{release_group}),   # this album's own genres
            agenres => _genreTags($tag->{artist}),          # the credited artist's genres
        };
    }
}

# Pull the GENRE tags out of one of the `tag` block's lists, strongest first.
# A tag is a genre only when it carries a `genre_mbid` (LB marks the MusicBrainz
# curated-genre vocabulary that way) — everything else is a freeform user tag
# ("seen live", country names, moods) and is dropped.
#
# Ordered by `count` DESC only, and deliberately NOT tie-broken on name. Only the
# first two or three are ever displayed, and in real data most tags tie at count 1
# — so an alphabetical tie-break silently reduces to "show the alphabetically
# first genres", which is actively misleading (a drum-and-bass artist whose tags
# all sit at 1 would be labelled "ambient, breakcore"). Perl's sort is a stable
# mergesort, so ties keep the order ListenBrainz returned them in, which tracks
# the artist's actual primary genre far better and is still deterministic for a
# given response.
sub _genreTags {
    my ($list) = @_;
    return [] unless ref $list eq 'ARRAY';
    my @g = grep { ref $_ eq 'HASH' && $_->{genre_mbid} && length($_->{tag} // '') } @$list;
    @g = sort { ($b->{count} // 0) <=> ($a->{count} // 0) } @g;
    my (@out, %seen);
    for my $t (@g) {
        my $n = lc $t->{tag};
        $n =~ s/^\s+//; $n =~ s/\s+$//;
        next if $n eq '' || $seen{$n}++;
        push @out, $n;
    }
    return \@out;
}

# ---------------------------------------------------------------------------
# THE shared collab-credit splitter. A joined artist credit ("Julianna Barwick
# & Mary Lattimore", "Panda Bear & Sonic Boom") defeats exact-artist searches on
# MusicBrainz AND service search recall — the fix is always the same ladder: try
# the FULL credit first (some collabs are entered as one unique artist), then
# each collaborator. Returns that ordered, deduped list. Separators: '&', '+',
# ',', ';' (metadata's usual multi-artist separator), x/vs/feat/ft/featuring/
# with as words — deliberately NOT bare "and", which would split real band names
# ("Belle and Sebastian", "Iron and Wine"). One splitter — Browse's Bandcamp
# search (_bandcampArtists, the original 0.9.56 fix) and getReleaseGroupByName
# both delegate here; don't grow private copies.
# ---------------------------------------------------------------------------
sub splitArtistCredits {
    my ($artist) = @_;
    $artist //= '';
    my @parts = ($artist,
        split m{\s*(?:&|\+|,|;|\bfeat\b\.?|\bft\b\.?|\bfeaturing\b|\bwith\b|\bx\b|\bvs\b\.?)\s*}i, $artist);
    my (%seen, @out);
    for my $a (@parts) {
        $a =~ s/^\s+|\s+$//g;
        next unless length $a;
        next if $seen{ lc $a }++;
        push @out, $a;
    }
    return @out;
}

# ---------------------------------------------------------------------------
# HOSTED TIER for getReleaseGroupByName: one `/discography` call per ARTIST,
# folded to a title -> answer map and cached, instead of one MusicBrainz search
# per ALBUM.
#
# WHY THIS EXISTS AT ALL. Measured on the live server 2026-08-22: a cold People
# You Follow open spent **22,880ms in 12 serial MusicBrainz searches** — because
# `mb_base_url` was unset, so they went to public musicbrainz.org at its ~1 req/s
# throttle, and one of them came back 503. The hosted route answered the same
# questions in 195-358ms cold / ~80ms warm.
#
# AND THE DECIDING ARGUMENT IS NOT THIS MACHINE. Pointing mb_base_url at a local
# mirror fixes the latency for anyone who HAS a mirror. LBF ships to people who do
# not, and their default path is the public API at 1 req/s — a ~23s stall inside a
# background warm, every time. Same reasoning as getArtistMbidByName's hosted tier.
#
# THE IDS ARE INTERCHANGEABLE, which is the part that makes this safe.
# `/discography` returns release-GROUP mbids, verified identical to MusicBrainz's
# own answers for the same albums (The Iron Roses "Molotov Nights" ->
# 87c8435b-e948-483a-9b88-c5e81b06d7c1, L'Rain "L'Rain" ->
# d1ce5cbf-bc7d-4fdd-aba5-6a59c4bf9d82, both ways). That matters because the
# release_group_mbid this fills is the IDENTITY everything downstream keys on: the
# dedupe key when one album arrives from two followers, the CAA
# `release-group/<id>` art URL, the LB genre lookups and the detail page.
#
# DO NOT "SIMPLIFY" THIS TO `/album/<title>/<artist>`. That route returns a
# RELEASE mbid, not a release-group one, and it would poison every consumer above
# while looking like it worked. The limitation is per-ROUTE, not API-wide.
#
# NOT `?type=Album` EITHER: measured 2.4s (a separate cache key, so always cold)
# to trim 580 entries to 385, because Live and Compilation are secondary types and
# still carry primary type Album. The bare call is the fast one.
#
# THIS BUYS SPEED, NOT COVERAGE. The four names public MB could not resolve in
# that same window, the hosted API does not resolve either.
# ---------------------------------------------------------------------------

# Pick one entry from the fold-equal candidates for a title. Two or more is
# normal — a remaster, a reissue and the original are separate release GROUPS
# under the identical title.
#
# ORIGINAL STUDIO RELEASE WINS, because the field this feeds is a YEAR shown
# beside an album a follower played, and "1997" is the answer to "what is this
# album" in a way that a 2017 remaster's date is not. So: entries with NO
# secondary types (Live / Compilation / Remix / Soundtrack are all secondary)
# beat entries with them, then the earliest date wins, and a dated entry always
# beats an undated one — an absent date must never sort as "earliest".
sub _hostedDiscoPick {
    my ($cands) = @_;
    return undef unless ref $cands eq 'ARRAY' && @$cands;
    my @sorted = sort {
           ($a->{sec} <=> $b->{sec})
        || (($a->{date} ne '' ? 0 : 1) <=> ($b->{date} ne '' ? 0 : 1))
        || ($a->{date} cmp $b->{date})
    } @$cands;
    return $sorted[0];
}

# Fetch (or read from cache) the folded title -> answer map for ONE artist.
# $onDone gets the map on success, or undef on ANY miss — unknown artist, bad
# shape, rate-limited past the budget, service down. undef means "fall back",
# never "this album does not exist".
sub _hostedDiscoMap {
    my ($artist, $artistMbid, $onDone) = @_;

    my $ck = Plugins::ListenBrainzFreshReleases::DB::kver('lbf:hdisco:') . lc($artist)
           . (length($artistMbid // '') ? '|' . lc($artistMbid) : '');
    utf8::encode($ck) if utf8::is_utf8($ck);

    if (defined(my $c = $cache->get($ck))) {
        $onDone->(ref $c eq 'HASH' ? $c : undef);   # '' is the cached "no discography"
        return;
    }

    # PASS THE ARTIST MBID WHEN WE HAVE ONE. Without it the service resolves the
    # name by POPULARITY, so a name collision silently returns a different
    # artist's catalogue — and unlike getArtistMbidByName there is no echoed name
    # to gate on here, only titles. The candidates in this path already carry
    # artist_mbid, so the guess is avoidable and therefore should be avoided.
    my $path = 'artist/' . _hostedSeg($artist) . '/discography'
             . (length($artistMbid // '') ? '?mbid=' . _hostedSeg($artistMbid) : '');

    _hostedGet($path, sub {
        my ($data) = @_;
        my $rows = $data->{discography};
        unless (ref $rows eq 'ARRAY' && @$rows) {
            # An unknown artist answers 200 with {} rather than 404. Cached as a
            # short miss so a whole feed of unmapped rows by the same unknown
            # artist does not re-ask per album — but at the EMPTY ttl, because an
            # artist absent from a weekly snapshot may be in the next one.
            eval { $cache->set($ck, '', MB_EMPTY_TTL); 1 }
                or $log->warn("hosted-discography cache set failed: $@");
            $onDone->(undef);
            return;
        }

        my %map;
        my $n = 0;
        for my $r (@$rows) {
            next unless ref $r eq 'HASH';
            last if ++$n > HOSTED_DISCO_MAX;
            my $mbid  = lc($r->{mbid} // '');
            my $title = $r->{title} // '';
            next unless length $mbid && length $title;

            my $key = _foldKey($title) or next;
            my $date = $r->{release_date} // '';
            push @{ $map{$key} }, {
                mbid => $mbid,
                date => $date,
                year => ($date =~ /^(\d{4})/) ? $1 : '',
                type => ($r->{primary_type} // ''),
                # Secondary types are what separate a live album or a compilation
                # from the studio release that shares its title. Stored as a COUNT,
                # not the list: the only question asked of it is "is this the plain
                # one", and a count answers that in a fraction of the bytes.
                sec  => (ref $r->{secondary_types} eq 'ARRAY' ? scalar @{ $r->{secondary_types} } : 0),
            };
        }

        # Collapse to one answer per title HERE, not at read time: the map is read
        # once per album but written once per artist, so the picking belongs on the
        # write side, and it keeps the cached value small.
        my %flat = map { $_ => _hostedDiscoPick($map{$_}) } keys %map;

        eval { $cache->set($ck, \%flat, HOSTED_DISCO_TTL); 1 }
            or $log->warn("hosted-discography cache set failed: $@");
        $log->info("Hosted API: discography for '$artist' — " . scalar(keys %flat)
                 . ' distinct title(s) from ' . scalar(@$rows) . ' entr(y/ies)'
                 . (length($artistMbid // '') ? ' [by mbid]' : ''));
        $onDone->(\%flat);
    }, sub { $onDone->(undef) });
}

# The fold used to key the map and to look titles up in it. Delegates to the
# shared matcher's normaliser through ->can at runtime — the same indirection and
# the same reason as _foldEq: API.pm must gain no compile-time dependency on
# Browse.pm, which already depends on API.
#
# THE MATCHING STAYS AT THIS CALL SITE. It reuses `_norm` but adds nothing to the
# shared matcher, so the four-repo sync rule is not triggered by this change.
sub _foldKey {
    my ($s) = @_;
    return '' unless defined $s && length $s;
    my $norm = Plugins::ListenBrainzFreshReleases::Browse->can('_norm');
    my $n    = $norm ? $norm->($s) : lc $s;
    $n =~ s/^\s+//; $n =~ s/\s+$//;
    return $n;
}

# ---------------------------------------------------------------------------
# Resolve an artist + album NAME to its MusicBrainz release-group. Needed for
# the People You Follow trending lists: ListenBrainz listen-stats rows are only
# as good as each follower's LISTEN MAPPING, and unmapped listens come back with
# release_group_mbid/caa_id = null (verified live — the same album can appear
# BOTH mapped and unmapped across different followers). NRFY never sees this
# because the fresh-releases feed is MusicBrainz-derived. Without the MBID a row
# has no cover, no date and no type — this fills the gap the same way the DSTM
# radio resolves artist names (fielded ws/2 search, mirror-aware base, score>=90
# gate, mirror-0-results→public retry, per-name cache). $onDone gets
# { mbid, date, year, type } or undef. One lookup per artist|title (cached
# 30d found / 1d miss, so a brand-new album that lands in MB soon retries daily).
# ---------------------------------------------------------------------------
sub getReleaseGroupByName {
    my ($class, $artist, $title, $onDone, %opt) = @_;   # %opt: artist_mbid
    $onDone ||= sub {};

    for ($artist, $title) { $_ = defined $_ ? $_ : ''; s/^\s+|\s+$//g; }
    unless (length $artist && length $title) { $onDone->(undef); return; }

    # THE ARTIST MBID IS PART OF THE IDENTITY, not just of the hosted request.
    # Keyed on `artist|title` alone, two DIFFERENT artists sharing a name and an
    # album title collide, and the first one cached wins for the other — which is
    # precisely the confusion `artist_mbid` is passed in to prevent, defeated one
    # layer below where it was fixed. Appended only when supplied, so a call
    # without one still reads and writes the keys it always did.
    my $cacheKey = Plugins::ListenBrainzFreshReleases::DB::kver("lbf:rgbyname:")
                 . lc($artist) . '|' . lc($title)
                 . (length($opt{artist_mbid} // '') ? '|' . lc($opt{artist_mbid}) : '');
    utf8::encode($cacheKey) if utf8::is_utf8($cacheKey);
    if (defined(my $c = $cache->get($cacheKey))) {
        $onDone->(ref $c eq 'HASH' ? $c : undef);   # '' is the cached "not found" sentinel
        return;
    }

    # Artist terms to try, in order. MB's fielded search misses a JOINED collab
    # credit — verified live: releasegroup:"Tragic Magic" AND artist:"Julianna
    # Barwick & Mary Lattimore" = 0 results, either collaborator alone = score
    # 100 — so on a full-credit miss each collaborator is retried individually
    # (same separators as the manual Bandcamp collab split). Capped at 3 terms.
    # (Full credit is tried FIRST because some collabs are entered in MB as one
    # unique artist; the split terms then cover the joined-credit case — the
    # same class as the NRFY "Panda Bear & Sonic Boom" Bandcamp gap (0.9.56),
    # now served by ONE shared splitter.)
    my @artistTerms = grep { length($_) >= 2 || $_ eq $artist } splitArtistCredits($artist);
    splice(@artistTerms, 3) if @artistTerms > 3;

    # Fielded exact-phrase query (embedded double quotes stripped — they'd break
    # the Lucene phrase). Same escaping as getArtistMbidByName's $mkQuery.
    my $mkQ = sub {
        my ($aTerm) = @_;
        (my $t = $title) =~ s/"//g;
        (my $a = $aTerm) =~ s/"//g;
        my $s = 'releasegroup:"' . $t . '" AND artist:"' . $a . '"';
        utf8::encode($s) if utf8::is_utf8($s);
        $s =~ s/([^A-Za-z0-9])/sprintf("%%%02X",ord($1))/ge;
        return 'release-group?query=' . $s . '&fmt=json&limit=1';
    };

    my $mirror = !_mbThrottled();

    # Self-passing sub (not a self-capturing closure) — same leak-avoidance as
    # getArtistMbidByName (0.9.95). $ti indexes @artistTerms.
    my $run = sub {
        my ($self, $base, $isFb, $ti) = @_;
        my $http = Slim::Networking::SimpleAsyncHTTP->new(
            sub {
                my $resp = shift;
                my $data = eval { from_json($resp->content) };
                my $rgs  = (!$@ && ref $data eq 'HASH' && ref $data->{'release-groups'} eq 'ARRAY')
                           ? $data->{'release-groups'} : undef;

                # Unbuilt-Solr mirror → one public retry (see getArtistMbidByName).
                if ($rgs && !@$rgs && $mirror && !$isFb) {
                    $log->info("RG '$artist - $title' => 0 results on mirror; retrying public API");
                    return $self->($self, MB_DEFAULT_BASE_URL, 1, $ti);
                }

                my $out;
                if ($rgs && @$rgs) {
                    my $rg = $rgs->[0];
                    if ($rg->{id} && ($rg->{score} // 0) >= 90) {
                        my $date = $rg->{'first-release-date'} // '';
                        $out = {
                            mbid => lc $rg->{id},
                            date => $date,
                            year => ($date =~ /^(\d{4})/) ? $1 : '',
                            type => ($rg->{'primary-type'} // ''),
                        };
                    }
                }

                # This term found nothing acceptable → try the next collaborator.
                if (!$out && $ti < $#artistTerms) {
                    return $self->($self, _mbBase(), 0, $ti + 1);
                }
                eval { $cache->set($cacheKey, ($out // ''), $out ? MB_FOUND_TTL : MB_EMPTY_TTL); 1 }
                    or $log->warn("rg-by-name cache set failed: $@");
                $log->info("RG '$artist - $title' => " . ($out ? $out->{mbid} : 'no match')
                    . ($ti ? " [term: $artistTerms[$ti]]" : '') . ($isFb ? ' [public fallback]' : ''));
                $onDone->($out);
            },
            sub {
                if ($mirror && !$isFb) {
                    $log->info("RG '$artist - $title' => mirror search error; retrying public API");
                    return $self->($self, MB_DEFAULT_BASE_URL, 1, $ti);
                }
                $log->warn("RG '$artist - $title' search failed: " . ($_[0] && $_[0]->can('error') ? ($_[0]->error // '?') : '?'));
                $onDone->(undef);   # never cache a network failure as a miss
            },
            { timeout => 12 }
        );
        $http->get($base . $mkQ->($artistTerms[$ti]), 'Accept' => 'application/json', 'User-Agent' => USER_AGENT);
    };

    # HOSTED FIRST, MusicBrainz behind it. The fallback is UNCONDITIONAL by
    # design, exactly as in getArtistMbidByName: any hosted outcome that is not a
    # confident hit — unknown artist, no fold-equal title, rate-limited past the
    # budget, bad JSON, service down — runs $run, which is the previous
    # implementation reached unchanged. An outage here degrades to today's
    # behaviour rather than breaking resolution.
    my $mbFallback = sub { $run->($run, _mbBase(), 0, 0) };

    _hostedDiscoMap($artist, $opt{artist_mbid}, sub {
        my ($map) = @_;
        return $mbFallback->() unless ref $map eq 'HASH';

        my $hit = $map->{ _foldKey($title) };
        unless (ref $hit eq 'HASH' && length($hit->{mbid} // '')) {
            $log->info("Hosted API: '$artist - $title' not in discography; falling back to MusicBrainz");
            return $mbFallback->();
        }

        # Cached in the SAME shape and under the SAME key the MusicBrainz path
        # writes, so every reader stays oblivious to which tier answered.
        my $out = { mbid => $hit->{mbid}, date => $hit->{date},
                    year => $hit->{year}, type => $hit->{type} };
        eval { $cache->set($cacheKey, $out, MB_FOUND_TTL); 1 }
            or $log->warn("rg-by-name cache set failed: $@");
        $log->info("RG '$artist - $title' => $out->{mbid} [hosted]");
        $onDone->($out);
    });
}

# ===========================================================================
# People You Follow — trending (top PLAYED tracks/albums of the users you
# follow). Three PUBLIC endpoints (no token required): the following list and
# the per-user listen-stats. Stats return 204 No Content when a user's stats
# aren't computed yet or their listens are private — treated as "no data", never
# an error, so one private/quiet follower can't sink the whole fan-out. Ranking
# and album-grouping happen in Browse::_buildTrending; these just fetch+normalise
# and cache per-user (LB recomputes stats ~daily). See tools/fetch_trending.py.
# ===========================================================================
use constant FOLLOWING_TTL => 12 * 3600;
use constant STATS_TTL     => 24 * 3600;   # LB recomputes user stats ~daily
use constant STATS_TIMEOUT => 15;

# GET /1/user/<user>/following → the users <user> follows, as a plain arrayref of
# username strings (bare strings on the live API). Public; token sent if present
# but not required. Cached FOLLOWING_TTL.
sub getFollowing {
    my ($class, %args) = @_;
    my $onDone  = $args{onDone}  || sub {};
    my $onError = $args{onError} || sub { $onDone->([]) };

    my $username = $args{user} // $prefs->get('username') // '';
    unless (length $username) { $onError->("No ListenBrainz username configured"); return; }

    my $cacheKey = 'lbf:following:' . $username;
    if (!$args{force} && (my $cached = $cache->get($cacheKey))) {
        $log->info("Following cache hit ($cacheKey)");
        $onDone->($cached);
        return;
    }

    (my $safe_user = $username) =~ s/([^A-Za-z0-9\-_.~])/sprintf("%%%02X",ord($1))/ge;
    my $url = sprintf('%s/1/user/%s/following', BASE_URL, $safe_user);
    $log->info("Fetching following: $url");

    my @headers = ('Accept' => 'application/json', 'User-Agent' => USER_AGENT);
    my $token   = $prefs->get('token') // '';
    push @headers, ('Authorization' => "Token $token") if $token;

    my $http = Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $resp = shift;
            my $data = eval { from_json($resp->content) };
            if ($@) { $log->error("Following JSON parse error: $@"); $onError->("JSON error: $@"); return; }
            my $users = _parseFollowing($data);
            eval { $cache->set($cacheKey, $users, FOLLOWING_TTL); 1 } or $log->warn("following cache set failed: $@");
            $log->info("Following: " . scalar(@$users) . " user(s)");
            $onDone->($users);
        },
        sub { _handleError(shift, $onError) },
        { timeout => STATS_TIMEOUT }
    );
    $http->get($url, @headers);
}

# GET /1/user/<u>/listens?count=1 → the user's LATEST listen timestamp (epoch,
# `payload.latest_listen_ts` — verified live), 0 when none/unknown. Drives the
# trending features' stale-follower filter: a followed user who stopped
# listening months ago shouldn't keep seeding This Year with their old plays.
# Cheap (one tiny request), cached per user for a day — activity state doesn't
# need to be fresher than the stats it gates (LB recomputes those ~daily too).
use constant LASTLISTEN_PFX => Plugins::ListenBrainzFreshReleases::DB::kver("lbf:lastlisten:");
use constant LASTLISTEN_TTL => 24 * 3600;
sub getLatestListenTs {
    my ($class, $user, $onDone, %args) = @_;
    $onDone ||= sub {};
    unless (defined $user && length $user) { $onDone->(0); return; }

    my $cacheKey = LASTLISTEN_PFX . $user;
    if (!$args{force} && defined(my $c = $cache->get($cacheKey))) {
        $onDone->($c + 0);
        return;
    }

    (my $safe_user = $user) =~ s/([^A-Za-z0-9\-_.~])/sprintf("%%%02X",ord($1))/ge;
    my $url = sprintf('%s/1/user/%s/listens?count=1', BASE_URL, $safe_user);

    my @headers = ('Accept' => 'application/json', 'User-Agent' => USER_AGENT);
    my $token   = $prefs->get('token') // '';
    push @headers, ('Authorization' => "Token $token") if $token;

    my $http = Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $resp = shift;
            my $data = eval { from_json($resp->content) };
            my $ts   = 0;
            my $got  = 0;
            if (!$@ && ref $data eq 'HASH' && ref $data->{payload} eq 'HASH') {
                $ts  = ($data->{payload}{latest_listen_ts} // 0) + 0;
                $got = 1;
            }
            # Cache ONLY a genuine answer (a valid payload — $ts may legitimately be 0).
            # A 204 No Content / empty / odd-shape 2xx reaches THIS success handler (as
            # _getUserStats' 204 handling proves), leaves $got=0, and is treated exactly
            # like the error path below: "unknown", NOT cached — so a private/transient
            # state can't pin a follower as unknown for a day.
            eval { $cache->set($cacheKey, $ts, LASTLISTEN_TTL); 1 } if $got;
            $onDone->($ts);
        },
        # Error → 0 = "unknown", NOT cached (a transient failure shouldn't pin a
        # follower as unknown for a day; the caller treats unknown as active).
        sub { $onDone->(0) },
        { timeout => STATS_TIMEOUT }
    );
    $http->get($url, @headers);
}

# Normalise a /following payload to an arrayref of username strings. The live API
# nests them under top-level `following` as bare strings; tolerate a payload wrap
# and {musicbrainz_id}/{user_name} object elements defensively.
sub _parseFollowing {
    my ($data) = @_;
    my $list = (ref $data eq 'HASH' && ref $data->{following} eq 'ARRAY') ? $data->{following}
             : (ref $data eq 'HASH' && ref $data->{payload} eq 'HASH'
                    && ref $data->{payload}{following} eq 'ARRAY')        ? $data->{payload}{following}
             : [];
    my @out;
    for my $u (@$list) {
        my $name = !ref $u        ? $u
                 : ref $u eq 'HASH' ? ($u->{musicbrainz_id} // $u->{user_name} // $u->{name})
                 : undef;
        push @out, $name if defined $name && length $name;
    }
    return \@out;
}

# GET /1/stats/user/<user>/<path>?range=<range>&count=<count>, shared by the two
# public stat fetchers. $path is 'recordings' or 'release-groups' — the latter is
# a HYPHEN with NO trailing slash (the underscore form 308-redirects to a URL
# that 404s). 204 (stats not computed / private listens) → an empty list, cached
# so a fan-out over many followers doesn't re-hit the same empties each warm. Any
# HTTP error for one follower → empty, not an error (don't sink the batch).
sub _getUserStats {
    my ($path, $pkey, $parser, $user, %args) = @_;
    my $onDone = $args{onDone} || sub {};
    my $range  = $args{range}  || 'week';
    my $count  = $args{count}  || 100;

    unless (defined $user && length $user) { $onDone->([]); return; }

    my $cacheKey = "lbf:userstats:$pkey:$range:$user";
    if (!$args{force} && (my $cached = $cache->get($cacheKey))) {
        $onDone->($cached);
        return;
    }

    (my $safe_user = $user) =~ s/([^A-Za-z0-9\-_.~])/sprintf("%%%02X",ord($1))/ge;
    my $url = sprintf('%s/1/stats/user/%s/%s?range=%s&count=%d',
        BASE_URL, $safe_user, $path, $range, $count);

    # ---------------------------------------------------------------------
    # RATE LIMITING. This endpoint had NONE, and the omission emptied a whole
    # feature.
    #
    # MEASURED on the live server 2026-08-22: **39 of 39 stats requests came back
    # 429 TOO MANY REQUESTS inside a 0.88-second burst** — 13 stats/recordings and
    # 26 stats/release-groups — leaving People You Follow completely empty
    # ("mapped 0 recordings", "aggregate 0 album(s)"). The cause is arithmetic:
    # `_warmTrending` started three builds within 50ms of each other, each fanning
    # out at FOLLOWER_FANOUT (10), so THIRTY concurrent requests went out at once
    # against ListenBrainz's measured budget of ~30 per 10 seconds.
    #
    # The backoff machinery to handle this has existed since 0.9.165 — it was just
    # wired to `getReleaseGroupMetadata` and nothing else, and the constant beside
    # FOLLOWER_FANOUT still reads "the LB stats endpoint is cheap — safe to
    # parallelise". Cheap is not the same as exempt.
    #
    # A 429 IS NOT AN ANSWER. Returning [] here laundered a rate limit into "this
    # follower has no listens", which is this repo's oldest rule (an empty result
    # is never a fact) failing on a new path. So it is retried against the SHARED
    # deadline, and only a genuinely exhausted budget falls through to [].
    # ---------------------------------------------------------------------
    my $go;
    $go = sub {
        my ($self, $attempt) = @_;   # passed to itself — never captured in its own
                                     # closure (the 0.9.95 reference-cycle leak)
        $attempt ||= 1;

        # BACK OFF TOGETHER, exactly as the genre path does: if any caller has
        # already been limited, wait out the shared deadline rather than joining
        # the queue that caused it. With the fan-out this is what turns a burst
        # into a queue.
        if ((my $wait = _lbWait()) > 0) {
            Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + $wait,
                                          sub { $self->($self, $attempt) });
            return;
        }

        my $http = Slim::Networking::SimpleAsyncHTTP->new(
            sub {
                my $resp = shift;
                my $body = $resp->content;
                my $rows;
                if (!defined $body || !length $body) {   # 204 No Content
                    $rows = [];
                } else {
                    my $data = eval { from_json($body) };
                    if ($@) { $log->warn("stats/$path JSON parse error for $user: $@"); $onDone->([]); return; }
                    $rows = $parser->($data);
                }
                eval { $cache->set($cacheKey, $rows, STATS_TTL); 1 } or $log->warn("stats cache set failed: $@");
                $onDone->($rows);
            },
            sub {
                my $resp = shift;

                if (_lbIsRateLimited($resp) && $attempt < LB_RETRY_MAX) {
                    my $in = _lbNoteLimit($resp, $attempt);
                    $log->info(sprintf('stats/%s rate-limited for %s — backing off %.1fs (attempt %d)',
                                       $path, $user, $in, $attempt)) if $log->is_info;
                    Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + $in,
                                                  sub { $self->($self, $attempt + 1) });
                    return;
                }

                # NOT cached — the write only happens on the success path above, so
                # a spent budget is retried on the next build rather than pinned as
                # "this follower has nothing".
                $log->info("stats/$path fetch failed for $user: " . ($resp->error // '?'));
                $onDone->([]);
            },
            { timeout => STATS_TIMEOUT }
        );
        $http->get($url, 'Accept' => 'application/json', 'User-Agent' => USER_AGENT);
    };
    $go->($go, 1);
}

# Public per-user top recordings (tracks). $onDone gets an arrayref of normalised
# rows: { recording_mbid, title, artist, artist_mbid, release_mbid, release_name,
# caa_id, caa_release_mbid, listen_count }.
sub getUserTopRecordings {
    my ($class, $user, %args) = @_;
    _getUserStats('recordings', 'rec', \&_parseTopRecordings, $user, %args);
}

# Public per-user top release groups (albums). $onDone gets: { release_group_mbid,
# title, artist, artist_mbid, caa_id, caa_release_mbid, listen_count }.
sub getUserTopReleaseGroups {
    my ($class, $user, %args) = @_;
    _getUserStats('release-groups', 'rg', \&_parseTopReleaseGroups, $user, %args);
}

# The true PRIMARY artist MBID for a stats row: first credit of the artists[]
# array (handles "feat." credits cleanly), falling back to artist_mbids[0].
sub _primaryArtistMbid {
    my ($row) = @_;
    return $row->{artists}[0]{artist_mbid}
        if ref $row->{artists} eq 'ARRAY' && ref $row->{artists}[0] eq 'HASH' && $row->{artists}[0]{artist_mbid};
    return (ref $row->{artist_mbids} eq 'ARRAY' ? $row->{artist_mbids}[0] : undef);
}

sub _parseTopRecordings {
    my ($data) = @_;
    my $payload = (ref $data eq 'HASH' && ref $data->{payload} eq 'HASH') ? $data->{payload} : {};
    my $rows    = ref $payload->{recordings} eq 'ARRAY' ? $payload->{recordings} : [];
    my @out;
    for my $r (@$rows) {
        next unless ref $r eq 'HASH';
        my $title  = $r->{track_name}  // '';
        my $artist = $r->{artist_name} // '';
        next unless length $title || length $artist;
        push @out, {
            recording_mbid   => lc($r->{recording_mbid} // ''),
            title            => $title,
            artist           => $artist,
            artist_mbid      => lc(_primaryArtistMbid($r) // ''),
            release_mbid     => $r->{release_mbid} // '',
            release_name     => $r->{release_name} // '',
            caa_id           => $r->{caa_id},
            caa_release_mbid => $r->{caa_release_mbid} // '',
            listen_count     => ($r->{listen_count} // 0) + 0,
        };
    }
    return \@out;
}

sub _parseTopReleaseGroups {
    my ($data) = @_;
    my $payload = (ref $data eq 'HASH' && ref $data->{payload} eq 'HASH') ? $data->{payload} : {};
    my $rows    = ref $payload->{release_groups} eq 'ARRAY' ? $payload->{release_groups} : [];
    my @out;
    for my $r (@$rows) {
        next unless ref $r eq 'HASH';
        my $title = $r->{release_group_name} // '';
        next unless length $title;
        push @out, {
            release_group_mbid => lc($r->{release_group_mbid} // ''),
            title              => $title,
            artist             => $r->{artist_name} // '',
            artist_mbid        => lc(_primaryArtistMbid($r) // ''),
            caa_id             => $r->{caa_id},
            caa_release_mbid   => $r->{caa_release_mbid} // '',
            listen_count       => ($r->{listen_count} // 0) + 0,
        };
    }
    return \@out;
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

    my $cacheKey = Plugins::ListenBrainzFreshReleases::DB::kver("lbf:artistmbid:") . lc $name;
    utf8::encode($cacheKey) if utf8::is_utf8($cacheKey);
    if (defined(my $c = $cache->get($cacheKey))) {
        $onDone->($c || undef);   # '' is the cached "not found" sentinel
        return;
    }

    # Fielded exact-phrase query. The 'artist' field searches the NAME only —
    # an artist reachable solely through an MB ALIAS ("The Oh Sees" -> Osees)
    # returns 0 results there, so a second stage retries the 'alias' field
    # (verified live: artist:"The Oh Sees" = 0, alias:"The Oh Sees" = score
    # 100). Alias runs ONLY when the name field found nothing acceptable, so
    # it can never change a resolution that works today. Matters here for the
    # DSTM radio's Last.fm similar-artist names, which are full of alias-era
    # spellings. (Ported from Discography 0.32.0.)
    my $mkQuery = sub {
        my ($field) = @_;
        my $q = $field . ':"' . $name . '"';
        utf8::encode($q) if utf8::is_utf8($q);
        (my $safe = $q) =~ s/([^A-Za-z0-9])/sprintf("%%%02X",ord($1))/ge;
        return 'artist?query=' . $safe . '&fmt=json&limit=1';
    };

    # MIRROR SEARCH FALLBACK (ported from Discography 0.23.0): a musicbrainz-docker
    # mirror serves entity BROWSES from Postgres, but ?query= SEARCH goes through
    # Solr — and a mirror whose search index was never built returns count:0 for
    # EVERY query while browses work. That would silently fail every name→MBID
    # resolution (the DSTM radio seed, Last.fm similar-artist resolution). So when
    # the configured base is a mirror and its search yields zero results (or is
    # unreachable), retry the SAME query ONCE against the public API before caching
    # a miss. The MBID is universal, so a public-resolved MBID still browses fine
    # against the mirror. $mirror gates it; $isFb guards against a loop.
    my $mirror = !_mbThrottled();

    # Pass the sub to itself ($self) rather than capturing $run lexically: a
    # self-capturing closure is a reference cycle Perl never collects, and this
    # resolver runs once per artist name (DSTM seeds, Last.fm similar-artist
    # resolution) so each call would leak. $self keeps the CV alive across the
    # async gap (the in-flight callbacks hold it), then frees when they do.
    my $run = sub {
        my ($self, $base, $isFb, $field) = @_;
        $log->info("Resolving artist name to MBID: $name ($field field"
            . ($isFb ? ', public fallback' : '') . ')');

        my $http = Slim::Networking::SimpleAsyncHTTP->new(
            sub {
                my $resp = shift;
                my $data = eval { from_json($resp->content) };
                my $arts = (!$@ && ref $data eq 'HASH' && ref $data->{artists} eq 'ARRAY')
                           ? $data->{artists} : undef;

                if ($arts && !@$arts && $mirror && !$isFb) {
                    $log->info("Artist '$name' ($field) => 0 results on mirror; retrying public API");
                    return $self->($self, MB_DEFAULT_BASE_URL, 1, $field);
                }

                my $mbid = '';
                if ($arts && @$arts) {
                    my $a = $arts->[0];
                    $mbid = lc $a->{id} if $a->{id} && ($a->{score} // 0) >= 90;
                }

                # Name field found nothing acceptable -> ONE alias-field pass
                # (same base/fallback state; the mirror-0-results branch above
                # still gives the alias pass its own public retry).
                if (!$mbid && $field eq 'artist') {
                    $log->info("Artist '$name' => no name-field match; retrying alias field");
                    return $self->($self, $base, $isFb, 'alias');
                }
                eval { $cache->set($cacheKey, $mbid, $mbid ? MB_FOUND_TTL : MB_EMPTY_TTL); 1 }
                    or $log->warn("artist-mbid cache set failed: $@");
                $log->info("Artist '$name' ($field) => " . ($mbid || 'no match') . ($isFb ? ' [public fallback]' : ''));
                $onDone->($mbid || undef);
            },
            sub {
                my $err = shift;
                if ($mirror && !$isFb) {
                    $log->info("Artist '$name' ($field) => mirror search error; retrying public API");
                    return $self->($self, MB_DEFAULT_BASE_URL, 1, $field);
                }
                _handleError($err, $onError);
            },
            { timeout => 12 }
        );

        $http->get($base . $mkQuery->($field), 'Accept' => 'application/json', 'User-Agent' => USER_AGENT);
    };

    # -----------------------------------------------------------------------
    # TIER 1: the hosted LMS-community API, in front of everything above.
    #
    # WHY: on public MusicBrainz — which is what the majority run, since most
    # users have no mirror — this resolver is throttled to ~1 req/s, and it is
    # called in LOOPS (a DSTM radio seed, then every Last.fm similar artist).
    # Resolving 25 names is ~25s of enforced throttle there versus ~57ms each
    # here, against a globally shared Cloudflare cache that is usually already
    # warm for anyone popular enough to be a radio seed.
    #
    # THE GATE, and it is the whole reason this is safe. The hosted endpoint
    # picks by POPULARITY and returns no score, while the MusicBrainz path below
    # deliberately requires score >= 90 — because these MBIDs seed radio and
    # similar-artist chains that resolve UNATTENDED, so a wrong artist silently
    # pollutes the output for hours. So we do not trust the hosted answer just
    # because it came back: it is accepted ONLY if the name it echoes folds equal
    # to the name we asked for.
    #
    # Fold-comparing (via Browse::_norm — lowercase, strip diacritics) is what
    # makes that gate correct rather than merely strict: it ACCEPTS the API's
    # diacritic corrections, which are the common case and are right
    # (Beyonce -> Beyoncé, Motorhead -> Motörhead — both verified live), while
    # REJECTING a fuzzy mapping to a differently-named popular namesake.
    #
    # THE LENGTH CHECK IS LOAD-BEARING. An unknown artist does not 404 and does
    # not return {} — it returns the QUERY NAME back with an empty mbid:
    #   {"name":"zzzqqq notanartist","mbid":""}
    # so the name folds equal to itself and the gate would pass on nothing at
    # all. Verified live 2026-08-12. Never drop `length $mbid`.
    #
    # Anything else — unknown artist, fold mismatch, bad JSON, HTTP failure,
    # service down — falls through to $run, which is the previous implementation
    # byte for byte. That fallback is UNCONDITIONAL by design: an outage here
    # degrades to exactly today's behaviour rather than breaking resolution.
    my $mbFallback = sub { $run->($run, _mbBase(), 0, 'artist') };

    _hostedGet('artist/' . _hostedSeg($name) . '/mbid', sub {
        my ($data) = @_;
        my $mbid = lc($data->{mbid} // '');
        my $got  = $data->{name} // '';

        unless (length $mbid) {
            $log->info("Hosted API: no MBID for '$name'; falling back to MusicBrainz");
            return $mbFallback->();
        }
        unless (_foldEq($got, $name)) {
            $log->info("Hosted API: '$name' resolved to a different artist ('$got'); falling back to MusicBrainz");
            return $mbFallback->();
        }

        eval { $cache->set($cacheKey, $mbid, MB_FOUND_TTL); 1 }
            or $log->warn("artist-mbid cache set failed: $@");
        $log->info("Artist '$name' => $mbid [hosted]");
        $onDone->($mbid);
    }, $mbFallback);
}

# Fold two names for the resolver's accept gate. Delegates to Browse::_norm —
# the shared matcher's normaliser (lowercase + NFD diacritic strip + the %FOLD
# atomic-letter map) — rather than growing a second, subtly different fold.
#
# Called through ->can at RUNTIME so API.pm gains no compile-time dependency on
# Browse.pm (Browse already depends on API; a `use` back the other way would be a
# circular load). Browse is loaded by Plugin.pm at init, so it is always there in
# the running plugin; the lc fallback only matters to a test harness that loads
# API.pm alone.
#
# DO NOT FORK OR EDIT _norm to suit this caller — it is shared matcher code under
# the fleet sync rule (see CLAUDE.md), and a change there has to land in every
# repo in the same session. Reading it is free; changing it is not.
#
# Comparing folded-to-folded is symmetric, which is why the known "!"-fold hole
# (Panic! At The Disco) cannot cause a false ACCEPT here: both sides fold the
# same way, so a mismatch is still a mismatch.
sub _foldEq {
    my ($x, $y) = @_;
    return 0 unless defined $x && defined $y;
    my $norm = Plugins::ListenBrainzFreshReleases::Browse->can('_norm');
    return $norm ? ($norm->($x) eq $norm->($y)) : (lc($x) eq lc($y));
}

# ---------------------------------------------------------------------------
# Artist sort-name (for the Artist sort). The ListenBrainz feed only carries the
# display credit ("Jack White"); the sort-name ("White, Jack"; a stage name like
# "Panda Bear" stays as-is) lives in MusicBrainz. We look it up by the artist
# MBID the feed DOES give us (artist/<mbid> → sort-name), store it, and warm it
# in the background so the Artist sort keys on it. A cold artist falls back to
# the display credit and self-corrects on re-entry (the plugin's second-load
# contract). Fast on an MB mirror; a courtesy-throttled background trickle on the
# public API (bounded per pass, so each open fills a little more of the table).
#
# THIS IS ONE OF THE THREE THINGS THAT WERE NEVER CACHES, so it lives in the
# `artist` TABLE, not in `kv`. Re-deriving it costs SORT_WARM_MAX(100) artists per
# pass, serially, with a 1.1s courtesy gap on public MusicBrainz — a multi-day
# reconvergence on a 2,900-release feed. A dev build wipes `kv` wholesale and
# clears only the GENRE columns of the facts tables, which is precisely so a genre
# change can never cost this.
#
# STALENESS IS AN AGE POLICY ON `fetched_at`, NOT A TTL. Nothing here hands a
# duration to anyone, so no value can mean 1970. `sort_src` records which tier
# answered, so the MusicBrainz tier can be re-run without disturbing a future
# local or hosted one.
# ---------------------------------------------------------------------------
use constant SORT_FOUND_AGE => 30 * 86400;   # a sort-name does not move
use constant SORT_NONE_AGE  =>  1 * 86400;   # "MB had none" — retry tomorrow, not in a month
use constant SORT_WARM_MAX  => 100;   # artists fetched per warm pass (rest self-heal on later opens)
my %sortInFlight;

# ---------------------------------------------------------------------------
# MUSICBRAINZ RATE-LIMIT BACKOFF. The other two network paths have had one for
# a long time — ListenBrainz (`_lbWait`) and the hosted API (`_hostedNoteLimit`)
# — and this one had NOTHING: a rate-limited response was logged at info level
# and the pump moved straight on to the next artist, so a courtesy gap that
# public MB had already rejected kept being applied to request after request.
#
# THE COURTESY GAP IS NOT A RATE LIMITER, and that is the whole reason this is
# needed. 1.1s is what MusicBrainz ASKS for; it is not a promise that a request
# sent 1.1s later is accepted. Measured against the live public API on
# 2026-08-22 while investigating this: two 503s inside eight requests paced at
# 1.2s — WIDER than the gap this code uses. When that happens today the whole
# 100-artist pass burns itself against the limit, stores nothing (an HTTP error
# is deliberately not cached), and the identical batch is re-queued on the next
# artist-sorted open — so the load repeats rather than backing off.
#
# 503 IS THE ONE THAT MATTERS HERE. MusicBrainz signals throttling with 503
# ("Your requests are exceeding the allowable rate limit"), not the 429 the
# other two services use — so a backoff copied straight from `_hostedGet`
# without this line would never fire. Both are matched anyway, by code and by
# error string, because a mirror or a proxy in front of one can answer either.
#
# THE DEADLINE IS SHARED AND ONLY EVER MOVES OUT, exactly as `_hostedNoteLimit`
# does and for the same reason: a later success resets the CURVE, and a plain
# assignment would then let a fresh 503 shorten a window still in force,
# releasing the pump early straight back into the live limit.
#
# Named for MusicBrainz rather than for the sort warm because nothing here is
# sort-specific — `getReleaseGroupByName` and the mirror genre path are the
# obvious next adopters. The sort warm is simply the only caller today.
use constant MB_BACKOFF_START => 5;
use constant MB_BACKOFF_MAX   => 30;
my $mbBusyUntil = 0;
my $mbDelay     = 0;

sub _mbWait {
    my $now = time();
    return $mbBusyUntil > $now ? $mbBusyUntil - $now : 0;
}

sub _mbIsRateLimited {
    my ($resp, $err) = @_;
    if (ref $resp && $resp->can('code')) {
        my $code = $resp->code // 0;
        return 1 if $code == 503 || $code == 429;
    }
    $err = '' unless defined $err;
    $err .= ref $resp && $resp->can('error') ? ($resp->error // '') : '';
    return $err =~ /rate limit|exceeding the allowable|too many requests|\b503\b|\b429\b/i ? 1 : 0;
}

sub _mbNoteLimit {
    $mbDelay = $mbDelay ? $mbDelay * 2 : MB_BACKOFF_START;
    $mbDelay = MB_BACKOFF_MAX if $mbDelay > MB_BACKOFF_MAX;
    my $until = time() + $mbDelay;
    $mbBusyUntil = $until if $until > $mbBusyUntil;   # only ever outward
    $log->warn("MusicBrainz rate limit — backing off ${mbDelay}s");
    return $mbDelay;
}

sub _mbNoteOk { $mbDelay = 0; return }

# ---------------------------------------------------------------------------
# Artist genres straight from MusicBrainz — the MIRROR-ONLY fast path
# ---------------------------------------------------------------------------
# WHY THIS EXISTS, because it looks like a duplicate of the ListenBrainz bulk
# metadata call and is not. Measured against a live All Releases feed (2026-07-29):
#
#   * The genre a list row shows is ALMOST ALWAYS the ARTIST's, not the release's.
#     Of 47 release groups ListenBrainz returned, 0 carried their own tags and 24
#     carried artist tags. Tier 1 is nearly always empty for fresh releases —
#     they're too new to have been tagged.
#   * A local MusicBrainz mirror answers `artist/<mbid>?inc=genres` in 40–120ms,
#     unthrottled, with NO variance. 50 artists took 3.8s strictly sequential.
#   * Coverage is IDENTICAL, which is the fact that makes this safe: over the same
#     50 artists, ListenBrainz had genres for 16 and the mirror for the same 16 —
#     zero disagreement in either direction. It is the same MusicBrainz data;
#     ListenBrainz is just another way to ask for it.
#
# So where a mirror exists we ask it directly, per artist, concurrently. Keyed by
# ARTIST, which is also the better cache shape: a release group is a one-shot key
# (next week's feed is all-new release groups, so the whole cache misses), while
# artists recur — measured at 23% of the next feed's artists already known versus
# 11% of its release groups.
#
# THIS IS NO LONGER THE ONLY VIABLE PATH, and that is the 2026-08-12 unpark. The
# original text here said ListenBrainz answered the same request in "0.25s to 24s"
# and took "125 SECONDS" for one feed, 502ing above ~90 mbids — which is why this
# mirror path was written and why the feature shipped OFF for everyone without a
# mirror. ListenBrainz has since fixed that endpoint: re-benchmarked on the live
# 556-release week, the bulk path now fills the WHOLE feed in 2.8s (12 batches,
# worst 0.52s, no 502s). So the mirror is now an optimisation, not a prerequisite.
#
# NEVER used against public MusicBrainz: that's 1 req/s courtesy, i.e. ~6 minutes
# for one feed. Without a mirror the caller uses the ListenBrainz bulk path
# (see Browse::_genreLookupMode).
# AGES, NOT TTLs, and this is the SECOND of the two constants that meant 1970.
# `AGEN_FOUND_TTL => 90 * 86400` was added by the 0.9.162 genre work and made this
# path 100% broken from the moment it shipped — see the note on RECMETA_AGE for
# the mechanism. It is now compared against `artist.fetched_at` in Perl, so the
# number is just a number again and 90 days means 90 days.
# AGE POLICY — docs/feed-findings-2026-08-14.md §2, and it is a standing rule, not
# a tuning knob: FOUND = 30 days, EMPTY = 1 day, matching SORT_FOUND_AGE /
# SORT_NONE_AGE above. No genre answer may sit stale for longer. The old 90d/7d
# pinned "this artist has no genres" across a week in which the upstream dataset
# was actively filling.
use constant AGEN_FOUND_AGE   => 30 * 86400;   # an artist's genres barely move
use constant AGEN_EMPTY_AGE   =>  1 * 86400;   # "MB knows none" — retry tomorrow
use constant AGEN_CONCURRENCY => 6;            # our own box; the public API is never used here
use constant AGEN_TIMEOUT     => 12;
my %agenInFlight;

# True when the configured/detected MusicBrainz base is a local mirror rather than
# the public API. The genre path is only allowed to fan out against a mirror.
sub hasMirror { return _mbThrottled() ? 0 : 1 }

# Store-only read: the artist's genres (possibly an empty arrayref, meaning "MB
# has none"), or undef when we've simply never looked. The render path uses this
# and NEVER fetches — same contract as peekArtistSort/peekLastfmTags.
#
# The mirror tier keys on the MBID and the hosted tier on `n:<normalised name>`
# (it has no MBID lookup at all), so the two occupy DIFFERENT ROWS of the same
# table and cannot overwrite one another. `genres_src` is checked anyway, so a
# future tier that did share a key would read as absent here rather than be
# silently mistaken for this one.
sub peekArtistGenres {
    my ($class, $mbid) = @_;
    return undef unless $mbid;
    return $class->peekArtistGenresBulk([$mbid])->{ lc $mbid };
}

# BULK — one statement for a whole page. See peekReleaseGroupMetadataBulk.
sub peekArtistGenresBulk {
    my ($class, $mbids) = @_;
    my %want;
    for my $m (@{ $mbids || [] }) { next unless defined $m && length $m; $want{ lc $m } = 1 }
    return {} unless %want;

    my $rows = Plugins::ListenBrainzFreshReleases::DB::artistGet([ keys %want ]);
    my %out;
    for my $k (keys %$rows) {
        next unless _artistGenresFresh($rows->{$k}, "mb_genres", AGEN_FOUND_AGE, AGEN_EMPTY_AGE);
        $out{$k} = $rows->{$k}{mb_genres} || [];
    }
    return \%out;
}

# Is a stored artist-genre row still good enough to serve, FOR ONE TIER?
#
# `$col` is that tier's own column ('hosted_genres' or 'mb_genres'), and reading a
# tier's own column is the point. Until schema 3 both tiers shared `artist.genres`
# with a `genres_src` discriminator, and this test returned 0 whenever the src did
# not match — so with both live, hosted saw 'mb', called it stale, refetched and
# wrote 'hosted'; the mirror saw 'hosted', called it stale, refetched and wrote
# 'mb'. Every pass, for ever, each destroying the other's answer. Separate columns
# make that ping-pong inexpressible: a tier can no longer see, still less clobber,
# anybody else's answer.
sub _artistGenresFresh {
    my ($row, $col, $foundAge, $emptyAge) = @_;
    return _answerFresh($row, "n_$col", "${col}_at", $foundAge, $emptyAge);
}

# Fill the artist-genre cache for @$mbids, then hand back everything known as
# { lc mbid => [ genre, … ] }. Cached artists cost nothing; only the unknown ones
# are fetched, AGEN_CONCURRENCY at a time. Best-effort throughout: a failed lookup
# is left uncached (so it retries) and simply contributes no genres.
sub getArtistGenres {
    my ($class, $mbids, $onDone) = @_;
    $onDone ||= sub {};

    unless (hasMirror()) { $onDone->({}); return }   # never fan out at public MB

    my (%out, %seen, @cand);
    for my $m (@{ $mbids || [] }) {
        next unless $m;
        my $lc = lc $m;
        next if $seen{$lc}++;
        next if $lc eq lc VA_MBID;
        push @cand, $lc;
    }
    unless (@cand) { $onDone->(\%out); return }

    # ONE read for the whole set, not one per artist.
    my $known = $class->peekArtistGenresBulk(\@cand);

    my @todo;
    for my $lc (@cand) {
        if (my $c = $known->{$lc}) { $out{$lc} = $c; next }
        next if $agenInFlight{$lc};
        push @todo, $lc;
    }
    unless (@todo) { $onDone->(\%out); return }

    # Reserve the whole batch up front — see warmArtistSorts for why doing it one
    # at a time lets a second pass re-fetch everything still queued.
    $agenInFlight{$_} = 1 for @todo;

    my $active = 0;
    my $fired  = 0;

    # $self arrives as an argument rather than being captured, so the closure never
    # references itself (the uncollectable cycle fixed in 0.9.95).
    my $pump = sub {
        my ($self) = @_;
        while ($active < AGEN_CONCURRENCY && @todo) {
            my $mbid = shift @todo;
            $active++;

            my $done = sub {
                delete $agenInFlight{$mbid};
                $active--;
                if (@todo)          { $self->($self) }
                elsif (!$active)    { $onDone->(\%out) unless $fired++ }
            };

            (my $safe = $mbid) =~ s/([^A-Za-z0-9\-_.~])/sprintf("%%%02X",ord($1))/ge;
            my $url = _mbBase() . 'artist/' . $safe . '?inc=genres&fmt=json';

            my $http = Slim::Networking::SimpleAsyncHTTP->new(
                sub {
                    my $data  = eval { from_json($_[0]->content) };
                    my $genres = _mbGenreNames(ref $data eq 'HASH' ? $data->{genres} : undef);
                    $out{$mbid} = $genres;
                    # An empty list is a REAL answer ("MB has no genres for them")
                    # and IS stored, or every artist without genres — most of them
                    # — would be re-fetched on every single fill. The read side
                    # rechecks an empty answer sooner, so tagging that lands later
                    # is still picked up.
                    Plugins::ListenBrainzFreshReleases::DB::artistPut(
                        $mbid, mbid => $mbid, mb_genres => $genres)
                        or $log->warn("artist-genre store write failed for $mbid");
                    $done->();
                },
                sub {
                    # Don't cache a transport failure — it would pin "no genres" for
                    # "no genres" on an artist we simply could not reach.
                    $log->info("artist-genre fetch error for $mbid: " . ($_[1] // '?')) if $log->is_info;
                    $done->();
                },
                { timeout => AGEN_TIMEOUT }
            );
            $http->get($url, 'Accept' => 'application/json', 'User-Agent' => USER_AGENT);
        }
    };

    $pump->($pump);
}

# ---------------------------------------------------------------------------
# HOSTED ARTIST GENRES — REMOVED 0.9.173. Do not reinstate it without new
# measurements; the ones that killed it are below and in
# docs/feed-findings-2026-08-14.md §1.
#
# THE REASONING THAT PUT IT HERE was that ListenBrainz answers only ~52% of a
# feed, so a SECOND artist tier from a different dataset was the only thing that
# could move the number. The premise was wrong: the hosted API is MusicBrainz-
# DERIVED, so it is not a different dataset. It succeeds where LB succeeds and
# fails where LB fails.
#
# MEASURED ON THE RESIDUE — the artists that actually reach this rung, i.e. the
# ones LB could not answer. That is the only population it was ever asked about,
# and judging it on a whole-feed sample (~50%) is what made it look useful:
#
#   2026-08-13   4 of 120 replayed names        11 of 411 in the live store
#   2026-08-21   1 of 67 replayed names         15 of 547 in the live store
#                (warm's own report: "asked 138, 5 answered" / "asked 161, 6")
#
# ~2%, unchanged across a week in which the upstream dataset was believed to be
# filling. Against that it cost ONE REQUEST PER ARTIST at HAGEN_CONCURRENCY => 1
# — roughly 64s of serial HTTP per warm for 400 artists — while Last.fm, the one
# genuinely independent (crowd-tagged, non-MB) source, answers ~63% of the same
# population and remains in the ladder.
#
# WHAT IS KEPT, and it is a DIFFERENT ROUTE: getAlbumGenresHosted, further down.
# That one is album-keyed, is called once per release-detail-page open (never on
# a list row), and measured 0 of 49 on fresh releases but rich on established
# albums — OK Computer 13 genres, Rumours 8, Kid A 15 — which is the Trending
# Albums population that shares that page. It earns its place on LATENCY, not
# coverage: MusicBrainz answers those same albums (7 of 8 identical), but for a
# user with no local mirror that is one public-API-throttled request per page
# open, which is exactly the cost this tier avoids.
#
# TWO PROPERTIES OF THIS ROUTE FAMILY SURVIVE THE REMOVAL, because they still
# apply to getAlbumGenresHosted and would cost the next person the same day:
#
#   1. `genres` IS A FIELD ON THE PARENT ROUTE, NOT A SUB-ROUTE — for artists.
#      `/music/artist/<name>/genres` does not exist, and an unrecognised path
#      answers HTTP 200 with a fixed `{"picture": …}` payload rather than a 404,
#      so a wrong path "works" while returning nothing usable for ever. (The
#      ALBUM route is the exception: `/music/album/<t>/<a>/genres` is real.)
#
#   2. THE PAYLOAD IS TITLE-CASED ("Alternative Rock"). It MUST be lowercased on
#      the way in or Browse::_genreFamily will not match genre-families.txt and
#      every row silently falls through to the raw genre instead of its family.
#      That is what _hostedGenreNames is for, and it is why that sub is KEPT.
# ---------------------------------------------------------------------------

# The `artist` table key for a NAME. Folded through the shared matcher's _norm so
# "Sigur Rós" and "Sigur Ros" are one row rather than two. Reached via ->can at
# runtime for the same reason _foldEq does it — API.pm must gain no compile-time
# dependency on Browse.pm, which already depends on API.
sub artistKeyForName {
    my ($class, $name) = @_;
    return '' unless defined $name && length $name;
    my $norm = Plugins::ListenBrainzFreshReleases::Browse->can('_norm');
    my $n    = $norm ? $norm->($name) : lc $name;
    $n =~ s/^\s+//; $n =~ s/\s+$//;
    return length $n ? 'n:' . $n : '';
}

# `_hagenFresh`, `peekArtistGenresHosted` and `getArtistGenresHosted` lived here
# and were removed in 0.9.173 along with HAGEN_FOUND_AGE / HAGEN_EMPTY_AGE /
# HAGEN_CONCURRENCY and %hagenInFlight. See the block comment above for the
# measurements; the `artist` table keeps its `hosted_genres` / `n_hosted_genres` /
# `hosted_genres_at` columns because SQLite column drops are a table rebuild and
# an unread column costs nothing but bytes.

# `_hostedGenreNames` lived here and was removed in 0.9.185 with the last caller
# that needed it (`getAlbumGenresHosted`). It lowercased the hosted API's
# Title-Cased payload at the boundary. IF ANY HOSTED GENRE ROUTE IS EVER
# REINSTATED IT MUST COME BACK WITH IT: `_genreFamily`, `_genreKnown` and
# `_bucketFor` all key on the lowercase vocabulary in genre-families.txt, and a
# Title-Cased genre does not fail loudly — it silently stops rolling up to its
# family, which is how it survived unnoticed until 0.9.173.

# MusicBrainz `inc=genres` gives [ { name, count, id }, … ]. Strongest first, and
# NOT tie-broken on name — same reasoning as _genreTags: most real tags tie at
# count 1, so an alphabetical tie-break quietly becomes "show the alphabetically
# first genres", which misdescribes the artist. Perl's sort is stable, so ties keep
# MB's own order.
sub _mbGenreNames {
    my ($genres) = @_;
    return [] unless ref $genres eq 'ARRAY';
    my @g = sort { ($b->{count} // 0) <=> ($a->{count} // 0) }
            grep { ref $_ eq 'HASH' && defined $_->{name} && length $_->{name} } @$genres;
    return [ map { $_->{name} } @g ];
}

# ---------------------------------------------------------------------------
# Caching FREE TEXT (0.9.141) — THE RULE STANDS; ITS HELPERS ARE GONE (0.9.186)
# ---------------------------------------------------------------------------
# `_setText`/`_getText` were removed with `getArtistBio`, their last caller (the
# other one, the MusicBrainz sort-name, moved to `DB::artistPut` when the store
# landed). NOTHING in this file writes a bare string to the cache any more.
#
# THE RULE IS KEPT HERE BECAUSE IT IS ABOUT THE NEXT ONE, not about the two that
# have gone: never `$cache->set($key, $some_string)` with text that came from an
# API. Wrap it in a hashref, or put it in the store.
#
# `Slim::Utils::DbCache::set` Storable-freezes a value only `if (ref $data)`; a
# plain scalar is handed STRAIGHT to a DBI SQL_BLOB bind. Binding a Perl string
# containing a codepoint above 255 there dies with
#
#     Wide character in subroutine entry at .../Slim/Utils/DbCache.pm line 78
#
# which is why every OTHER cache write in this file has always been safe (they all
# store hashrefs/arrayrefs, so freeze handles the encoding) while the two that
# stored a bare string — the MusicBrainz artist sort-name and the Last.fm bio —
# failed for any text with a non-Latin-1 character. Seen live in server.log as
# "artist-sort cache set failed", once per non-Latin artist. The consequences were
# silent and ongoing, not cosmetic: nothing was ever cached for those artists, so
# the sort-name warm re-fetched them from MusicBrainz on every pass, and an artist
# bio — where a single curly quote or em-dash is enough to trip it — was re-fetched
# from Last.fm on every single release-page open.
#
# Wrapping in a hashref puts the value back through Storable, which handles any
# codepoint and hands the string back with its utf8 flag intact. That is preferred
# over encode-on-write/decode-on-read: there is no second place to get wrong and no
# way to mojibake a value that was stored before this existed.
#
# (Related but distinct: cache KEYS are md5'd by DbCache and die the same way on
# wide input, which is the 0.6.15 bug. Keys built from free text are encoded to
# octets at the point of use — see `getLastfmTags`/`_lfmKey`, the last place in
# this file that builds a key out of an artist name.)


# BULK sync read for the sorter: { lc mbid => sort-name } holding only the artists
# actually known. No network.
#
# THE RENDER PATH MUST USE THIS ONE. An artist-sorted All Releases view is ~2,900
# releases, so a per-release read is ~2,900 synchronous SELECTs — exactly the
# blocking work 0.9.130 moved off the render path, and exactly the hazard the
# hosted-genre tier hit in 0.9.165 (caught by bench_walk.pl, not by review). One
# statement for the whole bucket instead.
sub peekArtistSorts {
    my ($class, $mbids) = @_;
    return {} unless ref $mbids eq 'ARRAY' && @$mbids;
    my %want;
    for my $m (@$mbids) { next unless defined $m && length $m; $want{ lc $m } = 1 }
    return {} unless %want;
    return Plugins::ListenBrainzFreshReleases::DB::artistSortGet([ keys %want ]);
}

# Single-key convenience — the sort-name string, or undef when it isn't known yet
# OR MB had none (both fall back to the display credit). Kept for callers outside
# a sort; a comparator must never reach it, see peekArtistSorts.
sub peekArtistSort {
    my ($class, $mbid) = @_;
    return undef unless $mbid;
    my $v = $class->peekArtistSorts([$mbid])->{ lc $mbid };
    return (defined $v && length $v) ? $v : undef;
}

# Background-fill sort-names for a list of artist MBIDs. Dedupes, skips anything
# already cached (found OR a cached "none") and anything in flight, then fetches
# the remainder ONE AT A TIME with the MB courtesy gap (0 on a mirror), capped at
# SORT_WARM_MAX per pass. Fire-and-forget — no client needed, never blocks a feed.
sub warmArtistSorts {
    my ($class, $mbids) = @_;
    return unless ref $mbids eq 'ARRAY' && @$mbids;

    my (%seen, @cand);
    for my $m (@$mbids) {
        next unless $m;
        my $lc = lc $m;
        next if $seen{$lc}++;
        next if $lc eq lc VA_MBID;
        push @cand, $lc;
    }
    return unless @cand;

    # ONE bulk read to decide what still needs fetching, rather than a read per
    # candidate. Staleness is decided HERE, in Perl, from `fetched_at` — a found
    # sort-name is good for 30 days, a recorded "MB had none" for one, so a
    # transient miss retries tomorrow instead of pinning credit-name sort for a
    # month. Nothing hands a duration to a store, which is the whole point.
    my $have = Plugins::ListenBrainzFreshReleases::DB::artistGet(\@cand);
    my $now  = time();

    # Anything with no row at all might already be answered in the outgoing LMS
    # cache. Asking before fetching is what stops this warm re-deriving, at 100
    # artists a pass with a courtesy gap between each, a set MusicBrainz has
    # already been asked for. Bounded by DB::IMPORT_WINDOW.
    my @cold = grep { !$have->{$_} } @cand;
    if (@cold) {
        my $carried = Plugins::ListenBrainzFreshReleases::DB::importSorts(\@cold);
        if (%$carried) {
            my $again = Plugins::ListenBrainzFreshReleases::DB::artistGet([ keys %$carried ]);
            $have->{$_} = $again->{$_} for keys %$again;
        }
    }

    my @todo;
    for my $lc (@cand) {
        my $row = $have->{$lc};
        if ($row && length($row->{sort_src} // '')) {
            # AGE THE SORT-NAME AGAINST ITS OWN STAMP, not the row's. `fetched_at`
            # moves whenever ANY tier writes this artist row, and the mirror genre
            # tier rewrites the same MBID-keyed row daily — so a row that recorded
            # "MusicBrainz has no sort-name" (SORT_NONE_AGE, one day) had its clock
            # reset every night and was never re-asked, while a real sort-name was
            # held well past SORT_FOUND_AGE for the same reason. `sort_at` is the
            # per-answer stamp schema 3 added for exactly this and was written but
            # never read. Fall back to `fetched_at` only for a pre-migration row
            # whose stamp is still 0.
            my $age = $now - ($row->{sort_at} || $row->{fetched_at} || 0);
            next if $age < (length($row->{sort_name} // '') ? SORT_FOUND_AGE : SORT_NONE_AGE);
        }
        next if $sortInFlight{$lc};
        push @todo, $lc;
        last if @todo >= SORT_WARM_MAX;
    }
    return unless @todo;

    # Reserve the WHOLE batch as in-flight up front, not one MBID at a time as
    # each fetch starts. The pump processes @todo serially over many seconds; if
    # a second warm pass ran in that window and only the single currently-fetching
    # MBID were marked, every queued-but-not-yet-fetched MBID would pass this
    # pass's in-flight guard and be fetched AGAIN in parallel — doubling MB traffic
    # past the 1 req/s courtesy gap. Each is cleared as the pump completes it
    # (success OR error/timeout, both via $next), so the batch never leaks.
    $sortInFlight{$_} = 1 for @todo;

    # RELEASE THE WHOLE RESERVATION WHEN THE PASS GIVES UP EARLY. The reservation
    # above is what stops a second pass re-fetching a queued MBID, and until now
    # the only way out of it was completing the fetch. A pass that abandons its
    # queue (below, on a rate limit) must hand every unfetched MBID back, or they
    # stay marked in flight for the life of the process and the in-flight guard
    # silently excludes them from EVERY later pass — a permanent hole in the table
    # that looks exactly like "MusicBrainz has no sort-name for these".
    my $release = sub {
        delete $sortInFlight{$_} for @todo;
        @todo = ();
    };

    # Somebody already hit the limit — don't start at all. Without this the warm
    # re-enters on every artist-sorted open and spends its whole pass discovering
    # the same deadline one request at a time.
    if ((my $wait = _mbWait()) > 0) {
        $log->info("artist-sort warm: MusicBrainz backing off ${wait}s — deferring "
                 . scalar(@todo) . " artist(s) to a later open");
        $release->();
        return;
    }

    my $gap = _mbThrottled() ? 1.1 : 0;   # 1 req/s courtesy on public MB; a mirror is our own box

    my $pump;
    $pump = sub {
        my ($self) = @_;
        my $mbid = shift @todo;
        unless ($mbid) { return }
        # already reserved in %sortInFlight above; $next clears it when this one done

        (my $safe = $mbid) =~ s/([^A-Za-z0-9\-_.~])/sprintf("%%%02X",ord($1))/ge;
        my $url = _mbBase() . 'artist/' . $safe . '?fmt=json';

        my $next = sub {
            delete $sortInFlight{$mbid};
            return unless @todo;
            if ($gap) { Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + $gap, sub { $self->($self) }) }
            else      { $self->($self) }
        };

        my $http = Slim::Networking::SimpleAsyncHTTP->new(
            sub {
                my $data = eval { from_json($_[0]->content) };
                my $sort = (ref $data eq 'HASH') ? ($data->{'sort-name'} // '') : '';
                # An EMPTY answer is stored too, with `sort_src` set — that is what
                # makes "MB has none for this artist" a recorded fact the age policy
                # can retry on a day, rather than an absence that is refetched every
                # single pass. (The old `artist-sort cache set failed` spam in live
                # logs was a non-Latin sort-name dying on the way into the LMS cache;
                # a frozen value cannot do that.)
                _mbNoteOk();                         # a success clears the backoff curve
                Plugins::ListenBrainzFreshReleases::DB::artistPut(
                    $mbid, mbid => $mbid, sort_name => $sort, sort_src => 'mb')
                    or $log->warn("artist-sort store write failed for $mbid");
                $next->();
            },
            sub {
                # A RATE LIMIT ENDS THE PASS; any other error is just this artist's.
                # The distinction matters because the remedies are opposites: an
                # artist MB genuinely cannot answer for should not stop the other
                # ninety-nine, while a 503 means every one of those ninety-nine is
                # about to be refused too, and sending them is what holds the limit
                # open. Nothing is stored either way — an HTTP error is not an
                # answer — so the deferred artists are picked up whole on a later
                # open, which is the same self-healing path a partial pass uses.
                if (_mbIsRateLimited($_[0], $_[1])) {
                    _mbNoteLimit();
                    delete $sortInFlight{$mbid};
                    $log->info("artist-sort warm: rate-limited — deferring "
                             . scalar(@todo) . " remaining artist(s)");
                    $release->();
                    return;
                }
                # HTTP error: don't cache (retry next pass); just move on.
                $log->info("artist-sort fetch error for $mbid: " . ($_[1] // '?')) if $log->is_info;
                $next->();
            },
            { timeout => 12 }
        );
        $http->get($url, 'Accept' => 'application/json', 'User-Agent' => USER_AGENT);
    };

    $pump->($pump);
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
    my $url = _mbBase() . 'release/' . $safe . '?inc=recordings&fmt=json';

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
# `getReleaseGroupGenres` (MusicBrainz `release-group/<mbid>?inc=genres`) lived
# here and was REMOVED in 0.9.185, together with `getAlbumGenresHosted` below,
# when the detail page stopped fetching genres on demand. Both were fallbacks
# behind a store peek that had ALREADY walked the whole ladder, so they only ever
# ran on the residue where every MB-derived source was already empty — and both
# ARE MB-derived. Measured before removal: the hosted route answered 0 of 40
# albums off the live fresh-releases feed, and this one previously measured 0 of
# 14 on the same residue. See `Browse::_releaseDetail`'s genre block.
#
# `lbf:rggenres:` and `lbf:hgenres:` are dropped from DB::KEY_VERSIONS with them.
# NOTHING ACTIVELY DELETES THE STALE ENTRIES, and nothing needs to: both families
# lived in `Slim::Utils::Cache`, not in `kv`, so `retirePrefixes` never reached
# them anyway — they age out on their own TTL (30 days at most) and no code reads
# them in the meantime.
#
# Do not reinstate either without a measurement taken on the RESIDUE — the
# population that actually reaches the rung — never on a whole feed.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Album genres from the hosted LMS-community API — the tier that now sits in
# FRONT of the per-album MusicBrainz call on the release detail page.
#
# WHAT IT RETURNS IS MUSICBRAINZ'S OWN GENRE LIST, Title-Cased and in MB's own
# order — verified live 2026-08-12 (In Rainbows comes back as MB's exact set) and
# twice before that (So, OK Computer). So this is a FASTER ROUTE TO THE SAME DATA,
# not a second opinion: the vocabulary still matches `genre-families.txt`, and the
# page cannot start disagreeing with the row that opened it.
#
# WHY IT IS ONLY HERE, AND MUST NOT BE PROMOTED TO LIST ROWS. Coverage on this
# plugin's actual population is ~2% (1 of 60 Album-type releases off a live All
# Releases feed) because the dataset lags brand-new releases, and there is NO
# artist-genre route to fall back on — which is where 47% of the feed's coverage
# lives. The ListenBrainz bulk path stays the feed's genre backend; see the
# hosted-API notes at the top of this file and docs/genre-sources-investigation.md.
# What this tier does buy: on the detail page the call it precedes is ONE
# PUBLIC-MB-THROTTLED request per page open for every user without a mirror, and
# the hit rate is much higher there than on a fresh feed — the same endpoint
# measured 57% against albums people actually listen to, which is exactly the
# Trending Albums population that also lands on this page.
#
# NAME-KEYED, AND IT CANNOT BE DISAMBIGUATED. `?mbid=` is documented as an
# override and is IGNORED on this route — verified live: a deliberately bogus mbid
# on Chorus/Mildlife returns the identical list as no mbid at all. So our
# release-group MBID is deliberately NOT sent; it would buy nothing and imply a
# precision the answer does not have. Two same-titled albums by one artist can
# collide; the blast radius is one line on one page, behind two better tiers.
#
# ALBUM FIRST, THEN ARTIST in the path. Reversed it still returns plausible
# results, which is exactly how a subtly wrong integration ships — the log line
# below prints them in order so a transposition is visible rather than silent.
# ---------------------------------------------------------------------------
# REMOVED 0.9.185 — see the tombstone above `_parseGenres`' neighbour further up
# (where getReleaseGroupGenres used to sit) for the measurements and the reasoning.
# The short version: the detail page peeks the store, the store has already been
# filled by the ladder AND (for Trending Albums) by the trending build's own
# `inc=release_group tag` pass, so this only ever ran where every MB-derived
# source was already empty — and it is MB-derived. 0 of 40 on the live feed.
#
# `_hostedGenreNames` went with it: the 0.9.173 note kept that helper expressly
# because THIS sub still needed the lowercasing. Nothing needs it now.

# Top genre names (most-voted first, max 5) from a MusicBrainz entity response.
sub _parseGenres {
    my ($data) = @_;
    return [] unless ref $data->{genres} eq 'ARRAY';
    my @g = sort { ($b->{count} // 0) <=> ($a->{count} // 0) } @{ $data->{genres} };
    @g = @g[0 .. 4] if @g > 5;
    return [ grep { defined && length } map { $_->{name} } @g ];
}

# ---------------------------------------------------------------------------
# `getArtistBio` (Last.fm artist.getinfo) LIVED HERE — removed 0.9.186, with the
# `lbf:bio:` key family and the `_setText`/`_getText` pair that existed for it.
#
# It was the detail page's bio fallback for users without the MAI plugin, and
# Simon's call was that it is not worth having: **MAI's own bio sources include
# Last.fm**, so this was a second route to a well MAI had already drawn from, and
# it bought a bio for a population that has never been offered an artist PHOTO
# either (that has been MAI-only since the Artist section was written). No MAI now
# means no bio, and the section falls back to the artist name + Block-artist row.
#
# `_cleanBio` and `BIO_MAX` STAY — the MAI path runs its bio through them
# (`Browse::_fetchArtistInfo`), which is also why `_cleanBio`'s HTML handling is
# tuned for MAI's runtime output rather than for Last.fm's.
# ---------------------------------------------------------------------------
use constant BIO_MAX => 20000;   # pure DoS guard; never trims a real bio (no visible cap)

# Strip Last.fm's trailing "Read more on Last.fm" link + any HTML and decode the
# common entities, but KEEP the full text (and paragraph breaks) so Material's
# "more" expander reveals the whole biography. Only caps at BIO_MAX as a safety net.
sub _cleanBio {
    my ($s) = @_;
    return '' unless defined $s && length $s;
    # LINKS: DELETE ONLY WHERE THE LINK IS THE WHOLE POINT, UNWRAP EVERYWHERE ELSE.
    # This started as a blanket `<a\b[^>]*>.*?</a>` delete, written for Last.fm's
    # single trailing "Read more on Last.fm". 0.9.157 then established that MAI's
    # runtime input is Wikipedia-derived HTML, which is full of INLINE links inside
    # sentences — so the blanket delete silently removed words mid-sentence: "The
    # band signed to <a>Merge Records</a> in 1994" became "The band signed to in
    # 1994". The <(li|p)></\1> cleanup below existed precisely because this rule
    # empties elements; that is the same damage showing up at block level.
    #
    # Order matters, and the first two rules preserve the existing output exactly:
    #   1. a list item that is NOTHING BUT a link is a link list (MAI's "More
    #      online sources"), so the item goes — leaving that heading trailing over
    #      nothing, which Browse::_bioParagraphs then drops, as it always has;
    #   2. Last.fm's trailing link goes, matched on its own text;
    #   3. anything still standing is an inline link inside a sentence. Unwrap it.
    # [^<]* IS LOAD-BEARING, and `.*?` was the bug: laziness only sets the ORDER
    # the engine tries lengths in, it does not stop it growing. On an item that is
    # a link PLUS text ("<li><a>Album One</a> (1994)</li>") the first </a> is not
    # followed by </li>, so the engine backtracked, crossed </li><li> under /s and
    # matched a LATER item's </a> — deleting every item in between. A Wikipedia
    # discography list (linked title + year) collapsed to an empty <ul>. [^<]*
    # cannot reach a tag boundary, so the match stays inside one item; a link-only
    # item has no inner markup by definition, which is exactly what it describes.
    $s =~ s{<li\b[^>]*>\s*<a\b[^>]*>[^<]*</a>\s*</li>}{}gis;
    $s =~ s{<a\b[^>]*>\s*Read more on Last\.fm\s*</a>}{}gis;
    $s =~ s{<a\b[^>]*>(.*?)</a>}{$1}gis;
    # Any element the removals above emptied would otherwise become a bare bullet
    # or a blank paragraph.
    $s =~ s{<(li|p)[^>]*>\s*</\1>}{}gis;
    $s =~ s/\s*\.?\s*User-contributed text is available.*$//is;  # Last.fm CC licence boilerplate
    # STRUCTURE FIRST, TAGS SECOND. At runtime MAI hands us HTML, not the plain
    # text the CLI shows: its isWebBrowser() test is true for a Material client, so
    # the bio arrives as <p>/<h2>/<b> markup (verified live —
    # `musicartistinfo biography html:1 artist:<n>`). Until 0.9.157 the only break
    # rule here was </p><p> ADJACENCY, so a `</p><h2>Description and history</h2><p>`
    # never matched and the heading was flattened to a space in the middle of the
    # body. That is why no section titles ever appeared, however they were styled.
    #
    # A heading becomes a SETEXT block ("title\n------"), which is exactly the shape
    # Browse::_bioBlocks already detects and is tested for — one code path for MAI's
    # HTML and for the plain-text renders that carry real underlines.
    $s =~ s{<h[1-6][^>]*>\s*(.*?)\s*</h[1-6]>}{"\n\n$1\n" . ('-' x 10) . "\n\n"}gise;
    # \b IS LOAD-BEARING: without it `<li[^>]*>` also matches the `<link rel=…>`
    # stylesheet MAI prepends to its HTML bio, turning it into a stray bullet that
    # then swallowed the opening paragraph.
    $s =~ s{<li\b[^>]*>}{\n* }gis;     # list items -> the bullet _bioBullet knows
    $s =~ s{</(?:p|div|ul|ol|li|tr|blockquote|section)>}{\n\n}gis;
    $s =~ s{<br\s*/?>}{\n}gis;
    # Remaining tags are INLINE (<b>, <i>, <span>, the <link> MAI prepends), so they
    # vanish rather than becoming a space — a space here is what produced the
    # "Lambchop , originally Posterchild ," spacing in the field screenshots.
    $s =~ s/<[^>]+>//g;
    $s =~ s/&amp;/&/gi;
    $s =~ s/&lt;/</gi;
    $s =~ s/&gt;/>/gi;
    $s =~ s/&quot;/"/gi;
    $s =~ s/&#0?39;|&apos;/'/gi;
    $s =~ s/&[a-z]+;/ /gi;             # any remaining named entity
    $s =~ s/[ \t]+/ /g;                # collapse spaces/tabs, but keep newlines
    $s =~ s/ *\n */\n/g;
    $s =~ s/^[*\x{2022}]\s*$//gm;      # a marker whose item emptied above
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
# ---------------------------------------------------------------------------
# Cache-ONLY read of the Last.fm tags for an artist/album — never makes a request.
# Mirrors peekArtistSort. The list-render path uses this so browsing can never pay
# for a per-artist Last.fm call: the background warm populates the cache, the render
# just reads whatever is already there. Returns an arrayref (possibly empty).
#
# MEMOED, and this is the one peek that really needs it. It is tier 4 of
# _genresFor, which the render path calls SEVERAL times for the same release in a
# single walk — once to build the row (_familyFor), once to bucket it for the genre
# filter, once more for the picker's counts — and every one of those was a separate
# SQLite read. On a feed of a few hundred releases with a Last.fm key set, that is
# hundreds of blocking reads inside the browse callback: exactly the shape 0.9.130
# moved the release-group metadata scan off the render path to avoid. The tags
# themselves are written only by the nightly warm, so an in-process copy can't be
# meaningfully stale within one interaction. Bounded so a long browse can't grow it
# without limit; the whole entry is cheap (a handful of short strings).
use constant LFM_MEMO_TTL => 60;
use constant LFM_MEMO_MAX => 2000;
my %LFM_MEMO;                            # lfm key => [ expiry, $tags ]

# Same two-age rule as every other tier: a populated answer is near-immutable, an
# empty one is re-asked on a fraction of that, because Last.fm gains tags over
# time and "nothing today" must not become a permanent verdict.
sub _lfmFresh {
    my ($row) = @_;
    return _answerFresh($row, 'n_tags', 'fetched_at', LFM_FOUND_TTL, LFM_EMPTY_TTL);
}

# The tier's key, in ONE place. It is artist+ALBUM because the rung asks
# album.gettoptags before falling back to artist.gettoptags, so the answer is
# release-specific. Octets, not characters: a CJK title with the utf8 flag set used
# to reach Digest::MD5 through the old cache and die "Wide character in subroutine
# entry", taking the whole detail request with it.
sub _lfmKey {
    my ($artist, $album) = @_;
    utf8::encode($artist)               if utf8::is_utf8($artist);
    utf8::encode($album) if defined $album && utf8::is_utf8($album);
    return lc("$artist|" . ($album // ''));
}

sub peekLastfmTags {
    my ($class, $artist, $album) = @_;
    return [] unless length($artist // '');
    my $key = _lfmKey($artist, $album);

    my $now = time();
    if (my $e = $LFM_MEMO{$key}) {
        return $e->[1] if $e->[0] >= $now;
    }
    # IN THE STORE, not Slim::Utils::Cache. This was the last genre tier still
    # sitting in the store this rework exists to leave — so a Last.fm answer that
    # cost a paced, one-per-second warm could be evicted, and was subject to the
    # 30-day TTL boundary besides.
    my $row  = Plugins::ListenBrainzFreshReleases::DB::lfmGet($key);
    my $tags = _lfmFresh($row) ? ($row->{tags} || []) : [];
    # Cheaper than an LRU and bounded: at the cap, drop what has expired, and if
    # that frees nothing (every entry still live) clear the lot and start again.
    if (scalar keys %LFM_MEMO >= LFM_MEMO_MAX) {
        delete @LFM_MEMO{ grep { $LFM_MEMO{$_}[0] < $now } keys %LFM_MEMO };
        %LFM_MEMO = () if scalar keys %LFM_MEMO >= LFM_MEMO_MAX;
    }
    $LFM_MEMO{$key} = [ $now + LFM_MEMO_TTL, $tags ];
    return $tags;
}

sub getLastfmTags {
    my ($class, $artist, $album, $onDone, $onError) = @_;

    my $key = $prefs->get('lastfm_api_key');
    unless ($key && length($artist // '')) {
        $onDone->([]);
        return;
    }

    # Octets, not characters — see _lfmKey. _lastfmCall percent-encodes per byte,
    # so the request needs them in this form too.
    utf8::encode($artist)               if utf8::is_utf8($artist);
    utf8::encode($album) if defined $album && utf8::is_utf8($album);

    my $lfmKey = _lfmKey($artist, $album);
    my $row    = Plugins::ListenBrainzFreshReleases::DB::lfmGet($lfmKey);
    if (_lfmFresh($row)) {
        $onDone->($row->{tags} || []);
        return;
    }

    my $finish = sub {
        my $tags = shift || [];
        # An EMPTY answer is STORED, and re-asked sooner rather than never. Last.fm
        # gains tags over time, so "nothing today" must not become permanent — but
        # without storing it at all, every artist Last.fm has never heard of would be
        # re-asked on every pass, and this rung is paced at one request per second.
        Plugins::ListenBrainzFreshReleases::DB::lfmPut($lfmKey, $tags)
            or $log->warn("Last.fm tag store write failed for $lfmKey");
        delete $LFM_MEMO{$lfmKey};
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
# Similar artists from the hosted LMS-community API (/artist/<name>/relatedArtists).
# Sits between ListenBrainz's similar-artists dataset and the Last.fm fallback in
# the DSTM radio ladder.
#
# THIS IS THE BIGGEST WIN of the hosted-API work, for two reasons:
#
#  1. NO API KEY. The Last.fm rung below needs a user-supplied key, which most
#     installs do not have — so today, when ListenBrainz has nothing for a seed
#     (a known gap), the radio simply falls through to generic recommendations
#     for those users. This rung works everywhere.
#  2. EVERY ENTRY CARRIES AN MBID. Measured live 2026-08-12: 25 similar artists
#     for Radiohead, 25 of them with an MBID. Last.fm returns NAMES with spotty
#     mbids, so DSTM::_resolveArtistMbids has to resolve the misses one by one —
#     on public MusicBrainz that is up to 25 throttled lookups, ~25s, before the
#     radio can play anything. Because this returns the SAME
#     { name, artist_mbid, score } shape, it drops straight into that existing
#     pump, whose inline-MBID short-circuit then means ZERO MusicBrainz lookups.
#
# Underlying data is last.fm "similar", the same flavour as the rung below — NOT
# MusicBrainz "member of band". Cached lbf:hsimilar:1:* (found = SIMILAR_TTL,
# empty = LFM_EMPTY_TTL, matching the Last.fm rung).
# ---------------------------------------------------------------------------
sub getSimilarArtistsHosted {
    my ($class, $artist, $onDone, $onError) = @_;
    $onDone  ||= sub {};
    $onError ||= sub { $onDone->([]) };

    unless (length($artist // '')) { $onDone->([]); return; }

    # Octets — safe md5 cache key, same rule as every other free-text key here.
    my $key = $artist;
    utf8::encode($key) if utf8::is_utf8($key);
    my $cacheKey = Plugins::ListenBrainzFreshReleases::DB::kver("lbf:hsimilar:") . lc $key;
    if (my $cached = $cache->get($cacheKey)) { $onDone->($cached); return; }

    _hostedGet('artist/' . _hostedSeg($artist) . '/relatedArtists', sub {
        my ($data) = @_;
        my $list = ref $data->{similarArtists} eq 'ARRAY' ? $data->{similarArtists}
                 : ref $data->{relatedArtists} eq 'ARRAY' ? $data->{relatedArtists}
                 : [];
        my @out;
        for my $r (@$list) {
            next unless ref $r eq 'HASH';
            # NB the field is `artist`, not `name` — the shape differs from
            # Last.fm's here even though what we emit deliberately does not.
            my $name = $r->{artist} // $r->{name};
            next unless defined $name && length $name;
            push @out, {
                name        => $name,
                artist_mbid => ($r->{mbid} && $r->{mbid} =~ /^[0-9a-f-]{36}$/i) ? lc $r->{mbid} : '',
                score       => $r->{match} // 0,
            };
        }
        eval { $cache->set($cacheKey, \@out, @out ? SIMILAR_TTL : LFM_EMPTY_TTL); 1 }
            or $log->warn("hosted-similar cache set failed: $@");
        $log->info("Hosted similar artists for '$artist': " . scalar(@out));
        $onDone->(\@out);
    }, sub { $onError->([]) });
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
    if (ref $rel eq 'HASH') {
        return CAA_BASE_URL . $rel->{caa_release_mbid} . '/front-250'
            if $rel->{caa_release_mbid};
        # MuSpy items carry only a release-GROUP MBID — CAA serves group art at a
        # different path. (No has-art signal exists for a group, so this may 404
        # for the rare art-less release group; the image proxy degrades to a
        # placeholder. Overlaps with an LB copy are resolved in _dedupeReleases,
        # which prefers the entry that has cover art — i.e. the richer LB one.)
        return CAA_RG_BASE_URL . $rel->{caa_release_group_mbid} . '/front-250'
            if $rel->{caa_release_group_mbid};
        return undef;
    }

    my $mbid = $rel;
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

# ---------------------------------------------------------------------------
# Read-only accessors for the connectivity diagnostic (Diag.pm).
#
# The point is that Diag probes the SAME endpoints this module actually uses,
# resolved by the SAME rules — mbBase in particular hides whether the user is on
# the public API, a hand-configured mirror or an auto-detected one, and a
# diagnostic that duplicated any of that could report on a base the plugin does
# not use. So Diag asks here rather than reading prefs or restating constants.
#
# These MUST stay below every `use constant` above: constants are installed at
# BEGIN time, so a bareword referenced earlier in the file than its declaration
# fails to compile under strict subs.
# ---------------------------------------------------------------------------
sub baseUrl     { BASE_URL }
sub labsUrl     { LABS_URL }
sub caaBaseUrl  { CAA_BASE_URL }
sub lastfmUrl   { LASTFM_BASE_URL }
sub muspyUrl    { MUSPY_BASE_URL }
sub similarAlgo { SIMILAR_ALGO }
sub mbProbeMbid { MB_PROBE_MBID }
sub mbProbeName { MB_PROBE_NAME }
sub mbBase      { _mbBase() }
sub mbIsPublic  { _mbThrottled() }
sub hostedUrl   { HOSTED_BASE_URL }
# The plugin-id header, exposed so Diag's probe sends exactly what the real calls
# send rather than a hand-copied literal that could drift from _hostedGet.
sub hostedHeaders {
    return Slim::Utils::Misc->can('apiHeaders')
        ? { Slim::Utils::Misc::apiHeaders(PLUGIN_PACKAGE) }
        : { 'X-LMS-Plugin-ID' => PLUGIN_PACKAGE };
}

1;
