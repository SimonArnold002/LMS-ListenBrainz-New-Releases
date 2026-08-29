#!/usr/bin/env perl
#
# t_db.pl — the plugin-owned SQLite store, against a REAL file in a temp dir.
#
#   perl tools/t_db.pl
#
# WHAT THIS PROTECTS, AND WHY IT IS NOT "JUST STORAGE".
#
# The store exists because Slim::Utils::Cache ATE DATA SILENTLY here for the whole
# life of the genre feature. DbCache reads any TTL above 2,592,000 as an ABSOLUTE
# Unix epoch rather than a duration, so RECMETA_TTL and AGEN_FOUND_TTL (both 90
# days) wrote entries expiring 1 April 1970: `set` returned 1, nothing died,
# nothing warned, and every read came back undef. Worse, the long TTL was the
# DATED branch — so the entries worth keeping were exactly the ones discarded.
#
# So the assertions here are mostly about the SHAPES OF FAILURE, not happy paths:
#
#   - PERSISTENCE IS PROVED CROSS-PROCESS. `$dbh` is a file-lexical, so a suite
#     that writes and reads in one interpreter is talking to the handle it already
#     holds and proves nothing at all about what reached the disk. Section 8
#     forks a fresh `perl` and reads the file from a process that never wrote it.
#   - A 90-DAY TTL MUST ROUND-TRIP, and `expires_at` must literally be
#     `now + 7776000` — the positive assertion that the defect above is now
#     INEXPRESSIBLE rather than merely corrected.
#   - 0, '' AND undef MUST STAY DISTINGUISHABLE FROM A MISS. Both are meaningful
#     values here (an empty resolve, a "probed and found nothing" marker) and a
#     bare freeze of 0 comes back indistinguishable the moment anything tests
#     truth. That is what the `{ v => … }` wrapper is for.
#   - A BLOB WHOSE BYTES ARE NOT VALID UTF-8 MUST COME BACK BYTE-IDENTICAL.
#     `sqlite_unicode => 1` decodes TEXT on read, so a blob bound without an
#     explicit type is silent corruption waiting to happen — the exact class this
#     module exists to end.
#   - AN UNOPENABLE STORE MUST DEGRADE, NEVER DIE (section 9, also in a child
#     process, because `$broken` latches for the life of the interpreter).
#   - THE DEV-BUILD WIPE MUST NOT TOUCH THE DURABLE TABLES. `DELETE FROM kv` is
#     unconditional and has no allowlist, which is only safe while a Bandcamp pin,
#     a follow item and a release live in tables. Section 6 is what stops that
#     rule being quietly broken by moving one of them back into kv.
#
# ANTI-TEST (do this after changing anything here — a green baseline against a
# store that never writes is worth nothing):
#
#   cp ListenBrainzFreshReleases/DB.pm /tmp/DB.pm
#   # make kvSet return 1 without writing, or drop the SQL_BLOB bind
#   LBF_DB=/tmp/DB.pm perl tools/t_db.pl        # must go RED
#
# Exit 0 = all good. Exit 1 = at least one regressed.

use strict;
use warnings;
use FindBin;
use File::Temp qw(tempdir);
use File::Spec;
use Storable ();

my $DB = $ENV{LBF_DB} || File::Spec->catfile($FindBin::Bin, File::Spec->updir,
                                             'ListenBrainzFreshReleases', 'DB.pm');
my $NS = 'Plugins::ListenBrainzFreshReleases::DB';

# ---------------------------------------------------------------------------
# Throwaway Slim:: stubs. DB.pm needs exactly three things from LMS: a log
# category, the server `cachedir` pref, and one plugin pref (the legacy-import
# deadline, which is a pref precisely so the kv wipe cannot reset it).
# ---------------------------------------------------------------------------
BEGIN { $INC{'Slim/Utils/Log.pm'} = $INC{'Slim/Utils/Prefs.pm'} = __FILE__ }
{
    package Slim::Utils::Log;   use Exporter 'import'; our @EXPORT = qw(logger);
                                sub addLogCategory {} sub logger { bless {}, 'T::Log' }
    package T::Log;             our (@WARNED, @ERRORED);
                                our $AUTOLOAD; sub AUTOLOAD {}
                                sub warn  { push @WARNED,  $_[1]; 1 }
                                sub error { push @ERRORED, $_[1]; 1 }
                                sub is_debug {0} sub is_info {0}
    package Slim::Utils::Prefs; use Exporter 'import'; our @EXPORT = qw(preferences);
                                our %P; sub preferences { bless {}, 'T::Prefs' }
    package T::Prefs;           sub get { $Slim::Utils::Prefs::P{$_[1]} }
                                sub set { $Slim::Utils::Prefs::P{$_[1]} = $_[2] }
}

