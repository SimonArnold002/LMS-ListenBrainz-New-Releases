#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin;
BEGIN { *CORE::GLOBAL::time = sub { $T::now } }

open my $fh, '<', "$FindBin::Bin/../ListenBrainzFreshReleases/Browse.pm" or die $!;
my $source = do { local $/; <$fh> };
open my $afh, '<', "$FindBin::Bin/../ListenBrainzFreshReleases/API.pm" or die $!;
my $apiSource = do { local $/; <$afh> };
sub grab {
    my ($name) = @_;
    $source =~ /^(sub \Q$name\E \{.*?^\})/ms or die "missing $name";
    return $1;
}
{
    package T;
    our $now = 100;
    our (%lastfmHolds, %lastfmSettledArtists, $lastfmHoldId, $lastfmRequestBusy, $lastfmNextAt, $lastfmWarmPending, $detailMainReady,
         %BUILDING, @coverQueue, $coverRunning, $lastBrowseAt);
    our (@requests, @timers, @follow, @trending, @metadata, @lastfm, @stages, @stored,
         $listingError, %freshLfm, $apiRows);
    $lastfmNextAt = 0;
    our $prefs = bless { username => 'user', people_follow => 1, lastfm_api_key => 'key' }, 'Prefs';
    our $log = bless {}, 'Logger';
    use constant LASTFM_CORE_MAX => 3600;
    use constant LASTFM_SETTLED_TTL => 86400;
    use constant COVER_BROWSE_QUIET => 20;
    use constant LFM_WARM_MAX => 40;
    use constant LFM_WARM_ALL => 400;
    use constant GENRE_WARM_ALL => 4000;
    # warmCache is lifted here for its Last.fm hold/release ordering; it also carries
    # the playlist resolve, so the resolver's own ceiling has to be in scope.
    # t_playlistresolve.pl owns the assertions about it.
    use constant PLAYLIST_RESOLVE_TIMEOUT => 150;
    sub _dbg {}
    sub _stage { push @stages, [@_] }
    sub _genresFor { () }
    sub _pickValue { $_[0]{artist} }
    sub _genreKnown { lc($_[0] // '') ne 'usa' && lc($_[0] // '') ne 'seen live' }
    sub _stashPlaylistSummary {}
    sub _orderedAdapters { () }
    sub _warmFollow { push @follow, $_[2] }
    sub _warmTrending { push @trending, $_[2] }
    sub _filterAll { $_[0] }
    sub _filterForYou { $_[0] }
    sub _persistLbArtistTags {}
    sub _warmReport {}
    sub _withGenres { push @metadata, $_[0][0]{artist}; $_[1]->({}) }
    package Prefs;
    sub get { $_[0]{$_[1]} }
    package Logger;
    sub warn {}
    sub info {}
    package Slim::Utils::Timers;
    sub setTimer { my $t = [ @_ ]; push @T::timers, $t; return $t }
    sub killSpecific { $_[0][4] = 1 }
    package Plugins::ListenBrainzFreshReleases::API;
    sub getLastfmTags { push @T::requests, [ @_[1..5] ] }
    sub artistKeyForName { 'n:' . lc($_[1] // '') }
    sub peekLastfmArtistGenresBulk {
        my $accept = $_[2];
        return { map {
            my $key = $_;
            exists $T::freshLfm{$key}
                ? ($key => [ grep { !ref($accept) || $accept->($_) }
                                   @{ $T::freshLfm{$key} || [] } ])
                : ()
        } @{ $_[1] || [] } };
    }
    sub getCreatedForPlaylists {
        my ($class, %args) = @_;
        $T::listingError ? $args{onError}->('offline') : $args{onDone}->([]);
    }
    sub getFreshReleasesForUser { my ($class, %a) = @_; $a{onDone}->([{ artist => 'personal' }]) }
    sub getFreshReleasesAll { my ($class, %a) = @_; $a{onDone}->([{ artist => 'global' }]) }
    package Plugins::ListenBrainzFreshReleases::DB;
    sub artistPut { my ($key, %fields) = @_; push @T::stored, [$key, \%fields]; 1 }
    sub artistGet { $T::apiRows || {} }
}
$INC{'Plugins/ListenBrainzFreshReleases/DB.pm'} = __FILE__;
my $code = join "\n", map { grab($_) } qw(_holdLastfm _holdLastfmForDetail _lastfmPriorityBusy _detailPriorityBusy _warmLastfm _lastfmWarmNote _warmGenres warmCache);
eval "package T; no strict 'vars'; $code"; die $@ if $@;
sub advance {
    my ($to) = @_;
    my $steps = 0;
    while (1) {
        @T::timers = sort { $a->[1] <=> $b->[1] } grep { !$_->[4] } @T::timers;
        last unless @T::timers && $T::timers[0][1] <= $to;
        die 'timer spin' if ++$steps > 10000;
        my $t = shift @T::timers;
        $T::now = $t->[1];
        $t->[2]->($t->[0], $t->[3]);
    }
    $T::now = $to;
}

# Both daily feed branches (and the browse top-up) may snapshot one artist as
# missing before either callback stores it. The shared lane must ask once, and
# the skipped duplicate must leave its request allowance available for the next
# unique artist rather than deferring that work.
{
    local $T::now = 300;
    local @T::requests;
    local @T::timers;
    local @T::stored;
    local %T::freshLfm;
    local %T::lastfmSettledArtists;
    local $T::lastfmRequestBusy = 0;
    local $T::lastfmNextAt = 0;
    local $T::lastfmWarmPending = 0;
    my (@stats, $done);
    T::_warmLastfm([{ artist => 'Shared Artist' }], {},
        sub { $stats[0] = shift; $done++ }, 1);
    T::_warmLastfm([{ artist => 'Shared Artist' }, { artist => 'Unique Artist' }], {},
        sub { $stats[1] = shift; $done++ }, 1);
    advance(300);
    is_deeply([ map { $_->[0] } @T::requests ], ['Shared Artist'],
        'overlapping passes initially dispatch the shared artist once');
    $T::requests[0][2]->(['rock']);
    advance(301);
    is_deeply([ map { $_->[0] } @T::requests ], ['Shared Artist', 'Unique Artist'],
        'the duplicate checkpoint frees the second pass allowance for its unique artist');
    $T::requests[1][2]->([]);
    advance(302);
    is($done, 2, 'both overlapping Last.fm passes complete');
    is_deeply($stats[1],
        { enabled => 1, candidates => 2, fresh => 1, requested => 1,
          filled => 0, empty => 1, rejected => 0, failed => 0, deferred => 0 },
        'the overlapping pass reports one shared checkpoint and no false deferral');
}

# A failed owner did not produce a checkpoint. Its overlapping waiter must still
# retry the artist; deduplication must never turn a transient error into a cached
# negative answer.
{
    local $T::now = 400;
    local @T::requests;
    local @T::timers;
    local %T::freshLfm;
    local %T::lastfmSettledArtists;
    local $T::lastfmRequestBusy = 0;
    local $T::lastfmNextAt = 0;
    local $T::lastfmWarmPending = 0;
    my $done = 0;
    T::_warmLastfm([{ artist => 'Retry Artist' }], {}, sub { $done++ }, 1);
    T::_warmLastfm([{ artist => 'Retry Artist' }], {}, sub { $done++ }, 1);
    advance(400);
    $T::requests[0][3]->();
    advance(401);
    is_deeply([ map { $_->[0] } @T::requests ], ['Retry Artist', 'Retry Artist'],
        'a failed shared request leaves the overlapping artist retryable');
    $T::requests[1][2]->([]);
    advance(402);
    is($done, 2, 'failure and retry both settle their original passes');
}

my $release = T::_holdLastfm();
my $finished = 0;
T::_warmLastfm([{artist => 'one'}], {}, sub { $finished++ });
advance(102);
is(scalar @T::requests, 0, 'core work defers Last.fm without dropping its job');
$release->();
push @T::coverQueue, 'cover';
advance(103);
is(scalar @T::requests, 1, 'an unchecked preserved-cover marker does not delay Last.fm');
$T::requests[0][2]->([]);
@T::coverQueue = (); $T::coverRunning = 1;
T::_warmLastfm([{artist => 'two'}], {}, sub { $finished++ });
advance(104);
is(scalar @T::requests, 1, 'actual in-flight artwork has priority');
$T::coverRunning = 0; $T::lastBrowseAt = 104;
advance(123);
is(scalar @T::requests, 1, 'browsing pauses Last.fm');
advance(124);
is(scalar @T::requests, 2, 'Last.fm resumes after browsing is quiet');
T::_warmLastfm([{artist => 'three'}], {}, sub { $finished++ });
advance(125);
is(scalar @T::requests, 2, 'concurrent warm/top-up shares one request slot');
$T::requests[1][2]->([]);
advance(126);
is(scalar @T::requests, 3, 'next queued request starts after shared courtesy gap');
$T::requests[2][3]->();
advance(127);
is($finished, 3, 'success and failure both drain their jobs');

T::_warmLastfm([{artist => 'lost'}], {}, sub { $finished++ });
advance(128);
T::_warmLastfm([{artist => 'after'}], {}, sub { $finished++ });
advance(218);
is(scalar @T::requests, 5, 'watchdog releases a lost request so another job can run');
$T::requests[3][2]->([]);
ok($T::lastfmRequestBusy, 'late callback cannot release the newer request');
$T::requests[4][2]->([]); advance(219);

my $beforeTimers = scalar @T::timers;
$T::freshLfm{'n:cached empty'} = [];
$T::freshLfm{'n:cached rejected'} = ['seen live'];
my $cachedDone = 0;
T::_warmLastfm([{artist => 'Cached Empty'}, {artist => 'Cached Rejected'}], {}, sub { $cachedDone++ });
is(scalar @T::requests, 5, 'fresh empty and recently rejected answers make no Last.fm request');
is(scalar @T::timers, $beforeTimers, 'fresh settled answers consume no paced worker timer');
is($cachedDone, 1, 'fresh settled answers complete synchronously');

# The request bound belongs AFTER the cheap checkpoint scan.  This is the live
# 0.9.204 failure: the first 400 candidates were mostly fresh, so they filled the
# candidate allowance, were removed, and every never-asked artist after them was
# stranded on every subsequent pass.
{
    local %T::freshLfm = (
        'n:already one' => [],
        'n:already two' => ['seen live'],
    );
    my ($stats, $cappedDone);
    T::_warmLastfm([
        { artist => 'Already One' }, { artist => 'Already Two' },
        { artist => 'Needs One' },   { artist => 'Needs Two' },
        { artist => 'Deferred' },
    ], {}, sub { $cappedDone++; $stats = shift }, 2);
    advance($T::now);
    is($T::requests[-1][0], 'Needs One',
       'fresh checkpoints do not consume the request allowance');
    $T::requests[-1][2]->(['rock']);
    advance($T::now + 1);
    is($T::requests[-1][0], 'Needs Two',
       'the worker reaches later never-asked artists');
    $T::requests[-1][2]->([]);
    advance($T::now + 1);
    is($cappedDone, 1, 'the checkpoint-aware capped pass completes');
    is_deeply($stats,
        { enabled => 1, candidates => 5, fresh => 2, requested => 2,
          filled => 1, empty => 1, rejected => 0, failed => 0, deferred => 1 },
        'the pass reports candidates, answers and genuinely deferred work');
}

# Exercise the real core warm barrier with synchronous playlist cache hits and
# independently completing follower branches. Stub only the metadata worker.
{
    no warnings 'redefine';
    local *T::_warmGenres = sub {};
    T::warmCache('player');
    ok(T::_lastfmPriorityBusy(), 'core warm holds Last.fm');
    $T::follow[-1]->();
    ok(T::_lastfmPriorityBusy(), 'follow completion does not release trending work');
    $T::trending[-1]->();
    ok(!T::_lastfmPriorityBusy(), 'both branches complete before Last.fm is released');
    local $T::prefs->{people_follow} = 0;
    T::warmCache('player');
    ok(!T::_lastfmPriorityBusy(), 'disabled follower section releases core hold');
    local $T::listingError = 1;
    T::warmCache('player');
    ok(!T::_lastfmPriorityBusy(), 'playlist error releases core hold');
    local $T::prefs->{username} = '';
    T::warmCache('player');
    ok(!T::_lastfmPriorityBusy(), 'account-less warm releases core hold');
}
{
    no warnings 'redefine';
    local @T::stages;
    local *T::_warmLastfm = sub {
        push @T::lastfm, $_[2];
        $_[2]->({ enabled => 1, candidates => 4, fresh => 2, requested => 2,
                  filled => 1, empty => 1, rejected => 0, failed => 0, deferred => 0 });
    };
    T::_warmGenres();
    is_deeply(\@T::metadata, ['personal', 'global'], 'both ListenBrainz passes finish without waiting for Last.fm');
    is(scalar @T::lastfm, 2, 'both feeds queue their Last.fm tail');
    is($T::lastfmWarmPending, 0, 'main-enrichment phase releases only after both Last.fm tails finish');
    my @notes = map { $_->[3] }
                grep { $_->[0] eq 'end' && $_->[1] =~ /^genres_lastfm_/ } @T::stages;
    is(scalar @notes, 2, 'both Last.fm stages publish an outcome note');
    like($notes[0], qr/2 requested: 1 genre\(s\), 1 empty/,
         'warmstats says what Last.fm actually answered');
}
my $old = T::_holdLastfm();
$T::now += 3601;
my $new = T::_holdLastfm();
ok(T::_lastfmPriorityBusy(), 'expired old reservation does not free a newer core run');
$old->(); $new->();
ok(!T::_lastfmPriorityBusy(), 'reservation releases are independent');
$T::lastfmWarmPending = 1;
ok(T::_detailPriorityBusy(), 'general detail warming waits for the Last.fm phase to drain');
$T::lastfmWarmPending = 0;
ok(!T::_detailPriorityBusy(), 'general detail warming resumes after main enrichment');
$T::detailMainReady = 0;
ok(T::_detailPriorityBusy(), 'new feed inventory cannot run before its main enrichment starts');
$T::detailMainReady = 1;
ok(!T::_detailPriorityBusy(), 'the completed main phase opens the remainder phase');

for my $ending (qw(success failure watchdog)) {
    my $settle = T::_holdLastfmForDetail(1);
    ok(T::_lastfmPriorityBusy(), "a foreground release $ending holds Last.fm");
    $settle->();
    ok(!T::_lastfmPriorityBusy(), "foreground $ending releases its hold");
    $settle->();
    ok(!T::_lastfmPriorityBusy(), "foreground $ending releases the hold exactly once");
}

# A Last.fm response is a bag of independent tags.  Keep every displayable one;
# one rejected companion must not make the artist blank.  This is the live Hannah
# Cole shape: Last.fm says `indie, usa`, while only `indie` is a genre.
{
    local %T::freshLfm;
    local @T::stored;
    my $stats;
    T::_warmLastfm([{ artist => 'Hannah Cole' }], {}, sub { $stats = shift }, 1);
    advance($T::now);
    my $req = $T::requests[-1];
    is($req->[0], 'Hannah Cole', 'the mixed-tag artist reaches Last.fm');
    is($req->[4], 1, 'an expired artist checkpoint bypasses the raw 30-day tag cache');
    $req->[2]->(['indie', 'usa']);
    advance($T::now + 1);
    is_deeply($T::stored[-1],
        ['n:hannah cole', { lastfm_genres => ['indie'] }],
        'the accepted genre is stored and only its rejected companion is discarded');
    is_deeply($stats,
        { enabled => 1, candidates => 1, fresh => 0, requested => 1,
          filled => 1, empty => 0, rejected => 0, failed => 0, deferred => 0 },
        'a mixed accepted/rejected response counts as a displayable genre answer');
}

# Exercise API.pm's real cached-checkpoint classifier.  Rejected-only raw tags
# are negative answers and receive the one-day age even though their stored array
# is non-empty; accepted tags keep the 30-day positive age.
{
    my ($peek) = $apiSource =~ /^(sub peekLastfmArtistGenresBulk \{.*?^\})/ms;
    die 'missing peekLastfmArtistGenresBulk' unless $peek;
    my $code = "package AP; use constant LFM_FOUND_TTL => 30 * 86400; "
             . "use constant LFM_EMPTY_TTL => 86400;\n$peek\n1;";
    eval $code or die "API checkpoint eval: $@";

    local $T::apiRows = {
        mixed => { n_lastfm_genres => 2, lastfm_genres_at => $T::now - 10,
                   lastfm_genres => ['indie', 'usa'] },
        rejected_recent => { n_lastfm_genres => 1, lastfm_genres_at => $T::now - 10,
                             lastfm_genres => ['seen live'] },
        rejected_old => { n_lastfm_genres => 1, lastfm_genres_at => $T::now - 86401,
                          lastfm_genres => ['seen live'] },
        accepted_old => { n_lastfm_genres => 1, lastfm_genres_at => $T::now - 86401,
                          lastfm_genres => ['rock'] },
    };
    my $got = AP->peekLastfmArtistGenresBulk(
        [qw(mixed rejected_recent rejected_old accepted_old)],
        sub { T::_genreKnown($_[0]) });
    is_deeply($got->{mixed}, ['indie'], 'cached mixed tags expose only the usable genre');
    ok(exists $got->{rejected_recent} && !@{ $got->{rejected_recent} },
       'a recent rejected-only answer is remembered as a short negative checkpoint');
    ok(!exists $got->{rejected_old},
       'a rejected-only answer expires after the one-day negative age');
    is_deeply($got->{accepted_old}, ['rock'],
       'a usable answer remains fresh under the 30-day positive age');
}

{
    open my $gfh, '<', "$FindBin::Bin/../ListenBrainzFreshReleases/genre-families.txt" or die $!;
    my %genres;
    while (<$gfh>) {
        chomp;
        my ($name, $family) = split /\t/, $_, 2;
        $genres{$name} = $family if defined $family;
    }
    is($genres{indie}, '?', '`indie` is a valid standalone genre, not a discarded modifier');
    is($genres{'neo progressive rock'}, 'Rock', 'hyphen-normalised Last.fm genre maps to Rock');
    is($genres{'hypnagogic pop'}, 'Pop', 'the formerly documented mismatch maps to Pop');
    is($genres{'space rock revival'}, '?', 'family-less vocabulary genres remain displayable');

    # DARKWAVE IS ROCK, AND BOTH SPELLINGS MUST AGREE (Simon's call, 2026-09-10).
    # MusicBrainz carries `dark wave` and `darkwave` as SEPARATE vocabulary entries,
    # and norm() flattens hyphens and slashes but NOT the space — so the two never
    # share a lookup and drifted apart unnoticed: `darkwave` was overridden to
    # Electronic while `dark wave` fell through the rule and shipped family-less.
    # The pair is asserted together because testing either one alone would have
    # passed throughout the whole period they disagreed.
    is($genres{'darkwave'},   'Rock', '`darkwave` is Rock');
    is($genres{'dark wave'},  'Rock', '...and so is the space-separated spelling');
    is($genres{'darkwave'}, $genres{'dark wave'},
       '...and the two spellings agree, which is the property that broke');

    # THE LINEAGE IT WAS SPLIT FROM — the control. These were already Rock, and if
    # they ever stop being, the choice above is the one that needs re-arguing.
    is($genres{'coldwave'}, 'Rock', 'CONTROL — coldwave was already Rock');
    is($genres{'new wave'}, 'Rock', 'CONTROL — new wave was already Rock');

    # NOT swept up, deliberately: these are darkwave-adjacent but were not asked
    # for, and they stay family-less rather than being decided silently.
    is($genres{'ethereal wave'}, '?', 'ethereal wave is left family-less, not assumed');
}
done_testing();
