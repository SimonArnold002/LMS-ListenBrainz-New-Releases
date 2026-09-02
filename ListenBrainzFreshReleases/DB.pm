package Plugins::ListenBrainzFreshReleases::DB;

# PLUGIN-OWNED STORAGE. One SQLite file holding everything this plugin used to
# keep in Slim::Utils::Cache, split into three tiers by how it must be
# invalidated rather than by what it contains.
#
# WHY THIS EXISTS AT ALL — two live defects, one structural problem.
#
#   1. THE 30-DAY BOUNDARY. Slim::Utils::DbCache::_canonicalize_expiration_time:
#
#          # "If value is less than 60*60*24*30 (30 days), time is assumed to be
#          # relative from the present. If larger, it's considered an absolute
#          # Unix time."
#          if ( $expiry <= 2592000 && $expiry > -1 ) { $expiry += time(); }
#
#      So a 90-day TTL is stored as an ABSOLUTE epoch of 1 April 1970 — expired
#      before the write returns. `set` returns 1, nothing dies, nothing warns.
#      RECMETA_TTL and AGEN_FOUND_TTL were both 90 days, and both are applied to
#      the entries WORTH keeping (a release group WITH a date, an artist WITH
#      genres) while the worthless ones got a valid 1-day TTL. The result is that
#      the ListenBrainz genre tiers have never once served a dated release, and
#      the background top-up re-fetched the same releases on every visit.
#      It cost the sibling Pitchfork plugin five releases of misdiagnosis first.
#
#      In `kv`, `expires_at` IS AN ABSOLUTE EPOCH, ALWAYS, computed here, with 0
#      meaning never. There is no relative/absolute guessing, so there is no
#      boundary, and no duration exists that silently means "already expired" —
#      the defect is not merely fixed, it is INEXPRESSIBLE. On the facts tables
#      it does not even arise: they store `fetched_at` and staleness is a policy
#      applied in Perl, so nothing hands a duration to anyone.
#
#   2. THE FEED WAS RE-MINTED AT EVERY LOCAL MIDNIGHT. `getFreshReleasesAll`
#      stored the whole ~2,900-release feed as ONE blob under a key containing
#      today's date, so the entire structure was re-fetched and re-frozen every
#      night, and again on any change to the window/past/future prefs — even
#      though most of those releases had not moved for weeks. `feed_day` turns
#      coverage into a QUERY, so a window change costs only the days it adds.
#
#   3. THREE THINGS IN THE CACHE WERE NOT CACHES. `lbf:bcmatch:` (hand-curated
#      Bandcamp pins with no automatic repopulation), `lbf:follow:accum:` (builds
#      forward from first capture; unrecoverable once events leave ListenBrainz's
#      75-event window) and `lbf:artistsort:` (re-derivable only at 100 artists a
#      pass, serially). They get TABLES, so the dev-build wipe can be a single
#      unconditional `DELETE FROM kv` with no allowlist to get wrong.
#
# THE RULE THAT MAKES THE TIERS SELF-ENFORCING:
#
#     IF IT IS IN `kv` IT IS DISPOSABLE. IF IT MUST SURVIVE, IT NEEDS A TABLE.
#
#   BASE    release, feed_member, feed_day, feed_meta, bandcamp_pin, follow_item
#           invalidated by a BASE_VERSION bump only; never wiped by a dev build.
#   FACTS   release_group, recording, artist
#           invalidated per table by its own *_FACT_VERSION; a dev build clears
#           only the genre columns, so years, types, MBIDs and sort-names survive
#           and a genre change never re-inflicts a multi-day artist-sort
#           reconvergence.
#   DERIVED kv — match decisions, resolved lists, text, markers. Wiped wholesale.
#
# A CORRECTION TO CARRY INTO THE REST OF THIS WORK: a naive per-row port of the
# Pitchfork plugin's DB would likely be SLOWER TO READ than today's single blob —
# 2,900 DBI fetches and thaws against one Storable::thaw in C. The win is that the
# base stops being re-minted and the window becomes queryable, NOT that row reads
# are faster. Lose that distinction and this ships a regression.
#
# Modelled on Plugins::PitchforkReviews::DB (same dbh shape, WAL, `$broken` latch,
# degrade-never-die, the same `{ v => … }` kv wrapper) and diverging deliberately
# in four places, each noted at its site: a frozen `payload` blob plus mirrored
# query columns rather than an enumerated column set; membership keyed on identity
# rather than position; `PRAGMA user_version` migrations rather than
# CREATE-TABLE-IF-NOT-EXISTS only; and explicit SQL_BLOB binding.

use strict;
use warnings;

use DBI;
use Storable ();
use Time::HiRes ();   # the chunked ingest schedules its yields on a hi-res timer

use Slim::Utils::Log;
use Slim::Utils::Prefs;

my $log = Slim::Utils::Log::logger('plugin.listenbrainzfreshreleases');

# The ONLY plugin pref this module touches, and it is here rather than in `kv`
# for the reason set out at IMPORT_DEADLINE_PREF: the dev-build wipe is one
# unconditional `DELETE FROM kv`, so a deadline stored there resets itself.
my $prefs = preferences('plugin.listenbrainzfreshreleases');

my $dbh;      # lazily-opened handle
my $broken;   # latched once the DB cannot be opened, so we complain once and degrade

# Bumped when _migrate gains a step. `PRAGMA user_version` records what a file has
# been migrated TO, which is what lets a step ADD A COLUMN later — the thing PFR's
# CREATE TABLE IF NOT EXISTS-only migration cannot do, and the reason its schema is
# frozen at whatever the first release shipped.
use constant SCHEMA_VERSION => 5;

sub _path {
    my $dir = preferences('server')->get('cachedir') || '/tmp';
    return "$dir/listenbrainzfreshreleases.db";
}

sub dbh {
    return undef if $broken;
    return $dbh if $dbh && eval { $dbh->ping };

    my $path = _path();
    $dbh = eval {
        my $h = DBI->connect("dbi:SQLite:dbname=$path", '', '', {
            RaiseError     => 1,
            PrintError     => 0,
            AutoCommit     => 1,
            # Load-bearing: it keeps the character/octet boundary inside
            # DBD::SQLite instead of leaving it to callers. Every blob written
            # here is bound SQL_BLOB explicitly so this cannot touch frozen bytes
            # — see _bindBlob.
            sqlite_unicode => 1,
        });
        $h->do('PRAGMA journal_mode=WAL');
        _migrate($h);
        $h;
    };

    unless ($dbh) {
        # DEGRADE, NEVER DIE. Without the DB the plugin re-fetches exactly as it
        # did before this module existed. A storage layer that can take the whole
        # plugin down with it would be worse than the bugs it replaces.
        $broken = 1;
        $log->error("LBF store unavailable at $path ($@) — falling back to re-fetching");
        return undef;
    }

    $log->info("LBF store ready at $path");
    return $dbh;
}

# ---------------------------------------------------------------------------
# Schema
#
# A THROWING MIGRATION LEAVES user_version UNTOUCHED and latches $broken via the
# eval in dbh(), so a half-applied schema is never recorded as complete and the
# next start retries from the same step rather than skipping it.
# ---------------------------------------------------------------------------
sub _migrate {
    my ($h) = @_;

    my ($have) = $h->selectrow_array('PRAGMA user_version');
    $have ||= 0;
    return if $have >= SCHEMA_VERSION;

    if ($have < 1) {
        _migrate_1($h);
        $h->do('PRAGMA user_version = 1');
    }

    if ($have < 2) {
        _migrate_2($h);
        $h->do('PRAGMA user_version = 2');
    }

    if ($have < 3) {
        _migrate_3($h);
        $h->do('PRAGMA user_version = 3');
    }

    if ($have < 4) {
        _migrate_4($h);
        $h->do('PRAGMA user_version = 4');
    }

    if ($have < 5) {
        _migrate_5($h);
        $h->do('PRAGMA user_version = 5');
    }

    # Future steps go here as `if ($have < N) { …; PRAGMA user_version = N }`.
    # ALTER TABLE ADD COLUMN is available to them; that is the whole point of
    # recording a version rather than inferring the schema from what exists.

    return;
}

# COUNTS BESIDE THE FROZEN GENRE LISTS, so the store can be ASKED how genre
# coverage is doing.
#
# WHY THIS EXISTS: `cachestats` reported `rg_genres` as the number of rows with
# `genres_src <> ''`, and NOTHING writes that column on release_group — so the
# figure was 0 by construction. On `artist` only the hosted tier and the
# MusicBrainz mirror path set it, so ListenBrainz's own artist tags were invisible
# there too. The one instrument for diagnosing "genres are not populating" was
# reporting on a column three of the four writers never touch, and read 0 on a
# perfectly healthy store.
#
# A frozen blob cannot be counted in SQL, so the LENGTH is mirrored into an
# integer at write time. `-1` means NEVER ASKED, `0` means asked and the answer
# was genuinely "none" — a distinction that matters here, because an empty list is
# a real answer from both ListenBrainz and the hosted API, and re-asking for the
# artists who will never have genres is exactly the waste the store exists to stop.
sub _migrate_2 {
    my ($h) = @_;

    # Each ALTER is guarded SEPARATELY so this step is re-runnable. SQLite has no
    # ADD COLUMN IF NOT EXISTS, and an unguarded duplicate-column error would abort
    # the step — leaving user_version untouched (correct) but also leaving the
    # BACK-FILL below unreachable for ever, on precisely the databases that had
    # already got the columns. A migration that cannot be retried is worse than one
    # that does nothing.
    for my $ddl (
        'ALTER TABLE artist        ADD COLUMN n_genres  INTEGER NOT NULL DEFAULT -1',
        'ALTER TABLE release_group ADD COLUMN n_genres  INTEGER NOT NULL DEFAULT -1',
        'ALTER TABLE release_group ADD COLUMN n_agenres INTEGER NOT NULL DEFAULT -1',
    ) {
        eval { $h->do($ddl); 1 } or $log->info("store: migration 2 column already present");
    }

    # Existing rows are back-filled from what they already hold, so the counts are
    # true for a store that predates this column rather than only for new writes —
    # otherwise the first report after an upgrade would understate coverage exactly
    # as the old stat did, and look like the very bug being diagnosed.
    for my $t (['artist', ['genres']], ['release_group', ['genres', 'agenres']]) {
        my ($table, $cols) = @$t;
        my $key = $table eq 'artist' ? 'artist_key' : 'rg_mbid';
        for my $col (@$cols) {
            my $rows = eval {
                $h->selectall_arrayref("SELECT $key AS k, $col AS v FROM $table WHERE $col IS NOT NULL",
                                       { Slice => {} })
            } || [];
            for my $r (@$rows) {
                my (undef, $v) = _thaw($r->{v}, "$table/$col backfill");
                next unless ref $v eq 'ARRAY';
                $h->do("UPDATE $table SET n_$col = ? WHERE $key = ?", undef, scalar(@$v), $r->{k});
            }
        }
    }
    return;
}

