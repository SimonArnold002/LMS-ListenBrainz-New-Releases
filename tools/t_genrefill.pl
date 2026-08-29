#!/usr/bin/env perl
#
# t_genrefill.pl — guards the 2026-08-12 genre unpark and the hosted-API resolver.
#
#   perl tools/t_genrefill.pl
#
# WHAT THIS IS ABOUT. The genre-labels + genre-picker feature sat parked on the
# `alpha` branch for one measured reason: ListenBrainz's bulk metadata endpoint
# answered a 50-mbid batch in anywhere from 0.25s to 24s, 502'd above ~90 mbids,
# and took 125s to fill one 381-release feed — so `_genreLookupMode` returned
# 'off' for everyone without a local MusicBrainz mirror, and that single line kept
# the whole feature dark. Re-benchmarked 2026-08-12 against the live 556-release
# All Releases week, that same endpoint now fills the WHOLE feed in 2.8s (12
# batches of 50, worst batch 0.52s, no 502s), with coverage reproduced exactly:
# 5% release-group tags, 47% artist tags. So the default flipped.
#
# Sub bodies are extracted VERBATIM from Browse.pm / API.pm (the bench_walk trick)
# and driven against stubs, so these assertions track shipped code rather than a
# paraphrase of it. No LMS needed.
#
#   1. _genreLookupMode — THE UNPARK. No mirror + default pref must now be 'lb',
#      not 'off'. This is the assertion that fails if anyone reinstates the old
#      "off unless a mirror" default.
#   2. _genreTags       — the genre_mbid quality gate, count-desc order, stable
#      ties (NOT alphabetical), dedupe.
#   3. _mergeReleaseGroupMetadata — genres/agenres actually land on the entry, and
#      the year/date/type fields the trending path depends on still do too.
#   4. _foldEq          — the hosted resolver's accept gate: takes the API's
#      diacritic corrections, rejects a differently-named namesake, and REJECTS an
#      empty MBID whose name trivially folds equal to the query (the live shape of
#      an unknown artist, and the reason the length check exists).
#
# Anti-test: LBF_BROWSE / LBF_API point at mutated copies.
#
# Exit 0 = all good. Exit 1 = at least one regressed.
use strict;
use warnings;
use File::Spec;

my $ROOT   = File::Spec->rel2abs(File::Spec->catdir((File::Spec->splitpath($0))[1], File::Spec->updir));
my $BROWSE = $ENV{LBF_BROWSE} || File::Spec->catfile($ROOT, 'ListenBrainzFreshReleases', 'Browse.pm');
my $APISRC = $ENV{LBF_API}    || File::Spec->catfile($ROOT, 'ListenBrainzFreshReleases', 'API.pm');

my ($pass, $fail) = (0, 0);
sub ok {
    my ($cond, $what) = @_;
    die "ok() called with no message\n" unless defined $what && length $what;
    $cond ? ($pass++, print "  PASS  $what\n") : ($fail++, print "  FAIL  $what\n");
    return $cond ? 1 : 0;
}

# Value-comparing sibling of ok(), so a failure prints what it actually got
# rather than only that it was false.
sub is {
    my ($got, $want, $what) = @_;
    $got  = defined $got  ? $got  : '(undef)';
    $want = defined $want ? $want : '(undef)';
    return ok($got eq $want, "$what  ->  '$got'" . ($got eq $want ? '' : "  (wanted '$want')"));
}

sub slurp {
    my ($f) = @_;
    open(my $fh, '<:encoding(UTF-8)', $f) or die "$f: $!";
    local $/; my $s = <$fh>; close $fh; return $s;
}