# ---------------------------------------------------------------------------
# Child-process roles. The script re-invokes ITSELF so the child gets the same
# stubs and the same DB.pm, with no second copy of this harness to drift.
# ---------------------------------------------------------------------------
if (($ENV{LBF_TDB_ROLE} // '') eq 'reader') {
    $Slim::Utils::Prefs::P{cachedir} = $ENV{LBF_TDB_DIR};
    do $DB or die "child: can't load $DB: " . ($@ || $!);
    binmode(STDOUT, ':encoding(UTF-8)');
    for my $k (qw(cross:hash cross:zero cross:undef cross:empty cross:wide cross:bytes cross:long)) {
        my $v = $NS->can('kvGet')->($k);
        print "GOT\t$k\t" . _render($v) . "\n";
    }
    my $s = $NS->can('stats')->();
    print "STATS\t" . ($s->{ok} ? 1 : 0) . "\t" . ($s->{tables}{kv} // -1)
        . "\t" . ($s->{tables}{bandcamp_pin} // -1) . "\t" . ($s->{version} // -1) . "\n";
    exit 0;
}
if (($ENV{LBF_TDB_ROLE} // '') eq 'degrade') {
    # A DIRECTORY sitting where the database file must go: SQLite cannot open it,
    # which is a faithful stand-in for a read-only cachedir or a corrupt file.
    $Slim::Utils::Prefs::P{cachedir} = $ENV{LBF_TDB_DIR};
    do $DB or die "child: can't load $DB: " . ($@ || $!);
    my @out;
    push @out, 'set='   . (eval { $NS->can('kvSet')->('x', { a => 1 }) } // 'DIED');
    push @out, 'get='   . (defined eval { $NS->can('kvGet')->('x') } ? 'defined' : 'undef');
    push @out, 'del='   . (eval { $NS->can('kvDel')->('x') } // 'DIED');
    push @out, 'sweep=' . (eval { $NS->can('kvSweep')->() } // 'DIED');
    push @out, 'prefix='. (eval { $NS->can('kvForgetPrefix')->('lbf:') } // 'DIED');
    push @out, 'wipe='  . (eval { $NS->can('wipeDerived')->() } // 'DIED');
    push @out, 'ok='    . (eval { $NS->can('stats')->()->{ok} } // 'DIED');
    print "DEGRADE\t" . join(' ', @out) . "\n";
    exit 0;
}

sub _render {
    my ($v) = @_;
    return 'MISS'                        unless defined $v;
    return 'HASH:' . join(',', map { "$_=$v->{$_}" } sort keys %$v) if ref $v eq 'HASH';
    return 'ARRAY:' . join(',', @$v)     if ref $v eq 'ARRAY';
    return 'EMPTY'                       if $v eq '';
    return "SCALAR:$v";
}

# ---------------------------------------------------------------------------
my $DIR = tempdir(CLEANUP => 1);
$Slim::Utils::Prefs::P{cachedir} = $DIR;
do $DB or die "can't load $DB: " . ($@ || $!);

binmode(STDOUT, ':encoding(UTF-8)');

my ($pass, $fail) = (0, 0);
sub ok {
    my ($cond, $what) = @_;
    die "ok() called with no message\n" unless defined $what && length $what;
    $cond ? ($pass++, print "  PASS  $what\n") : ($fail++, print "  FAIL  $what\n");
    return $cond ? 1 : 0;
}
sub is {
    my ($got, $want, $what) = @_;
    $got  = defined $got  ? $got  : '(undef)';
    $want = defined $want ? $want : '(undef)';
    ok($got eq $want, "$what  ->  '$got'" . ($got eq $want ? '' : "  (wanted '$want')"));
}
sub section { printf "\n%s\n%s\n", $_[0], '-' x 74 }

sub kvGet { $NS->can('kvGet')->(@_) }
sub kvSet { $NS->can('kvSet')->(@_) }
sub raw   { $NS->can('dbh')->() }

# ===========================================================================
section '1. SCHEMA — migrations are versioned, idempotent, and complete';
{
    my $h = raw();
    ok($h, 'the store opens against a real file');

    my ($ver) = $h->selectrow_array('PRAGMA user_version');
    is($ver, $NS->can('SCHEMA_VERSION')->(), 'user_version records the schema it migrated to');

    my %have = map { $_->[0] => 1 } @{
        $h->selectall_arrayref("SELECT name FROM sqlite_master WHERE type = 'table'") };
    ok($have{$_}, "table $_ exists") for qw(release feed_member feed_day feed_meta
                                            bandcamp_pin follow_item
                                            release_group recording artist kv);

    # Re-opening must be a no-op, not a second migration. _reset drops the cached
    # handle so the open path (and therefore _migrate) genuinely runs again.
    $NS->can('_reset')->();
    my $again = eval { raw() };
    ok($again, 'a second open of an existing file succeeds');
    my ($ver2) = $again->selectrow_array('PRAGMA user_version');
    is($ver2, $NS->can('SCHEMA_VERSION')->(), 'and leaves the version alone (migration is idempotent)');

    # THE UPGRADE PATH, WHICH THE FRESH-INSTALL PATH HIDES. Every column added by a
    # migration is ALSO in the CREATE TABLE used for a new store, so a test that
    # only ever builds a fresh file passes whether or not the migration step is
    # wired into _migrate at all. Found by mutation: deleting the `_migrate_5($h)`
    # call scored a full green suite.
    #
    # So: build the PREVIOUS schema by hand, stamp user_version to it, run the real
    # _migrate, and require the new column to appear. This is what an existing
    # user's store actually does on update.
    {
        my $old = File::Spec->catfile($DIR, 'v4store.db');
        my $h5  = DBI->connect("dbi:SQLite:dbname=$old", '', '',
                               { RaiseError => 1, PrintError => 0 });
        # The release_group table AS IT STOOD AT SCHEMA 4 — no detail-genre columns.
        $h5->do(q{CREATE TABLE release_group (
                      rg_mbid   TEXT PRIMARY KEY,
                      name      TEXT NOT NULL DEFAULT '',
                      genres    BLOB,
                      agenres   BLOB,
                      n_genres  INTEGER NOT NULL DEFAULT -1,
                      n_agenres INTEGER NOT NULL DEFAULT -1,
                      genres_at INTEGER NOT NULL DEFAULT 0)});
        $h5->do('PRAGMA user_version = 4');

        my %before = map { lc $_->[1] => 1 }
            @{ $h5->selectall_arrayref('PRAGMA table_info(release_group)') };
        ok(!$before{detail_genres}, 'a schema-4 store has no detail-genre column (setup)');

        $NS->can('_migrate')->($h5);        # the REAL dispatcher, on a real v4 file

        my %after = map { lc $_->[1] => 1 }
            @{ $h5->selectall_arrayref('PRAGMA table_info(release_group)') };
        ok($after{detail_genres},
           'MIGRATING AN EXISTING STORE ADDS THE DETAIL-GENRE COLUMN');
        ok($after{detail_genres_at} && $after{n_detail_genres},
           '...with its stamp and its count beside it');
        my ($v5) = $h5->selectrow_array('PRAGMA user_version');
        is($v5, $NS->can('SCHEMA_VERSION')->(),
           '...and records the version, so the step does not re-run on every open');
        $h5->disconnect;
    }
}

# ===========================================================================
section '2. kv ROUND-TRIP — 0, empty and undef stay distinct from a miss';
{
    kvSet('t:hash',  { a => 1, b => 'two' });
    kvSet('t:array', [ 1, 2, 3 ]);
    kvSet('t:str',   'plain');
    kvSet('t:zero',  0);
    kvSet('t:empty', '');
    kvSet('t:undef', undef);

    is(_render(kvGet('t:hash')),  'HASH:a=1,b=two', 'a hashref round-trips');
    is(_render(kvGet('t:array')), 'ARRAY:1,2,3',    'an arrayref round-trips');
    is(_render(kvGet('t:str')),   'SCALAR:plain',   'a plain scalar round-trips');

    # THE WRAPPER'S WHOLE JOB. Without `{ v => … }` a stored 0 is indistinguishable
    # from "not stored" to any caller that tests truth, and a stored undef cannot
    # exist at all.
    my $zero = kvGet('t:zero');
    ok(defined $zero && $zero == 0, 'a stored 0 reads back as 0, not as a miss');
    my $empty = kvGet('t:empty');
    ok(defined $empty && $empty eq '', "a stored '' reads back as '', not as a miss");

    my $h = raw();
    my ($n) = $h->selectrow_array("SELECT COUNT(*) FROM kv WHERE k = 't:undef'");
    ok($n == 1, 'a stored undef occupies a row (the key exists)');
    ok(!defined kvGet('t:undef'), '...and reads back as undef');
    ok(!defined kvGet('t:never-written'), 'an unwritten key reads back as undef');

    is(kvSet('', 'x'), 0, 'an empty key is refused rather than stored');
    ok(!defined kvGet(''), 'and reading an empty key is a miss, not a crash');
}

# ===========================================================================
section '3. THE 30-DAY BOUNDARY — the defect is inexpressible here';
{
    # THE POSITIVE ASSERTION. LMS would store this expiring in 1970. Here it must
    # be an absolute epoch of now + 7776000, and — the part that actually matters
    # — the value must be READABLE afterwards.
    my $before = time();
    kvSet('t:90d', { kept => 1 }, 90 * 86400);
    my $after = time();

    my ($exp) = raw()->selectrow_array("SELECT expires_at FROM kv WHERE k = 't:90d'");
    ok($exp >= $before + 7776000 && $exp <= $after + 7776000,
       "a 90-day TTL stores now+7776000 (got $exp, now~$before)");
    is(_render(kvGet('t:90d')), 'HASH:kept=1', 'and a 90-day entry is READABLE');

    kvSet('t:365d', 'still here', 365 * 86400);
    is(_render(kvGet('t:365d')), 'SCALAR:still here', 'a 365-day TTL is readable too');

    kvSet('t:forever', 'permanent');
    my ($noexp) = raw()->selectrow_array("SELECT expires_at FROM kv WHERE k = 't:forever'");
    is($noexp, 0, 'no TTL means expires_at 0 (never), not an implicit duration');
    is(_render(kvGet('t:forever')), 'SCALAR:permanent', 'and it reads back');

    # An entry whose expiry has passed is a MISS, and reading it collects the row.
    raw()->do("INSERT OR REPLACE INTO kv (k, v, expires_at) VALUES ('t:stale', ?, ?)",
              undef, Storable::nfreeze({ v => 'old' }), time() - 10);
    ok(!defined kvGet('t:stale'), 'an expired entry reads as a miss');
    my ($gone) = raw()->selectrow_array("SELECT COUNT(*) FROM kv WHERE k = 't:stale'");
    is($gone, 0, '...and the read collected the row');
}

# ===========================================================================
section '4. ENCODING — wide characters and non-UTF-8 blob bytes';
{
    # Both halves of the wide-character bug this repo has been bitten by twice:
    # from the VALUE side (DbCache freezes only refs, so a bare wide string went
    # straight to a SQL_BLOB bind and died) and from the KEY side (DbCache md5s
    # the key, which dies above codepoint 255).
    my $wideVal = "\x{30ca}\x{30ca} \x{2014} Sigur R\x{f3}s \x{2019}98";
    my $wideKey = "lbf:t:\x{8e0a}\x{3063}\x{3066}\x{3070}\x{304b}\x{308a}";

    kvSet('t:wideval', { bio => $wideVal });
    my $back = kvGet('t:wideval');
    ok(ref $back eq 'HASH' && $back->{bio} eq $wideVal,
       'a wide-character VALUE round-trips identically');

    ok(kvSet($wideKey, 'ok'), 'a wide-character KEY can be written');
    is(kvGet($wideKey), 'ok', '...and read back');

    # THE SQL_BLOB CASE. Frozen Storable output is routinely not valid UTF-8, and
    # sqlite_unicode => 1 decodes TEXT on read — so an unbound blob is silent
    # corruption. Store bytes that cannot be UTF-8 and demand them back verbatim.
    my $bytes = join('', map { chr($_) } 0xFF, 0xFE, 0x80, 0x00, 0x41, 0xC3, 0x28);
    kvSet('t:bytes', { blob => $bytes });
    my $b = kvGet('t:bytes');
    ok(ref $b eq 'HASH' && defined $b->{blob} && $b->{blob} eq $bytes,
       'a value holding non-UTF-8 bytes comes back byte-identical');
    ok(ref $b eq 'HASH' && length($b->{blob}) == length($bytes),
       "...and the same length (" . length($bytes) . " bytes)");

    # THE ASSERTION THAT ACTUALLY CATCHES A MISSING SQL_BLOB BIND, and it is the
    # FLAG, not the bytes. Measured on DBD::SQLite 1.64: an untyped bind stores
    # the same bytes but hands them back with the utf8 flag SET, so the store
    # would return a differently-flagged copy of what it was given. That is the
    # provenance question this repo has been bitten by twice (0.6.15 from the key
    # side, 0.9.141 from the value side). Reading the raw column is the only way
    # to see it — through kvGet, Storable has already normalised it away.
    my ($rawBlob) = raw()->selectrow_array("SELECT v FROM kv WHERE k = 't:bytes'");
    ok(defined $rawBlob && !utf8::is_utf8($rawBlob),
       'the stored blob comes back as BYTES, with no utf8 flag (SQL_BLOB bind)');
}

# ===========================================================================
section '5. SWEEP, PREFIX RETIRE AND KEY VERSIONS';
{
    my $h = raw();
    $h->do('DELETE FROM kv');

    kvSet('lbf:track:8:a', 'old');
    kvSet('lbf:track:8:b', 'old');
    kvSet('lbf:track:9:a', 'new');
    kvSet('lbf:stream:27:a', 'other family');
    kvSet('lbf:pl:resolved:8:x', 'outer');

    my $n = $NS->can('retirePrefixes')->({ 'lbf:track:' => 9 });
    is($n, 2, 'retirePrefixes drops exactly the two stale-version rows');
    is(kvGet('lbf:track:9:a'), 'new',          'the current version survives');
    ok(!defined kvGet('lbf:track:8:a'),        'the previous version is gone');
    is(kvGet('lbf:stream:27:a'), 'other family','an unrelated family is untouched');
    is(kvGet('lbf:pl:resolved:8:x'), 'outer',
       'a family whose name EXTENDS another is untouched');

    is($NS->can('kvForgetPrefix')->('lbf:stream:'), 1, 'kvForgetPrefix removes its family');
    ok(!defined kvGet('lbf:stream:27:a'), '...and the row is really gone');
    is($NS->can('kvForgetPrefix')->(''), 0,
       "kvForgetPrefix REFUSES an empty prefix (it must not mean 'everything')");
    ok(defined kvGet('lbf:track:9:a'), '...and nothing was deleted by that refusal');

    # The sweep collects what no read will ever reach.
    $h->do("INSERT OR REPLACE INTO kv (k, v, expires_at) VALUES ('t:s1', ?, ?)",
           undef, Storable::nfreeze({ v => 1 }), time() - 1);
    $h->do("INSERT OR REPLACE INTO kv (k, v, expires_at) VALUES ('t:s2', ?, ?)",
           undef, Storable::nfreeze({ v => 1 }), time() - 100);
    is($NS->can('kvSweep')->(), 2, 'kvSweep collects both expired rows');
    is($NS->can('kvSweep')->(), 0, '...and a second sweep finds nothing');
    ok(defined kvGet('lbf:track:9:a'), 'the sweep left unexpired rows alone');
}

# ===========================================================================
section '6. THE DEV-BUILD WIPE — kv goes, the durable tables do not';
{
    my $h = raw();
    my $now = time();

    # The three things that are NOT caches, plus a release row. Each is inserted
    # directly, because the point under test is the TABLE guarantee — that the
    # unconditional `DELETE FROM kv` is safe precisely because these are not in kv.
    $h->do('INSERT OR REPLACE INTO bandcamp_pin (rel_id, payload, pinned_at) VALUES (?,?,?)',
           undef, 'rg:abc', Storable::nfreeze({ v => { url => 'https://x.bandcamp.com' } }), $now);
    $h->do('INSERT OR REPLACE INTO follow_item (username, item_key, payload, created, stored_at)
            VALUES (?,?,?,?,?)', undef, 'simon', 'm:1234',
           Storable::nfreeze({ v => { title => 'A track' } }), $now, $now);
    $h->do('INSERT OR REPLACE INTO release (rel_id, base_version, payload, rel_date, week_start, seen_at)
            VALUES (?,?,?,?,?,?)', undef, 'mbid-1', 1,
           Storable::nfreeze({ v => { artist_credit_name => 'X' } }), '2026-08-24', '2026-08-24', $now);
    $h->do("INSERT OR REPLACE INTO artist (artist_key, name, sort_name, sort_src, sort_at,
            artist_type, hosted_genres, n_hosted_genres, hosted_genres_at, fetched_at)
            VALUES (?,?,?,?,?,?,?,?,?,?)",
           undef, 'mbid-a', 'Jack White', 'White, Jack', 'mb', $now, 'Person',
           Storable::nfreeze({ v => ['garage rock'] }), 1, $now, $now);
    $h->do("INSERT OR REPLACE INTO release_group (rg_mbid, year, type, genres, n_genres,
            genres_at, fetched_at) VALUES (?,?,?,?,?,?,?)", undef, 'rg-1', '2026', 'Album',
           Storable::nfreeze({ v => ['k-pop'] }), 1, $now, $now);

    kvSet('lbf:stream:27:z', 'disposable');
    ok($NS->can('kvCount')->() > 0, 'kv holds rows before the wipe');

    $NS->can('wipeDerived')->();
    is($NS->can('kvCount')->(), 0, 'wipeDerived empties kv completely');

    my $stats = $NS->can('stats')->();
    is($stats->{tables}{bandcamp_pin}, 1, 'the hand-curated Bandcamp pin SURVIVES the wipe');
    is($stats->{tables}{follow_item},  1, 'the follow item SURVIVES (it cannot be re-derived)');
    is($stats->{tables}{release},      1, 'the release base SURVIVES');
    is($stats->{tables}{artist},       1, 'the artist facts row SURVIVES');

    # The FACTS half of a dev build: genres only. THE DEV RULE IS THAT EVERY BUILD
    # CLEARS EVERY CACHE — otherwise there is no way to test first-run behaviour, or
    # what a user sees when they widen the window — so what has to be proved here is
    # not that the wipe is avoided but that it is RECOVERABLE and NARROW.
    # ASSERTED ON THE COLUMN, not on a cachestats counter. `artist_hosted_*` was
    # dropped from the report in 0.9.173 with the rung that fed it, but the COLUMN
    # survives and the wipe must still clear it — so reading it directly keeps this
    # covering the wipe rather than the instrument.
    $stats = $NS->can('stats')->();
    my ($preN) = $h->selectrow_array(
        'SELECT n_hosted_genres FROM artist WHERE artist_key = ?', undef, 'mbid-a');
    ok($preN >= 1, 'the artist row carried genres before the genre wipe');
    $NS->can('wipeGenres')->();

    my ($n, $at, $sortName, $sortAt, $type) = $h->selectrow_array(
        'SELECT n_hosted_genres, hosted_genres_at, sort_name, sort_at, artist_type
           FROM artist WHERE artist_key = ?', undef, 'mbid-a');
    is($n,  -1, 'wipeGenres returns the artist genre answer to NEVER ASKED');
    # THE ONE THAT MATTERS. Clearing an answer and leaving its clock running is what
    # locked the live store out for ninety days: the row read as freshly fetched, so
    # nothing ever asked again. The answer and its stamp move together or the wipe
    # is not a wipe, it is a deletion with no way back.
    is($at,  0, '...AND ZEROES ITS STAMP, so it is re-askable immediately');
    is($sortName, 'White, Jack',
       '...but the SORT-NAME survives (a genre change must not re-inflict an artist-sort reconvergence)');
    is($sortAt, $now, '...and so does the sort-name STAMP — a different answer, untouched');
    is($type, 'Person', '...and so does the artist type');

    my ($rgN, $rgAt, $rgYear, $rgFetched) = $h->selectrow_array(
        'SELECT n_genres, genres_at, year, fetched_at FROM release_group WHERE rg_mbid = ?',
        undef, 'rg-1');
    is($rgN,  -1, 'the release-group genre answer is returned to NEVER ASKED');
    is($rgAt,  0, '...with its stamp zeroed too');
    is($rgYear, '2026', '...but the YEAR survives');
    is($rgFetched, $now,
       '...and so does the DATE stamp — repairing a genre parse must not re-fetch every date in the feed');

    my $after = $NS->can('stats')->();
    is($n,  -1, 'and the hosted column is returned to NEVER ASKED, not to "asked and there were none"');
    is($at,  0, '...with its stamp zeroed, so it is re-askable the moment anything writes it again');
    # The rung is gone, so the report must NOT carry a frozen counter for it — a
    # populated-looking tier that cannot be contributing is the exact trap the
    # coverage block was rewritten to remove.
    ok(!exists $after->{detail}{artist_hosted_have},
       'cachestats no longer reports a tier nothing writes');
}

# ===========================================================================
section '6g. NOTHING OVERWRITES ITSELF — one column per tier, one stamp per answer';
{
    # THE THREE DEFECTS THIS SECTION PINS, all the same shape: a write touching
    # something it does not own.
    my $put = $NS->can('artistPut');
    my $get = $NS->can('artistGet');
    my $h   = raw();

    # ---- 1. a tier's write must not RE-AGE another answer on the same row ----
    # `_factPut` stamps `fetched_at` on every write, and an artist row is written by
    # the sort warm AND two genre tiers. With one shared stamp, the sort warm
    # refreshing a sort-name declared the genres beside it freshly fetched — so an
    # empty or stale genre answer could be held alive indefinitely by a tier that
    # never asked about genres at all.
    $put->('own:1', hosted_genres => ['shoegaze']);
    my ($g0) = $h->selectrow_array("SELECT hosted_genres_at FROM artist WHERE artist_key = 'own:1'");
    $h->do("UPDATE artist SET hosted_genres_at = ? WHERE artist_key = 'own:1'", undef, 1000);

    $put->('own:1', sort_name => 'Shoegaze, A');
    my ($gAfter, $sAfter) = $h->selectrow_array(
        "SELECT hosted_genres_at, sort_at FROM artist WHERE artist_key = 'own:1'");
    is($gAfter, 1000, 'a sort-name write does NOT re-age the genre answer beside it');
    ok($sAfter > 1000, '...while stamping its own answer');
    ok($g0 > 0, '(and a genre write does stamp the genre answer)');

    # ---- 2. two tiers cannot overwrite each other ----
    # Until schema 3 both wrote `artist.genres` behind a `genres_src` discriminator,
    # and each read the other's answer as stale — hosted refetched and wrote
    # 'hosted', the mirror refetched and wrote 'mb', for ever. Separate columns make
    # the ping-pong inexpressible rather than merely unlikely.
    $put->('own:2', hosted_genres => ['dream pop']);
    $put->('own:2', mb_genres     => ['ambient', 'drone']);
    my $both = $get->(['own:2'])->{'own:2'};
    is(join(',', @{ $both->{hosted_genres} || [] }), 'dream pop',
       'the hosted answer survives a mirror write');
    is(join(',', @{ $both->{mb_genres} || [] }), 'ambient,drone',
       '...and the mirror answer survives beside it');
    my ($nh, $nm) = $h->selectrow_array(
        "SELECT n_hosted_genres, n_mb_genres FROM artist WHERE artist_key = 'own:2'");
    is($nh, 1, 'each tier keeps its own count');
    is($nm, 2, '...independently');

    # ---- 3. Last.fm is IN THE STORE, and its empties are remembered ----
    # It was the last genre tier still in Slim::Utils::Cache: evictable, and on a
    # TTL, for an answer that costs a one-request-per-second paced warm.
    $NS->can('lfmPut')->('sigur ros|( )', ['post-rock', 'ambient']);
    $NS->can('lfmPut')->('nobody|nothing', []);
    my $lfm = $NS->can('lfmGet')->('sigur ros|( )');
    is(join(',', @{ $lfm->{tags} || [] }), 'post-rock,ambient', 'Last.fm tags round-trip through the store');
    is($NS->can('lfmGet')->('nobody|nothing')->{n_tags}, 0,
       'an empty Last.fm answer is STORED as "asked, none" rather than thrown away');
    is($NS->can('lfmGet')->('never|asked'), undef, '...and an unasked key is still undef');

    my $ls = $NS->can('stats')->();
    # The album-keyed table is the DETAIL PAGE's tier. The artist-level answer the
    # list rows read is a column on `artist`, counted with the other rungs — they
    # are reported separately because they are different questions.
    ok($ls->{detail}{lastfm_album_have} >= 1,
       'the album-keyed Last.fm tier is visible in the coverage report');
    $NS->can('artistPut')->('n:lfm artist', lastfm_genres => ['post-rock']);
    $NS->can('artistPut')->('n:lfm nobody', lastfm_genres => []);
    my $ls2 = $NS->can('stats')->();
    ok($ls2->{detail}{artist_lastfm_have} >= 1, 'and so is the ARTIST-level Last.fm rung');
    ok($ls2->{detail}{artist_lastfm_none} >= 1, '...with its empties counted separately');

    # A genre wipe has to take the whole ladder, or its bottom rung keeps serving
    # pre-wipe answers while everything above it is empty.
    $NS->can('wipeGenres')->();
    is($NS->can('lfmGet')->('sigur ros|( )'), undef, 'wipeGenres clears the Last.fm tier too');
}

# ===========================================================================
section '6f. GENRE COVERAGE IS REPORTABLE — the three states, told apart';
{
    my $put = $NS->can('artistPut');
    my $h3  = raw();

    # ---- the migration back-fill: THE LIVE CASE ----
    # Every genre row on an existing server was written under schema v1 and carries
    # no count. If migration 2 only affected NEW writes, the first report after the
    # upgrade would say "never asked" for thousands of rows that DO hold genres —
    # indistinguishable from the total genre loss being diagnosed, which is exactly
    # the confusion this counter exists to end. So the step back-fills from the
    # blobs already stored.
    # A PRE-SCHEMA-3 ROW: the answer sits in the legacy shared `genres` column with
    # a `genres_src` saying which tier put it there. Written as raw SQL because
    # nothing in the plugin writes that shape any more — which is the point.
    $h3->do("INSERT OR REPLACE INTO artist (artist_key, genres, n_genres, genres_src, fetched_at)
             VALUES (?,?,?,?,?)", undef, 'cov:legacy',
            Storable::nfreeze({ v => ['krautrock', 'ambient', 'drone'] }), 3, 'hosted', 5000);
    # READ OFF THE COLUMN, not off cachestats. The hosted tier's counters left the
    # report in 0.9.173 with the rung, but migration 3 still has to file a legacy
    # answer under the tier that produced it — a back-fill that put one tier's
    # answer under another's name is the defect this asserts against, and it is
    # unaffected by whether anything still reads that column.
    my ($preBf) = $h3->selectrow_array(
        "SELECT n_hosted_genres FROM artist WHERE artist_key = 'cov:legacy'");
    ok(!defined $preBf || $preBf < 0,
       'a pre-v3 store has no hosted answer before the back-fill (setup)');

    $NS->can('_migrate_3')->($h3);          # re-runnable: the ALTERs are guarded
    my ($postBf) = $h3->selectrow_array(
        "SELECT n_hosted_genres FROM artist WHERE artist_key = 'cov:legacy'");
    ok($postBf >= 1,
       'THE MIGRATION FILES LEGACY ANSWERS UNDER THE TIER THAT ACTUALLY ANSWERED THEM');
    my ($backfilled, $bfAt) = $h3->selectrow_array(
        "SELECT n_hosted_genres, hosted_genres_at FROM artist WHERE artist_key = 'cov:legacy'");
    is($backfilled, 3, 'and the back-filled count is the real length of the stored list');
    # Without this the upgrade would silently re-age every genre already collected to
    # "just now", and nothing would be re-checked for a full FOUND age.
    is($bfAt, 5000, '...stamped with when that answer was really obtained, not with now');
    my ($legacyMb) = $h3->selectrow_array("SELECT n_mb_genres FROM artist WHERE artist_key = 'cov:legacy'");
    is($legacyMb, -1, 'and it lands under ONE tier only — the other stays never-asked');

    # WHY THIS SECTION EXISTS. `cachestats` is the only way to see whether genres
    # are in the store, and it reported `genres_src <> ''` — a column ONLY the
    # MusicBrainz last-resort tier writes. So a store holding thousands of
    # ListenBrainz genres reported ZERO, and a genuine regression and a healthy
    # store were indistinguishable. A frozen blob cannot be counted in SQL, so the
    # length is mirrored into `n_genres` at write time.
    #
    # THE THREE STATES MUST STAY DISTINCT. "asked, none" is a REAL answer from both
    # ListenBrainz and the hosted API (Panda Bear returns `[]`, Radiohead omits the
    # key entirely), and collapsing it into "never asked" would make the warm
    # re-request the ~half of artists that will never answer — the exact waste the
    # store exists to end.
    # ON THE LISTENBRAINZ TIER, because that is a rung the ladder still has. This
    # used to exercise the hosted tier; 0.9.173 removed it, and a three-state test
    # against a tier nothing writes would pass for the wrong reason for ever.
    $put->(q{cov:has},  lb_genres => ['shoegaze', 'dream pop']);
    $put->('cov:none',  lb_genres => []);
    $put->('cov:never', name => 'never looked');            # no genres key at all

    my $s = $NS->can('stats')->();
    ok($s->{detail}{artist_lb_have}  >= 1, 'an artist WITH genres is counted as having them');
    ok($s->{detail}{artist_lb_none}  >= 1, 'an artist whose real answer was "none" is counted separately');
    ok($s->{detail}{artist_lb_never} >= 1, 'an artist never looked up is counted separately again');

    my $h2 = raw();
    my ($nHas)  = $h2->selectrow_array("SELECT n_lb_genres FROM artist WHERE artist_key = 'cov:has'");
    my ($nNone) = $h2->selectrow_array("SELECT n_lb_genres FROM artist WHERE artist_key = 'cov:none'");
    my ($nNev)  = $h2->selectrow_array("SELECT n_lb_genres FROM artist WHERE artist_key = 'cov:never'");
    is($nHas,   2, 'the stored count is the real number of genres');
    is($nNone,  0, 'an empty list stores 0 — asked, and there were none');
    is($nNev,  -1, 'a row never asked stores -1, which is what keeps it distinct from 0');

    # The release-group tier writes genres with no source column at all, which is
    # exactly why counting `genres_src` was wrong. Both of its lists are counted.
    $NS->can('rgPut')->('cov:rg', genres => ['jazz'], agenres => ['jazz', 'fusion']);
    my $s2 = $NS->can('stats')->();
    ok($s2->{detail}{rg_genres_have}  >= 1, 'release-group genres are counted with no source column');
    ok($s2->{detail}{rg_agenres_have} >= 1, 'and so are the artist tags that ride the same call');

    # NOTHING IS IMMUTABLE, and this is the figure that says whether the re-checking
    # is actually happening. An EMPTY answer ages out far sooner than a populated
    # one, because MusicBrainz tagging lands weeks after a release — so a tagless
    # release comes back round instead of being locked out. Had this existed, the
    # 0.9.166 lockout would have been one number: everything empty, nothing stale.
    my $h4 = raw();
    $NS->can('rgPut')->('cov:stale', genres => []);            # asked, nothing found
    $h4->do("UPDATE release_group SET genres_at = ? WHERE rg_mbid = 'cov:stale'",
            undef, time() - (30 * 86400));                     # older than the EMPTY age
    $NS->can('rgPut')->('cov:fresh', genres => []);            # asked just now
    $NS->can('rgPut')->('cov:kept',  genres => ['jazz']);
    $h4->do("UPDATE release_group SET genres_at = ? WHERE rg_mbid = 'cov:kept'",
            undef, time() - (30 * 86400));                     # old, but POPULATED
    my $s3 = $NS->can('stats')->();
    is($s3->{detail}{rg_genres_stale}, 1,
       'exactly the aged-out EMPTY answer is reported due for a re-check');
    # No counter may be reported over release_group.genres_src. Nothing writes
    # that column, so such a figure is 0 whatever the store holds and reads as
    # evidence about coverage when it is only evidence about the schema — which
    # is what made the first cut of this instrument useless.
    ok(!exists $s2->{detail}{rg_genres_from_mb},
       'and no counter is reported over release_group.genres_src, which has no writer');
}

# ===========================================================================
section '6b. THE artist FACTS TIER — merge, never blank';
{
    my $h = raw();
    $h->do('DELETE FROM artist');
    my $put = $NS->can('artistPut');
    my $get = $NS->can('artistGet');

    # THE MERGE RULE, and it is the one that matters: different tiers fill
    # different columns and arrive in either order. The hosted tier writes genres;
    # the sort tier writes a sort-name. Neither may erase the other.
    $put->('n:jack white', name => 'Jack White', hosted_genres => ['garage rock', 'blues rock']);
    $put->('n:jack white', sort_name => 'White, Jack', sort_src => 'local');

    my $row = $get->(['n:jack white'])->{'n:jack white'};
    ok(ref $row eq 'HASH', 'the artist row reads back');
    is(join(',', @{ $row->{hosted_genres} || [] }), 'garage rock,blues rock',
       'genres survive a later write that did not mention them');
    is($row->{sort_name},  'White, Jack', 'the sort-name landed');
    is($row->{n_hosted_genres}, 2, 'and the genre count was not blanked by the sort write');
    is($row->{name},       'Jack White',  'nor was the name');

    # The reverse order must behave identically.
    $put->('n:phoebe bridgers', sort_name => 'Bridgers, Phoebe', sort_src => 'local');
    $put->('n:phoebe bridgers', hosted_genres => ['indie rock']);
    my $r2 = $get->(['n:phoebe bridgers'])->{'n:phoebe bridgers'};
    is($r2->{sort_name}, 'Bridgers, Phoebe', 'sort-name survives a later genre write');
    is(join(',', @{ $r2->{hosted_genres} || [] }), 'indie rock', 'and the genres landed');

    # AN EMPTY LIST IS AN ANSWER, NOT A MISS. The hosted API returns `[]` for an
    # artist it knows and has no genres for (Panda Bear, verified live). Storing it
    # is what stops every warm asking again for the ~half of artists that will
    # never answer — so it MUST come back as an empty arrayref, not as undef.
    $put->('n:panda bear', name => 'Panda Bear', hosted_genres => []);
    my $r3 = $get->(['n:panda bear'])->{'n:panda bear'};
    ok(ref $r3->{hosted_genres} eq 'ARRAY' && !@{ $r3->{hosted_genres} },
       'an empty genre list stores and reads back as an empty ARRAYREF');
    is($r3->{n_hosted_genres}, 0, '...distinguishable from never-asked, which stores -1');

    my $never = $get->(['n:never asked']);
    ok(!exists $never->{'n:never asked'}, 'an artist never asked about is simply absent');

    # Wide characters, because these keys are folded artist names.
    $put->("n:sigur ros", name => "Sigur R\x{f3}s", hosted_genres => ["post-rock"]);
    my $r4 = $get->(['n:sigur ros'])->{'n:sigur ros'};
    is($r4->{name}, "Sigur R\x{f3}s", 'a wide-character artist name round-trips');

    # Bulk read, which is what a feed page actually does.
    my $many = $get->([qw(n:jack-white n:panda bear), 'n:jack white', 'n:sigur ros']);
    ok(scalar(keys %$many) == 2, 'a bulk read returns only the keys that exist');

    # fetched_at is what replaces a TTL — it must always be set, or the staleness
    # policy in API::_hagenFresh reads every row as infinitely old.
    ok(($r4->{fetched_at} // 0) > 0, 'every write stamps fetched_at (there is no TTL to rely on)');
}

# ===========================================================================
section '6a. THE FACTS TABLES — one implementation, three tables, no TTL';
{
    my $h = raw();
    $h->do('DELETE FROM release_group');
    $h->do('DELETE FROM recording');
    $h->do('DELETE FROM artist');

    my $rgPut = $NS->can('rgPut');
    my $rgGet = $NS->can('rgGet');

    # A release group as _mergeReleaseGroupMetadata actually parses one. Note
    # `date`, not `rel_date`: the caller's own field names go in, because a
    # translation layer at every call site is a translation layer to get wrong.
    $rgPut->('rg-nct', year => '2026', date => '2026-08-24', type => 'Single',
             name => 'BLINGY', genres => ['k-pop'], agenres => ['k-pop', 'dance-pop'],
             );
    my $rg = $rgGet->(['rg-nct'])->{'rg-nct'};
    is($rg->{year},  '2026',       'a release-group year round-trips');
    is($rg->{date},  '2026-08-24', 'and comes back under the CALLER\'s name (date, not rel_date)');
    is($rg->{type},  'Single',     'the primary type round-trips');
    is(join(',', @{ $rg->{genres}  || [] }), 'k-pop',            'the album\'s own genres round-trip');
    is(join(',', @{ $rg->{agenres} || [] }), 'k-pop,dance-pop',
       'and the ARTIST genres round-trip separately — two frozen columns on one row');

    # THE POINT OF THE WHOLE EXERCISE. This is the row shape that spent its entire
    # existence being written expiring in 1970: a release group WITH a date, under
    # a 90-day TTL. There is no TTL now, so it simply reads back.
    ok(($rg->{fetched_at} // 0) > 0, 'the row is stamped with fetched_at instead of an expiry');
    my ($cnt) = $h->selectrow_array(
        "SELECT COUNT(*) FROM release_group WHERE rg_mbid = 'rg-nct'");
    is($cnt, 1, 'a DATED release group with genres exists in the store — which it never once did');

    # MERGE, NEVER BLANK: two tiers write different columns, in either order.
    $rgPut->("rg-nct", genres => ["dance-pop"]);
    $rg = $rgGet->(['rg-nct'])->{'rg-nct'};
    is($rg->{year}, '2026', 'a later partial write leaves the year alone');
    is($rg->{name}, 'BLINGY', '...and the name');
    is(join(',', @{ $rg->{genres} || [] }), 'dance-pop', '...while updating what it did supply');
    is(join(',', @{ $rg->{agenres} || [] }), 'k-pop,dance-pop',
       '...and the OTHER frozen column is untouched');

    # THE DETAIL-PAGE TIER (0.9.173), round-tripped through REAL SQLite. Source-level
    # assertions in t_genrefill pin the call sites; this pins that the column exists,
    # freezes, thaws, mirrors its count and — the part that actually matters — that
    # it is a SEPARATE ANSWER WITH A SEPARATE STAMP. The bug it closes is the detail
    # page discovering a genre and discarding it; the bug it must not introduce is
    # that write re-dating ListenBrainz's answer sitting beside it.
    $rgPut->('rg-detail', genres => ['k-pop'], fetched_at => 4000);
    my ($lbAtBefore) = $h->selectrow_array(
        "SELECT genres_at FROM release_group WHERE rg_mbid = 'rg-detail'");
    $rgPut->('rg-detail', detail_genres => ['art rock', 'post-punk'], fetched_at => 9000);
    my $d = $rgGet->(['rg-detail'])->{'rg-detail'};
    is(join(',', @{ $d->{detail_genres} || [] }), 'art rock,post-punk',
       'the detail page\'s answer round-trips through its own column');
    is(join(',', @{ $d->{genres} || [] }), 'k-pop',
       '...leaving the ListenBrainz answer beside it untouched');
    my ($nDet, $detAt, $lbAtAfter) = $h->selectrow_array(
        "SELECT n_detail_genres, detail_genres_at, genres_at
           FROM release_group WHERE rg_mbid = 'rg-detail'");
    is($nDet, 2, '...with its length mirrored, so cachestats can count it');
    is($detAt, 9000, '...stamped when IT was obtained');
    # THE CROSS-TIER RE-DATING THIS PREVENTS: sharing genres_at would let a detail
    # write declare ListenBrainz's answer freshly fetched, which is how an empty
    # answer stayed alive indefinitely without anyone ever asking about it again.
    is($lbAtAfter, $lbAtBefore, '...and CANNOT re-date the ListenBrainz stamp');

    # An EMPTY list is a real answer and must be stored as one, not as absent —
    # otherwise the warm re-asks for every artist/album that will never answer.
    $rgPut->('rg-empty', genres => [], );
    my $e = $rgGet->(['rg-empty'])->{'rg-empty'};
    ok(ref $e->{genres} eq 'ARRAY' && !@{ $e->{genres} },
       'an empty genre list stores as an empty list, distinct from never-asked');
    ok(!defined $rgGet->(['rg-never'])->{'rg-never'}, '...and never-asked is simply absent');

    # Recording metadata, same implementation, its own alias.
    my $recPut = $NS->can('recPut');
    $recPut->('rec-1', artist => 'Radiohead', title => 'Airbag', album => 'OK Computer',
              release_group_mbid => 'rg-okc', year => '1997');
    my $rec = $NS->can('recGet')->(['rec-1'])->{'rec-1'};
    is($rec->{title}, 'Airbag', 'a recording round-trips');
    is($rec->{release_group_mbid}, 'rg-okc',
       'release_group_mbid comes back under the caller\'s name (column rg_mbid)');
    is($rec->{rg_mbid}, 'rg-okc', '...and under the column name too, so either reader works');

    # Bulk reads: the render path asks for a page at once, and the chunking has to
    # survive more keys than SQLite's 999-variable limit.
    $recPut->("rec-$_") for 1 .. 40;
    my $many = $NS->can('recGet')->([ map { "rec-$_" } 1 .. 1200 ]);
    is(scalar(keys %$many), 40, 'a bulk read past the SQLite variable limit returns what exists');

    # Wide characters and non-UTF-8 frozen bytes, on the facts tables too — the
    # 0.6.15 (key side) and 0.9.141 (value side) bugs both landed here.
    $rgPut->("rg-\x{30d0}\x{30f3}\x{30c9}", name => "Sigur R\x{f3}s \x{2014} ( )",
             genres => ["post-rock \x{2014} \x{a1}"]);
    my $w = $rgGet->(["rg-\x{30d0}\x{30f3}\x{30c9}"])->{"rg-\x{30d0}\x{30f3}\x{30c9}"};
    is($w->{name}, "Sigur R\x{f3}s \x{2014} ( )", 'a wide-character key and value round-trip');
    is($w->{genres}[0], "post-rock \x{2014} \x{a1}", '...including inside a frozen column');
}

# ===========================================================================
section '6b. KEY VERSIONS — declared once, and the layering rule is in the key';
{
    my $kver    = $NS->can('kver');
    my $kverNum = $NS->can('kverNum');
    my $KV      = $NS->can('KEY_VERSIONS')->();

    is($kver->('lbf:track:'), 'lbf:track:' . $KV->{'lbf:track:'} . ':',
       'kver composes family + version + colon');
    is($kverNum->('lbf:track:'), $KV->{'lbf:track:'}, 'kverNum returns the bare number');

    # An UNREGISTERED family must not silently produce a plausible key. It reports
    # once and answers 0, so the mistake shows up as a family that never hits
    # rather than as a crash mid-browse — and the report is what makes it findable.
    @T::Log::ERRORED = ();
    is($kver->('lbf:nosuch:'), 'lbf:nosuch:0:', 'an unregistered family gets version 0');
    ok(scalar(grep { /nosuch/ } @T::Log::ERRORED),
       '...and is reported, so it cannot pass as a working key');
    my $before = scalar @T::Log::ERRORED;
    $kver->('lbf:nosuch:');
    is(scalar @T::Log::ERRORED, $before, '...but only reported ONCE, not per render');

    # THE BUMP THAT WAS THE 0.9.42/0.9.141 BUG IS NOT EXPRESSIBLE. A Bandcamp pin
    # has no version in its identity at all, because it is a table row.
    ok(!exists $KV->{'lbf:bcmatch:'},
       'lbf:bcmatch: is NOT in KEY_VERSIONS — a pin has no version to bump');
    ok(exists $KV->{'lbf:bcdone:'},
       '...while the re-derivable "already searched" marker still does');

    # Retirement: rows under a family that do NOT carry the current version go,
    # rows that do stay, and other families are untouched.
    my $h = raw();
    $h->do('DELETE FROM kv');
    kvSet($kver->('lbf:track:') . 'keep', 'current');
    kvSet('lbf:track:1:old',              'stale');
    kvSet('lbf:track:99:future',          'wrong');
    kvSet($kver->('lbf:stream:') . 'other', 'untouched');
    kvSet('lbf:feed:all:whatever',          'unversioned family, not managed here');

    my $n = $NS->can('retirePrefixes')->({ 'lbf:track:' => $KV->{'lbf:track:'} });
    is($n, 2, 'retirePrefixes drops both off-version rows');
    is(kvGet($kver->('lbf:track:') . 'keep'), 'current', 'the current-version row survives');
    is(kvGet($kver->('lbf:stream:') . 'other'), 'untouched', 'another family is untouched');
    is(kvGet('lbf:feed:all:whatever'), 'unversioned family, not managed here',
       'an unmanaged family is left entirely alone');
}

# ===========================================================================
section '6c. THE DURABLE THREE — tables, and what they guarantee';
{
    my $h = raw();
    $h->do('DELETE FROM bandcamp_pin');
    $h->do('DELETE FROM follow_item');
    $h->do('DELETE FROM artist');

    # --- the Bandcamp pin -------------------------------------------------
    my $id = 'panda bear sonic boom a ? of when';
    ok(!defined $NS->can('bcPinGet')->($id), 'no pin to start with');
    $NS->can('bcPinPut')->($id, { items => [{ name => 'A ? of WHEN', _svc => 'Bandcamp' }] });
    my $pin = $NS->can('bcPinGet')->($id);
    is(ref($pin), 'HASH', 'a pin round-trips as a hash');
    is($pin->{items}[0]{_svc}, 'Bandcamp', '...with its item intact');

    # --- the recommendation store ----------------------------------------
    my $u = 'simon';
    $NS->can('followAdd')->($u, [
        { _key => 'm:aaa', title => 'Oldest', created => 100 },
        { _key => 'm:bbb', title => 'Newest', created => 300 },
        { _key => 'm:ccc', title => 'Middle', created => 200 },
    ]);
    my $list = $NS->can('followList')->($u, 10);
    is(scalar(@$list), 3, 'three recommendations stored');
    is(join(',', map { $_->{title} } @$list), 'Newest,Middle,Oldest',
       'followList returns newest-first');
    ok(!exists $list->[0]{_key}, 'the dedupe key is not written into the payload');

    # ADD-IF-NEW is the whole point: a rec that scrolls out of ListenBrainz's
    # 75-event window and comes back must not duplicate, and a re-merge of the
    # same feed must not rewrite what is there.
    my $added = $NS->can('followAdd')->($u, [
        { _key => 'm:bbb', title => 'Newest RENAMED', created => 999 },
        { _key => 'm:ddd', title => 'Brand new',      created => 400 },
    ]);
    is($added, 1, 'only the genuinely new item is inserted');
    $list = $NS->can('followList')->($u, 10);
    is(scalar(@$list), 4, 'the store grew by exactly one');
    is((grep { $_->{title} eq 'Newest' } @$list)[0]{title}, 'Newest',
       'the existing item was NOT overwritten by the re-merge');

    # Per-user, so two accounts on one server cannot read each other's store.
    $NS->can('followAdd')->('someone_else', [{ _key => 'm:zzz', title => 'Theirs', created => 500 }]);
    is(scalar(@{ $NS->can('followList')->($u, 10) }), 4, 'another user\'s rows are not visible');

    # The cap is applied in SQL, keeping the NEWEST.
    is($NS->can('followTrim')->($u, 2), 2, 'followTrim drops the excess');
    is(join(',', map { $_->{title} } @{ $NS->can('followList')->($u, 10) }),
       'Brand new,Newest', '...and keeps the newest');

    # --- artist sort-names -------------------------------------------------
    $NS->can('artistSortPut')->('mbid-jw', 'White, Jack', 'mb');
    $NS->can('artistSortPut')->('mbid-none', '', 'mb');
    my $sorts = $NS->can('artistSortGet')->(['mbid-jw', 'mbid-none', 'mbid-unknown']);
    is($sorts->{'mbid-jw'}, 'White, Jack', 'a sort-name reads back');
    ok(!exists $sorts->{'mbid-none'},
       'a recorded "MB has none" is absent from the map (the caller falls back to the credit)');
    ok(!exists $sorts->{'mbid-unknown'}, 'an unknown artist is simply absent');

    # ...but the ROW exists, which is what stops the warm re-asking MusicBrainz
    # every pass for an artist it already established has no sort-name.
    my $row = $NS->can('artistGet')->(['mbid-none'])->{'mbid-none'};
    ok($row && $row->{sort_src} eq 'mb',
       'the "none" answer IS recorded, so the warm can age-policy it instead of refetching');

    # --- and all three survive the dev-build wipe --------------------------
    kvSet('lbf:stream:27:whatever', 'disposable');
    $NS->can('wipeDerived')->();
    $NS->can('wipeGenres')->();
    ok(defined $NS->can('bcPinGet')->($id), 'the Bandcamp pin survives a dev build');
    is(scalar(@{ $NS->can('followList')->($u, 10) }), 2, 'the recommendations survive a dev build');
    is($NS->can('artistSortGet')->(['mbid-jw'])->{'mbid-jw'}, 'White, Jack',
       'the sort-name survives a dev build — a genre change must never cost it');
}

# ===========================================================================
section '6d. THE LAZY LEGACY IMPORT — the durable three, carried across';
{
    # A stand-in for the outgoing Slim::Utils::Cache, holding what a user's box
    # would have on the morning of the upgrade. DB::_legacy `require`s the module
    # and calls ->new, so satisfying %INC is enough.
    $INC{'Slim/Utils/Cache.pm'} = __FILE__;
    {
        package Slim::Utils::Cache;
        our %D;
        sub new { bless {}, __PACKAGE__ }
        sub get { my (undef, $k) = @_; return $D{$k} }
    }

    my $h = raw();
    $h->do('DELETE FROM bandcamp_pin');
    $h->do('DELETE FROM follow_item');
    $h->do('DELETE FROM artist');
    $h->do('DELETE FROM kv');

    my $id = 'legacy pin id';
    %Slim::Utils::Cache::D = (
        'lbf:bcmatch:6:' . $id => { items => [{ name => 'Pinned long ago', _svc => 'Bandcamp' }] },
        'lbf:follow:accum:1:simon' => { tracks => [
            { recording_mbid => 'rec-1', title => 'Carried', artist => 'A', created => 10 },
            { title => 'No mbid', artist => 'B', created => 20 },
        ] },
        # Written through API::_setText, so hashref-wrapped...
        'lbf:artistsort:1:mbid-x' => { t => 'Bear, Panda' },
        # ...and a pre-0.9.141 BARE string, which _getText was written to keep reading.
        'lbf:artistsort:1:mbid-y' => 'Beethoven, Ludwig van',
        # An empty answer is a real recorded fact and must come across too, or the
        # warm re-asks MusicBrainz for every artist already known to have none.
        'lbf:artistsort:1:mbid-z' => { t => '' },
    );

    my $got = $NS->can('importPin')->($id);
    is(ref($got), 'HASH', 'importPin returns the payload, so the current render can use it');
    is($NS->can('bcPinGet')->($id)->{items}[0]{name}, 'Pinned long ago',
       '...and it is now a durable row');

    is($NS->can('importFollow')->('simon'), 2, 'importFollow carries both recommendations');
    my $list = $NS->can('followList')->('simon', 10);
    is($list->[0]{title}, 'No mbid', '...newest first');
    ok(!exists $list->[0]{recording_mbid},
       'a rec with no MBID still came across (keyed on artist|title)');

    my $sorts = $NS->can('importSorts')->(['mbid-x', 'MBID-Y', 'mbid-z', 'mbid-absent']);
    is($sorts->{'mbid-x'}, 'Bear, Panda', 'a _setText-wrapped sort-name is carried');
    is($sorts->{'mbid-y'}, 'Beethoven, Ludwig van',
       'a pre-0.9.141 BARE string is carried too, and the MBID is case-folded');
    ok(exists $sorts->{'mbid-z'},
       'the EMPTY answer is returned as well, so the caller does not queue it for a refetch');
    ok(!exists $sorts->{'mbid-absent'}, 'an artist the old cache never knew is absent');
    is($NS->can('artistGet')->(['mbid-z'])->{'mbid-z'}{sort_src}, 'mb',
       '...and the empty answer was written as a real row');

    # THE DEADLINE, not a "done" flag: a lazy import is never finished, so what
    # bounds it is time. Past it, nothing is asked of the old cache at all — which
    # is the only thing that ever stops this costing a read on every miss.
    my $DEADLINE = $NS->can('IMPORT_DEADLINE_PREF')->();
    ok(defined $Slim::Utils::Prefs::P{$DEADLINE},
       'the first import stamps a deadline');

    # AND IT IS A PREF, NOT A `kv` ROW. The dev-build wipe is one unconditional
    # DELETE FROM kv, so a deadline kept there would be thrown away by every build
    # and re-minted 180 days out on the next miss — a window that never elapses, and
    # so an extra Slim::Utils::Cache read on every store miss for ever, which is the
    # exact cost the window exists to end.
    my $stamped = $Slim::Utils::Prefs::P{$DEADLINE};
    $NS->can('wipeDerived')->();
    is($Slim::Utils::Prefs::P{$DEADLINE}, $stamped,
       '...and the dev-build wipe cannot reach it');

    $Slim::Utils::Prefs::P{$DEADLINE} = time() - 1;
    $h->do('DELETE FROM bandcamp_pin');
    ok(!defined $NS->can('importPin')->($id),
       'past the deadline the old cache is not consulted at all');

    delete $INC{'Slim/Utils/Cache.pm'};

    # Leave exactly one pin behind: section 8 re-opens this file from a process
    # that never wrote it and counts them, which is the only way to tell a real
    # write from a write that returned 1 and did nothing.
    $NS->can('bcPinPut')->('cross-process pin', { items => [{ _svc => 'Bandcamp' }] });
}

# ===========================================================================
section '6e. THE FEED — coverage as a query, and the four ways it must not lie';
{
    # The text rung of the identity ladder calls Browse::_streamId ON PURPOSE, so
    # the release key and the stream key can never disagree about what "the same
    # album" is. Here that is a STUB: what this section tests is WHICH RUNG the
    # ladder picks, not how a name is normalised — `_norm` has its own suite and a
    # second copy of it here would be a fifth copy of a fleet-synced sub.
    {
        package Plugins::ListenBrainzFreshReleases::Browse;
        sub _streamId {
            my ($artist, $album, $mbid) = @_;
            return $mbid if defined $mbid && length $mbid;
            return join(' ', grep { length } map { my $s = lc($_ // ''); $s =~ s/[^a-z0-9 ]//g; $s }
                                             ($artist, $album));
        }
    }

    my $relId    = $NS->can('relId');
    my $ingest   = $NS->can('ingestFeed');
    my $coverage = $NS->can('feedCoverage');
    my $rels     = $NS->can('feedReleases');
    my $noteFail = $NS->can('feedNoteAttempt');
    my $invalid  = $NS->can('feedInvalidate');
    my $sweep    = $NS->can('feedSweep');
    my $shift    = sub { $NS->can('_fromDays')->($NS->can('_toDays')->(split /-/, $_[0]) + $_[1]) };

    # ---- the identity ladder ------------------------------------------
    is($relId->({ release_mbid => 'REL-1', release_group_mbid => 'RG-1',
                  artist_credit_name => 'A', release_name => 'B' }),
       'REL-1', 'a release mbid wins the ladder outright');
    is($relId->({ release_group_mbid => 'RG-1', artist_credit_name => 'A', release_name => 'B' }),
       'rg:RG-1', 'no release mbid falls to the release GROUP — the MuSpy case');
    is($relId->({ artist_credit_name => 'Panda Bear', release_name => 'Buoys' }),
       't:panda bear buoys', 'neither mbid falls to the matcher\'s own normalised text');
    is($relId->({}), '', 'a release with no identity at all is skipped, not stored under ""');

    # ---- ingest and read back -----------------------------------------
    my $today = $NS->can('_fromDays')->(int(time() / 86400));
    my ($d0, $d1, $d2) = (map { $shift->($today, $_) } (-2, -1, 0));

    my $mk = sub {
        my ($id, $date, %extra) = @_;
        return { release_mbid => $id, release_date => $date,
                 artist_credit_name => "Artist $id", release_name => "Album $id",
                 release_group_mbid => "rg-$id", caa_release_mbid => "caa-$id",
                 artist_mbids => ["amb-$id"],
                 # A field NOTHING mirrors into a column. It has to survive, because
                 # the whole reason the upstream hash is frozen whole is that the day
                 # ListenBrainz adds a field it must not be silently dropped.
                 release_tags => ['shoegaze', 'dream pop'], %extra };
    };

    my $r = $ingest->('all', [ $mk->('A', $d0), $mk->('B', $d1), $mk->('C', $d2) ],
                      from => $d0, to => $d2);
    ok($r->{ok},                 'a first ingest succeeds');
    is($r->{stored},  3,         'three releases are stored');
    is($r->{added},   3,         'all three are new members');
    is($r->{removed}, 0,         'a first ingest removes nothing');

    my $back = $rels->('all', $d0, $d2);
    is(scalar @$back, 3, 'all three read back');
    my ($a) = grep { $_->{release_mbid} eq 'A' } @$back;
    is(ref $a->{release_tags} eq 'ARRAY' ? $a->{release_tags}[0] : '(none)',
       'shoegaze', 'A FIELD NO COLUMN MIRRORS SURVIVES THE ROUND TRIP');
    is($a->{artist_credit_name}, 'Artist A', 'the payload comes back as the upstream hash');

    # ---- coverage is a query ------------------------------------------
    my $c = $coverage->('all', $d0, $d2);
    is($c->{days},     3, 'coverage counts every day in the window');
    is($c->{covered},  3, 'every day the ingest answered for is covered');
    ok($c->{complete},    'a fully covered window reports complete');
    is($c->{rows},     3, 'coverage reports the stored row count');

    # NARROWING THE WINDOW IS FREE — the whole point of feed_day. The old blob key
    # contained the window, so this was a total miss and a full re-fetch.
    my $narrow = $coverage->('all', $d1, $d2);
    ok($narrow->{complete}, 'NARROWING the window needs no fetch at all');
    is(scalar @{ $rels->('all', $d1, $d2) }, 2, 'and the read filters to the narrower window');

    # WIDENING costs only the days it adds, not the whole feed.
    my $wide = $coverage->('all', $shift->($d0, -2), $d2);
    is(scalar @{ $wide->{missing} }, 2, 'WIDENING the window is short by exactly the days it added');
    ok(!$wide->{complete},              'and so reports incomplete');

    # THE MIDNIGHT CASE, and it is weaker than docs/caching-rework.md claims. The
    # window shifting by a day leaves exactly ONE day uncovered — the new edge —
    # NOT zero. What actually changed is that the other 14 days, and every row, are
    # still there and still served: the old date-keyed blob was a TOTAL miss and a
    # full re-fetch of ~3,255 releases. So midnight goes from "re-mint everything,
    # blocking" to "serve everything, revalidate behind the render".
    my $tomorrow = $coverage->('all', $shift->($d0, 1), $shift->($d2, 1));
    is(scalar @{ $tomorrow->{missing} }, 1, 'a day\'s shift leaves exactly ONE day uncovered');
    is($tomorrow->{rows}, 3,                'and loses no stored rows — nothing is re-minted');

    # ---- merge, never blank -------------------------------------------
    # LB and MuSpy describe the same release with different completeness, so an
    # incoming empty field must leave the stored one alone.
    $ingest->('all', [ { release_mbid => 'A', release_date => $d0,
                         artist_credit_name => 'Artist A', release_name => 'Album A',
                         caa_release_mbid => '' } ], from => $d0, to => $d2);
    my $raw = raw()->selectrow_hashref('SELECT caa_rel_mbid, rel_date FROM release WHERE rel_id = ?',
                                       undef, 'A');
    is($raw->{caa_rel_mbid}, 'caa-A', 'AN INCOMING EMPTY DOES NOT BLANK THE STORED VALUE');
    is($raw->{rel_date},     $d0,     'and a supplied value is kept');

    # ---- an empty result is never a fact -------------------------------
    my $before = $coverage->('all', $d0, $d2);
    # `now` is pushed forward deliberately. Without it the refused write and the
    # previous good one land in the SAME SECOND, so the ok_at assertion below could
    # not tell an accepted empty ingest from a refused one and was vacuous.
    my $empty  = $ingest->('all', [], from => $d0, to => $d2, now => time() + 500);
    ok($empty->{refused},  'AN EMPTY RESPONSE IS REFUSED while rows already exist');
    is($empty->{stored}, 3,'and reports what is still stored');
    is(scalar @{ $rels->('all', $d0, $d2) }, 3, 'AN EMPTY RESPONSE DELETES NOTHING');
    my $after = $coverage->('all', $d0, $d2);
    is($after->{generation}, $before->{generation}, 'a refused ingest does not move the generation');
    # THE ASSERTION THAT ACTUALLY PINS THE REFUSE BRANCH. Deletion is guarded twice
    # over (rotation also needs a non-empty response), so "deletes nothing" stays
    # true even with the refuse branch removed — it is a property, not a mechanism.
    # The damage an accepted empty response really does is to stamp `ok_at` on every
    # day in the window, claiming they were answered when nothing answered.
    is($after->{ok_at}, $before->{ok_at},
       'AND DOES NOT CLAIM THE WINDOW WAS ANSWERED — ok_at is untouched');

    # A recorded FAILURE moves fetched_at and leaves ok_at, so the day stays
    # uncovered and the next open tries again rather than believing the gap real.
    $noteFail->('all', $d0, $d2, time() + 500);
    my $noted = $coverage->('all', $d0, $d2);
    ok($noted->{fetched_at} > $noted->{ok_at}, 'a failed attempt moves fetched_at but not ok_at');
    ok($noted->{complete},                     'and does not un-cover a day that really was answered');

    # ---- rotation is scoped to the REQUESTED window --------------------
    # B disappears from the response. It is inside the window, so it goes; a row
    # OUTSIDE the window was never spoken about and must survive.
    my $old = $shift->($today, -40);
    $ingest->('all', [ $mk->('OLD', $old) ], from => $old, to => $old);
    sleep 1;   # rotation compares seen_at < now, so the pass must be a second later
    my $rot = $ingest->('all', [ $mk->('A', $d0), $mk->('C', $d2) ], from => $d0, to => $d2);
    is($rot->{removed}, 1, 'a release that left the window\'s response is rotated out');
    my %left = map { $_->{release_mbid} => 1 } @{ $rels->('all') };
    ok(!$left{B},   'the dropped release is gone from the feed');
    ok($left{OLD},  'A ROW OUTSIDE THE REQUESTED WINDOW IS NEVER ROTATED — the response never named it');

    # ---- a TOP-N source must not rotate --------------------------------
    # MuSpy's `?limit=100` is a slice, not a window: a release still perfectly
    # valid can simply fall past the limit, so rotation there would delete it.
    #
    # THE WINDOW IS PASSED HERE ON PURPOSE, and the first cut of this test did not
    # pass one — which made it VACUOUS. Rotation is also guarded on having a
    # window, so with from/to omitted the rows survived whether the rotate flag was
    # honoured or not, and an anti-test that ignored the flag entirely stayed
    # green. API::_ingestFeed WIDENS the window to the span the response actually
    # carried before calling this, so MuSpy really does arrive here with one and
    # `rotate => 0` really is the only thing standing between it and deletion.
    $ingest->('muspy:u1', [ $mk->('M1', $d0), $mk->('M2', $d1) ], from => $d0, to => $d1, rotate => 0);
    sleep 1;
    my $mres = $ingest->('muspy:u1', [ $mk->('M1', $d0) ], from => $d0, to => $d1, rotate => 0);
    is($mres->{removed}, 0, 'a top-N source rotates NOTHING even with a window');
    is(scalar @{ $rels->('muspy:u1') }, 2,
       'A ROW PUSHED PAST THE LIMIT SURVIVES — a truncated list is not proof of absence');

    # ---- feeds are independent ----------------------------------------
    ok(!$coverage->('user:nobody', $d0, $d2)->{any}, 'an unfetched feed reports nothing stored');
    my %allIds = map { $_->{release_mbid} => 1 } @{ $rels->('all') };
    ok(!$allIds{M1}, 'a MuSpy row is not a member of the All Releases feed');
    ok(scalar(raw()->selectrow_array('SELECT COUNT(*) FROM release WHERE rel_id = ?', undef, 'M1')),
       'though both feeds share the one release table');

    # ---- generation moves only on real change --------------------------
    my $g1 = $coverage->('all', $d0, $d2)->{generation};
    $ingest->('all', [ $mk->('A', $d0), $mk->('C', $d2) ], from => $d0, to => $d2);
    is($coverage->('all', $d0, $d2)->{generation}, $g1, 'an identical ingest does not move the generation');
    $ingest->('all', [ $mk->('A', $d0), $mk->('C', $d2), $mk->('NEW', $d2) ], from => $d0, to => $d2);
    ok($coverage->('all', $d0, $d2)->{generation} > $g1, 'a new member does move it');

    # ---- Refresh marks stale, it does not delete -----------------------
    # Counted rather than hardcoded: the point is that the number does not CHANGE.
    my $rowsBefore = $coverage->('all', $d0, $d2)->{rows};
    $invalid->('all');
    my $inv = $coverage->('all', $d0, $d2);
    is($inv->{ok_at},   0, 'Refresh marks the feed stale');
    ok(!$inv->{complete},  'so every day reads as needing revalidation');
    is($inv->{rows}, $rowsBefore, 'AND REFRESH DELETES NOTHING — the user keeps seeing releases');

    # ---- BASE_VERSION ---------------------------------------------------
    raw()->do("UPDATE release SET base_version = 0 WHERE rel_id = 'A'");
    my %v = map { $_->{release_mbid} => 1 } @{ $rels->('all') };
    ok(!$v{A}, 'a row at an older BASE_VERSION reads as absent rather than as a shape mismatch');
    raw()->do("UPDATE release SET base_version = ? WHERE rel_id = 'A'",
              undef, $NS->can('BASE_VERSION')->());

    # ---- the sweep ------------------------------------------------------
    # Stored rows do not expire, so without this a permanently dead feed would show
    # months-old releases for ever.
    raw()->do('UPDATE feed_member SET seen_at = 1 WHERE rel_id = ?', undef, 'OLD');
    raw()->do('UPDATE release SET seen_at = 1 WHERE rel_id = ?',     undef, 'OLD');
    ok($sweep->(86400) > 0, 'the sweep prunes members nothing has re-seen');
    ok(!scalar(raw()->selectrow_array('SELECT COUNT(*) FROM release WHERE rel_id = ?', undef, 'OLD')),
       'and then collects the release row no feed points at any more');
    ok(scalar(raw()->selectrow_array('SELECT COUNT(*) FROM release WHERE rel_id = ?', undef, 'C')),
       'while a release a feed still holds is untouched');
}

# ===========================================================================
section '7. REPORTING — what cachestats has to be able to say';
{
    my $s = $NS->can('stats')->();
    ok($s->{ok},                       'stats reports a healthy store');
    ok(($s->{bytes} // 0) > 0,         'stats reports a non-zero file size');
    is($s->{version}, $NS->can('SCHEMA_VERSION')->(), 'stats reports the schema version');
    ok(exists $s->{tables}{kv},        'stats counts kv');
    ok(exists $s->{detail}{kv_expired},'stats counts expired-but-uncollected rows');
}

# ===========================================================================
section '8. PERSISTENCE, PROVED FROM A PROCESS THAT NEVER WROTE IT';
{
    # `$dbh` is a file-lexical. Writing and reading in one interpreter talks to the
    # handle we already hold and says nothing about what reached the disk — which
    # is exactly the illusion that let the 1970 defect survive for so long.
    kvSet('cross:hash',  { survived => 'yes' });
    kvSet('cross:zero',  0);
    kvSet('cross:undef', undef);
    kvSet('cross:empty', '');
    kvSet('cross:wide',  "Sigur R\x{f3}s \x{2014} \x{a1}");
    kvSet('cross:bytes', join('', map { chr($_) } 0xFF, 0x00, 0x80));
    kvSet('cross:long',  'ninety days', 90 * 86400);

    local $ENV{LBF_TDB_ROLE} = 'reader';
    local $ENV{LBF_TDB_DIR}  = $DIR;
    local $ENV{LBF_DB}       = $DB;
    # DECODE THE PIPE. The child writes UTF-8 deliberately; reading it back as
    # bytes would mangle the wide-character case HERE and report a store defect
    # that does not exist. A harness that cannot carry the value it is asserting
    # about is measuring itself.
    my @lines = map { utf8::decode($_); $_ } `$^X $0 2>&1`;
    ok(scalar(@lines), 'the child process ran');

    my %got = map { my (undef, $k, $v) = split /\t/, $_, 3; chomp $v if defined $v; ($k => $v) }
              grep { /^GOT\t/ } @lines;

    is($got{'cross:hash'},  'HASH:survived=yes', 'a hashref survives the process boundary');
    is($got{'cross:zero'},  'SCALAR:0',          'a stored 0 survives as 0');
    is($got{'cross:undef'}, 'MISS',              'a stored undef survives as undef');
    is($got{'cross:empty'}, 'EMPTY',             "a stored '' survives as ''");
    is($got{'cross:wide'},  "SCALAR:Sigur R\x{f3}s \x{2014} \x{a1}",
       'wide characters survive the process boundary intact');
    ok(defined $got{'cross:bytes'} && $got{'cross:bytes'} ne 'MISS',
       'non-UTF-8 bytes survive the process boundary');
    is($got{'cross:long'},  'SCALAR:ninety days',
       'THE 90-DAY ENTRY IS STILL THERE IN A FRESH PROCESS (the whole point)');

    my ($stats) = grep { /^STATS\t/ } @lines;
    my (undef, $sok, $kvRows, $pinRows, $ver) = split /\t/, ($stats // '');
    is($sok, '1', 'the child sees a healthy store');
    ok(($kvRows // 0) >= 7, 'the child counts the rows this process wrote');
    is($pinRows, '1', 'the Bandcamp pin is still there in a fresh process');
    chomp $ver if defined $ver;
    is($ver, '' . $NS->can('SCHEMA_VERSION')->(), 'the child reads the same schema version');
}

# ===========================================================================
section '9. AN UNOPENABLE STORE DEGRADES, IT DOES NOT DIE';
{
    # Also a child process, because $broken latches for the life of the
    # interpreter — an in-process attempt would poison every later section.
    my $bad = File::Spec->catdir($DIR, 'broken');
    mkdir $bad;
    mkdir File::Spec->catdir($bad, 'listenbrainzfreshreleases.db');   # a DIRECTORY where the file must go

    local $ENV{LBF_TDB_ROLE} = 'degrade';
    local $ENV{LBF_TDB_DIR}  = $bad;
    local $ENV{LBF_DB}       = $DB;
    my $out = `$^X $0 2>&1`;

    ok($out =~ /^DEGRADE\t/m, 'the child completed without dying');
    my ($fields) = $out =~ /^DEGRADE\t(.*)$/m;
    $fields //= '';
    ok($fields !~ /DIED/, "no store call died  ->  $fields");
    ok($fields =~ /\bset=0\b/,    'kvSet reports failure rather than pretending success');
    ok($fields =~ /\bget=undef\b/,'kvGet answers "not held"');
    ok($fields =~ /\bok=0\b/,     'stats reports an unhealthy store');
}

# ===========================================================================
printf "\n%s\n%d passed, %d failed.\n", '=' x 74, $pass, $fail;
exit($fail ? 1 : 0);