# ONE COLUMN PER TIER, ONE TIMESTAMP PER ANSWER. This is the migration that makes
# "nothing overwrites itself" a property of the schema rather than a rule everybody
# has to remember, and it closes three defects that all have the same shape.
#
# 1. ONE `fetched_at` SERVED A ROW HOLDING SEVERAL INDEPENDENT ANSWERS. `_factPut`
#    stamps it on every write, and an `artist` row is written by the sort warm, the
#    hosted genre tier and the mirror genre tier. So the sort warm refreshing a
#    sort-name RE-AGED the genre answer beside it, and could hold an empty or stale
#    genre answer alive indefinitely without ever asking about genres. Freshness was
#    judged per ROW; the data is per ANSWER.
#
# 2. TWO TIERS SHARED `artist.genres`, discriminated by `genres_src`, and
#    `_artistGenresFresh` returned 0 the moment the src did not match. With both
#    tiers live: hosted sees 'mb', calls it stale, refetches, writes 'hosted'; the
#    mirror sees 'hosted', calls it stale, refetches, writes 'mb'. Every pass, for
#    ever, each destroying the other's answer. It is dormant only where no local
#    MusicBrainz mirror exists. Separate columns make the ping-pong INEXPRESSIBLE —
#    a tier now reads and writes its own column and cannot see, still less clobber,
#    anybody else's.
#
# 3. LAST.FM WAS NOT IN THE STORE AT ALL — it sat in `Slim::Utils::Cache` under
#    `lbf:lfm:`, i.e. the store this whole rework exists to get off, on a TTL. It is
#    keyed by artist+ALBUM (the rung asks album.gettoptags before falling back to
#    artist.gettoptags), so it does not belong on the artist row; it gets its own
#    table, keyed the way the rung actually keys it.
#
# The legacy `genres` / `genres_src` / `n_genres` columns on `artist` are left in
# place and simply stop being written. SQLite's DROP COLUMN is too new to rely on,
# and a back-fill that reads them is the only thing that stops this migration
# throwing away every genre already collected.
sub _migrate_3 {
    my ($h) = @_;

    # Guarded individually, so the step is re-runnable — see _migrate_2 for why
    # that matters more than it looks.
    for my $ddl (
        'ALTER TABLE artist ADD COLUMN hosted_genres    BLOB',
        'ALTER TABLE artist ADD COLUMN n_hosted_genres  INTEGER NOT NULL DEFAULT -1',
        'ALTER TABLE artist ADD COLUMN hosted_genres_at INTEGER NOT NULL DEFAULT 0',
        'ALTER TABLE artist ADD COLUMN mb_genres        BLOB',
        'ALTER TABLE artist ADD COLUMN n_mb_genres      INTEGER NOT NULL DEFAULT -1',
        'ALTER TABLE artist ADD COLUMN mb_genres_at     INTEGER NOT NULL DEFAULT 0',
        'ALTER TABLE artist ADD COLUMN sort_at          INTEGER NOT NULL DEFAULT 0',
        'ALTER TABLE release_group ADD COLUMN genres_at INTEGER NOT NULL DEFAULT 0',
    ) {
        eval { $h->do($ddl); 1 } or $log->info("store: migration 3 column already present");
    }

    $h->do(<<'SQL');
CREATE TABLE IF NOT EXISTS lastfm_tags (
    lfm_key    TEXT PRIMARY KEY,
    tags       BLOB,
    n_tags     INTEGER NOT NULL DEFAULT -1,
    fetched_at INTEGER NOT NULL DEFAULT 0
)
SQL

    # BACK-FILL, and it is not optional: without it every artist genre already
    # collected would read as never-asked and the first run after the upgrade would
    # look exactly like the regression this all started with. Each legacy row is
    # filed under the tier that actually answered it, and its stamp is taken from
    # the row's old `fetched_at` — the best evidence available of when that answer
    # was really obtained.
    my $rows = eval {
        $h->selectall_arrayref(
            'SELECT artist_key AS k, genres AS g, genres_src AS src, n_genres AS n,
                    sort_name AS sn, fetched_at AS ts
               FROM artist', { Slice => {} })
    } || [];
    for my $r (@$rows) {
        my $src = ($r->{src} // '') eq 'hosted' ? 'hosted'
                : ($r->{src} // '') eq 'mb'     ? 'mb'
                :                                 '';
        if ($src && defined $r->{g}) {
            my (undef, $v) = _thaw($r->{g}, "artist/$r->{k} genres backfill");
            if (ref $v eq 'ARRAY') {
                _execBlob($h,
                    "UPDATE artist SET ${src}_genres = ?, n_${src}_genres = ?, ${src}_genres_at = ?
                      WHERE artist_key = ?",
                    [1], _freeze($v), scalar(@$v), ($r->{ts} || time()), $r->{k});
            }
        }
        # A sort-name that is already present was fetched at the row's stamp too.
        $h->do('UPDATE artist SET sort_at = ? WHERE artist_key = ?', undef,
               ($r->{ts} || time()), $r->{k})
            if length($r->{sn} // '');
    }

    # A release group that has been ASKED about genres (n_genres >= 0, set by
    # migration 2's back-fill) had that answer at its row stamp. One left at -1 is
    # genuinely never-asked and keeps a zero stamp, so it reads as stale and gets
    # asked — which is what we want.
    eval {
        $h->do('UPDATE release_group SET genres_at = fetched_at WHERE n_genres >= 0');
        1;
    } or $log->info("store: migration 3 release_group stamp back-fill skipped");

    return;
}

# AN ARTIST-LEVEL ANSWER BELONGS ON THE ARTIST, and until schema 4 two of the three
# rungs that produce one filed it under a RELEASE-specific key. That is why the feed
# could never be prepared, and why the per-pass caps bit so hard: the allowance was
# not small, it was being spent re-buying answers the store already owned.
#
#   • ListenBrainz's `tag.artist` — the CREDITED ARTIST's genres — was written to
#     `release_group.agenres`. So an artist's tags learned from one release did
#     nothing for that artist's other releases, and any release whose group LB had
#     nothing for stayed bare even when a sibling release had already told us.
#   • Last.fm was worse, because the code's own comment claimed the opposite ("One
#     call covers every release by that artist in the feed"). `_warmLastfm` dedupes
#     by ARTIST and then stored under the FIRST release's album, while
#     `_lastfmGenres` read back with each release's OWN album — so of an artist's
#     three releases, only the one that happened to seed the warm could ever read
#     the answer, and the other two consumed the allowance again next night.
#
# Both now write the artist row. `lastfm_tags` STAYS, and is not redundant: the
# release detail page asks album.gettoptags first and that answer is genuinely
# album-specific, so it keeps its own album-keyed table. The list rows read the
# artist-level answer, which is the one that generalises.
sub _migrate_4 {
    my ($h) = @_;

    for my $ddl (
        'ALTER TABLE artist ADD COLUMN lb_genres        BLOB',
        'ALTER TABLE artist ADD COLUMN n_lb_genres      INTEGER NOT NULL DEFAULT -1',
        'ALTER TABLE artist ADD COLUMN lb_genres_at     INTEGER NOT NULL DEFAULT 0',
        'ALTER TABLE artist ADD COLUMN lastfm_genres    BLOB',
        'ALTER TABLE artist ADD COLUMN n_lastfm_genres  INTEGER NOT NULL DEFAULT -1',
        'ALTER TABLE artist ADD COLUMN lastfm_genres_at INTEGER NOT NULL DEFAULT 0',
    ) {
        eval { $h->do($ddl); 1 } or $log->info("store: migration 4 column already present");
    }

    # NO BACK-FILL — and that is a decision, not an omission. Both sources are keyed
    # in a space this file does not own and must not guess at:
    #
    #   • `release_group.agenres` records nowhere WHICH artist's tags those are. It
    #     is keyed by release group; the association lives in the feed row, which the
    #     store never sees.
    #   • `lastfm_tags` keys are `lc("artist|album")`, but the artist row's key is
    #     `'n:' . Browse::_norm($name)` — a DIFFERENT fold (diacritics, punctuation,
    #     the whole %FOLD table). Reconstructing it here would need Browse loaded
    #     from DB.pm, which inverts the layering and is the load-order trap that made
    #     0.9.166 unloadable. Approximating it with `lc` would file answers under
    #     keys nothing ever reads — silently, and looking exactly like the coverage
    #     loss this rework exists to end.
    #
    # Refilling is cheap and correct instead: the ListenBrainz artist tags ride a
    # bulk request the plugin already makes for dates, so rebuilding them costs
    # nothing extra, and the next warm writes both rungs through the same key
    # builder the readers use.
    return;
}

# THE RELEASE DETAIL PAGE STOPS THROWING ITS ANSWER AWAY (0.9.173).
#
# The bug this closes, from docs/feed-findings-2026-08-14.md §5.1: opening an album
# resolves a genre through the hosted album route or MusicBrainz, shows it, and
# discards it. Both wrote only to Slim::Utils::Cache — `lbf:hgenres:` keyed on
# album+artist text, `lbf:rggenres:<mbid>` keyed on the release group. The second
# is keyed on the ROW'S OWN KEY, so the list had the answer sitting one table away
# and could not see it. That is a real cause of the bare rows on a newly-admitted
# week: the detail page fetches live, the list peeks, and nothing joined them up.
#
# WHY A NEW COLUMN RATHER THAN `genres`. `release_group.genres` and `.agenres` are
# ListenBrainz's, and they share ONE `genres_at` because one request answers both.
# Filing a MusicBrainz or hosted answer into `genres` would be a write touching
# something it does not own — the exact defect class schema 3 exists to make
# inexpressible, and it would also re-date LB's answer beside it. So this tier
# gets its own column and its own stamp, like every other tier.
#
# §8 of that document predicted this column would be "dead on arrival" because
# step 4 would remove the calls that feed it. That turned out to be wrong on both
# halves: the hosted ALBUM route is KEPT (measured rich on the Trending Albums
# population that shares this page), and the MusicBrainz release-group call is
# kept as the unconditional tier behind it. Both still run, so the column is fed.
sub _migrate_5 {
    my ($h) = @_;

    for my $ddl (
        'ALTER TABLE release_group ADD COLUMN detail_genres    BLOB',
        'ALTER TABLE release_group ADD COLUMN n_detail_genres  INTEGER NOT NULL DEFAULT -1',
        'ALTER TABLE release_group ADD COLUMN detail_genres_at INTEGER NOT NULL DEFAULT 0',
    ) {
        eval { $h->do($ddl); 1 } or $log->info("store: migration 5 column already present");
    }

    # NO BACK-FILL, and here it is genuinely impossible rather than merely unwise:
    # the answers this column will hold live in Slim::Utils::Cache under md5'd
    # keys, and an md5 cannot be reversed to the release group it came from. They
    # refill on the next detail-page open, which is when they were free anyway.
    return;
}

sub _migrate_1 {
    my ($h) = @_;

    # ---- BASE ----------------------------------------------------------
    #
    # `release` is keyed by the SAME identity ladder as Browse::_streamId:
    # release_mbid, else rg:<release_group_mbid> (the MuSpy case), else
    # t:<norm artist> <norm title>. Reusing it means the release key and the
    # stream key can never disagree about what "the same album" is.
    #
    # THE WHOLE UPSTREAM HASH IS FROZEN INTO `payload`, and only what must be
    # QUERIED is mirrored into typed columns. This plugin passes third-party JSON
    # around whole — the feed's own release_tags, the caa ids, fields nobody reads
    # yet — so enumerating columns guarantees that the day ListenBrainz adds a
    # field, it is silently dropped on the way through our own store.
    $h->do(<<'SQL');
CREATE TABLE IF NOT EXISTS release (
    rel_id       TEXT PRIMARY KEY,
    base_version INTEGER NOT NULL DEFAULT 0,
    payload      BLOB,
    rel_date     TEXT    NOT NULL DEFAULT '',
    week_start   TEXT    NOT NULL DEFAULT '',
    rg_mbid      TEXT    NOT NULL DEFAULT '',
    artist_mbids TEXT    NOT NULL DEFAULT '',
    caa_rel_mbid TEXT    NOT NULL DEFAULT '',
    dedupe_key   TEXT    NOT NULL DEFAULT '',
    first_seen   INTEGER NOT NULL DEFAULT 0,
    seen_at      INTEGER NOT NULL DEFAULT 0
)
SQL
    $h->do('CREATE INDEX IF NOT EXISTS release_date  ON release (rel_date)');
    $h->do('CREATE INDEX IF NOT EXISTS release_week  ON release (week_start)');
    $h->do('CREATE INDEX IF NOT EXISTS release_rg    ON release (rg_mbid)');
    $h->do('CREATE INDEX IF NOT EXISTS release_dedup ON release (dedupe_key)');

    # Membership is keyed (feed, rel_id) — deliberately NOT (feed, position) as
    # the Pitchfork plugin does. LBF re-derives order on every walk in
    # _sortReleases/_sortWithin, so position here would be provenance, not data,
    # and keying on it would rewrite every row whenever one insertion shifted the
    # rest. `seen_at` is what rotation is scoped by.
    $h->do(<<'SQL');
CREATE TABLE IF NOT EXISTS feed_member (
    feed    TEXT    NOT NULL,
    rel_id  TEXT    NOT NULL,
    seen_at INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (feed, rel_id)
)
SQL
    $h->do('CREATE INDEX IF NOT EXISTS feed_member_rel ON feed_member (rel_id)');

    # No counterpart in the Pitchfork plugin, and the reason a window change
    # becomes free: coverage is a QUERY over days actually fetched, instead of
    # something encoded in a cache key that a new window invalidates wholesale.
    # `fetched_at` records an ATTEMPT; `ok_at` records an ATTEMPT THAT ANSWERED.
    # Keeping them apart is what lets a 429 be a failed attempt that deletes
    # nothing (an empty result is never a fact — learned twice, 0.9.119, 0.9.149).
    $h->do(<<'SQL');
CREATE TABLE IF NOT EXISTS feed_day (
    feed       TEXT    NOT NULL,
    day        TEXT    NOT NULL,
    fetched_at INTEGER NOT NULL DEFAULT 0,
    ok_at      INTEGER NOT NULL DEFAULT 0,
    n_items    INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (feed, day)
)
SQL

    # `generation` moves only when content actually moved, which is what gives
    # %FEED_MEMO / %SECTION_MEMO a validity better than their present 5-second
    # expiry: they can hold for minutes without masking a refresh.
    $h->do(<<'SQL');
CREATE TABLE IF NOT EXISTS feed_meta (
    feed       TEXT PRIMARY KEY,
    fetched_at INTEGER NOT NULL DEFAULT 0,
    ok_at      INTEGER NOT NULL DEFAULT 0,
    generation INTEGER NOT NULL DEFAULT 0,
    n_items    INTEGER NOT NULL DEFAULT 0
)
SQL

    # NOT A CACHE. A Bandcamp pin comes back ONLY from a manual "Search Bandcamp"
    # tap, and for a Bandcamp-only release it is the sole playable entry — which
    # is why `lbf:bcmatch:` has never been version-bumped (0.9.42's bump was
    # reverted in 0.9.47 and again in 0.9.141's pre-release review). As a table it
    # has no version in its identity at all, so the question cannot come up again.
    $h->do(<<'SQL');
CREATE TABLE IF NOT EXISTS bandcamp_pin (
    rel_id    TEXT PRIMARY KEY,
    payload   BLOB,
    pinned_at INTEGER NOT NULL DEFAULT 0
)
SQL

    # NOT A CACHE. The follow store builds FORWARD from first capture; a
    # recommendation that scrolls out of ListenBrainz's 75-event feed window
    # cannot be re-derived from anywhere.
    $h->do(<<'SQL');
CREATE TABLE IF NOT EXISTS follow_item (
    username  TEXT    NOT NULL,
    item_key  TEXT    NOT NULL,
    payload   BLOB,
    created   INTEGER NOT NULL DEFAULT 0,
    stored_at INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (username, item_key)
)
SQL
    $h->do('CREATE INDEX IF NOT EXISTS follow_item_created ON follow_item (username, created)');

    # ---- FACTS ---------------------------------------------------------
    #
    # `fetched_at` REPLACES EVERY TTL. Staleness is a policy applied in Perl
    # (preserving 0.9.113's dated/dateless soft-hit rule exactly), so nothing here
    # hands a duration to LMS and no value can mean 1970. This is the structural
    # fix for the genre bug.
    #
    # release_group stays SEPARATE from release, for two reasons: several releases
    # share a group, so genres on the release row would duplicate N ways and could
    # disagree; and the Trending path looks groups up that never appeared in any
    # feed. Readers still see one merged hash.
    $h->do(<<'SQL');
CREATE TABLE IF NOT EXISTS release_group (
    rg_mbid      TEXT PRIMARY KEY,
    fact_version INTEGER NOT NULL DEFAULT 0,
    name         TEXT    NOT NULL DEFAULT '',
    year         TEXT    NOT NULL DEFAULT '',
    rel_date     TEXT    NOT NULL DEFAULT '',
    type         TEXT    NOT NULL DEFAULT '',
    genres       BLOB,
    agenres      BLOB,
    n_genres     INTEGER NOT NULL DEFAULT -1,
    n_agenres    INTEGER NOT NULL DEFAULT -1,
    genres_src   TEXT    NOT NULL DEFAULT '',
    -- `genres`/`agenres` arrive together on ONE request (inc=release_group tag),
    -- so they share a stamp — but it is separate from `fetched_at`, which covers
    -- the DATE the same request also answers. That is what lets a genre wipe be
    -- repaired without re-fetching every date in the feed, and what stops a date
    -- refresh silently declaring the genres fresh.
    genres_at    INTEGER NOT NULL DEFAULT 0,
    -- The RELEASE DETAIL PAGE's own answer (hosted album route, else MusicBrainz
    -- release-group genres), with its OWN stamp. Separate from `genres` because
    -- that column is ListenBrainz's and a write must never touch a tier it does
    -- not own — see _migrate_5. Filled when an album is opened; read by the list.
    detail_genres    BLOB,
    n_detail_genres  INTEGER NOT NULL DEFAULT -1,
    detail_genres_at INTEGER NOT NULL DEFAULT 0,
    fetched_at   INTEGER NOT NULL DEFAULT 0
)
SQL

    $h->do(<<'SQL');
CREATE TABLE IF NOT EXISTS recording (
    rec_mbid     TEXT PRIMARY KEY,
    fact_version INTEGER NOT NULL DEFAULT 0,
    artist       TEXT    NOT NULL DEFAULT '',
    title        TEXT    NOT NULL DEFAULT '',
    album        TEXT    NOT NULL DEFAULT '',
    rg_mbid      TEXT    NOT NULL DEFAULT '',
    year         TEXT    NOT NULL DEFAULT '',
    fetched_at   INTEGER NOT NULL DEFAULT 0
)
SQL

    # Keyed by MBID where there is one, else `n:<normalised name>` — the hosted
    # LMS-community API is NAME-keyed with no MBID lookup anywhere, so an artist
    # tier that answers for Trending rows arriving with no MBID needs a name key.
    #
    # ONE COLUMN PER TIER, ONE STAMP PER ANSWER (schema 3). Every independent thing
    # this row can hold — the hosted genres, the mirror genres, the sort-name — has
    # its OWN blob, its OWN count and its OWN timestamp, so no tier can overwrite or
    # re-age another's answer. Two tiers sharing one `genres` column with a
    # `genres_src` discriminator produced a permanent refetch/overwrite ping-pong
    # wherever both were live; a shared `fetched_at` let the sort warm declare the
    # genres fresh. Both defects are now inexpressible rather than avoided.
    #
    # `genres` / `genres_src` / `n_genres` are the pre-schema-3 columns. They are no
    # longer read or written — migration 3 files their contents under the right
    # tier — and remain only because SQLite's DROP COLUMN is too new to depend on.
    $h->do(<<'SQL');
CREATE TABLE IF NOT EXISTS artist (
    artist_key       TEXT PRIMARY KEY,
    fact_version     INTEGER NOT NULL DEFAULT 0,
    mbid             TEXT    NOT NULL DEFAULT '',
    name             TEXT    NOT NULL DEFAULT '',
    sort_name        TEXT    NOT NULL DEFAULT '',
    sort_src         TEXT    NOT NULL DEFAULT '',
    sort_at          INTEGER NOT NULL DEFAULT 0,
    artist_type      TEXT    NOT NULL DEFAULT '',
    lb_genres        BLOB,
    n_lb_genres      INTEGER NOT NULL DEFAULT -1,
    lb_genres_at     INTEGER NOT NULL DEFAULT 0,
    hosted_genres    BLOB,
    n_hosted_genres  INTEGER NOT NULL DEFAULT -1,
    hosted_genres_at INTEGER NOT NULL DEFAULT 0,
    lastfm_genres    BLOB,
    n_lastfm_genres  INTEGER NOT NULL DEFAULT -1,
    lastfm_genres_at INTEGER NOT NULL DEFAULT 0,
    mb_genres        BLOB,
    n_mb_genres      INTEGER NOT NULL DEFAULT -1,
    mb_genres_at     INTEGER NOT NULL DEFAULT 0,
    genres           BLOB,
    n_genres         INTEGER NOT NULL DEFAULT -1,
    genres_src       TEXT    NOT NULL DEFAULT '',
    fetched_at       INTEGER NOT NULL DEFAULT 0
)
SQL
    $h->do('CREATE INDEX IF NOT EXISTS artist_mbid ON artist (mbid)');

    # THE LAST.FM RUNG, which until schema 3 was the one genre tier still living in
    # `Slim::Utils::Cache` — on a TTL, in the store this rework exists to leave.
    # Keyed as the rung keys it: artist+ALBUM, because it asks album.gettoptags
    # before falling back to artist.gettoptags, so the answer is release-specific
    # and does not belong on the artist row.
    $h->do(<<'SQL');
CREATE TABLE IF NOT EXISTS lastfm_tags (
    lfm_key    TEXT PRIMARY KEY,
    tags       BLOB,
    n_tags     INTEGER NOT NULL DEFAULT -1,
    fetched_at INTEGER NOT NULL DEFAULT 0
)
SQL

    # ---- DERIVED -------------------------------------------------------
    #
    # Copied from the Pitchfork plugin, wrapper and all. The `{ v => … }` hash is
    # not decoration: 0 and undef are both MEANINGFUL values here (an empty
    # resolve, a "probed and found nothing" marker), and a bare freeze of 0 comes
    # back indistinguishable from a miss the moment anything tests truth.
    $h->do(<<'SQL');
CREATE TABLE IF NOT EXISTS kv (
    k          TEXT PRIMARY KEY,
    v          BLOB,
    expires_at INTEGER NOT NULL DEFAULT 0
)
SQL
    $h->do('CREATE INDEX IF NOT EXISTS kv_expiry ON kv (expires_at)');

    return;
}

# ---------------------------------------------------------------------------
# Blob binding.
#
# The Pitchfork plugin passes nfreeze output to `do` with no bind type. MEASURED
# against DBD::SQLite 1.64 with sqlite_unicode => 1, that is not merely untidy:
#
#   bind          frozen bytes go in       come back
#   ------------  -----------------------  ----------------------------------
#   untyped       "\xFF\x00\x80A"          same bytes, BUT utf8 flag SET
#   SQL_BLOB      "\xFF\x00\x80A"          same bytes, utf8 flag CLEAR
#
# The bytes survive either way, so this is not corruption today — it is a value
# whose UTF8 FLAG depends on which side of the store it came from. This repo has
# been bitten twice by exactly that provenance question (0.6.15 from the key side,
# 0.9.141 from the value side), so a store that hands back a differently-flagged
# copy of what it was given is a trap left armed for later.
#
# The second measured property is the useful one: SQL_BLOB DIES ("Wide character
# in subroutine entry") if handed an unfrozen string with a codepoint above 255,
# where an untyped bind would quietly accept it. Everything here is frozen first,
# so that can only fire on a future caller who forgets — and failing loudly is
# precisely what the 0.9.141 bug did not do.
#
# Asserted in tools/t_db.pl section 4 by the flag, not by the bytes.
# ---------------------------------------------------------------------------
# $blobPos is a single 1-based position or an arrayref of them (a facts row can
# carry more than one frozen column — `release_group` has both `genres` and
# `agenres`).
sub _execBlob {
    my ($h, $sql, $blobPos, @args) = @_;
    my %blob = map { $_ => 1 } (ref $blobPos eq 'ARRAY' ? @$blobPos : ($blobPos));
    # PREPARED ONCE PER STATEMENT, NOT ONCE PER CALL. ingestFeed calls this for
    # EVERY release inside one synchronous transaction — ~3,255 of them on a full
    # feed — so a fresh prepare here meant 3,255 parse/plan cycles blocking the
    # event loop inside an HTTP callback. That is the hazard _withGenresLB spends a
    # whole block comment avoiding at 150, twenty times smaller. The SQL here is a
    # fixed set of literals, so the cache is bounded by the number of call sites.
    #
    # $if_active = 3: hand back a fresh, unstashed handle rather than finish one
    # that is somehow still active. Every statement passed here is DML, which
    # DBD::SQLite does not leave active, so that is a guard rather than a path.
    my $sth = $h->prepare_cached($sql, undef, 3);
    my $i   = 1;
    for my $a (@args) {
        if ($blob{$i}) { $sth->bind_param($i, $a, DBI::SQL_BLOB) }
        else           { $sth->bind_param($i, $a) }
        $i++;
    }
    $sth->execute;
    return 1;
}

sub _freeze { return Storable::nfreeze({ v => $_[0] }) }

sub _thaw {
    my ($blob, $what) = @_;
    return (0, undef) unless defined $blob;
    my $wrapped = eval { Storable::thaw($blob) };
    unless (ref $wrapped eq 'HASH') {
        $log->warn("store: unreadable value for $what — treating as absent");
        return (0, undef);
    }
    return (1, $wrapped->{v});
}

# ---------------------------------------------------------------------------
# kv — the DERIVED tier. Everything disposable: match decisions, resolved lists,
# cleaned text, negative markers.
# ---------------------------------------------------------------------------

# undef when absent OR expired. A caller needing to tell those apart stores a
# sentinel (the wrapper above is what makes a stored 0 or undef survive).
sub kvGet {
    my ($key) = @_;
    my $h = dbh() or return undef;
    return undef unless defined $key && length $key;

    my $row = eval {
        $h->selectrow_arrayref('SELECT v, expires_at FROM kv WHERE k = ?', undef, $key)
    } or return undef;

    my ($blob, $exp) = @$row;
    if ($exp && $exp < time()) {
        eval { $h->do('DELETE FROM kv WHERE k = ?', undef, $key) };
        return undef;
    }

    my (undef, $value) = _thaw($blob, $key);
    return $value;
}

# $ttl is SECONDS FROM NOW; undef or 0 means "never expires". ANY duration is
# valid — 90 days, a year, ten years — because what is stored is `time() + $ttl`
# and nothing downstream re-interprets it. See the header.
sub kvSet {
    my ($key, $value, $ttl) = @_;
    my $h = dbh() or return 0;
    return 0 unless defined $key && length $key;

    my $exp = $ttl ? time() + $ttl : 0;
    my $ok  = eval {
        _execBlob($h, 'INSERT OR REPLACE INTO kv (k, v, expires_at) VALUES (?, ?, ?)',
                  2, $key, _freeze($value), $exp);
    };
    $log->warn("store: kv write failed for $key: $@") unless $ok;
    return $ok ? 1 : 0;
}

sub kvDel {
    my ($key) = @_;
    my $h = dbh() or return 0;
    return 0 unless defined $key && length $key;
    eval { $h->do('DELETE FROM kv WHERE k = ?', undef, $key); 1 } or return 0;
    return 1;
}

# Wipe every kv row whose key starts with $prefix — how a version bump retires a
# whole family without touching anything else. REFUSES AN EMPTY PREFIX rather
# than treating it as "everything"; wipeDerived is the sub that means that, and
# an accidental '' reaching here should not be able to impersonate it.
sub kvForgetPrefix {
    my ($prefix) = @_;
    my $h = dbh() or return 0;
    return 0 unless defined $prefix && length $prefix;
    my $n = eval {
        my $like = $prefix;
        $like =~ s/([%_\\])/\\$1/g;
        $h->do("DELETE FROM kv WHERE k LIKE ? ESCAPE '\\'", undef, $like . '%');
    } || 0;
    return int($n);
}

sub kvCount {
    my $h = dbh() or return 0;
    return int(eval { $h->selectrow_array('SELECT COUNT(*) FROM kv') } || 0);
}

# Delete every expired row. Returns how many went.
#
# NOT REDUNDANT WITH THE PER-READ CLEANUP IN kvGet, and the Pitchfork plugin
# learned this the hard way: the rows needing collection are precisely the ones
# nothing will ever read again, so no read-triggered cleanup can reach them, and a
# sweep that runs from dbh() fires once per server START and never again. On a
# server that stays up for months the table therefore grows with UPTIME —
# invisible on a machine that happens to reboot nightly. The warm tick calls this.
sub kvSweep {
    my $h = dbh() or return 0;
    my $n = eval {
        $h->do('DELETE FROM kv WHERE expires_at > 0 AND expires_at < ?', undef, time())
    } || 0;
    return int($n);
}

# ---------------------------------------------------------------------------
# THE `kv` DROP-IN.
#
# Every module in this plugin used to hold `my $cache = Slim::Utils::Cache->new()`
# and call `->get/->set/->remove` on it, at ~120 sites. This object answers the
# same three methods against `kv`, so the storage moved without rewriting any of
# them — which is deliberate: a 120-site mechanical rewrite is exactly where a
# transposed argument hides, and the call sites are not what was wrong.
#
# WHAT CHANGES BEHIND THE IDENTICAL CALL:
#   * `$ttl` is SECONDS FROM NOW, always, and is stored as `now + $ttl`. LMS
#     re-interpreted anything over 2,592,000 as an absolute epoch; nothing here
#     does, so the 30-day boundary does not exist.
#   * The key is used verbatim as a TEXT primary key. LMS md5'd it, which DIED on
#     any codepoint above 255 (0.6.15). Existing callers still `utf8::encode`
#     their keys — leave that alone, it keeps a key stable across the change —
#     but a caller that forgets can no longer take the dispatch down.
#   * A BARE STRING round-trips with its utf8 flag intact. LMS froze a value only
#     `if (ref $data)` and bound a plain scalar straight to DBD::SQLite, which is
#     the OTHER half of the same die (0.9.141, `_setText`). `_freeze` wraps every
#     value, so that failure mode is gone as well.
#   * `set` returns 1/0 rather than dying or warning from inside LMS.
# ---------------------------------------------------------------------------
sub store { return bless {}, 'Plugins::ListenBrainzFreshReleases::DB::Store' }

# ---------------------------------------------------------------------------
# KEY VERSIONS, DECLARED ONCE.
#
# These used to be literals scattered across _streamKey, _bcMarkerKey,
# _followResolvedKey, _trendingResolvedKey, _albumsDataKey and three separate
# copies of 'lbf:pl:resolved:8:' — a shape this repo has got wrong more than once
# (0.9.42/0.9.47, 0.9.106, 0.9.120). A family's version now exists in exactly one
# place, `retirePrefixes` reclaims the space a bump orphans at startup, and
# `cachestats` can report on families rather than on an opaque row count.
#
# THE LAYERING RULE IS NOW STRUCTURAL, NOT DOCUMENTED. An outer resolved-list key
# embeds the inner 'lbf:track:' version via `kverNum` (see Browse::_resolvedTag),
# so bumping the inner NECESSARILY invalidates every list wrapping it. That rule
# has been written down three times and broken anyway; it cannot be forgotten
# when it is a term in the key.
#
# NOT LISTED HERE, DELIBERATELY: 'lbf:bcmatch:' — a hand-curated Bandcamp pin is
# not a cache, it is a table (below), and it must have no version in its identity
# at all so the question of bumping it cannot come up again.
#
# ---------------------------------------------------------------------------
# WHICH FAMILIES A `_norm` CHANGE MOVES, and it is more than the match caches.
# Recorded at the fleet matcher sync (the three DSC-origin rules), where five
# families bumped together: stream, track, artistmbid, rgbyname and hdisco.
#
# The rule is NOT "bump the match caches". It is: **a family moves if `_norm`
# decided what is stored, OR if `_norm` built the key it is stored under.**
#
#   * 'lbf:stream:' / 'lbf:track:' — the DECISION. A cached match (or no-match)
#     was reached with the old normaliser. The resolved-LIST families wrapping
#     them re-key for free through the layer tags above.
#   * 'lbf:artistmbid:' / 'lbf:rgbyname:' — also the decision, one layer out:
#     both accept a candidate through API::_foldEq, which delegates to `_norm`.
#     A cached MISS is the stale one that matters — a name the new fold accepts
#     would keep answering "not found" for the whole TTL.
#   * 'lbf:hdisco:' — THE ONE THAT IS EASY TO MISS, and the reason this note
#     exists. Its VALUE is a map **keyed by `_foldKey($title)`**, i.e. by `_norm`
#     output. The cache key does not move (it is `lc($artist)`), so the entry
#     still HITS — and then every lookup, folded the new way, misses inside a map
#     written the old way. Silent: the resolver just falls back to MusicBrainz
#     for exactly the titles the fold change was meant to fix. A family whose
#     CONTENT is fold-keyed has to bump even though its own key is untouched.
#
# So when `_norm` changes, grep for `_foldKey` and `_foldEq` as well as for the
# matcher's own callers.
# ---------------------------------------------------------------------------
use constant KEY_VERSIONS => {
    'lbf:artistmbid:'        => 3,
    'lbf:bcdone:'            => 6,   # the "searched Bandcamp, found nothing" marker IS disposable
    # 'lbf:bio:' removed 0.9.186 with the detail page's Last.fm bio fallback (MAI's
    # own sources already include Last.fm). Like the two genre families below it
    # lived in Slim::Utils::Cache rather than kv, so there is nothing here to
    # retire — stale entries age out on their own TTL and nothing reads them.
    'lbf:hdisco:'            => 2,   # hosted /discography, folded title -> rg answer, per ARTIST
    # 'lbf:hgenres:' and 'lbf:rggenres:' removed 0.9.185 with the detail page's two
    # on-demand genre fetches (API.pm's tombstones carry the measurements). Both
    # lived in Slim::Utils::Cache rather than kv, so there is nothing here to
    # retire — stale entries age out on their own TTL and nothing reads them.
    'lbf:hsimilar:'          => 1,
    # THE COVER-WARM MARKER, AND IT WAS THE ONE FAMILY NOT DECLARED HERE.
    # `_warmCovers` wrote `lbf:imgwarm:<proxy path>` by hand, so the family was
    # invisible to `cachestats` (about 950 of 1,570 kv rows on the live server
    # were unaccounted for), unreachable by `retirePrefixes`, and had no way to
    # be invalidated short of the dev wipe. Registering it fixes all three, and
    # the bump is needed NOW: every marker written so far describes a `.png`
    # proxy path, and `coverArtUrl` emits `.jpg` from this build on. Those
    # markers claim a warm entry for a URL no client will ever request again, so
    # without a bump the warm would skip the whole feed and every cover would be
    # cold on first sight — the exact failure the warm exists to prevent.
    'lbf:imgwarm:'           => 2,
    'lbf:lastlisten:'        => 1,
    'lbf:rgbyname:'          => 2,
    'lbf:stream:'            => 28,
    'lbf:track:'             => 9,
    'lbf:pl:resolved:'       => 8,
    'lbf:follow:resolved:'   => 5,
    'lbf:trending:resolved:' => 8,
    'lbf:trending:albums:'   => 7,
};

my %_KVER_WARNED;

# 'lbf:track:' -> 'lbf:track:8:'. An unregistered family is a programming error,
# not a storage error: it is reported once and given version 0, so the mistake
# shows up as a family that never hits rather than as a crash on a browse.
sub kver {
    my ($family) = @_;
    my $v = KEY_VERSIONS->{ $family // '' };
    unless (defined $v) {
        $log->error("store: key family '" . ($family // '(undef)') . "' is not in KEY_VERSIONS")
            unless $_KVER_WARNED{ $family // '' }++;
        $v = 0;
    }
    return $family . $v . ':';
}

sub kverNum { return KEY_VERSIONS->{ $_[0] // '' } // 0 }

# ---------------------------------------------------------------------------
# BASE — `bandcamp_pin`. NOT A CACHE.
#
# A pin comes back ONLY from a manual "Search Bandcamp" tap, and for a
# Bandcamp-only release it is the album's sole playable entry. As a kv row it was
# one `DELETE FROM kv` away from being destroyed, which is why the dev-build wipe
# could not be unconditional until this existed.
#
# The payload is the same `{ items => [...] }` hash `_cacheStream` wrote, so a pin
# imported from the old cache and a pin made after this change are the same value.
# ---------------------------------------------------------------------------
sub bcPinGet {
    my ($relId) = @_;
    my $h = dbh() or return undef;
    return undef unless defined $relId && length $relId;
    my $row = eval {
        $h->selectrow_arrayref('SELECT payload FROM bandcamp_pin WHERE rel_id = ?', undef, $relId)
    } or return undef;
    my (undef, $v) = _thaw($row->[0], "bandcamp_pin $relId");
    return $v;
}

sub bcPinPut {
    my ($relId, $value) = @_;
    my $h = dbh() or return 0;
    return 0 unless defined $relId && length $relId;
    my $ok = eval {
        _execBlob($h, 'INSERT OR REPLACE INTO bandcamp_pin (rel_id, payload, pinned_at) VALUES (?, ?, ?)',
                  2, $relId, _freeze($value), time());
    };
    $log->warn("store: bandcamp pin write failed for $relId: $@") unless $ok;
    return $ok ? 1 : 0;
}

sub bcPinDel {
    my ($relId) = @_;
    my $h = dbh() or return 0;
    return 0 unless defined $relId && length $relId;
    eval { $h->do('DELETE FROM bandcamp_pin WHERE rel_id = ?', undef, $relId); 1 } or return 0;
    return 1;
}

# ---------------------------------------------------------------------------
# BASE — `follow_item`. NOT A CACHE.
#
# The recommendation store builds FORWARD from first capture: ListenBrainz's feed
# endpoint returns a 75-EVENT WINDOW, most of which is not a recommendation, so an
# item that scrolls out of it cannot be re-derived from anywhere. It was a single
# 30-day kv blob, which meant it also silently emptied itself for anyone who went
# a month without opening the section.
#
# One ROW per item rather than one blob per user, so a merge is an insert of what
# is new instead of a rewrite of everything, and `created` can be indexed.
# ---------------------------------------------------------------------------
sub followList {
    my ($username, $max) = @_;
    my $h = dbh() or return [];
    $username = '' unless defined $username;
    my $rows = eval {
        $h->selectall_arrayref(
            'SELECT item_key, payload FROM follow_item WHERE username = ?
             ORDER BY created DESC LIMIT ?', { Slice => {} }, $username, int($max || 500))
    } || [];
    my @out;
    for my $r (@$rows) {
        my ($ok, $v) = _thaw($r->{payload}, "follow_item $r->{item_key}");
        push @out, $v if $ok && ref $v eq 'HASH';
    }
    return \@out;
}

# Add-if-new. Returns how many rows were actually inserted, so the caller can tell
# "nothing new arrived" from "the feed was empty".
sub followAdd {
    my ($username, $items) = @_;
    my $h = dbh() or return 0;
    $username = '' unless defined $username;
    return 0 unless ref $items eq 'ARRAY' && @$items;

    my $n = 0;
    my $ok = eval {
        $h->begin_work;
        for my $it (@$items) {
            next unless ref $it eq 'HASH' && defined $it->{_key} && length $it->{_key};
            my ($have) = $h->selectrow_array(
                'SELECT 1 FROM follow_item WHERE username = ? AND item_key = ?',
                undef, $username, $it->{_key});
            next if $have;
            my %row = %$it;
            delete $row{_key};
            _execBlob($h, 'INSERT INTO follow_item (username, item_key, payload, created, stored_at)
                           VALUES (?, ?, ?, ?, ?)',
                      3, $username, $it->{_key}, _freeze(\%row), int($it->{created} // 0), time());
            $n++;
        }
        $h->commit;
        1;
    };
    unless ($ok) {
        eval { $h->rollback };
        $log->warn("store: follow merge failed: $@");
        return 0;
    }
    return $n;
}

# Keep the newest $max and drop the rest — the table equivalent of the old
# FOLLOW_KEEP_MAX slice, done in SQL so a long-running store never has to be read
# in full to be trimmed.
sub followTrim {
    my ($username, $max) = @_;
    my $h = dbh() or return 0;
    $username = '' unless defined $username;
    $max = int($max || 500);
    my $n = eval {
        $h->do('DELETE FROM follow_item WHERE username = ? AND item_key NOT IN
                (SELECT item_key FROM follow_item WHERE username = ?
                 ORDER BY created DESC LIMIT ?)', undef, $username, $username, $max)
    } || 0;
    return int($n);
}

sub followCount {
    my ($username) = @_;
    my $h = dbh() or return 0;
    return int(eval {
        $h->selectrow_array('SELECT COUNT(*) FROM follow_item WHERE username = ?',
                            undef, ($username // ''))
    } || 0);
}

# ===========================================================================
# BASE — THE FEED ITSELF. `release`, `feed_member`, `feed_day`, `feed_meta`.
#
# THE DEFECT THIS REPLACES. `getFreshReleasesAll` stored the whole feed as ONE
# blob under a key containing TODAY'S DATE, so at every local midnight the entire
# ~3,255-release structure was re-fetched, re-parsed and re-frozen — and again on
# any change to the window or the past/future prefs — even though almost none of
# those releases had moved for weeks. Two 5-second in-process memos exist purely
# to blunt the cost of DESERIALISING that blob on every XMLBrowser walk.
#
# Coverage becomes a QUERY over `feed_day` instead of something encoded in a
# cache key that a new window invalidates wholesale. Shrinking the window costs
# nothing; widening it costs the days it adds; midnight costs nothing at all when
# the shifted window is already covered.
#
# A CORRECTION TO THE PLAN, MEASURED AGAINST THE REAL ENDPOINT. docs/caching-
# rework.md §2.2 says a partial window "fetches only the uncovered days". THAT IS
# NOT EXPRESSIBLE: ListenBrainz's fresh_releases routes take `days=N&past=&future=`
# and return the WHOLE window in one response — there is no day-range parameter on
# either the user or the explore route. So a gap in coverage is repaired by the one
# full fetch, and what the coverage query actually buys is the decision of whether
# that fetch has to BLOCK the render (it does not, once any rows are stored).
#
# WHAT A FEED NAME IS: 'all', "user:<username>", "muspy:<userid>". The username is
# part of the identity because a different account is a different feed; the WINDOW
# prefs deliberately are NOT, because making them part of the identity is the very
# bug being removed.
# ===========================================================================

# Bumped ONLY when the shape stored in `payload` changes. Rows carrying an older
# value read as absent.
#
# THE LBF-SPECIFIC COST, STATED PLAINLY, because it does not apply to the sibling
# Pitchfork plugin this store is modelled on: there, a bump re-downloads an article
# that is always available. Here, ListenBrainz only re-serves releases INSIDE the
# release window, so a bump LOSES every older row for good. Prefer an additive
# change with a back-fill migration; reserve the bump for genuine incompatibility.
use constant BASE_VERSION => 1;

# BUMP THIS WHEN THE GENRE PARSER CHANGES — `_genreTags`, `_hostedGenreNames`, the
# vocabulary gate — and at no other time. It is what clears stored genres, and it
# is deliberately NOT the plugin version.
#
# WHY IT IS NOT THE PLUGIN VERSION, learned the hard way in 0.9.166/0.9.167: the
# dev-build wipe cleared every genre on EVERY install. Two builds in one afternoon
# therefore threw away the whole genre store twice, and refilling it is the single
# most expensive thing this plugin does — 66 rate-limited ListenBrainz batches plus
# a per-artist hosted pass, spread over a warm that runs once a day. The result
# looked exactly like the genre bug the whole rework exists to fix, which is the
# worst possible failure mode for a diagnostic tool.
#
# §2.3 of docs/caching-rework.md already specified this mechanism ("bumped when the
# parser changes"); the build-change wipe was a blunt duplicate of it. The dev-build
# wipe still clears ALL of `kv` unconditionally — every match decision, resolved
# list and marker — which is what the fleet "dev builds clear caches" rule is
# actually protecting. Genres are not a decision; they are expensive upstream fact.
use constant GENRE_FACT_VERSION => 1;

# ---------------------------------------------------------------------------
# THE AGE POLICY. NOTHING STORED HERE IS IMMUTABLE — every fact gets re-checked
# eventually, because upstream data genuinely changes: MusicBrainz genre tagging
# lands weeks after a release, ListenBrainz backfills first_release_date, a
# streaming service catalogues an album the day after we looked. A store that
# locks an answer for ever is not a cache, it is a decision nobody can revisit.
#
# TWO AGES PER ANSWER, and the split is the whole mechanism:
#   FOUND — a populated answer is near-immutable, so it is held a long time.
#   EMPTY — "asked, and there was nothing" is a REAL answer worth storing (or the
#           ~half of every feed that has no tags would be re-asked on every pass),
#           but it is the answer most likely to become wrong, so it is held for a
#           fraction as long and quietly comes back round.
#
# That is what makes re-checking a TRICKLE rather than a stampede: at any moment
# only the answers that have aged past their own age are due, they are spread
# across the feed by when each was fetched, and the per-pass caps upstream bound
# how many of those are actually asked about. Nothing has to update at once, and
# nothing is locked.
#
# Declared HERE, once, so `stats` reports on the same numbers the fetchers obey.
# A staleness figure computed from a second copy of these constants would drift
# and then lie — and a lying instrument is what turned a one-line bug into two
# bad builds. Read them from API.pm as `DB->RG_GENRE_FOUND_AGE` (a METHOD call —
# a bareword `DB::RG_GENRE_FOUND_AGE` resolves at compile time and takes the whole
# module down, which is how 0.9.166 shipped a plugin that could not load).
# AGE POLICY — docs/feed-findings-2026-08-14.md §2: FOUND = 30 days, EMPTY = 1 day,
# fleet-wide for genres. The old 14-day empty age was the worst offender: MB tagging
# lands AFTER release, which is precisely the argument for re-asking tomorrow rather
# than in a fortnight.
use constant RG_GENRE_FOUND_AGE =>  30 * 86400;   # tagged: it is not going to change much
use constant RG_GENRE_EMPTY_AGE =>   1 * 86400;   # untagged: MB tagging lands after release — retry tomorrow

# The identity ladder, and it is deliberately the SAME LADDER as the stream cache
# uses: release_mbid, else rg:<release_group_mbid> (the MuSpy case, which carries
# no release-level id at all), else t:<the matcher's own normalised artist+title>.
#
# THE TEXT RUNG CALLS Browse::_streamId AND WILL NOT SUBSTITUTE ANYTHING ELSE. A
# private normaliser here would be a fifth copy of a fleet-synced sub, and — worse
# — a second key space: the same album would key one way while Browse was loaded
# and another way while it was not, so one release would occupy two rows and the
# dedupe would never see them as the same thing. Failing loudly into the caller's
# eval (which skips this ingest and re-fetches next time) is strictly better than
# inventing a key nothing else agrees with.
sub _relTextId {
    my ($artist, $title) = @_;
    my $fn = Plugins::ListenBrainzFreshReleases::Browse->can('_streamId')
        or die "release id needs Browse::_streamId — refusing to invent a second key space";
    return $fn->($artist, $title, undef);
}

sub relId {
    my ($rel) = @_;
    return '' unless ref $rel eq 'HASH';

    my $rmb = $rel->{release_mbid} // '';
    return $rmb if length $rmb;

    my $rg = $rel->{release_group_mbid} // '';
    return "rg:$rg" if length $rg;

    my $t = _relTextId($rel->{artist_credit_name} // '', $rel->{release_name} // '');
    return length $t ? "t:$t" : '';
}

# The columns mirrored out of the payload — ONLY what has to be QUERIED. The whole
# upstream hash is frozen into `payload` because this plugin passes third-party
# JSON around whole (the feed's own release_tags, caa ids, fields nobody reads
# yet), so enumerating columns would guarantee that the day ListenBrainz adds a
# field, it is silently dropped on the way through our own store.
sub _relCols {
    my ($rel) = @_;
    my $date = $rel->{release_date} // '';
    my $mbids = $rel->{artist_mbids};
    return {
        rel_date     => $date,
        week_start   => _weekStart($date),
        rg_mbid      => ($rel->{release_group_mbid}     // ''),
        artist_mbids => (ref $mbids eq 'ARRAY' ? join(',', grep { defined } @$mbids) : ''),
        caa_rel_mbid => ($rel->{caa_release_mbid}       // ''),
        dedupe_key   => _dedupeKey($rel),
    };
}

# Monday-based, matching Browse::_weekStart. Kept local and arithmetic-only (no
# Time::Local) so the store has no opinion the render could disagree with: it is
# a QUERY convenience, never the thing a week divider is built from.
sub _weekStart {
    my ($date) = @_;
    return '' unless defined $date && $date =~ /^(\d{4})-(\d{2})-(\d{2})$/;
    my ($y, $m, $d) = ($1, $2, $3);
    my $days = _toDays($y, $m, $d);
    my $dow  = ($days + 3) % 7;          # 1970-01-01 was a Thursday
    return _fromDays($days - $dow);
}

# The same key Browse::_dedupeReleases collapses on — normalised artist+title plus
# the date — so a duplicate the render would merge is visible as a duplicate here
# too, without the store deciding anything about it.
sub _dedupeKey {
    my ($rel) = @_;
    my $t = eval { _relTextId($rel->{artist_credit_name} // '', $rel->{release_name} // '') } // '';
    return length $t ? $t . '|' . ($rel->{release_date} // '') : '';
}

# --- date helpers. Days since 1970-01-01, proleptic Gregorian. -------------
sub _toDays {
    my ($y, $m, $d) = @_;
    my $a = int((14 - $m) / 12);
    my $yy = $y + 4800 - $a;
    my $mm = $m + 12 * $a - 3;
    my $jdn = $d + int((153 * $mm + 2) / 5) + 365 * $yy
            + int($yy / 4) - int($yy / 100) + int($yy / 400) - 32045;
    return $jdn - 2440588;
}

sub _fromDays {
    my ($days) = @_;
    my $jdn = $days + 2440588;
    my $a = $jdn + 32044;
    my $b = int((4 * $a + 3) / 146097);
    my $c = $a - int((146097 * $b) / 4);
    my $dd = int((4 * $c + 3) / 1461);
    my $e = $c - int((1461 * $dd) / 4);
    my $mm = int((5 * $e + 2) / 153);
    return sprintf('%04d-%02d-%02d',
        100 * $b + $dd - 4800 + int($mm / 10),
        $mm + 3 - 12 * int($mm / 10),
        $e - int((153 * $mm + 2) / 5) + 1);
}

# Every day in [$from, $to] inclusive. Bounded hard: a garbage window must not be
# able to write a million feed_day rows.
use constant WINDOW_MAX_DAYS => 800;

sub _dayRange {
    my ($from, $to) = @_;
    return () unless $from && $to && $from =~ /^\d{4}-\d{2}-\d{2}$/ && $to =~ /^\d{4}-\d{2}-\d{2}$/;
    my ($f, $t) = (_toDays(split /-/, $from), _toDays(split /-/, $to));
    return () if $t < $f;
    return () if ($t - $f) > WINDOW_MAX_DAYS;
    return map { _fromDays($_) } ($f .. $t);
}

# ---------------------------------------------------------------------------
# Coverage — the query that replaces the date in the cache key.
#
# Returns what the caller needs to choose between "serve from the store", "serve
# from the store AND revalidate in the background" and "there is nothing here, go
# and fetch". `fresh` is deliberately NOT decided here: how stale is too stale is
# a policy of the feed, not of the storage.
# ---------------------------------------------------------------------------
sub feedCoverage {
    my ($feed, $from, $to) = @_;
    my $out = { days => 0, covered => 0, missing => [], rows => 0,
                ok_at => 0, fetched_at => 0, generation => 0, complete => 0, any => 0 };
    my $h = dbh() or return $out;
    return $out unless defined $feed && length $feed;

    my @days = _dayRange($from, $to);
    $out->{days} = scalar @days;

    my %ok;
    my $rows = eval {
        $h->selectall_arrayref('SELECT day, ok_at FROM feed_day WHERE feed = ? AND ok_at > 0',
                               { Slice => {} }, $feed)
    } || [];
    $ok{ $_->{day} } = $_->{ok_at} for @$rows;

    my @missing = grep { !$ok{$_} } @days;
    $out->{missing}  = \@missing;
    $out->{covered}  = scalar(@days) - scalar(@missing);
    $out->{complete} = (@days && !@missing) ? 1 : 0;

    my $meta = eval {
        $h->selectrow_hashref('SELECT fetched_at, ok_at, generation, n_items FROM feed_meta WHERE feed = ?',
                              undef, $feed)
    };
    if ($meta) {
        $out->{$_} = int($meta->{$_} // 0) for qw(fetched_at ok_at generation);
    }

    $out->{rows} = int(eval {
        $h->selectrow_array('SELECT COUNT(*) FROM feed_member WHERE feed = ?', undef, $feed)
    } || 0);
    $out->{any} = $out->{rows} ? 1 : 0;

    return $out;
}

# Read the feed back. ONE statement and ONE thaw per release — which is more work
# than the single Storable::thaw of the old blob, and the plan says so plainly: the
# win here is that the base stops being re-minted and the window became queryable,
# NOT that reads got faster. Lose that distinction and this ships a regression.
#
# Rows carrying an older BASE_VERSION are skipped rather than served, so a bump is
# a cold start for the rows it orphans instead of a shape mismatch at the render.
sub feedReleases {
    my ($feed, $from, $to) = @_;
    my $h = dbh() or return [];
    return [] unless defined $feed && length $feed;

    my ($sql, @args) = (
        'SELECT r.payload FROM feed_member m JOIN release r ON r.rel_id = m.rel_id
          WHERE m.feed = ? AND r.base_version = ?', $feed, BASE_VERSION);

    # A window is a FILTER on the read, not part of the identity — which is what
    # makes narrowing it free. A dateless row is always kept: it cannot be shown to
    # be outside the window, and dropping it would silently lose the MuSpy rows
    # whose date MusicBrainz has not settled yet.
    if ($from && $to) {
        $sql .= " AND (r.rel_date = '' OR (r.rel_date >= ? AND r.rel_date <= ?))";
        push @args, $from, $to;
    }
    $sql .= ' ORDER BY r.rel_date DESC';

    my $rows = eval { $h->selectall_arrayref($sql, { Slice => {} }, @args) } || [];
    my @out;
    for my $r (@$rows) {
        my ($ok, $v) = _thaw($r->{payload}, "release payload");
        push @out, $v if $ok && ref $v eq 'HASH';
    }
    return \@out;
}

# ---------------------------------------------------------------------------
# Ingest. ONE transaction.
#
# THREE RULES, each of which this repo has learned the hard way:
#
#  1. AN EMPTY RESULT IS NEVER A FACT (0.9.119, 0.9.149). An empty response when
#     rows already exist is a FAILED ATTEMPT: `fetched_at` is recorded, `ok_at` is
#     not, and NOTHING is deleted. It is also where the 429 backoff plugs in — a
#     rate-limited fetch takes exactly this branch.
#  2. ROTATION IS SCOPED TO THE REQUESTED WINDOW, passed in and NEVER inferred
#     from the response. Infer it and a day that legitimately went empty can never
#     be cleaned, because nothing in the response names that day.
#  3. UPSERT MERGES, IT NEVER BLANKS. ListenBrainz and MuSpy describe the same
#     release with different completeness — MuSpy has the artist sort-name and no
#     release mbid, LB has the caa ids — so an empty incoming field must leave the
#     stored one alone.
#
# $opt{rotate} defaults ON and MUST be passed 0 for a source whose response is a
# TOP-N SLICE rather than a window. MuSpy's `?limit=100` is exactly that: a day
# inside the range can hold releases that simply fell outside the limit, so
# rotation there would delete rows that are still perfectly valid. Same rule as (1)
# arriving from a different direction — a truncated list is not proof of absence.
#
# ---------------------------------------------------------------------------
# $opt{chunk} — WHY THIS IS NOT ONE TRANSACTION ANY MORE.
#
# Field report 2026-08-22: *"server losing players when opening an All Releases
# feed"*, plus lazily-loaded artwork failing to populate until a revisit. Players
# dropping off is the signature of a BLOCKED EVENT LOOP — LMS streams audio, and
# serves the image proxy, from the same loop that runs this callback.
#
# MEASURED (tools/bench_store.pl, real DBD::SQLite, the live 4,061-release feed):
# this sub issued ~4 statements per release — about 16,000 — inside ONE
# transaction, called from inside an async HTTP callback where nothing can
# interleave. 185ms on a dev Mac, so roughly 1.85s on the target Pi.
#
# THE REGRESSION IS REAL AND IT IS THIS SUB. Before the caching rework a feed was
# stored by TWO `$cache->set` calls — two Storable freezes and two row writes.
# The store replaced that with a per-release upsert loop, i.e. two statements
# became sixteen thousand, and that is the whole of "none of this was an issue
# before we switched the cache model".
#
# So the row work is now done in CHUNKS, each its own transaction, with the caller
# yielding between them. The atomicity that is given up is real and bounded:
#
#   * Mid-ingest a reader sees a MIX of old and new rows. Both are valid releases —
#     the upsert MERGES (rule 3) and deletes nothing — so no row is ever absent or
#     half-written, there are simply some fresh and some stale.
#   * COVERAGE IS NOT STAMPED UNTIL THE PASS COMPLETES. `feed_day`, `feed_meta`
#     and `ok_at` are written once, at the end, in a final transaction alongside
#     rotation. So throughout the pass the feed still reads as "stale,
#     revalidating" — exactly the state it was already in when the fetch began.
#   * A crash or an error part-way leaves extra rows and NO `ok_at` update, so the
#     next open revalidates. It cannot leave a feed looking fresh but half-written.
#   * ROTATION STILL RUNS ONLY ON A COMPLETE PASS, which is what preserves rule 1:
#     a partial pass must never be allowed to delete rows it merely did not reach.
#
# $opt{chunk} = rows per transaction; 0/absent = the old fully-synchronous
# behaviour, which the tests and any caller wanting final totals still use.
# $opt{onDone} = called with the result hash when a chunked pass finishes.
# ---------------------------------------------------------------------------

# Rows per chunk, SET FROM MEASUREMENT rather than picked (tools/bench_store.pl,
# --- run it again if this changes). At 200 the longest uninterrupted block was
# 12.2ms on a dev Mac, i.e. ~122ms projected onto a Pi — over the ~100ms where
# blocking starts to be audible, so the first guess was wrong and this is the
# corrected value. 150 gives ~9ms here and ~90ms there, with the yield between
# chunks letting audio and the image proxy run.
#
# Lower is not free: every chunk is its own transaction, so halving this doubles
# the commit count for the same rows.
use constant INGEST_CHUNK => 150;

sub ingestFeed {
    my ($feed, $releases, %opt) = @_;
    my $out = { ok => 0, stored => 0, added => 0, removed => 0, refused => 0, generation => 0 };
    my $h = dbh() or return $out;
    return $out unless defined $feed && length $feed;

    $releases = [] unless ref $releases eq 'ARRAY';
    my $now    = $opt{now} || time();
    my $rotate = exists $opt{rotate} ? ($opt{rotate} ? 1 : 0) : 1;
    my @days   = _dayRange($opt{from}, $opt{to});

    my $have = int(eval {
        $h->selectrow_array('SELECT COUNT(*) FROM feed_member WHERE feed = ?', undef, $feed)
    } || 0);

    # RULE 1. Note the attempt, delete nothing, tell the caller it was refused.
    if (!@$releases && $have) {
        $log->warn("store: refusing an empty ingest for '$feed' — $have rows already stored");
        feedNoteAttempt($feed, $opt{from}, $opt{to}, $now);
        $out->{stored}  = $have;
        $out->{refused} = 1;
        return $out;
    }

    my ($added, $changed, $removed, $stored) = (0, 0, 0, 0);
    my %perDay;

    # ---- one chunk of rows, in its own transaction --------------------------
    # Returns 1 on success, 0 on failure. Everything it accumulates ($added,
    # $changed, $stored, %perDay) is closed over, so a chunked pass and a
    # synchronous one build exactly the same totals.
    my $doRows = sub {
        my ($from_i, $to_i) = @_;
        return 1 if $from_i > $to_i;
        return eval {
        $h->begin_work;

        # prepare_cached, not prepare: chunking would otherwise re-prepare these
        # three statements once per chunk. Same reason the 0.9.174 review moved
        # _execBlob onto prepare_cached — the cost of GETTING a value there is
        # what the per-row review missed.
        my $selRel = $h->prepare_cached(
            'SELECT rel_date, week_start, rg_mbid, artist_mbids, caa_rel_mbid, dedupe_key, base_version
               FROM release WHERE rel_id = ?');
        my $selMem = $h->prepare_cached('SELECT 1 FROM feed_member WHERE feed = ? AND rel_id = ?');
        my $insMem = $h->prepare_cached('INSERT OR REPLACE INTO feed_member (feed, rel_id, seen_at) VALUES (?, ?, ?)');

        for my $rel (@{$releases}[$from_i .. $to_i]) {
            next unless ref $rel eq 'HASH';
            my $id = eval { relId($rel) } // '';
            next unless length $id;

            my $cols = _relCols($rel);
            $perDay{ $cols->{rel_date} }++ if length $cols->{rel_date};

            $selRel->execute($id);
            my $old = $selRel->fetchrow_hashref;
            $selRel->finish;

            unless ($old) {
                _execBlob($h,
                    'INSERT INTO release (rel_id, base_version, payload, rel_date, week_start,
                                          rg_mbid, artist_mbids, caa_rel_mbid, dedupe_key,
                                          first_seen, seen_at)
                     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
                    3, $id, BASE_VERSION, _freeze($rel),
                    @{$cols}{qw(rel_date week_start rg_mbid artist_mbids caa_rel_mbid dedupe_key)},
                    $now, $now);
                $changed++;
            }
            else {
                # MERGE, NEVER BLANK: an incoming empty leaves the stored value.
                my %merged;
                for my $c (qw(rel_date week_start rg_mbid artist_mbids caa_rel_mbid dedupe_key)) {
                    $merged{$c} = length($cols->{$c} // '') ? $cols->{$c} : ($old->{$c} // '');
                }
                # Generation tracks the QUERYABLE shape of the feed — the member set
                # and the mirrored columns. A payload edit that moves none of them
                # (LB filling a field nothing queries) deliberately does not move it;
                # the memos it guards are second-scale, so that cannot go stale
                # visibly, and reading 3,255 blobs back to compare them would cost
                # more than the whole ingest.
                $changed++ if int($old->{base_version} // -1) != BASE_VERSION
                           || grep { ($old->{$_} // '') ne $merged{$_} }
                                   qw(rel_date rg_mbid caa_rel_mbid dedupe_key);

                _execBlob($h,
                    'UPDATE release SET base_version = ?, payload = ?, rel_date = ?, week_start = ?,
                                        rg_mbid = ?, artist_mbids = ?, caa_rel_mbid = ?,
                                        dedupe_key = ?, seen_at = ?
                      WHERE rel_id = ?',
                    2, BASE_VERSION, _freeze($rel),
                    @merged{qw(rel_date week_start rg_mbid artist_mbids caa_rel_mbid dedupe_key)},
                    $now, $id);
            }

            $selMem->execute($feed, $id);
            my $wasMember = $selMem->fetchrow_arrayref ? 1 : 0;
            $selMem->finish;
            $added++ unless $wasMember;

            $insMem->execute($feed, $id, $now);
            $stored++;
        }

        $h->commit;
        1;
        } || do {
            eval { $h->rollback };
            $log->error("store: feed ingest chunk for '$feed' failed: $@");
            0;
        };
    };

    # ---- the FINISH step: rotation + coverage, once, after every row is in ----
    # THE ORDER HERE IS THE SAFETY PROPERTY, not a tidiness preference. Rotation
    # deletes rows this pass did not re-see, so it is only sound once the pass is
    # KNOWN COMPLETE — running it after a partial pass would delete rows merely
    # not reached yet, which is rule 1 ("an empty result is never a fact") failing
    # from a third direction. `ok_at` is stamped in the same transaction, so a feed
    # can never read as fresh unless rotation actually ran.
    my $finish = sub {
        return eval {
        $h->begin_work;

        # RULE 2. Window-scoped, and only over rows this pass could have re-seen.
        if ($rotate && $opt{from} && $opt{to} && @$releases) {
            $removed = int($h->do(
                'DELETE FROM feed_member
                  WHERE feed = ? AND seen_at < ?
                    AND rel_id IN (SELECT rel_id FROM release
                                    WHERE rel_date >= ? AND rel_date <= ?)',
                undef, $feed, $now, $opt{from}, $opt{to}) || 0);
        }

        # A day inside the requested window with no releases is a REAL answer, and
        # recording it is what stops that day being re-fetched for ever.
        my $insDay = $h->prepare(
            'INSERT OR REPLACE INTO feed_day (feed, day, fetched_at, ok_at, n_items) VALUES (?, ?, ?, ?, ?)');
        $insDay->execute($feed, $_, $now, $now, int($perDay{$_} // 0)) for @days;

        my $total = int($h->selectrow_array(
            'SELECT COUNT(*) FROM feed_member WHERE feed = ?', undef, $feed) || 0);

        my ($gen) = $h->selectrow_array('SELECT generation FROM feed_meta WHERE feed = ?', undef, $feed);
        $gen = int($gen // 0);
        $gen++ if $added || $removed || $changed;

        $h->do('INSERT OR REPLACE INTO feed_meta (feed, fetched_at, ok_at, generation, n_items)
                VALUES (?, ?, ?, ?, ?)', undef, $feed, $now, $now, $gen, $total);

        $h->commit;
        $out->{generation} = $gen;
        $out->{stored}     = $total;
        1;
        } || do {
            eval { $h->rollback };
            $log->error("store: feed ingest finish for '$feed' failed: $@");
            0;
        };
    };

    my $last = $#$releases;

    # ---- report, shared by both modes ---------------------------------------
    my $report = sub {
        my ($ok) = @_;
        return $out unless $ok;
        $out->{ok}      = 1;
        $out->{added}   = $added;
        $out->{removed} = $removed;
        $log->info("store: ingested '$feed' — $out->{stored} rows (+$added, -$removed),"
                 . " generation $out->{generation}");
        return $out;
    };

    # ---- CHUNKED: yield between chunks so audio and the image proxy can run ---
    # Timers are required lazily and the whole thing degrades to synchronous if
    # they are unavailable — DB.pm is loadable with only Log and Prefs stubbed
    # (t_db.pl), and a store that dies because a scheduler is missing would be a
    # worse failure than the stall this fixes.
    my $chunk = int($opt{chunk} // 0);
    if ($chunk > 0 && $last >= 0 && eval { require Slim::Utils::Timers; 1 }) {
        my $i = 0;
        my $step;
        $step = sub {
            my (undef, $self) = @_;  # the timer calls $step->($obj, @args), so the
                               # self-reference arrives in the SECOND slot — same
                               # signature as the steppers in Browse.pm. Passed to
                               # itself rather than captured, which is the
                               # uncollectable reference cycle fixed in
                               # getArtistMbidByName in 0.9.95.
            my $hi = $i + $chunk - 1;
            $hi = $last if $hi > $last;
            unless ($doRows->($i, $hi)) {
                # A failed chunk abandons the pass WITHOUT stamping coverage, so
                # the feed stays stale and the next open revalidates. Rows already
                # committed are merged, never half-written, so they are safe to keep.
                $opt{onDone}->($out) if ref $opt{onDone} eq 'CODE';
                return;
            }
            $i = $hi + 1;
            if ($i > $last) {
                my $ok = $finish->();
                $report->($ok);
                $opt{onDone}->($out) if ref $opt{onDone} eq 'CODE';
                return;
            }
            Slim::Utils::Timers::setTimer(undef, Time::HiRes::time(), $self, $self);
        };
        $step->(undef, $step);   # first turn runs inline, with the timer's own shape
        # The caller gets the REFUSAL VERDICT synchronously (which is all either
        # call site reads) and renders from the payload it just fetched; the totals
        # arrive via onDone. Marked in-progress so nothing mistakes this for done.
        $out->{chunked} = 1;
        return $out;
    }

    # ---- SYNCHRONOUS: the original behaviour, kept for tests and the sweep ----
    for (my $i = 0; $i <= $last; $i += $chunk > 0 ? $chunk : $last + 1) {
        my $hi = $chunk > 0 ? $i + $chunk - 1 : $last;
        $hi = $last if $hi > $last;
        return $out unless $doRows->($i, $hi);
    }
    return $out unless $finish->();
    return $report->(1);
}

# A FETCH THAT DID NOT ANSWER. `fetched_at` moves, `ok_at` does not, and no row is
# touched — so a 429, a timeout or an unparseable 200 leaves the stored feed
# exactly as it was AND leaves the day still marked uncovered, which is what makes
# the next open try again instead of believing the gap was real.
sub feedNoteAttempt {
    my ($feed, $from, $to, $now) = @_;
    my $h = dbh() or return 0;
    return 0 unless defined $feed && length $feed;
    $now ||= time();

    # INSERT OR IGNORE + a targeted UPDATE, not SQLite's UPSERT/`excluded` syntax —
    # the same reason _factPut avoids it: that needs 3.24+ and would tie the
    # plugin's storage to whichever SQLite is bundled with the user's LMS. The
    # UPDATE touches `fetched_at` ALONE, so a day that was previously covered keeps
    # its `ok_at` and does not become uncovered because one later fetch failed.
    eval {
        my $ins = $h->prepare('INSERT OR IGNORE INTO feed_day (feed, day, fetched_at, ok_at, n_items) VALUES (?, ?, ?, 0, 0)');
        my $upd = $h->prepare('UPDATE feed_day SET fetched_at = ? WHERE feed = ? AND day = ?');
        for my $day (_dayRange($from, $to)) {
            $ins->execute($feed, $day, $now);
            $upd->execute($now, $feed, $day);
        }
        $h->do('INSERT OR IGNORE INTO feed_meta (feed, fetched_at, ok_at, generation, n_items) VALUES (?, ?, 0, 0, 0)',
               undef, $feed, $now);
        $h->do('UPDATE feed_meta SET fetched_at = ? WHERE feed = ?', undef, $now, $feed);
        1;
    } or $log->warn("store: recording a failed attempt for '$feed' failed: $@");

    return 1;
}

# Mark a feed's coverage stale WITHOUT deleting a single row — what the "Refresh
# (force update now)" row does now. The old Refresh removed the cache key, which
# meant the feed was GONE until the fetch came back; here the user keeps seeing
# releases while the re-fetch runs behind them.
sub feedInvalidate {
    my ($feed) = @_;
    my $h = dbh() or return 0;
    return 0 unless defined $feed && length $feed;
    eval {
        $h->do('UPDATE feed_day  SET ok_at = 0 WHERE feed = ?', undef, $feed);
        $h->do('UPDATE feed_meta SET ok_at = 0 WHERE feed = ?', undef, $feed);
        1;
    } or return 0;
    return 1;
}

# Prune members nothing has re-seen in $maxAge seconds, then the release rows no
# feed points at any more.
#
# WHY IT EXISTS AT ALL: rows no longer expire, so the one behaviour that genuinely
# changes with this store is that a PERMANENTLY dead feed would otherwise show
# months-old releases for ever. The date-span subtitle on the category tile already
# makes that visible; this bounds it. 120 days is comfortably beyond the four-week
# window's reach, so it can never take a row the window still wants — and MuSpy
# rows are deliberately held here far beyond what is DISPLAYED, precisely so a
# release announced months out is already stored when the window rolls onto it.
use constant MEMBER_MAX_AGE => 120 * 86400;

sub feedSweep {
    my ($maxAge) = @_;
    my $h = dbh() or return 0;
    $maxAge = MEMBER_MAX_AGE unless defined $maxAge && $maxAge > 0;
    my $cutoff = time() - $maxAge;

    my $n = 0;
    eval {
        $n += int($h->do('DELETE FROM feed_member WHERE seen_at > 0 AND seen_at < ?', undef, $cutoff) || 0);
        $n += int($h->do('DELETE FROM feed_day WHERE fetched_at > 0 AND fetched_at < ?', undef, $cutoff) || 0);
        $n += int($h->do('DELETE FROM release
                           WHERE seen_at > 0 AND seen_at < ?
                             AND rel_id NOT IN (SELECT rel_id FROM feed_member)', undef, $cutoff) || 0);
        1;
    } or $log->warn("store: feed sweep failed: $@");
    return $n;
}

# ---------------------------------------------------------------------------
# FACTS — the `artist` table.
#
# Keyed by MBID where there is one, else `n:<normalised name>`. The hosted
# LMS-community API is NAME-keyed with no MBID lookup anywhere (`/artist/<mbid>`
# returns a bare `{}`), so a name key is not a convenience — it is the only key
# that tier can answer to. It also means this table can carry a genre for a
# Trending row that arrives with no MBID at all, which no other genre tier can.
#
# `fetched_at` REPLACES A TTL. Staleness is decided in Perl by the caller, so no
# duration is ever handed to LMS and no value can mean 1970.
#
# WRITES MERGE, THEY NEVER BLANK. Different tiers fill different columns — the
# hosted tier writes genres, the sort tier writes sort_name — and they arrive in
# either order. Done as INSERT OR IGNORE + a targeted UPDATE of only the columns
# the caller actually supplied, rather than SQLite's UPSERT/excluded syntax, which
# needs 3.24+ and would tie the plugin's storage to the SQLite version bundled
# with whichever LMS the user is running.
# ---------------------------------------------------------------------------

# THE THREE FACTS TABLES SHARE ONE IMPLEMENTATION, because they are the same
# thing three times: a keyed row, some typed columns, some frozen ones, a
# `fetched_at` stamp and a merge rule. Three hand-written copies is precisely how
# one of them ends up with a subtly different merge — and a merge that blanks is
# invisible until the tier it blanked is the one somebody is looking for.
#
# `alias` maps the CALLER's field names onto columns, in both directions, so
# API.pm's parsed hashes go in and come out in the shape its own code already
# uses (`date`, `release_group_mbid`) without a translation layer at every site.
#
# `stamp` maps a WRITTEN column onto the timestamp that records when THAT answer
# was obtained. It is what stops one tier's write re-aging another's: a row holds
# several independent facts with different lifetimes, and `fetched_at` alone
# cannot say which of them was actually refreshed. Two columns may share a stamp
# when they genuinely arrive on one request (`genres`/`agenres` do).
my %FACT = (
    artist => {
        table => 'artist',
        key   => 'artist_key',
        text  => [qw(mbid name sort_name sort_src artist_type)],
        blobs => [qw(lb_genres hosted_genres lastfm_genres mb_genres)],
        stamp => {
            lb_genres     => 'lb_genres_at',
            hosted_genres => 'hosted_genres_at',
            lastfm_genres => 'lastfm_genres_at',
            mb_genres     => 'mb_genres_at',
            sort_name     => 'sort_at',
        },
        alias => {},
    },
    release_group => {
        table => 'release_group',
        key   => 'rg_mbid',
        text  => [qw(name year rel_date type)],
        # `detail_genres` carries its OWN stamp. `genres`/`agenres` share one
        # because ONE ListenBrainz request answers both; the detail page's answer
        # comes from a different source at a different time, so sharing theirs
        # would let one tier declare another fresh — the defect schema 3 exists to
        # prevent. See _migrate_5.
        blobs => [qw(genres agenres detail_genres)],
        stamp => {
            genres        => 'genres_at',
            agenres       => 'genres_at',
            detail_genres => 'detail_genres_at',
        },
        alias => { date => 'rel_date' },
    },
    recording => {
        table => 'recording',
        key   => 'rec_mbid',
        text  => [qw(artist title album rg_mbid year)],
        blobs => [],
        alias => { release_group_mbid => 'rg_mbid' },
    },
);

# Read many at once. The render path asks for a whole PAGE of rows, and one
# statement beats N round trips — a per-row read here is the ~2,900 synchronous
# SELECTs that bench_walk.pl caught in 0.9.165 and that 0.9.130 moved off the
# render path in the first place. Returns { key => row } holding only the keys
# actually present; a frozen column comes back as its arrayref, or undef.
sub _factGet {
    my ($kind, $keys) = @_;
    my $spec = $FACT{$kind} or return {};
    my $h = dbh() or return {};
    my @k = grep { defined && length } @{ $keys || [] };
    return {} unless @k;

    my %stampCols = map { $_ => 1 } values %{ $spec->{stamp} || {} };
    my @cols = ($spec->{key}, 'fact_version', @{ $spec->{text} }, @{ $spec->{blobs} },
                (map { "n_$_" } @{ $spec->{blobs} }), sort(keys %stampCols), 'fetched_at');
    my $sel  = join(', ', @cols);
    my %alias = %{ $spec->{alias} };   # caller's field name => column name

    my %out;
    # Chunked: SQLite's default SQLITE_MAX_VARIABLE_NUMBER is 999, and a feed page
    # can ask for more rows than that.
    while (my @chunk = splice(@k, 0, 500)) {
        my $ph   = join(',', ('?') x @chunk);
        my $rows = eval {
            $h->selectall_arrayref(
                "SELECT $sel FROM $spec->{table} WHERE $spec->{key} IN ($ph)",
                { Slice => {} }, @chunk)
        } || [];
        for my $r (@$rows) {
            my $id = $r->{ $spec->{key} };
            for my $b (@{ $spec->{blobs} }) {
                my (undef, $v) = _thaw($r->{$b}, "$kind $id/$b");
                $r->{$b} = ref $v eq 'ARRAY' ? $v : undef;
            }
            # Hand back the caller's own field names ALONGSIDE the columns, so a
            # reader written against the parsed API shape needs no translation and
            # one written against the schema still works. Direction matters:
            # field <- column, never the reverse, which would clobber the column
            # with undef.
            $r->{$_} = $r->{ $alias{$_} } for keys %alias;
            $out{$id} = $r;
        }
    }
    return \%out;
}

# %fields may carry any of the table's text columns (under either the column name
# or the caller's alias), any of its blob columns as an arrayref, and
# `fact_version`. ANYTHING ABSENT IS LEFT ALONE — that is the merge rule, and it
# is what lets different tiers fill different columns in either order (the hosted
# tier writes genres, the sort tier writes sort_name).
#
# AN EMPTY ARRAYREF IS A REAL ANSWER, NOT A MISS. The hosted API returns `[]` for
# an artist it knows and has no genres for (Panda Bear), which is a DIFFERENT
# answer from the `genres` key being absent (Radiohead). Storing it is what stops
# the warm re-asking for the ~half of artists that will never answer.
#
# INSERT OR IGNORE + a targeted UPDATE rather than SQLite's UPSERT/`excluded`
# syntax, which needs 3.24+ and would tie the plugin's storage to whichever SQLite
# is bundled with the user's LMS.
sub _factPut {
    my ($kind, $key, %fields) = @_;
    my $spec = $FACT{$kind} or return 0;
    my $h = dbh() or return 0;
    return 0 unless defined $key && length $key;

    # Normalise the caller's aliases onto column names before anything looks at
    # them, so `date` and `rel_date` cannot both be present and disagree.
    while (my ($from, $to) = each %{ $spec->{alias} }) {
        $fields{$to} = delete $fields{$from} if exists $fields{$from} && !exists $fields{$to};
    }

    my $ok = eval {
        $h->do("INSERT OR IGNORE INTO $spec->{table} ($spec->{key}) VALUES (?)", undef, $key);

        my (@set, @args, %stamped);
        my $stampFor = $spec->{stamp} || {};
        my $now      = $fields{fetched_at} // time();

        for my $col (@{ $spec->{text} }) {
            next unless exists $fields{$col};
            push @set, "$col = ?";
            push @args, ($fields{$col} // '');
            $stamped{ $stampFor->{$col} } = 1 if $stampFor->{$col};
        }
        if (exists $fields{fact_version}) {
            push @set, 'fact_version = ?';
            push @args, int($fields{fact_version} // 0);
        }
        push @set, 'fetched_at = ?';
        push @args, $now;

        my @blobPos;
        for my $b (@{ $spec->{blobs} }) {
            next unless exists $fields{$b};
            push @set, "$b = ?";
            push @args, _freeze($fields{$b});
            push @blobPos, scalar(@args);     # 1-based bind position of this arg

            # Mirror the LENGTH into an integer alongside it. A frozen blob cannot
            # be counted in SQL, and without this `cachestats` cannot answer the
            # only question anyone asks it about genres. -1 = never asked, 0 = asked
            # and the answer was none.
            push @set, "n_$b = ?";
            push @args, (ref $fields{$b} eq 'ARRAY' ? scalar @{ $fields{$b} } : -1);
            $stamped{ $stampFor->{$b} } = 1 if $stampFor->{$b};
        }

        # ONLY the answers this call actually wrote are stamped. `fetched_at` above
        # still records "the row was touched", but nothing judges a tier's freshness
        # by it any more — that is the whole point. A sort-name write must not make
        # the genres beside it look freshly fetched.
        for my $s (sort keys %stamped) {
            push @set, "$s = ?";
            push @args, $now;
        }

        my $sql = "UPDATE $spec->{table} SET " . join(', ', @set) . " WHERE $spec->{key} = ?";
        if (@blobPos) {
            # Bound explicitly as blobs, so frozen bytes come back as bytes.
            _execBlob($h, $sql, \@blobPos, @args, $key);
        } else {
            $h->do($sql, undef, @args, $key);
        }
        1;
    };
    $log->warn("store: $kind write failed for $key: $@") unless $ok;
    return $ok ? 1 : 0;
}

sub artistGet { return _factGet('artist', @_) }
sub artistPut { return _factPut('artist', @_) }

# The album's own genres and its credited artist's, plus the first-release date
# and primary type — everything ListenBrainz's bulk `inc=release_group tag` call
# returns, which is the call the genre tiers ride on.
#
# SEPARATE FROM `release`, and it has to be: several releases share a group, so
# genres on the release row would duplicate N ways and could disagree, and the
# Trending path looks up groups that never appeared in any feed at all.
sub rgGet { return _factGet('release_group', @_) }
sub rgPut { return _factPut('release_group', @_) }

sub recGet { return _factGet('recording', @_) }
sub recPut { return _factPut('recording', @_) }

# A MusicBrainz sort-name is one of the three things that were never caches: it is
# re-derivable only at SORT_WARM_MAX(100) artists per pass, serially, with a
# courtesy gap between each — so a wipe costs a multi-day reconvergence on an
# artist-sorted view. It lives here rather than in `kv` for that reason, and the
# dev-build genre wipe deliberately leaves it alone.
#
# `sort_src` records WHICH tier answered ('mb' | 'local' | 'hosted'), so the
# MusicBrainz tier and the local tier can be re-run independently.
sub artistSortGet {
    my ($keys) = @_;
    my $got = artistGet($keys);
    my %out;
    for my $k (keys %$got) {
        next unless length($got->{$k}{sort_name} // '');
        $out{$k} = $got->{$k}{sort_name};
    }
    return \%out;
}

sub artistSortPut {
    my ($key, $sortName, $src) = @_;
    return artistPut($key, sort_name => ($sortName // ''), sort_src => ($src // 'mb'));
}

# ---------------------------------------------------------------------------
# Key-version retirement.
#
# Callers pass the { family => version } map above; every row under a family whose
# key does NOT carry the current version is dropped at startup, so a bump reclaims
# its own space instead of stranding the old family for the length of its TTL.
#
# `family` includes its trailing colon ('lbf:track:'), and the retained keys are
# exactly those starting 'lbf:track:<version>:'.
# ---------------------------------------------------------------------------
sub retirePrefixes {
    my ($versions) = @_;
    return 0 unless ref $versions eq 'HASH';
    my $h = dbh() or return 0;

    my $total = 0;
    for my $family (sort keys %$versions) {
        next unless length($family // '');
        my $keep = $family . $versions->{$family} . ':';
        my $like = $family;
        $like =~ s/([%_\\])/\\$1/g;
        my $n = eval {
            $h->do("DELETE FROM kv WHERE k LIKE ? ESCAPE '\\' AND k NOT LIKE ? ESCAPE '\\'",
                   undef, $like . '%', do { my $k = $keep; $k =~ s/([%_\\])/\\$1/g; $k . '%' });
        } || 0;
        next unless $n > 0;
        $total += int($n);
        $log->info("store: retired " . int($n) . " stale $family rows (now $keep)");
    }
    return $total;
}

# ---------------------------------------------------------------------------
# Wipes
# ---------------------------------------------------------------------------

# THE DEV-BUILD WIPE. One unconditional statement with no allowlist to get wrong —
# which is only safe because anything that must survive has a table. Do not add
# exceptions here; move the data instead.
sub wipeDerived {
    my $h = dbh() or return 0;
    my $n = eval { $h->do('DELETE FROM kv') } || 0;
    return int($n);
}

# The dev-build wipe's FACTS half: genres only. Years, types, MBIDs and
# sort-names survive deliberately, so a genre change never re-inflicts a
# multi-day artist-sort reconvergence.
sub wipeGenres {
    my $h = dbh() or return 0;
    my $n = 0;
    eval {
        # EVERY TIER, AND EACH ONE'S STAMP WITH IT. Zeroing the stamp is what makes
        # the wipe RECOVERABLE: a cleared answer whose timestamp still says "just
        # fetched" is unaskable until it ages out, which on release groups meant
        # NINETY DAYS of empty rows and no traffic trying to fix them (0.9.166).
        # Clearing the answer and leaving its clock running is the bug; the two
        # always move together.
        #
        # `fetched_at`, `year`, `rel_date`, `type` and the sort-name are deliberately
        # untouched — they are different answers on the same rows, and re-fetching
        # every date in the feed to repair a genre parse is exactly the cost per-answer
        # stamps exist to avoid.
        $n += $h->do("UPDATE release_group SET genres = NULL, agenres = NULL,
                                               n_genres = -1, n_agenres = -1,
                                               genres_at = 0,
                                               detail_genres = NULL,
                                               n_detail_genres = -1,
                                               detail_genres_at = 0");
        $n += $h->do("UPDATE artist SET lb_genres = NULL, n_lb_genres = -1, lb_genres_at = 0,
                                        hosted_genres = NULL, n_hosted_genres = -1,
                                        hosted_genres_at = 0,
                                        lastfm_genres = NULL, n_lastfm_genres = -1,
                                        lastfm_genres_at = 0,
                                        mb_genres = NULL, n_mb_genres = -1,
                                        mb_genres_at = 0");
        # Last.fm is a genre tier too, and it is in the store now — a wipe that left
        # it behind would leave the ladder's bottom rung serving pre-wipe answers.
        $n += $h->do("DELETE FROM lastfm_tags");
        1;
    } or $log->warn("store: genre wipe failed: $@");
    return int($n);
}

# ---------------------------------------------------------------------------
# THE LAST.FM TIER'S OWN TABLE. Keyed as the rung keys it (artist + album, lower
# -cased), because it asks album.gettoptags before falling back to
# artist.gettoptags — the answer is release-specific, so it cannot live on the
# artist row.
#
# An EMPTY list is stored, and that is the whole point of `n_tags`: "asked, and
# Last.fm had nothing" is a fact worth keeping, distinct from "never asked". The
# read side gives an empty answer a shorter life than a populated one, so it comes
# back round eventually without being re-asked on every pass.
# ---------------------------------------------------------------------------
sub lfmGet {
    my ($key) = @_;
    return undef unless defined $key && length $key;
    my $h = dbh() or return undef;
    my $r = eval {
        $h->selectrow_hashref('SELECT tags, n_tags, fetched_at FROM lastfm_tags WHERE lfm_key = ?',
                              undef, $key)
    } or return undef;
    my (undef, $v) = _thaw($r->{tags}, "lastfm_tags/$key");
    return {
        tags       => (ref $v eq 'ARRAY' ? $v : undef),
        n_tags     => int($r->{n_tags} // -1),
        fetched_at => int($r->{fetched_at} // 0),
    };
}

sub lfmPut {
    my ($key, $tags) = @_;
    return 0 unless defined $key && length $key;
    my $h = dbh() or return 0;
    my $ok = eval {
        _execBlob($h,
            'INSERT OR REPLACE INTO lastfm_tags (lfm_key, tags, n_tags, fetched_at)
             VALUES (?, ?, ?, ?)',
            [2], $key, _freeze($tags), (ref $tags eq 'ARRAY' ? scalar @$tags : -1), time());
        1;
    };
    $log->warn("store: lastfm write failed for $key: $@") unless $ok;
    return $ok ? 1 : 0;
}

# ---------------------------------------------------------------------------
# THE LAZY LEGACY IMPORT.
#
# Moving the reads here is, for every DISPOSABLE family, simply a cold start — the
# plugin re-fetches, exactly as it would after any cache bump. For the three
# families that were never caches it would be DATA LOSS, so they are carried over
# from the outgoing Slim::Utils::Cache.
#
# IT HAS TO BE LAZY, and that is a property of the source, not a convenience:
# Slim::Utils::Cache CANNOT BE ENUMERATED. There is no way to ask it for every
# `lbf:bcmatch:` key it holds, so an eager import would have to guess the ids —
# which means the ids currently in the feed window, which is precisely the set
# that does NOT include the old, hand-pinned, Bandcamp-only album somebody cares
# about. Asking for a specific id at the moment something wants it has no such
# blind spot.
#
# IT IS BOUNDED BY A DEADLINE, not by a "done" flag. A flag would have to be set
# after an import that, being lazy, is never finished; a deadline says the honest
# thing — after IMPORT_WINDOW the old cache has aged out anyway, so stop paying a
# read for it. Until then the cost is one extra local read on a MISS only. The
# deadline lives in a PREF so the dev-build wipe cannot reset it — see
# IMPORT_DEADLINE_PREF.
#
# WHY IT LIVES HERE AND NOT IN Plugin.pm: this is the last place in the plugin that
# touches the LMS cache at all, and keeping it in one place is what lets
# t_ttlceiling.pl assert that no other module does.
#
# BEST EFFORT THROUGHOUT: an LMS without a usable cache, a value that will not
# thaw, a missing username — each skips that item, never the rest.
# ---------------------------------------------------------------------------
# THE DEADLINE IS A PREF, NOT A `kv` ROW, and that is not a style choice. The
# dev-build wipe is one unconditional `DELETE FROM kv` (wipeDerived), so a deadline
# kept there is deleted by every build and re-minted at `time() + 180 days` on the
# next miss — a window that can never elapse, and therefore an extra
# Slim::Utils::Cache read on every store miss FOR EVER. That is precisely the cost
# IMPORT_WINDOW exists to stop paying. It is also what this module's own header
# rule says: IF IT IS IN `kv` IT IS DISPOSABLE, and this is not. _buildChanged's
# marker is a pref for the identical reason.
use constant IMPORT_DEADLINE_PREF => 'legacy_import_until';
use constant IMPORT_WINDOW        => 180 * 86400;

my ($legacyCache, $legacyTried);

sub _legacy {
    my $until = $prefs->get(IMPORT_DEADLINE_PREF);
    unless (defined $until) {
        $until = time() + IMPORT_WINDOW;
        $prefs->set(IMPORT_DEADLINE_PREF, $until);
    }
    return undef if time() > $until;

    return $legacyCache if $legacyTried;
    $legacyTried = 1;
    $legacyCache = eval {
        require Slim::Utils::Cache;
        Slim::Utils::Cache->new();
    };
    $log->warn("store: legacy import unavailable — no LMS cache ($@)") unless $legacyCache;
    return $legacyCache;
}

# A Bandcamp pin, asked for by release id at the moment the detail page misses.
# Returns the imported payload (so the caller can use it on this very render) or
# undef.
sub importPin {
    my ($relId) = @_;
    return undef unless defined $relId && length $relId;
    my $c = _legacy() or return undef;

    my $key = 'lbf:bcmatch:6:' . $relId;
    utf8::encode($key) if utf8::is_utf8($key);
    my $v = eval { $c->get($key) };
    return undef unless ref $v eq 'HASH' && ref $v->{items} eq 'ARRAY' && @{ $v->{items} };

    bcPinPut($relId, $v);
    $log->info("store: imported a legacy Bandcamp pin for $relId");
    return $v;
}

# The recommendation store — one blob, so one read, done when the table is empty
# for this user. Returns how many rows were added.
sub importFollow {
    my ($username) = @_;
    return 0 unless defined $username && length $username;
    my $c = _legacy() or return 0;

    my $v = eval { $c->get('lbf:follow:accum:1:' . $username) };
    return 0 unless ref $v eq 'HASH' && ref $v->{tracks} eq 'ARRAY' && @{ $v->{tracks} };

    my @items;
    for my $t (@{ $v->{tracks} }) {
        next unless ref $t eq 'HASH';
        my $k = $t->{recording_mbid}
            ? "m:$t->{recording_mbid}"
            : 't:' . lc(($t->{artist} // '') . '|' . ($t->{title} // ''));
        push @items, { %$t, _key => $k };
    }
    my $n = followAdd($username, \@items);
    $log->info("store: imported $n legacy recommendations for $username") if $n;
    return $n;
}

# Artist sort-names, in bulk, for the MBIDs a warm pass was about to fetch. The
# value was written through API::_setText, so it is `{ t => ... }`; a legacy BARE
# string is read too, because 0.9.141's fix deliberately left old entries readable.
# Returns { lc mbid => sort-name } for EVERY key it wrote, empty strings included —
# the caller re-reads exactly these, and an artist whose recorded answer is "MB has
# none" must be among them or the warm queues it for a fetch anyway, which is the
# work this exists to avoid.
sub importSorts {
    my ($mbids) = @_;
    return {} unless ref $mbids eq 'ARRAY' && @$mbids;
    my $c = _legacy() or return {};

    my (%got, $named);
    for my $mbid (@$mbids) {
        next unless defined $mbid && length $mbid;
        my $lc = lc $mbid;
        my $v = eval { $c->get('lbf:artistsort:1:' . $lc) };
        next unless defined $v;
        my $sort = ref $v eq 'HASH' ? $v->{t} : (ref $v ? undef : $v);
        next unless defined $sort;
        # An empty string is a real answer here ("MB has no sort-name for this
        # artist"), and carrying it over is what stops the warm re-asking
        # MusicBrainz for every artist it had already established has none.
        artistSortPut($lc, $sort, 'mb');
        $got{$lc} = $sort;
        $named++ if length $sort;
    }
    $log->info("store: imported " . scalar(keys %got) . " legacy sort-names ($named named)") if %got;
    return \%got;
}

# ---------------------------------------------------------------------------
# Reporting — what ["lbf","cachestats"] renders.
#
# It exists because a silently failing write is indistinguishable from a fix that
# was never installed, and the only way to tell them apart is to look at the store
# from outside the process that wrote it (and again after a restart).
# ---------------------------------------------------------------------------
my @TABLES = qw(release feed_member feed_day feed_meta bandcamp_pin follow_item
                release_group recording artist lastfm_tags kv);

sub stats {
    my $h = dbh();
    return { ok => 0, path => _path(), tables => {} } unless $h;

    my %t;
    for my $tbl (@TABLES) {
        $t{$tbl} = int(eval { $h->selectrow_array("SELECT COUNT(*) FROM $tbl") } || 0);
    }

    my %extra;
    $extra{kv_expired} = int(eval {
        $h->selectrow_array('SELECT COUNT(*) FROM kv WHERE expires_at > 0 AND expires_at < ?',
                            undef, time())
    } || 0);
    # GENRE COVERAGE, REPORTED HONESTLY — three states per tier, because two of
    # them look identical from the outside and only one of them is a problem:
    #   *_have   asked, and got at least one genre
    #   *_none   asked, and the answer really was "none" (a REAL answer from both
    #            ListenBrainz and the hosted API — not a miss, and not re-asked)
    #   *_never  never looked
    # The previous version of this counted `genres_src <> ''`. NOTHING in the
    # plugin writes that column on release_group, so `rg_genres` was 0 by
    # construction — not "0 because the store is empty", 0 because the query
    # could not have returned anything else. On `artist` it is written only by
    # the hosted tier and by the MusicBrainz mirror path, so it could not see
    # ListenBrainz's own artist tags either. The one instrument for diagnosing
    # "genres are not populating" was reporting on a column three of the four
    # writers never touch.
    my $count = sub {
        my ($sql) = @_;
        return int(eval { $h->selectrow_array($sql) } || 0);
    };
    # PER TIER, because the whole ladder is per tier now. A single "artist genres"
    # figure could not say WHICH rung answered, so it could not tell a working
    # ladder from one rung carrying all of it.
    #
    # `hosted` IS DELIBERATELY ABSENT since 0.9.173. Nothing writes
    # n_hosted_genres any more, so the three counters would report a frozen
    # snapshot of a rung that no longer exists — and a reader diagnosing "genres
    # are not populating" would see a populated-looking tier that cannot be
    # contributing. That is precisely the failure this whole block was written to
    # replace (a count over a column no writer touches), so it must not be
    # reintroduced for the sake of completeness. The COLUMN stays; the instrument
    # does not report on it.
    #
    # `mb` STAYS, and reads 0/0/all-never on any box without a local MusicBrainz
    # mirror — that is not a dead rung, it is a rung this box cannot reach. See
    # _genreLookupMode: with `mb_base_url` pointing at the public API,
    # hasMirror() is false and the mirror path never runs at all.
    for my $t (['lb', 'n_lb_genres'],
               ['lastfm', 'n_lastfm_genres'], ['mb', 'n_mb_genres']) {
        my ($name, $col) = @$t;
        $extra{"artist_${name}_have"}  = $count->("SELECT COUNT(*) FROM artist WHERE $col > 0");
        $extra{"artist_${name}_none"}  = $count->("SELECT COUNT(*) FROM artist WHERE $col = 0");
        $extra{"artist_${name}_never"} = $count->("SELECT COUNT(*) FROM artist WHERE $col < 0");
    }
    # The album-keyed table is now the DETAIL PAGE's tier only; the artist-level
    # answer the list rows read lives in artist.lastfm_genres, counted above.
    $extra{lastfm_album_have} = $count->("SELECT COUNT(*) FROM lastfm_tags WHERE n_tags > 0");
    $extra{rg_genres_have}      = $count->("SELECT COUNT(*) FROM release_group WHERE n_genres > 0");
    $extra{rg_agenres_have}     = $count->("SELECT COUNT(*) FROM release_group WHERE n_agenres > 0");
    $extra{rg_genres_never}     = $count->("SELECT COUNT(*) FROM release_group WHERE n_genres < 0");
    # HOW MANY ANSWERS ARE DUE A RE-CHECK. Nothing here is immutable — an empty
    # answer is re-asked on a short age because tagging lands after release — so
    # "how much is stale right now" is the number that says whether the trickle is
    # working, and it is the one figure that would have shown the 0.9.166 lockout
    # immediately (everything empty, nothing stale, no traffic).
    my $now = time();
    $extra{rg_genres_stale} = $count->(
        "SELECT COUNT(*) FROM release_group
          WHERE n_genres >= 0
            AND genres_at < " . ($now - RG_GENRE_EMPTY_AGE) . "
            AND (n_genres = 0 OR genres_at < " . ($now - RG_GENRE_FOUND_AGE) . ")");
    # NB there is deliberately no counter over `genres_src` on either table. Nothing
    # writes release_group.genres_src at all, so a count over it is 0 forever and
    # reads as evidence about the store when it is only evidence about the schema.
    # That is the exact trap this block replaced — do not add one back.
    $extra{artist_sorts} = int(eval {
        $h->selectrow_array("SELECT COUNT(*) FROM artist WHERE sort_name <> ''")
    } || 0);

    # Per-family kv counts. The whole point of KEY_VERSIONS is that a family is a
    # thing you can name; reporting the total row count alone would have said
    # nothing about WHICH family failed to fill, which is the question every genre
    # diagnosis this year has actually been.
    my %fam;
    for my $family (sort keys %{ (KEY_VERSIONS) }) {
        my $like = kver($family);
        $like =~ s/([%_\\])/\\$1/g;
        $fam{$family} = int(eval {
            $h->selectrow_array("SELECT COUNT(*) FROM kv WHERE k LIKE ? ESCAPE '\\'",
                                undef, $like . '%')
        } || 0);
    }

    # Per-FEED rows, days covered and the age of the last answering fetch. A bare
    # `release` row count cannot say whether All Releases is stored and For You is
    # not, and "which feed is empty" is the question a stage-5/6 verification is
    # actually asking.
    my @feeds;
    my $fr = eval {
        $h->selectall_arrayref(
            'SELECT m.feed, m.fetched_at, m.ok_at, m.generation, m.n_items,
                    (SELECT COUNT(*) FROM feed_member x WHERE x.feed = m.feed) AS rows,
                    (SELECT COUNT(*) FROM feed_day d WHERE d.feed = m.feed AND d.ok_at > 0) AS days
               FROM feed_meta m ORDER BY m.feed', { Slice => {} })
    } || [];
    for my $f (@$fr) {
        push @feeds, {
            feed       => $f->{feed},
            rows       => int($f->{rows} // 0),
            days       => int($f->{days} // 0),
            generation => int($f->{generation} // 0),
            age        => $f->{ok_at} ? (time() - int($f->{ok_at})) : -1,
        };
    }

    return {
        ok       => 1,
        path     => _path(),
        version  => int(eval { $h->selectrow_array('PRAGMA user_version') } || 0),
        bytes    => int((-s _path()) || 0),
        tables   => \%t,
        detail   => \%extra,
        families => \%fam,
        feeds    => \@feeds,
    };
}

# Test seam only: forget the handle so a suite can re-open the file (and prove a
# write survived the process that made it). Never called by plugin code.
sub _reset {
    eval { $dbh->disconnect } if $dbh;
    ($dbh, $broken) = (undef, undef);
    %_KVER_WARNED = ();
    return 1;
}

# ===========================================================================
# The object every module holds in place of its Slim::Utils::Cache handle.
#
# Three methods, the same three signatures, so the ~120 existing call sites did
# not have to be touched to move the storage. Stateless — `store()` can be called
# as often as anyone likes.
#
# Do NOT grow this into a general facade. Anything that needs a table needs a
# NAMED sub on the DB package; the moment durable data can be reached through a
# method called `set`, the rule that makes the tiers self-enforcing is gone.
# ===========================================================================
package Plugins::ListenBrainzFreshReleases::DB::Store;

sub new { return bless {}, $_[0] }

sub get    { shift; return Plugins::ListenBrainzFreshReleases::DB::kvGet(@_) }
sub set    { shift; return Plugins::ListenBrainzFreshReleases::DB::kvSet(@_) }
sub remove { shift; return Plugins::ListenBrainzFreshReleases::DB::kvDel(@_) }

1;