# Brace-matched verbatim extraction of a named sub.
sub grab {
    my ($src, $name) = @_;
    $src =~ /^sub \Q$name\E\b\s*\{/mg or die "no sub $name\n";
    my $start = $-[0];
    my $i     = pos($src);
    my $depth = 1;
    while ($i < length($src) && $depth) {
        my $c = substr($src, $i++, 1);
        $depth++ if $c eq '{';
        $depth-- if $c eq '}';
    }
    pos($src) = undef;
    return substr($src, $start, $i - $start) . "\n";
}

my $browse_src = slurp($BROWSE);
my $api_src    = slurp($APISRC);
# DB.pm at file scope too, so the sections that assert on the STORE's half of a
# contract (the detail-genre tier's column, stamp and wipe) read the same source
# the KEY_VERSIONS block below already uses. LBF_DB points it at a mutated copy
# for anti-testing, exactly like LBF_BROWSE and LBF_API.
my $DBSRC   = $ENV{LBF_DB} || File::Spec->catfile($ROOT, 'ListenBrainzFreshReleases', 'DB.pm');
my $db_src  = slurp($DBSRC);

# ---------------------------------------------------------------------------
# A minimal DB::kver/kverNum, built from the REAL KEY_VERSIONS in DB.pm.
#
# Since the caching rework the key builders ask DB for a family's version rather
# than spelling it out, so a harness that evals a lifted sub body has to answer
# that call. It is derived from the shipped table rather than restated here, for
# the usual reason: a hand-copied constant drifts silently, and a suite that
# asserts a key it made up itself asserts nothing. Loading the real DB.pm would
# pull in DBI and a real file for two hash lookups.
# ---------------------------------------------------------------------------
{
    my ($body) = $db_src =~ /use constant KEY_VERSIONS => \{(.*?)\n\};/s
        or die "no KEY_VERSIONS in DB.pm\n";
    my %v = $body =~ /'([^']+)'\s*=>\s*(\d+)/g;
    die "KEY_VERSIONS parsed empty\n" unless keys %v;
    no strict 'refs';
    *{'Plugins::ListenBrainzFreshReleases::DB::kver'}    = sub { $_[0] . ($v{$_[0]} // 0) . ':' };
    *{'Plugins::ListenBrainzFreshReleases::DB::kverNum'} = sub { $v{$_[0]} // 0 };
    $INC{'Plugins/ListenBrainzFreshReleases/DB.pm'} = __FILE__;
}

# ===========================================================================
print "\n1. THE UNPARK — genre lookup defaults ON without a mirror\n";
print "-" x 74, "\n";
{
    my $pkg = <<'CODE';
package G1;
our $MIRROR = 0;
our $PREF;
package Plugins::ListenBrainzFreshReleases::API;
sub hasMirror { $G1::MIRROR }
package G1;
our $prefs = bless {}, 'G1::Prefs';
package G1::Prefs;
sub get { $G1::PREF }
package G1;
CODE
    $pkg .= grab($browse_src, '_genreLookupMode') . "1;\n";
    eval $pkg or die "G1 eval: $@";

    # The parked state: no mirror, pref never set (so undef -> 'auto').
    local $G1::MIRROR = 0;
    local $G1::PREF   = undef;
    my $mode = G1::_genreLookupMode();
    ok($mode eq 'lb', "no mirror + unset pref -> 'lb' (was 'off' — this IS the unpark)");
    print "    resolved to: $mode\n";

    local $G1::PREF = 'auto';
    ok(G1::_genreLookupMode() eq 'lb', "explicit 'auto' + no mirror -> 'lb'");

    # A mirror is still preferred when present — it is faster than the bulk path,
    # so the unpark must not have thrown that away.
    local $G1::MIRROR = 1;
    local $G1::PREF   = 'auto';
    ok(G1::_genreLookupMode() eq 'mirror', "a mirror still wins under 'auto'");

    # 'always' now means "use ListenBrainz even if a mirror exists", rather than
    # the old "opt in to something slow".
    local $G1::PREF = 'always';
    ok(G1::_genreLookupMode() eq 'lb', "'always' forces the bulk path even with a mirror");

    # Off must still mean off — the escape hatch has to keep working.
    local $G1::PREF = 'off';
    ok(G1::_genreLookupMode() eq 'off', "'off' still disables lookup entirely");
    local $G1::MIRROR = 0;
    ok(G1::_genreLookupMode() eq 'off', "'off' disables it with no mirror too");
}

# ===========================================================================
print "\n2. _genreTags — the genre_mbid gate and the ordering rule\n";
print "-" x 74, "\n";
{
    my $pkg = "package G2;\n" . grab($api_src, '_genreTags') . "1;\n";
    eval $pkg or die "G2 eval: $@";

    # A tag is a GENRE only when it carries a genre_mbid. Freeform user tags are
    # what "seen live" / country names / moods arrive as, and they are exactly the
    # noise the label must never show.
    my $mixed = [
        { tag => 'seen live',      count => 99 },                       # no genre_mbid
        { tag => 'shoegaze',       count => 5,  genre_mbid => 'g1' },
        { tag => 'united kingdom', count => 40 },                        # no genre_mbid
        { tag => 'dream pop',      count => 9,  genre_mbid => 'g2' },
    ];
    my $got = G2::_genreTags($mixed);
    ok(scalar(@$got) == 2, 'freeform tags dropped, genres kept');
    ok(!(grep { $_ eq 'seen live' || $_ eq 'united kingdom' } @$got),
        'the highest-count entries are dropped when they are not genres');
    ok($got->[0] eq 'dream pop', 'strongest genre first (count desc)');
    print "    -> " . join(', ', @$got) . "\n";

    # Ties must keep the SOURCE order, not fall back to alphabetical. Most real
    # tags tie at count 1, so an alphabetical tie-break silently becomes "show the
    # alphabetically first genres" — which is how a drum-and-bass artist ends up
    # labelled "ambient, breakcore".
    my $tied = [
        { tag => 'drum and bass', count => 1, genre_mbid => 'g1' },
        { tag => 'ambient',       count => 1, genre_mbid => 'g2' },
        { tag => 'breakcore',     count => 1, genre_mbid => 'g3' },
    ];
    my $t = G2::_genreTags($tied);
    ok($t->[0] eq 'drum and bass', 'ties keep source order, NOT alphabetical');
    print "    -> " . join(', ', @$t) . "\n";

    ok(scalar(@{ G2::_genreTags([ { tag => 'rock', count => 2, genre_mbid => 'g1' },
                                  { tag => 'Rock', count => 1, genre_mbid => 'g2' } ]) }) == 1,
        'case-insensitive dedupe');
    ok(scalar(@{ G2::_genreTags(undef) }) == 0, 'undef list -> empty, no die');
    ok(scalar(@{ G2::_genreTags([]) })    == 0, 'empty list -> empty');
}

# ===========================================================================
print "\n3. _mergeReleaseGroupMetadata — genres ride the existing bulk call\n";
print "-" x 74, "\n";
{
    my $pkg = "package G3;\n" . grab($api_src, '_genreTags')
            . grab($api_src, '_mergeReleaseGroupMetadata') . "1;\n";
    eval $pkg or die "G3 eval: $@";

    my %meta;
    G3::_mergeReleaseGroupMetadata(\%meta, {
        'RG-1' => {
            release_group => { date => '2026-08-14', type => 'Album', name => 'A Record' },
            tag => {
                release_group => [ { tag => 'slowcore', count => 3, genre_mbid => 'x' } ],
                artist        => [ { tag => 'indie rock', count => 7, genre_mbid => 'y' },
                                   { tag => 'favourites', count => 90 } ],
            },
        },
    });
    my $e = $meta{'rg-1'};
    ok(ref $e eq 'HASH', 'entry keyed lower-case');
    # The year/date/type fields predate the genre work and the trending path still
    # depends on them — adding genres must not have disturbed them.
    ok($e->{year} eq '2026',       'year still parsed (trending rows depend on it)');
    ok($e->{date} eq '2026-08-14', 'full date still carried');
    ok($e->{type} eq 'Album',      'primary type still carried');
    ok(ref $e->{genres} eq 'ARRAY' && $e->{genres}[0] eq 'slowcore',
        "the album's OWN genres land in `genres`");
    ok(ref $e->{agenres} eq 'ARRAY' && $e->{agenres}[0] eq 'indie rock',
        "the ARTIST's genres land separately in `agenres`");
    ok(!(grep { $_ eq 'favourites' } @{ $e->{agenres} }),
        'the genre_mbid gate still applies on the artist list');
    print "    genres=" . join(',', @{ $e->{genres} })
        . "  agenres=" . join(',', @{ $e->{agenres} }) . "\n";

    # Album and artist genres are kept APART on purpose: an artist genre is only a
    # proxy, so a jazz artist's ambient side project must not inherit "jazz" as
    # though the record itself were tagged that way.
    ok(!(grep { $_ eq 'indie rock' } @{ $e->{genres} }),
        'artist genres are NOT merged into the album\'s own list');
}

# ===========================================================================
print "\n4. _foldEq — the hosted resolver's accept gate\n";
print "-" x 74, "\n";
{
    # _foldEq delegates to Browse::_norm at runtime; give it the real one.
    my $pkg = "package Plugins::ListenBrainzFreshReleases::Browse;\n"
            . "our \$HAVE_NFD;\n"
            . grab($browse_src, '_norm')
            . "package G4;\n"
            . grab($api_src, '_foldEq') . "1;\n";
    # %FOLD and $HAVE_NFD live outside the sub bodies; lift them verbatim.
    my ($fold) = $browse_src =~ /(my %FOLD = \(.*?\);)/s;
    my ($nfd)  = $browse_src =~ /(my \$HAVE_NFD = [^\n]+)/;
    $pkg = "package Plugins::ListenBrainzFreshReleases::Browse;\n$nfd\n$fold\n"
         . grab($browse_src, '_norm')
         . "package G4;\n" . grab($api_src, '_foldEq') . "1;\n";
    eval $pkg or die "G4 eval: $@";

    # BUILD THE ACCENTED NAMES THE WAY THE RUNTIME DOES, or this section tests the
    # wrong thing. _norm only applies its NFD diacritic fold to a utf8-FLAGGED
    # string, and the hosted API's names reach it via from_json, which returns
    # flagged strings (verified: JSON::PP->utf8->decode of "Beyonc\xc3\xa9" gives
    # is_utf8=YES). A literal chr(0xE9) here would be an UNFLAGGED Latin-1 string,
    # _norm would skip the fold, and these assertions would fail against
    # perfectly correct code — the 0.9.157 "the fixture was the wrong string"
    # lesson, in miniature. So decode from UTF-8 bytes, exactly like the real path.
    my $dec = sub { my $s = shift; utf8::decode($s); $s };
    my $beyonce   = $dec->("Beyonc\xc3\xa9");
    my $motorhead = $dec->("Mot\xc3\xb6rhead");
    ok(utf8::is_utf8($beyonce), 'fixture is utf8-flagged, like a real decoded response');

    # ACCEPT: the API returns the canonically-accented spelling for an unaccented
    # query. These are the common case and they are correct — a gate that rejected
    # them would send almost every real resolution to the slow MusicBrainz path.
    ok(G4::_foldEq('Beyonce',   $beyonce),   'accepts Beyonce -> Beyonce (diacritic pick)');
    ok(G4::_foldEq('Motorhead', $motorhead), 'accepts Motorhead -> Motorhead with umlaut');
    ok(G4::_foldEq('boygenius', 'boygenius'), 'accepts an exact match');
    ok(G4::_foldEq('Better Oblivion Community Center', 'Better Oblivion Community Center'),
        'accepts a long exact match');

    # REJECT: a differently-named popular artist. This is what the score>=90 gate
    # protected against on the MusicBrainz path, and what the fold gate replaces —
    # these MBIDs seed radio chains that run unattended, so a wrong artist quietly
    # poisons the output.
    ok(!G4::_foldEq('The Oh Sees', 'Osees'), 'rejects a differently-named artist');
    ok(!G4::_foldEq('Nirvana', 'Nirvana UK'), 'rejects a near-miss namesake');
    ok(!G4::_foldEq('Prism', ''), 'rejects an empty answer');
}

# ===========================================================================
print "\n5. The unknown-artist shape — why the length check is load-bearing\n";
print "-" x 74, "\n";
{
    # Verified live 2026-08-12: an artist the hosted API does not know does NOT
    # 404 and does NOT return {} — it echoes the QUERY back with an empty mbid:
    #     {"name":"zzzqqq notanartist","mbid":""}
    # so the NAME folds equal to itself and a gate written on the name alone would
    # accept nothing at all as though it were a hit. The accept condition must
    # therefore test the MBID's length as well as the fold.
    my $unknown = { name => 'zzzqqq notanartist', mbid => '' };
    my $query   = 'Zzzqqq Notanartist';

    my $nameFolds = lc($unknown->{name}) eq lc($query);
    ok($nameFolds, 'the unknown-artist reply DOES fold-match the query (the trap)');

    my $accepted = (length($unknown->{mbid} // '') && $nameFolds) ? 1 : 0;
    ok(!$accepted, 'the length check rejects it anyway');

    # And the gate as SHIPPED must contain that check.
    my ($body) = $api_src =~ /(sub getArtistMbidByName\b.*?\n\}\n)/s;
    ok(scalar($body =~ /unless \(length \$mbid\)/),
        'getArtistMbidByName still guards on length $mbid');
    ok(scalar($body =~ /_foldEq\(/),
        'getArtistMbidByName still applies the fold gate');
    # The MusicBrainz fallback must stay UNCONDITIONAL: an outage of a third-party
    # accelerator has to degrade to the previous behaviour, never to breakage.
    ok(scalar($body =~ /\$mbFallback/),
        'the MusicBrainz fallback is still wired for every reject path');
}

# ===========================================================================
print "\n6. THE DETAIL PAGE FETCHES NO GENRES — both on-demand tiers removed (0.9.185)\n";
print "-" x 74, "\n";
{
    # THIS SECTION USED TO DRIVE `getAlbumGenresHosted` FOR REAL. Both it and the
    # MusicBrainz call behind it were removed in 0.9.185, so what is worth
    # asserting now is the opposite: that the detail page reads the store and asks
    # nobody, and that neither sub creeps back.
    #
    # WHY THEY WENT, so nobody reinstates them from the old comments: the block
    # peeks the store having ALREADY walked the whole ladder, and the Trending
    # Albums build stores genres itself (its rg-metadata pass carries
    # `inc=release_group tag`). So both tiers only ever ran on the residue where
    # every MB-derived source was already empty — and both are MB-derived.
    # Measured 2026-08-22: hosted 0 of 40 off the live fresh-releases feed; the MB
    # release-group tier 0 of 14 on the same residue.
    ok(!scalar($api_src =~ /^\s*sub getAlbumGenresHosted\b/m),
       'getAlbumGenresHosted is GONE from API.pm');
    ok(!scalar($api_src =~ /^\s*sub getReleaseGroupGenres\b/m),
       'getReleaseGroupGenres is GONE from API.pm');
    ok(!scalar($api_src =~ /^\s*sub _hostedGenreNames\b/m),
       '...and so is _hostedGenreNames, which existed only to serve the hosted one');
    ok(!scalar($api_src =~ /^use constant HGENRES_/m),
       'the HGENRES_ constants went with them');

    my ($detail) = $browse_src =~ /(if \(\$wantGenres\) \{.*?\n    \}\n)/s;
    ok(defined $detail, 'found the detail page\'s genre block');
    # Match a CALL, not a mention — the block's comment names the removed subs on
    # purpose, so that whoever reads it knows what used to be there and why it went.
    ok(defined $detail && $detail !~ /->\s*(?:getAlbumGenresHosted|getReleaseGroupGenres)\b/,
       'the detail page calls NEITHER genre API');
    ok(defined $detail && $detail =~ /peek => 1, kick => 0/,
       'it is still a peek that makes no request of its own');
    ok(defined $detail && $detail !~ /API->/,
       'in fact the whole block reaches no API at all');
    # The barrier still has to be decremented exactly once or the page hangs to
    # its watchdog on every open — the failure mode a naive deletion produces.
    my $dec = () = $detail =~ /\$pending--/g;
    ok($dec == 1, "the render barrier is decremented exactly once  ->  $dec");
    ok(defined $detail && $detail =~ /\$finish->\(\)/,
       '...and $finish is still called, so the page renders');
}

print "\n6b. THE DETAIL PAGE ASKS LAST.FM NOTHING EITHER (0.9.186)\n";
print "-" x 74, "\n";
{
    # 0.9.185 kept the page's own Last.fm call on the grounds that Last.fm is the
    # one genuinely INDEPENDENT source. That is true of the LADDER and irrelevant
    # here: Last.fm IS the ladder's last rung (_genresFor tier 5 — artist tags,
    # then _lastfmGenres), so the peek in section 6 has already asked it. The live
    # album.gettoptags call could only repeat the rung that just answered, or
    # re-ask the one that just came up empty — blocking the render barrier behind
    # up to two chained HTTP calls, and rendering tags UNGATED by _genreKnown that
    # the lists themselves would have refused.
    my ($detail_all) = $browse_src =~ /(sub _releaseDetail\b.*?\n\}\n)/s;
    ok(defined $detail_all, 'found _releaseDetail');
    ok(defined $detail_all && $detail_all !~ /->\s*getLastfmTags\b/,
       '_releaseDetail calls getLastfmTags nowhere');
    ok(defined $detail_all && $detail_all !~ /\$wantLastfm/,
       '...and the $wantLastfm barrier slot is gone with it');

    # THE OTHER HALF OF THE SAME REMOVAL, and it is the one to get right: the tier
    # itself must SURVIVE. _warmLastfm is what puts Last.fm's answer in the store
    # for the peek above to find, so deleting getLastfmTags would silently empty
    # the ladder's last rung — a much worse bug than the duplicate call.
    ok(scalar($api_src =~ /^sub getLastfmTags\b/m),
       'API::getLastfmTags SURVIVES — the warm fills the ladder with it');
    ok(scalar($api_src =~ /^sub peekLastfmTags\b/m),
       '...and peekLastfmTags, which is how the ladder reads it back');
    ok(scalar($browse_src =~ /->\s*getLastfmTags\b/),
       'Browse still calls it — from _warmLastfm, the tier-5 filler');

    # The barrier must now count exactly the four surviving tasks. A stale term
    # here is the hang a careless deletion produces.
    my ($sum) = $browse_src =~ /my \$pending = ([^;]+);/;
    ok(defined $sum && $sum !~ /\$wantLastfm/,
       'the render barrier no longer counts a Last.fm task');
    ok(defined $sum && $sum =~ /\$wantStream/ && $sum =~ /\$wantGenres/
                    && $sum =~ /\$wantTracks/ && $sum =~ /\$wantArtist/,
       '...and still counts the four that remain');

    # And the genres line now has ONE source. Two would mean something was left
    # behind to prefer over the other.
    ok(scalar($browse_src =~ /my \$g = \(ref \$mbGenres eq 'ARRAY' && \@\$mbGenres\) \? \$mbGenres : undef;/),
       'the Genres line reads the ladder answer and nothing else');
}

print "\n6c. NO LAST.FM BIO FALLBACK — MAI, or no bio (0.9.186)\n";
print "-" x 74, "\n";
{
    # Removed on the same reasoning as the genre call, one layer over: MAI's OWN
    # bio sources include Last.fm, so this was a second route to a well MAI had
    # already drawn from — and it served a population that has never been offered
    # an artist PHOTO either (MAI-only since the Artist section was written).
    ok(!scalar($api_src =~ /^sub getArtistBio\b/m),
       'API::getArtistBio is GONE');
    ok(!scalar($api_src =~ /^sub _setText\b/m),
       '...and _setText, orphaned by it');
    ok(!scalar($api_src =~ /^sub _getText\b/m),
       '...and _getText');

    # _cleanBio MUST STAY — the MAI path runs its bio through it, and MAI returns
    # HTML at runtime, which is the whole reason that sub is as involved as it is.
    ok(scalar($api_src =~ /^sub _cleanBio\b/m),
       '_cleanBio SURVIVES — the MAI bio still goes through it');
    ok(scalar($browse_src =~ /API::_cleanBio\b/),
       '...and Browse still calls it on MAI output');

    my ($fetch) = $browse_src =~ /(sub _fetchArtistInfo\b.*?\n\}\n)/s;
    ok(defined $fetch, 'found _fetchArtistInfo');
    ok(defined $fetch && $fetch !~ /getArtistBio/,
       '_fetchArtistInfo reaches no bio API');

    # WITHOUT MAI THE TASK IS ABSENT, not a barrier slot resolving to an empty
    # hash. Gating $wantArtist is what makes "no MAI, no bio" cost nothing.
    ok(scalar($browse_src =~ /my \$wantArtist = \(length \$artist && _maiEnabled\(\)\) \? 1 : 0;/),
       'the artist task is gated on MAI being present');
    ok(scalar($browse_src =~ /^sub _maiEnabled\b/m),
       '_maiEnabled exists to answer that before the barrier is counted');

    # The bio branch owns exactly one barrier slot, and must release it on BOTH
    # exits — the callback AND the eval-threw path. This is the same hang section
    # 6 guards, in the sub the fallback used to hide it in.
    my ($bioBranch) = $fetch =~ /(# --- Biography.*?\n    \}\n)/s;
    ok(defined $bioBranch, 'found the biography branch');
    my $inc = () = ($bioBranch // '') =~ /\$pending\+\+/g;
    my $dec = () = ($bioBranch // '') =~ /\$pending--/g;
    ok($inc == 1, "it takes exactly one barrier slot  ->  $inc");
    ok($dec == 2, "...and releases it on both exits, callback and eval-threw  ->  $dec");
}

print "\n7. THE ARTIST-ROW KEY — shared by every artist-level rung\n";
print "-" x 74, "\n";
{
    # This section used to drive the HOSTED ARTIST tier end to end — its freshness
    # rule, its two ages, its store round trip. That rung was removed in 0.9.173
    # (see section 8 for why), and with it _hagenFresh, peekArtistGenresHosted and
    # getArtistGenresHosted. What survives, and still needs pinning, is the KEY:
    # artistKeyForName is how every remaining artist-level rung finds its row, so
    # a change to it silently refiles every answer under a key nothing reads.

    # NAME-KEYED, and that is the feature: it is the only genre tier that can
    # answer for a Trending row arriving with no MBID at all.
    my $key = grab($api_src, 'artistKeyForName');
    eval "package G7K; $key
        package Plugins::ListenBrainzFreshReleases::Browse;
        sub _norm { my \$s = lc(\$_[0] // ''); \$s =~ s/[^a-z0-9 ]//g; \$s =~ s/\\s+/ /g; \$s =~ s/^ | \$//g; \$s }
        1;" or die $@;
    is(G7K::artistKeyForName('x', 'NCT 127'), 'n:nct 127', 'a name folds to an n: key');
    is(G7K::artistKeyForName('x', '  NCT   127 '), 'n:nct 127', 'whitespace does not make a second row');
    is(G7K::artistKeyForName('x', ''), '', 'an empty name yields no key at all');
}

# ===========================================================================
print "\n8. THE LADDER ORDER — and the hosted ARTIST rung is GONE (0.9.173)\n";
print "-" x 74, "\n";
{
    # WHY THE HOSTED ARTIST RUNG WAS REMOVED, so nobody re-adds it on the old
    # reasoning ("ListenBrainz only answers ~52%, so a second artist source is the
    # only thing that moves the number"). That premise was wrong: the hosted API is
    # MusicBrainz-DERIVED, so it succeeds where LB succeeds and fails where LB
    # fails. Measured on the RESIDUE — the artists that actually reached it —
    # 4 of 120 (2026-08-13) and 1 of 67 (2026-08-21), i.e. ~2%, for one HTTP
    # request per artist at a concurrency of one. Last.fm, the only genuinely
    # independent source, answers ~63% of that same population.
    # ANCHORED ON CODE, NOT ON COMMENT TEXT. An earlier cut of this section keyed
    # on the strings "tier 1"/"tier 2" and broke the moment a comment mentioned a
    # tier out of order — an assertion that a prose edit can flip is not pinning
    # the ladder, it is pinning the prose.
    my $src = grab($browse_src, '_genresFor');
    my $ownAt      = index($src, '$m->{genres}');
    my $detailAt   = index($src, '$m->{detail_genres}');
    my $artAt      = index($src, '$m->{agenres}');
    my $inlineAt   = index($src, '_releaseTags');
    my $lastfmAt   = index($src, '_lastfmGenres');

    ok($ownAt >= 0 && $artAt > $ownAt, "the album's own genres are tried before the artist's");
    # AN ALBUM-SPECIFIC ANSWER OUTRANKS AN ARTIST-LEVEL ONE. An artist genre is
    # only ever a proxy for the record — the same reason tier 2 sits below tier 1.
    ok($detailAt > $ownAt && $detailAt < $artAt,
       "the detail page's own answer sits above the ARTIST tiers, below the album's own");
    ok($inlineAt > $artAt,   'inline release_tags come after the artist tiers');
    ok($lastfmAt > $inlineAt,'Last.fm remains the last resort');

    # THE RUNG IS ACTUALLY GONE, not merely unreferenced in the ladder.
    ok(!scalar($browse_src =~ /^\s*sub _hostedGenres\b/m),
       '_hostedGenres no longer exists');
    ok(!scalar($browse_src =~ /^\s*sub _warmHosted\b/m),
       '_warmHosted no longer exists');
    ok(!scalar($api_src =~ /^\s*sub getArtistGenresHosted\b/m),
       'getArtistGenresHosted no longer exists');
    # The ALBUM route was kept in 0.9.173 for the Trending Albums population and
    # then REMOVED TOO in 0.9.185 — that population turned out to be covered
    # already, because the trending build stores genres itself. Section 6 owns the
    # reasoning; this is here so the two cannot disagree about what exists.
    ok(!scalar($api_src =~ /^\s*sub getAlbumGenresHosted\b/m),
       '...and the hosted ALBUM route is gone as well (0.9.185)');

    # THE RENDER PATH MUST NEVER FETCH, and MUST NOT READ THE STORE PER RELEASE.
    # The first cut of the removed tier did exactly that — one synchronous SQLite
    # SELECT per row, ~30 for a page and ~2,900 for the genre picker, which walks
    # the whole feed through _bucketFor. That is the blocking work 0.9.130 moved
    # off the render path. bench_walk caught it; review did not.
    my $merge = grab($browse_src, '_mergeHostedGenres');
    ok(scalar($merge =~ /artistGet\(\[ keys %want \]\)/),
       'the whole page is read in ONE bulk store call');
    my $reads = () = $merge =~ /artistGet/g;
    ok($reads == 1, 'and exactly one — every artist rung shares it');
    # The removed rung must be gone from the bulk read too, or it would keep
    # thawing a column nothing can serve.
    # The TIER-LIST ENTRY specifically, not any mention of the column — the sub's
    # comment still names it, because the column itself survives unread.
    ok(!scalar($merge =~ /\['hosted_genres'/),
       'the bulk read no longer thaws the dead tier\'s column');

    # The two sides must agree on the key, or the fill writes somewhere the read
    # never looks — a failure with no symptom except "no genres", which is
    # indistinguishable from having none.
    my $tier = grab($browse_src, '_artistTierGenres');
    ok(scalar($tier =~ /_hostedArtistKey/) && scalar($merge =~ /_hostedArtistKey/),
       'the read and the fill derive the $meta key from the same sub');
    ok(!scalar($tier =~ /artistGet|DB::/),
       'the shared reader touches no store either');

    # The warm chain is now LB bulk -> Last.fm, with nothing between them.
    my $warm = grab($browse_src, '_warmGenres');
    ok(!scalar($warm =~ /_warmHosted/), 'the warm no longer fills a hosted tier');
    ok(scalar($warm =~ /_warmLastfm\(\$rels, \$meta/),
       '...and still chains Last.fm, which is the rung carrying the population');

    # The background top-up must follow the SAME ladder. It used to stop after the
    # ListenBrainz pass and never reach the rung below, so it could only ever
    # repair about half the feed — the "rows stay blank however many times you
    # open them" report.
    my $kick = grab($browse_src, '_kickGenreFill');
    ok(scalar($kick =~ /_warmLastfm/),
       'the background top-up reaches the last rung, not just the first');

    # THE WARM COVERS THE WHOLE FEED. This is the fix for "genres only appear if I
    # go in and out": GENRE_WARM_MAX (600) covered ~20% of a 3,255-release feed, so
    # every other week rendered bare and filled only from a background top-up.
    ok(scalar($warm =~ /GENRE_WARM_ALL/), 'the warm uses the whole-feed bound, not the per-render one');
    my ($all) = $browse_src =~ /use constant GENRE_WARM_ALL\s*=>\s*(\d+)/;
    ok(defined $all && $all >= 3300,
       "GENRE_WARM_ALL ($all) covers a full live feed (3,255 releases measured 2026-08-13)");

    # THE TOKEN GATE. 0.9.160 established fresh_releases never needed a token, but
    # the genre warm still demanded one — so a tokenless user's For You genres were
    # never warmed at all.
    ok(!scalar($warm =~ /unless \(\$user && \$token\)/),
       'the For You genre warm no longer requires a TOKEN');
    ok(scalar($warm =~ /unless \(\$user\)/), '...only a username');

    # THE USERNAME GATE IN warmCache, which is the OTHER half of the same bug.
    # `_warmGenres` opens by saying All Releases needs no account and handles the
    # case itself — but its one caller sat BELOW warmCache's early return, so an
    # account-less user never reached it and that branch was dead code. All
    # Releases was fetched and stored by warmFeeds (which runs ahead of warmCache
    # for exactly this reason) while its genres were never pre-warmed, so the view
    # opened bare and could only fill from the 120s-apart background top-up.
    my $wc = grab($browse_src, 'warmCache');
    my ($beforeGate) = $wc =~ /^(.*?)unless \(\(\$prefs->get\('username'\)/s;
    ok(defined $beforeGate && scalar($beforeGate =~ /_warmGenres\(\)/),
       '_warmGenres runs BEFORE warmCache\'s username gate');
    my $calls = () = $wc =~ /_warmGenres\(\)/g;
    ok($calls == 1, '...and exactly once — the old call site below the gate is gone');

    # The gate must no longer mark the genre stages skipped: _warmGenres has just
    # recorded them itself (For You skipped, All Releases running), and re-ending a
    # live stage with the wrong outcome is worse than the missing warm was.
    my ($skipList) = $wc =~ /'no username'\)\s*\n\s*for qw\(([^)]*)\)/s;
    ok(defined $skipList && !scalar($skipList =~ /genres_/),
       'the no-username skip list names no genre stage');
    ok(defined $skipList && scalar($skipList =~ /playlists/) && scalar($skipList =~ /trending_year/),
       '...while the stages that genuinely need an account are still marked');
}

# ===========================================================================
print "\n8b. THE DETAIL PAGE STOPS THROWING ITS ANSWER AWAY (0.9.173)\n";
print "-" x 74, "\n";
{
    # THE BUG: opening an album resolved a genre through the hosted album route or
    # MusicBrainz, showed it, and discarded it. Both wrote only to
    # Slim::Utils::Cache — and the MusicBrainz one was ALREADY KEYED ON
    # release_group_mbid, the row's own key. So the answer sat one table away from
    # the list that needed it. The render path is peek-only by design, so nothing
    # but the warm ever filled the store, and a newly-admitted week rendered bare
    # while its detail pages showed genres.
    my $detail = grab($browse_src, '_releaseDetail');

    # 0.9.185 INVERTED THIS. The page learns nothing to file any more: both
    # on-demand tiers are gone, so it reads the store and renders. `detail_genres`
    # is therefore write-once history — still READ as ladder tier 1b, never written
    # here again. The assertion is kept, inverted, because a reinstated fetch would
    # otherwise silently start writing a tier nothing measures.
    ok(!scalar($detail =~ /rgPut\(\s*lc \$rg,\s*detail_genres/),
       'the detail page no longer FILES genres — it has none to file (0.9.185)');

    # ITS OWN COLUMN. Writing into `genres` would re-date ListenBrainz's answer
    # beside it (they share one genres_at because ONE request answers both) — the
    # cross-tier overwrite schema 3 exists to make inexpressible.
    ok(!scalar($detail =~ /rgPut\([^)]*\bgenres\s*=>/),
       '...into detail_genres, never into the ListenBrainz column');

    # $fileDetail went with the fetches it served.
    my $files = () = $detail =~ /\$fileDetail->\(/g;
    ok($files == 0, 'the $fileDetail closure is gone with the calls that fed it');

    # And the store must carry it as its own tier, with its own stamp.
    ok(scalar($db_src =~ /detail_genres\s*=>\s*'detail_genres_at'/),
       'the store stamps detail_genres separately from the ListenBrainz answer');
    ok(scalar($db_src =~ /SCHEMA_VERSION\s*=>\s*5/),
       'the schema version is bumped, so the column is actually added');
    # A WIPE MUST CLEAR THE ANSWER AND ITS CLOCK TOGETHER. Clearing the answer and
    # leaving the stamp running is the 0.9.166 lockout: unaskable until it ages
    # out, which was NINETY DAYS of empty rows with no traffic trying to fix them.
    my $wipe = grab($db_src, 'wipeGenres');
    ok(scalar($wipe =~ /detail_genres = NULL/) && scalar($wipe =~ /detail_genres_at = 0/),
       'the genre wipe clears the new tier AND zeroes its stamp');
}

# ===========================================================================
print "\n9. LISTENBRAINZ RATE LIMITING — a 429 is a retry, not a lost chunk\n";
print "-" x 74, "\n";
{
    # MEASURED 2026-08-13: 30 requests per ~10s window, stated in
    # X-RateLimit-Remaining / X-RateLimit-Reset-In. The widened warm is 66 batches,
    # so exhausting the window is now certain rather than merely possible — and
    # before this, a 429 was logged and the chunk silently abandoned.
    my $isLim = grab($api_src, '_lbIsRateLimited');
    my $note  = grab($api_src, '_lbNoteLimit');
    my $wait  = grab($api_src, '_lbWait');
    eval "package G9;
        use Time::HiRes ();
        use constant LB_BACKOFF_MIN => 2;
        use constant LB_BACKOFF_CAP => 30;
        our \$_lbBusyUntil = 0;
        $isLim $note $wait 1;" or die $@;

    # A faithful stand-in for what SimpleAsyncHTTP hands an error handler: ->code
    # is not always populated (the reason Diag::_httpCode digs into the string
    # too), and ->headers is reached through ->can.
    { package G9::Resp;
      sub new     { my ($c, %a) = @_; bless { %a }, $c }
      sub code    { $_[0]{code} }
      sub error   { $_[0]{error} }
      sub headers { $_[0]{nohdr} ? die "no headers\n" : $_[0] }
      sub header  { $_[0]{reset} }
    }

    ok( G9::_lbIsRateLimited(G9::Resp->new(code => 429)), 'a 429 status is a rate limit');
    ok( G9::_lbIsRateLimited(G9::Resp->new(error => '429 TOO MANY REQUESTS')),
       '...and so is the 429 that only ever appears in the error STRING');
    ok(!G9::_lbIsRateLimited(G9::Resp->new(code => 500)), 'a 500 is a real failure, not a limit');
    ok(!G9::_lbIsRateLimited(G9::Resp->new(error => 'connect timeout')), 'nor is a timeout');
    ok(!G9::_lbIsRateLimited(undef), 'nor is no response at all');

    # The server states the reset; honour it rather than guessing.
    $G9::_lbBusyUntil = 0;
    my $in = G9::_lbNoteLimit(G9::Resp->new(code => 429, reset => 7), 1);
    ok($in == 7, "X-RateLimit-Reset-In is honoured verbatim  ->  ${in}s");
    ok(G9::_lbWait() > 6, 'and it becomes a SHARED deadline every caller sees');

    $G9::_lbBusyUntil = 0;
    my $floor = G9::_lbNoteLimit(G9::Resp->new(code => 429, reset => undef), 1);
    ok($floor == 2, 'a missing reset header falls back to the floor, never to an instant retry');

    # SimpleAsyncHTTP does not guarantee a headers object on a failure at all, so
    # reaching for one must not throw inside an error handler.
    $G9::_lbBusyUntil = 0;
    my $nohdr = eval { G9::_lbNoteLimit(G9::Resp->new(code => 429, nohdr => 1), 1) };
    ok(defined $nohdr && $nohdr == 2,
       'a response with NO headers object backs off at the floor rather than dying');

    $G9::_lbBusyUntil = 0;
    my $capped = G9::_lbNoteLimit(G9::Resp->new(code => 429, reset => 9999), 1);
    ok($capped == 30, 'an absurd reset is capped, so a chunk can never sit for ever');

    $G9::_lbBusyUntil = 0;
    my $a1 = G9::_lbNoteLimit(G9::Resp->new(code => 429, reset => 3), 1);
    $G9::_lbBusyUntil = 0;
    my $a3 = G9::_lbNoteLimit(G9::Resp->new(code => 429, reset => 3), 3);
    ok($a3 > $a1, "backoff grows with the attempt  ->  ${a1}s then ${a3}s");

    # THE CALL SITE, which is where the actual defect lived: the chunk must stay at
    # the head of the queue across a rate-limited attempt, or a "retry" retries the
    # NEXT chunk and the current one is lost exactly as before.
    my $rg = grab($api_src, 'getReleaseGroupMetadata');
    ok(scalar($rg =~ /my \$chunk = \$chunks\[0\];/),
       'the chunk is READ from the head of the queue, not shifted off it');
    my $shifts = () = $rg =~ /shift \@chunks;/g;
    ok($shifts == 2, 'it is removed on exactly two paths: success, and giving up');
    ok(scalar($rg =~ /_lbIsRateLimited\(\$resp\) && \$attempt < LB_RETRY_MAX/),
       'a rate-limited chunk is retried rather than dropped');
    ok(scalar($rg =~ /if \(\(my \$wait = _lbWait\(\)\) > 0\)/),
       'and a caller checks the shared deadline BEFORE issuing');
    ok(!scalar($rg =~ /my \$next;\s*\$next = sub/),
       'the driver does not capture itself (the uncollectable cycle from 0.9.95)');
}

# ===========================================================================
print "\n10. THE WIPE x REFETCH INTERACTION — a wiped genre must be re-askable\n";
print "-" x 74, "\n";
# THE REGRESSION THIS EXISTS FOR (0.9.166, live store 2026-08-13: 0 of 1034
# release groups holding a genre, and NO ListenBrainz traffic trying to fix it).
#
# `wipeGenres` nulls release_group.genres/agenres and deliberately leaves
# `fetched_at` and `year` alone, so a genre change cannot re-inflict a date
# refetch across the whole feed. getReleaseGroupMetadata then decided freshness
# from the DATE alone — and the request carries `inc=release_group tag`, i.e. it
# answers the date AND the genres. So every wiped row still looked fresh and its
# genres could not be re-asked for RECMETA_AGE: NINETY DAYS.
#
# Neither half is wrong on its own, which is exactly why no suite caught it —
# t_db.pl proves the wipe clears the columns, this file proved each tier fetches.
# The defect is only visible where the two meet, so that is what is driven here:
# the REAL freshness decision over the four states a row can be in.
{
    my $pkg = <<'CODE';
package G10;
our @ASKED;          # every mbid the sub decided to go and fetch
our %ROWS;           # what the store hands back

package Plugins::ListenBrainzFreshReleases::DB;
sub rgGet { my %o; $o{$_} = $G10::ROWS{$_} for grep { $G10::ROWS{$_} } @{$_[0]}; \%o }
sub rgPut { 1 }
# The AGES come from DB.pm, because that is where the policy lives and `stats`
# reports staleness from the same constants. A second copy here would let the
# fetcher and the instrument drift apart and both look correct.
sub RG_GENRE_FOUND_AGE { 90 * 86400 }
sub RG_GENRE_EMPTY_AGE { 14 * 86400 }

package Slim::Networking::SimpleAsyncHTTP;
sub new { bless {}, shift }
sub get {                       # record the request; never call back
    my ($self, $url) = @_;
    my ($csv) = $url =~ /release_group_mbids=(.*)$/;
    push @G10::ASKED, split(/(?:,|%2C)/, $csv // '');
}

package Plugins::ListenBrainzFreshReleases::API;
use constant BASE_URL       => 'https://api.listenbrainz.org';
use constant METADATA_CHUNK => 50;
use constant LB_RETRY_MAX   => 3;
use constant RECMETA_AGE    => 90 * 86400;
use constant USER_AGENT     => 'lbf-test';
our $log = G10::Log->new;
sub _lbWait { 0 }
sub _lbIsRateLimited { 0 }
sub _lbNoteLimit { 1 }
sub _mergeReleaseGroupMetadata { }
sub from_json { {} }

package G10::Log;
sub new { bless {}, shift }
sub error { } sub warn { } sub info { } sub is_info { 0 }

package Plugins::ListenBrainzFreshReleases::API;
CODE
    $pkg .= grab($api_src, '_factFresh');            # the REAL freshness rules,
    $pkg .= grab($api_src, '_answerFresh');          # both of them, unstubbed
    $pkg .= grab($api_src, '_genresFresh');
    $pkg .= grab($api_src, 'getReleaseGroupMetadata');
    $pkg .= "\npackage G10;\n1;\n";
    eval $pkg or die "G10 eval: $@";

    my $now = time();
    my $ask = sub {
        my (@mbids) = @_;
        @G10::ASKED = ();
        Plugins::ListenBrainzFreshReleases::API->getReleaseGroupMetadata(\@mbids, sub {});
        return { map { $_ => 1 } @G10::ASKED };
    };

    # Every row below has a live date and a FRESH `fetched_at` — so only the genre
    # answer's own count and stamp can distinguish them, which is the whole point.
    my $rg = sub {
        my ($n, $ago) = @_;
        return { year => '2026', fetched_at => $now,
                 n_genres => $n, genres_at => (defined $ago ? $now - $ago : 0) };
    };
    %G10::ROWS = (
        answered => $rg->(2,  86400),                  # tagged, recently
        empty    => $rg->(0,  86400),                  # asked, LB had no tags
        wiped    => $rg->(-1, undef),                  # wiped: answer gone, stamp zeroed
        old_full => $rg->(2,  200 * 86400),            # tagged, but past the FOUND age
        old_none => $rg->(0,   30 * 86400),            # empty, past the EMPTY age
        held     => $rg->(2,   30 * 86400),            # tagged and 30d old: still held
    );

    my $a = $ask->('answered');
    ok(!$a->{answered}, 'a row holding genres is served from the store, not refetched');

    # THE ONE THAT MAKES IT TERMINATE. _mergeReleaseGroupMetadata always sets
    # `genres`, so "asked, and LB had no tags" is recorded as an empty list. If
    # that counted as a miss, every tagless release group — most of a feed —
    # would be re-asked on every single pass, for ever.
    my $e = $ask->('empty');
    ok(!$e->{empty}, 'an EMPTY answer is a real answer and is not re-asked while fresh');

    my $w = $ask->('wiped');
    ok($w->{wiped},
       'a WIPED row IS re-asked, though its DATE is present and its date stamp is fresh');

    # NOTHING IS IMMUTABLE — the two ages are what make re-checking a trickle rather
    # than a stampede, and what stop an empty answer becoming a permanent verdict.
    my $of = $ask->('old_full');
    ok($of->{old_full}, 'a populated answer is re-checked once it passes the FOUND age');
    my $on = $ask->('old_none');
    ok($on->{old_none}, 'an EMPTY answer is re-checked far sooner — MB tagging lands after release');
    my $hd = $ask->('held');
    ok(!$hd->{held},
       '...while a POPULATED answer of the same age is still held, so the two ages really differ');

    # The live shape: one answered row among many wiped ones must not mask them.
    %G10::ROWS = (
        (map { ("w$_" => $rg->(-1, undef)) } 1 .. 5),
        ok1 => $rg->(2, 86400),
    );
    my $m = $ask->(qw(w1 w2 w3 w4 w5 ok1));
    ok(scalar(keys %$m) == 5, 'in a mixed set exactly the wiped rows are asked for');
    ok(!$m->{ok1}, 'and the answered one is still served from the store');
    print "    asked: " . join(', ', sort keys %$m) . "\n";
}

# ===========================================================================
print "\n11. ARTIST-KEYING + THE 429 BACKOFF — steps 1-4 of the ladder rework\n";
print "-" x 74, "\n";
{
    # ---- step 1: an artist-level answer must be readable by EVERY release by
    # that artist. Before schema 4 both artist rungs filed their answer under a
    # RELEASE-specific key, so the store re-bought the same answer once per
    # release and the warm's allowance went on work it had already done.
    my $pkg = <<'CODE';
package G11;
our @PUT;
package Plugins::ListenBrainzFreshReleases::DB;
sub artistPut { my ($k, %f) = @_; push @G11::PUT, [$k, \%f]; 1 }
sub artistGet { return $G11::ROWS || {} }
package Plugins::ListenBrainzFreshReleases::API;
sub artistKeyForName { my (undef, $n) = @_; return length($n // '') ? 'n:' . lc $n : '' }
package Plugins::ListenBrainzFreshReleases::Browse;
our $ROWS;
sub _dbg { }
CODE
    $pkg .= grab($browse_src, '_pickValue');
    $pkg .= grab($browse_src, '_hostedArtistKey');
    $pkg .= grab($browse_src, '_persistLbArtistTags');
    $pkg .= grab($browse_src, '_artistTierGenres');
    $pkg .= grab($browse_src, '_lbArtistGenres');
    $pkg .= grab($browse_src, '_lastfmArtistGenres');
    # The marker constants must live in the package the lifted subs run in, or
    # every rung dies on an undefined sub the moment it is called. HOSTED_MARK
    # went with its rung in 0.9.173 and is deliberately not stubbed back in — a
    # harness that supplies a constant the shipped code no longer defines would
    # keep a removed tier "working" here for ever.
    $pkg .= "package Plugins::ListenBrainzFreshReleases::Browse;\n"
          . "sub LB_MARK { 'lbartist?' }\n"
          . "sub LFM_MARK { 'lfmartist?' }\n1;\n";
    eval $pkg or die "G11 eval: $@";

    my @rels = (
        { release_group_mbid => 'RG1', artist_credit_name => 'Lambchop', release_name => 'A' },
        { release_group_mbid => 'RG2', artist_credit_name => 'Lambchop', release_name => 'B' },
        { release_group_mbid => 'RG3', artist_credit_name => 'Lambchop', release_name => 'C' },
    );
    # ALL THREE release groups carry the artist's tags — which is what the LB
    # response actually looks like, since `tag.artist` rides every release group by
    # that artist. Without the per-artist dedupe this writes the same answer three
    # times; the first cut of this fixture gave only ONE group tags, so the dedupe
    # was never exercised and the assertion below passed against a mutant that
    # removed it. Caught by the mutation run, not by review.
    my $meta = {
        rg1 => { agenres => ['country soul'] },
        rg2 => { agenres => ['country soul'] },
        rg3 => { agenres => ['country soul'] },
    };

    @G11::PUT = ();
    Plugins::ListenBrainzFreshReleases::Browse::_persistLbArtistTags(\@rels, $meta);
    ok(scalar(@G11::PUT) == 1, 'the artist tags are filed ONCE per artist, not once per release');
    is($G11::PUT[0][0], 'n:lambchop', '...on the artist row, through the readers own key builder');
    is(join(',', @{ $G11::PUT[0][1]{lb_genres} || [] }), 'country soul',
       '...carrying the answer');

    # THE PAYOFF: a release whose OWN release group has no answer still renders a
    # genre, because the artist row does. That is the difference between a feed
    # that can be prepared and one that cannot.
    my $pageMeta = { 'lb:n:lambchop' => ['country soul'], 'lbartist?' => 1 };
    my @g2 = Plugins::ListenBrainzFreshReleases::Browse::_lbArtistGenres($rels[1], $pageMeta);
    is(join(',', @g2), 'country soul',
       "a sibling release with NO release-group answer reads the artist's");
    ok(!scalar(Plugins::ListenBrainzFreshReleases::Browse::_lbArtistGenres(
                   { artist_credit_name => 'Someone Else' }, $pageMeta)),
       '...and a different artist gets nothing from it');

    # The marker short-circuit must stay: without it every release pays a key build
    # that can only miss, on a whole-feed walk (bench_walk, +1.5ms).
    ok(!scalar(Plugins::ListenBrainzFreshReleases::Browse::_lbArtistGenres(
                   $rels[0], { 'lb:n:lambchop' => ['country soul'] })),
       'no marker means no key is built at all (the empty case stays free)');

    # Each rung reads its OWN prefix — one cannot serve another's answer. Demoed
    # on Last.fm now that the hosted rung is gone, and with BOTH markers set on
    # purpose: with only the LB marker present the short-circuit would return
    # early and this would be re-testing the marker rather than the prefix.
    my $bothMarked = {
        %$pageMeta,
        Plugins::ListenBrainzFreshReleases::Browse::LFM_MARK() => 1,
    };
    ok(!scalar(Plugins::ListenBrainzFreshReleases::Browse::_lastfmArtistGenres(
                   $rels[0], $bothMarked)),
       'a rung cannot read another rung\'s answer even when its own marker is set');
}

{
    # ---- steps 2 and 3: the pacing that makes an uncapped run safe.
    my $pkg = "package G11B;\nuse constant HOSTED_BACKOFF_START => 5;\n"
            . "use constant HOSTED_BACKOFF_MAX => 30;\n"
            . "our \$log = G11B::L->new;\n"
            . "package G11B::L; sub new { bless {}, shift } sub warn { } sub info { }\n"
            . "package G11B;\nour \$hostedBusyUntil = 0; our \$hostedDelay = 0;\n";
    for my $sub (qw(_hostedWait _hostedIsRateLimited _hostedNoteLimit _hostedNoteOk)) {
        my $body = grab($api_src, $sub);
        $body =~ s/\$hostedBusyUntil/\$G11B::hostedBusyUntil/g;
        $body =~ s/\$hostedDelay/\$G11B::hostedDelay/g;
        $pkg .= $body;
    }
    $pkg .= "1;\n";
    eval $pkg or die "G11B eval: $@";

    ok(G11B::_hostedIsRateLimited(G11B::R->new(code => 429)), 'a 429 status is a rate limit');
    ok(G11B::_hostedIsRateLimited(G11B::R->new(err => 'Error: 429 Too Many Requests')),
       '...and so is the 429 that only ever appears in the error STRING');
    ok(!G11B::_hostedIsRateLimited(G11B::R->new(code => 500)), 'a 500 is a real failure, not a limit');

    # MAI's curve exactly: 5, doubling, capped at 30, reset on any success.
    $G11B::hostedDelay = 0; $G11B::hostedBusyUntil = 0;
    is(G11B::_hostedNoteLimit(), 5,  'the first backoff is 5s, as MusicArtistInfo does');
    is(G11B::_hostedNoteLimit(), 10, '...then doubles');
    is(G11B::_hostedNoteLimit(), 20, '...and again');
    is(G11B::_hostedNoteLimit(), 30, '...capped at 30s so a run can never stall for ever');
    is(G11B::_hostedNoteLimit(), 30, '...and stays there');
    ok(G11B::_hostedWait() > 0, 'and it becomes a deadline every caller sees');
    G11B::_hostedNoteOk();
    $G11B::hostedBusyUntil = 0;
    is(G11B::_hostedNoteLimit(), 5, 'a success resets the curve to the floor');

    # A DEADLINE ONLY EVER MOVES OUT — the guard _lbNoteLimit has always had and
    # this side did not (0.9.175). The deadline is SHARED while the curve is reset
    # by ANY success, so a plain assignment lets a later, SMALLER backoff shorten a
    # window still in force: A is limited at the 30s cap, B succeeds a second later
    # and zeroes the curve, C is limited and restarts at 5 — releasing every waiter
    # ~25 seconds early, straight back into the live limit. Backing off TOGETHER is
    # the entire reason the deadline is shared rather than per-caller.
    $G11B::hostedDelay = 0; $G11B::hostedBusyUntil = 0;
    G11B::_hostedNoteLimit() for 1 .. 5;                  # curve up to the 30s cap
    my $far = $G11B::hostedBusyUntil;
    G11B::_hostedNoteOk();                                # another caller succeeds
    is(G11B::_hostedNoteLimit(), 5, 'a later 429 still restarts the curve at the floor');
    is($G11B::hostedBusyUntil, $far,
       '...but it cannot pull a longer deadline already in force back in');

    # The call site: a 429 must be a RETRY, never a miss. Cached as a miss it would
    # be a lie ("this artist has no genres") AND would let the caller march on at
    # full speed, which is what makes an uncapped run dangerous.
    my $get = grab($api_src, '_hostedGet');
    ok(scalar($get =~ /_hostedIsRateLimited\(\$resp\)/), 'the error path tests for a rate limit');
    ok(scalar($get =~ /if \(\(my \$wait = _hostedWait\(\)\) > 0\)/),
       'and every caller checks the SHARED deadline BEFORE issuing');
    # A 429 IS A RETRY — UNTIL THE BUDGET RUNS OUT (0.9.174). Both halves are
    # user-visible failures and they pull in opposite directions:
    #
    #   miss on the FIRST 429  -> a lie ("this artist has no genres") that the
    #                             store then honours for the full FOUND age, and
    #                             the caller marches on at full speed.
    #   retry FOR EVER         -> a hang. $onMiss is the MusicBrainz fallback in
    #                             getArtistMbidByName, so it is never reached, and
    #                             DSTM::_resolveArtistMbids pumps one artist at a
    #                             time waiting on a callback that never comes.
    #
    # The LB side has capped this at LB_RETRY_MAX since it was written; this side
    # had no cap at all. So the assertion is no longer "never misses" but "misses
    # only once the budget is spent".
    ok(scalar($get =~ /\$st->\{tries\}\+\+ >= HOSTED_RETRY_MAX/),
       'the 429 retry is BOUNDED, the way the ListenBrainz side already was');
    my ($beforeMiss) = $get =~ /_hostedIsRateLimited\(\$resp\)\)\s*\{(.*?)\$onMiss->\(/s;
    ok($beforeMiss && $beforeMiss =~ /HOSTED_RETRY_MAX/,
       '...so the only $onMiss in the branch is the one the cap guards');
    my ($afterCap) = $get =~ /HOSTED_RETRY_MAX\b(.*)/s;
    ok($afterCap && $afterCap =~ /setTimer/,
       '...and an unspent budget still retries on the deadline rather than missing');

    # THE BUDGET MUST BE THREADED THROUGH THE RETRY. `$st` is what carries the
    # count across reschedules; if the timer re-entered _hostedGet without it, the
    # counter would reset to 0 on every retry and the cap above would be inert —
    # the bug would read as fixed while behaving exactly as before.
    ok(scalar($get =~ /_hostedGet\(\$path, \$onFound, \$onMiss, \$st\)/),
       'the retry carries the budget with it, so the cap cannot reset itself');

    # The OTHER way back into this sub. Standing down on somebody else's deadline
    # is not this caller's 429, so it gets its own looser budget — but it needs a
    # bound too, or a permanently-busy deadline is the same hang by another route.
    my ($waitBlock) = $get =~ /if \(\(my \$wait = _hostedWait\(\)\) > 0\)\s*\{(.*?)\n    \}/s;
    ok($waitBlock && $waitBlock =~ /\$st->\{waits\}\+\+ >= HOSTED_WAIT_MAX/
                  && $waitBlock =~ /\$onMiss->\(/,
       'the shared-deadline wait is bounded separately, and falls back when spent');
    ok(scalar($get =~ /_hostedNoteOk\(\)/), 'and a success clears the backoff');

    # AND THE RETRY IS SCHEDULED OFF THE DEADLINE IN FORCE, not off this caller's
    # own fresh backoff — which may be shorter than one another caller is holding,
    # in which case waking early only spends a wait slot rediscovering it.
    ok(scalar($get =~ /_hostedNoteLimit\(\);/) && scalar($get =~ /my \$wait = _hostedWait\(\);/),
       'the 429 retry waits out the shared deadline, not its own backoff');

    # HAGEN_CONCURRENCY went with the hosted ARTIST rung in 0.9.173. The pacing
    # machinery above (_hostedWait / _hostedNoteLimit / the 429 backoff) is NOT
    # dead with it — getAlbumGenresHosted still goes through the same _hostedGet
    # funnel, so the backoff still governs every hosted request the plugin makes.
    # That is why this section is kept rather than deleted alongside the rung.
    # THE DECLARATION, not any mention: the comment recording why the rung went
    # names the constant, and an assertion a comment can flip pins nothing.
    ok(!scalar($api_src =~ /^use constant HAGEN_CONCURRENCY/m),
       'the removed rung took its concurrency constant with it');
    ok(scalar($api_src =~ /sub _hostedWait\b/) && scalar($api_src =~ /sub _hostedNoteLimit\b/),
       '...but the shared 429 backoff survives, because the ALBUM route still uses it');
}

package G11B::R;
sub new { my ($c, %a) = @_; bless {%a}, $c }
sub code { $_[0]->{code} }
sub error { $_[0]->{err} }
package main;

# ===========================================================================
print "\n12. THE GENRE LADDER STARTS FIRST — not behind the streaming work\n";
print "-" x 74, "\n";
{
    # WHAT THIS PINS. _warmGenres used to be chained LAST in warmCache, behind the
    # created-for playlists (every track resolved against the streaming services),
    # the follow feed, and the whole trending build. Measured on the live server
    # that put the ladder many minutes into the tick, and the ladder's own tail is
    # slow by design (Last.fm at one request per second) — so after every install
    # views opened bare for a long window, which is what "it still renders when it
    # has none" turned out to be.
    #
    # Source-level, because there is no return value to inspect: the property is
    # WHERE in the chain the call sits, and the failure mode is silent.
    my $warm = grab($browse_src, 'warmCache');

    my $genres    = index($warm, '_warmGenres();');
    my $playlists = index($warm, 'getCreatedForPlaylists');
    ok($genres >= 0, 'warmCache still starts the genre ladder at all');
    ok($genres < $playlists,
       'and starts it BEFORE the playlist/follow/trending chain, not after it');

    # Exactly one call site — a second one would double every request in the ladder.
    my $n = () = $warm =~ /_warmGenres\(\)/g;
    is($n, 1, 'exactly once — not kicked again at the end of the chain');

    # The ladder itself must keep its own order, which is the whole point of the
    # tiers: each rung only asks about what the cheaper one could not answer.
    my $wg = grab($browse_src, '_warmGenres');
    my $lb  = index($wg, '_withGenres(');
    my $lfm = index($wg, '_warmLastfm(');
    ok($lb >= 0 && $lfm > $lb,
       'and the rungs stay in ladder order: ListenBrainz, then Last.fm');

    # Each rung is handed the WHOLE-FEED bound. A rung capped at a per-pass quota
    # cannot prepare a feed however many nights pass — the 0.9.165 lesson, which was
    # applied to the ListenBrainz rung and left off the ones below it.
    ok(scalar($wg =~ /GENRE_WARM_ALL/),  'the ListenBrainz rung gets the whole-feed bound');
    ok(scalar($wg =~ /LFM_WARM_ALL/),    '...and so does Last.fm');
}

print "\n13. MUSICBRAINZ RATE LIMITING — the sort warm defers instead of burning\n";
print "-" x 74, "\n";
{
    # The third network path finally gets what the other two always had. MEASURED
    # 2026-08-22 against the live public API: two 503s inside eight requests paced
    # at 1.2s — WIDER than the 1.1s courtesy gap this code applies — so a pass that
    # ignores the limit burns all 100 artists, stores none of them (an HTTP error is
    # deliberately not cached) and re-queues the identical batch on the next open.
    my $isLim = grab($api_src, '_mbIsRateLimited');
    my $note  = grab($api_src, '_mbNoteLimit');
    my $wait  = grab($api_src, '_mbWait');
    eval "package G13;
        use constant MB_BACKOFF_START => 5;
        use constant MB_BACKOFF_MAX   => 30;
        our \$mbBusyUntil = 0;
        our \$mbDelay     = 0;
        my \$log = G13::Log->new;
        $isLim $note $wait 1;
      package G13::Log; sub new { bless {}, shift } sub warn {} sub info {} 1;" or die $@;

    { package G13::Resp;
      sub new   { my ($c, %a) = @_; bless { %a }, $c }
      sub code  { $_[0]{code} }
      sub error { $_[0]{error} }
    }

    # 503 IS THE ONE THAT MATTERS. MusicBrainz throttles with 503, not the 429 the
    # other two services use — a backoff copied from the hosted side without this
    # would never fire at all.
    ok( G13::_mbIsRateLimited(G13::Resp->new(code => 503)),
       'a 503 is MusicBrainz saying "slow down" — the case a 429-only check misses');
    ok( G13::_mbIsRateLimited(G13::Resp->new(code => 429)), '...and a 429 still counts');
    ok( G13::_mbIsRateLimited(undef, '503 Service Temporarily Unavailable'),
       '...and so does a limit that only ever appears in the error STRING');
    ok( G13::_mbIsRateLimited(undef, 'Your requests are exceeding the allowable rate limit'),
       '...including MB\'s own wording, which carries no status code at all');
    ok(!G13::_mbIsRateLimited(G13::Resp->new(code => 404)), 'a 404 is a real answer, not a limit');
    ok(!G13::_mbIsRateLimited(undef, 'connect timeout'),    'nor is a timeout');
    ok(!G13::_mbIsRateLimited(undef, undef),                'nor is no response at all');

    # The curve, and the shared deadline that only ever moves OUTWARD.
    $G13::mbBusyUntil = 0; $G13::mbDelay = 0;
    my $d1 = G13::_mbNoteLimit();
    my $d2 = G13::_mbNoteLimit();
    ok($d1 == 5 && $d2 == 10, "the backoff doubles  ->  ${d1}s then ${d2}s");
    $G13::mbDelay = 30;
    ok(G13::_mbNoteLimit() == 30, 'and caps at 30s rather than growing without bound');
    ok(G13::_mbWait() > 0, 'the deadline is shared, so a second caller sees it too');

    # A later success resets the CURVE; it must not pull a deadline still in force
    # back in — the trap _hostedNoteLimit documents and this copies deliberately.
    my $far = $G13::mbBusyUntil;
    $G13::mbDelay = 0;
    G13::_mbNoteLimit();
    ok($G13::mbBusyUntil >= $far, 'a fresh limit never SHORTENS a window already running');

    # THE SILENT-HOLE GUARD. The reservation is what stops a second pass
    # re-fetching a queued MBID, so a pass that abandons its queue must hand every
    # unfetched MBID back. Miss this and they stay marked in flight for the life of
    # the process, the in-flight guard excludes them from EVERY later pass, and the
    # result is indistinguishable from "MusicBrainz has no sort-name for these".
    my $warm = grab($api_src, 'warmArtistSorts');
    ok(scalar($warm =~ /\$release\s*=\s*sub\s*\{[^}]*delete\s+\$sortInFlight\{\$_\}\s+for\s+\@todo/s),
       'the abandon path releases the WHOLE reservation, not just the current MBID');
    ok(scalar($warm =~ /_mbIsRateLimited/), 'the error handler tells a rate limit from a real failure');
    ok(scalar($warm =~ /_mbNoteOk/),        'and a success clears the curve');

    # Don't start a pass into a limit that is already in force — otherwise the warm
    # re-enters on every artist-sorted open and rediscovers it one request at a time.
    my ($guard) = $warm =~ /(if \(\(my \$wait = _mbWait\(\)\).*?\n    \})/s;
    ok($guard && $guard =~ /\$release->\(\)/ && $guard =~ /return/,
       'a pass that starts inside the deadline stands down and releases its claim');
}

# ===========================================================================
print "\n14. THE LADDER MUST ALWAYS CALL BACK — an artist-only list is not an empty one\n";
print "-" x 74, "\n";
# BEHAVIOURAL, and it has to be: the defect is "the chain simply stops", which no
# pattern match can show. The real _withGenresLB is driven over stubbed timers.
#
# THE BUG: @batches is built from release-group MBIDs, and the launch loop runs
# `1 .. $starts` where $starts is 0 for an empty @batches — so $step never ran and
# $cb was never called at all. The all-empty case is guarded upstream in
# _withGenres; the reachable hole is the MIXED one 0.9.174 deliberately introduced
# (@rels empty, @artOnly non-empty) — rows with an artist credit and no release
# group, which is the Trending shape the @artOnly budget was added for.
#
# It strands the WARM: _warmGenres chains For You -> Last.fm -> $warmAll, so a For
# You pass that filters down to artist-only rows leaves genres_foryou 'running' for
# ever and All Releases is never warmed for that tick.
{
    my $pkg = <<'CODE';
package G14;
our @SCHEDULED;      # timers, fired only when the test drains them
our @FETCHED;        # every batch that reached the metadata endpoint

package Slim::Utils::Timers;
sub setTimer { my ($obj, $when, $cb, @args) = @_; push @G14::SCHEDULED, [$cb, $obj, @args]; 1 }

package G14::API;
sub getReleaseGroupMetadata {
    my ($class, $batch, $cb) = @_;
    push @G14::FETCHED, [@$batch];
    $cb->({ map { $_ => { genres => ['rock'] } } @$batch });
}

package Plugins::ListenBrainzFreshReleases::Browse;
use constant GENRE_BATCH       => 50;
use constant GENRE_CONCURRENCY => 4;
sub _mergeHostedGenres  { 1 }
sub _kickGenreFill      { 1 }
sub _rgAnswered         { 1 }
sub _artistRungMissing  { 0 }
CODE
    # The sub calls the API by its real package name, so the stub has to answer to
    # it. Aliased rather than defined, because other sections in this file eval the
    # REAL getReleaseGroupMetadata into that package and a second definition here
    # would depend on which section ran first.
    $pkg .= grab($browse_src, '_withGenresLB') . "\npackage G14;\n1;\n";
    eval $pkg or die "G14 eval: $@";
    {
        no warnings 'redefine', 'once';
        *Plugins::ListenBrainzFreshReleases::API::getReleaseGroupMetadata =
            \&G14::API::getReleaseGroupMetadata;
    }

    my $run = sub {
        my ($rels, $artOnly) = @_;
        @G14::SCHEDULED = ();
        @G14::FETCHED   = ();
        my $called = 0;
        Plugins::ListenBrainzFreshReleases::Browse::_withGenresLB(
            $rels, $artOnly, sub { $called++ }, 0, 0);
        # Drain the timer queue the way the event loop would. Bounded: a chain that
        # reschedules for ever is a failure too, not a reason to hang the suite.
        my $spins = 0;
        while (@G14::SCHEDULED && $spins++ < 500) {
            my $t = shift @G14::SCHEDULED;
            my ($cb, @args) = @$t;
            $cb->(@args);
        }
        return { called => $called, fetched => scalar @G14::FETCHED };
    };

    my $rg   = { release_group_mbid => 'rg-1', artist_credit_name => 'A' };
    my $bare = { artist_credit_name => 'B' };

    # The controls first: if these two were not already green the assertion below
    # would be measuring the harness rather than the fix.
    my $r1 = $run->([$rg], []);
    is($r1->{called},  1, 'a release-group list calls back exactly once');
    is($r1->{fetched}, 1, '...having fetched its one batch');

    my $r2 = $run->([$rg], [$bare]);
    is($r2->{called},  1, 'a MIXED list calls back too');
    is($r2->{fetched}, 1, '...still one batch — the artist-only row adds no lookup');

    # THE DEFECT.
    my $r3 = $run->([], [$bare]);
    is($r3->{called},  1, 'an ARTIST-ONLY list still calls back');
    is($r3->{fetched}, 0, '...without inventing a lookup it has no MBID for');

    # Exactly once, not "at least once" — a guard bolted on ahead of a $step that
    # also fires would double-answer, and every caller here does real work.
    my $r4 = $run->([], []);
    is($r4->{called}, 1, 'and a wholly empty list answers once, never twice');

    # The mirror path is the precedent, and it must keep it — the two paths are
    # selected by a pref, so a hole in either is invisible on a box using the other.
    # PROPERTY, NOT BYTES. This first pinned the guard's exact source line and went
    # red the moment §15 gave that branch a release-group lookup to do before
    # calling back — a correct change failing a test that had encoded one spelling
    # of the behaviour. What matters is that the branch answers and stops.
    my $mir = grab($browse_src, '_withGenresMirror');
    my ($noArtists) = $mir =~ /unless \(\@artists\)\s*\{(.*?)\n    \}/s;
    $noArtists = $1 if !defined $noArtists && $mir =~ /unless \(\@artists\)\s*\{([^}]*)\}/;
    ok(scalar(defined $noArtists && $noArtists =~ /\$cb->\(/ && $noArtists =~ /\breturn\b/),
       'the mirror path still carries the guard the LB path was missing');
}

# ===========================================================================
print "\n15. MIRROR MODE REACHES THE RELEASE-GROUP TIERS (1 and 1b)\n";
print "-" x 74, "\n";
# `detail_genres` reaches $meta only through DB::rgGet — peekReleaseGroupMetadataBulk
# and getReleaseGroupMetadata, BOTH ON THE LB PATH. Mirror mode built $meta purely
# from artist rows (_metaFromArtists hard-codes `genres => []` and never reads the
# release_group row), so tier 1b was unreachable there and opening an album still
# threw its answer away as far as the list was concerned. It is the DEFAULT path on
# any server with a local MusicBrainz mirror.
#
# Driven end to end — _withGenresMirror to build the map, then the REAL _genresFor
# over it — because the property is "which tier answers", and asserting on the map
# alone would not show that an artist proxy still outranks the record.
{
    my $pkg = <<'CODE';
package G15;
our %ARTIST_ROWS;    # artist mbid  => [genres]
our %RG_ROWS;        # rg mbid      => { detail_genres => [...] }
our $RG_READS = 0;   # bulk reads issued, so "one per page" stays testable

package G15::API;
sub peekArtistGenresBulk {
    my ($class, $mbids) = @_;
    my %o; for (@$mbids) { $o{lc $_} = $G15::ARTIST_ROWS{lc $_} if $G15::ARTIST_ROWS{lc $_} } \%o;
}
sub peekReleaseGroupMetadataBulk {
    my ($class, $mbids) = @_;
    $G15::RG_READS++;
    my %o; for (@$mbids) { $o{lc $_} = $G15::RG_ROWS{lc $_} if $G15::RG_ROWS{lc $_} } \%o;
}
sub getArtistGenres { my ($class, $a, $cb) = @_; $cb->($class->peekArtistGenresBulk($a)) }

package Plugins::ListenBrainzFreshReleases::Browse;
sub _mergeHostedGenres { 1 }
sub _kickGenreFill     { 1 }
sub _artistRungMissing { 0 }
sub _hostedArtistKey   { my $r = shift; my $a = $r->{artist_mbids}; ref $a eq 'ARRAY' && $a->[0] ? 'a:' . lc $a->[0] : undef }
sub _lbArtistGenres    { () }
sub _lastfmGenres      { () }
sub _releaseTags       { () }
sub LB_MARK            { '__lb' }
sub LFM_MARK           { '__lfm' }
CODE
    $pkg .= grab($browse_src, '_withGenresMirror');
    $pkg .= grab($browse_src, '_mergeRgGenres');
    $pkg .= grab($browse_src, '_metaFromArtists');
    $pkg .= grab($browse_src, '_genresFor');
    $pkg .= "\npackage G15;\n1;\n";
    eval $pkg or die "G15 eval: $@";
    {
        no warnings 'redefine', 'once';
        *Plugins::ListenBrainzFreshReleases::API::peekArtistGenresBulk =
            \&G15::API::peekArtistGenresBulk;
        *Plugins::ListenBrainzFreshReleases::API::peekReleaseGroupMetadataBulk =
            \&G15::API::peekReleaseGroupMetadataBulk;
        *Plugins::ListenBrainzFreshReleases::API::getArtistGenres =
            \&G15::API::getArtistGenres;
    }

    my $B = 'Plugins::ListenBrainzFreshReleases::Browse';
    my $genresOf = sub {
        my ($rels, $peek) = @_;
        $G15::RG_READS = 0;
        my $meta;
        $B->can('_withGenresMirror')->($rels, [], sub { $meta = shift }, $peek, 0);
        return [ map { [ $B->can('_genresFor')->($_, $meta) ] } @$rels ];
    };

    my $rel = { release_group_mbid => 'RG-1', artist_mbids => ['amb-1'] };

    # (a) the record's own answer, and NO artist answer at all: before the fix the
    #     map had no entry for this release group whatsoever.
    %G15::ARTIST_ROWS = ();
    %G15::RG_ROWS     = ('rg-1' => { detail_genres => ['ambient'] });
    for my $peek (1, 0) {
        my $got = $genresOf->([$rel], $peek);
        is(join(',', @{ $got->[0] }), 'ambient',
           "the detail page's answer reaches the list (" . ($peek ? 'peek' : 'fetch') . ")");
    }

    # (b) THE TIER ORDER, which is the whole point of 1b: a record-level answer
    #     must outrank the artist proxy, not merely be present somewhere.
    %G15::ARTIST_ROWS = ('amb-1' => ['jazz']);
    my $got = $genresOf->([$rel], 1);
    is(join(',', @{ $got->[0] }), 'ambient',
       'and it OUTRANKS the artist genres, as _genresFor ranks it');

    # (b2) TIER 1 — the album's OWN ListenBrainz tags, in the same store row. Mirror
    #      mode ignored this column for the same reason it ignored 1b, and a mirror
    #      box DOES hold answers here: getReleaseGroupMetadata is called by the two
    #      Trending passes regardless of genre mode, and carries `inc=release_group
    #      tag`. So a mirror user who had browsed Trending saw the artist proxy over
    #      an album-level answer that was already stored.
    %G15::RG_ROWS = ('rg-1' => { genres => ['post-rock'], detail_genres => ['ambient'] });
    $got = $genresOf->([$rel], 1);
    is(join(',', @{ $got->[0] }), 'post-rock',
       "the album's OWN tags outrank both the detail answer and the artist");

    # ...and the ORDER below it is unchanged: with no tier 1, 1b still wins.
    %G15::RG_ROWS = ('rg-1' => { detail_genres => ['ambient'] });
    $got = $genresOf->([$rel], 1);
    is(join(',', @{ $got->[0] }), 'ambient', '...with tier 1b still ahead of the artist');

    # An EMPTY column must not overwrite the filled slot beside it — the two share
    # one $meta entry, so a blanket assignment would blank whichever landed second.
    %G15::RG_ROWS = ('rg-1' => { genres => [], detail_genres => ['ambient'] });
    $got = $genresOf->([$rel], 1);
    is(join(',', @{ $got->[0] }), 'ambient',
       'an empty tier-1 column does not erase the tier-1b answer');

    # (c) the artist rung is untouched where the record has nothing to say.
    %G15::RG_ROWS = ();
    $got = $genresOf->([$rel], 1);
    is(join(',', @{ $got->[0] }), 'jazz',
       'with no detail answer the artist tier still answers, unchanged');

    # (d) ONE bulk read for the page. A per-row read here is the ~2,900 synchronous
    #     SELECTs bench_walk caught in 0.9.165 and the hazard 0.9.130 removed.
    %G15::RG_ROWS = map { ("rg-$_" => { detail_genres => ['ambient'] }) } 1 .. 5;
    my @many = map { { release_group_mbid => "RG-$_", artist_mbids => ['amb-1'] } } 1 .. 5;
    $genresOf->(\@many, 1);
    is($G15::RG_READS, 1, 'five releases cost ONE bulk read, not one per release');

    # (e) the no-artist-MBID branch. The artist rungs have nothing to look up, but a
    #     release-group answer does not depend on them — it used to answer {}.
    %G15::ARTIST_ROWS = ();
    %G15::RG_ROWS     = ('rg-1' => { detail_genres => ['ambient'] });
    $got = $genresOf->([ { release_group_mbid => 'RG-1' } ], 0);
    is(join(',', @{ $got->[0] }), 'ambient',
       'a list with no artist MBIDs still gets the record-level answer');

    # ...and that branch must still CALL BACK, which is the §14 property arriving
    # from the other side: it is the guard the LB path was missing.
    my $called = 0;
    $B->can('_withGenresMirror')->([], [], sub { $called++ }, 0, 0);
    is($called, 1, '...and an empty list still calls back exactly once');
}

print "\n", "=" x 74, "\n";
print "$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
